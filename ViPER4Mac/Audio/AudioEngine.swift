import AudioToolbox
import CoreAudio
import Foundation

private let logger = AppLogger(category: "AudioEngine")

private let kOutputBus: AudioUnitElement = 0

struct OutputDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

final class AudioEngine {
    static let shared = AudioEngine()

    let viperBridge = ViPERBridge()
    private let viperDeviceUID = "ViPER4Mac_VirtualDevice" as CFString

    private var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var originalDefaultDeviceID: AudioDeviceID = kAudioObjectUnknown

    private var outputUnit: AudioUnit?
    private var inputIOProcID: AudioDeviceIOProcID?

    private var isRunning = false
    private var settingDevice = false
    private var deviceListenerInstalled = false
    private var deviceListChangedListenerInstalled = false
    private var volumeListenerInstalled = false
    var onOutputDeviceChanged: (() -> Void)?

    var processingEnabled = true {
        didSet {
            guard isRunning, processingEnabled != oldValue else { return }
            if processingEnabled {
                settingDevice = true
                setDefaultOutputDevice(inputDeviceID)
                setDefaultSystemOutputDevice(inputDeviceID)
                settingDevice = false
            } else {
                settingDevice = true
                setDefaultOutputDevice(outputDeviceID)
                setDefaultSystemOutputDevice(outputDeviceID)
                settingDevice = false
            }
        }
    }

    fileprivate var inputCallbackCount: UInt64 = 0
    fileprivate var outputCallbackCount: UInt64 = 0

    // MARK: - Ring Buffer (Swift-side, between IOProc and AUHAL)
    private var ringBuffer: UnsafeMutablePointer<Float>?
    fileprivate let ringCapacityFrames = 8192
    let channelCount: UInt32 = 2
    private var ringWritePos: Int = 0
    private var ringReadPos: Int = 0
    fileprivate var ringLock = os_unfair_lock()

    // MARK: - Shared Memory (from driver)
    private var inputASBD = AudioStreamBasicDescription()
    fileprivate var sharedRingPtr: UnsafeMutableRawPointer?
    private var sharedMappedSize: Int = 0

    // MARK: - DSP temp buffer
    fileprivate var dspTempBuffer: UnsafeMutablePointer<Float>?
    fileprivate let dspTempBufferFrames = 4096

    // MARK: - Software volume
    fileprivate var currentVolume: Float = 1.0
    fileprivate var currentlyMuted: Bool = false
    fileprivate var volumeLock = os_unfair_lock()

    // MARK: - Buffer frame size (from HAL, used in IOProc)
    fileprivate var inputBufferFrameSize: UInt32 = 512

    // MARK: - AudioConverter (ASRC for clock drift between devices)
    fileprivate var audioConverter: AudioConverterRef?
    fileprivate var converterInputRate: Float64 = 48000
    fileprivate var converterOutputRate: Float64 = 44100
    fileprivate var isConverterActive = false

    // Intermediate buffer for converter input — filled by IOProc, drained by converter
    fileprivate var srcBuffer: UnsafeMutablePointer<Float>?
    fileprivate var srcBufferFrames: Int = 0
    fileprivate var srcBufferCapacity: Int = 8192
    fileprivate var srcLock = os_unfair_lock()


    // MARK: - Adaptive Sample Rate Conversion (ASRC) for clock drift compensation
private var targetRingLevel: Int = 4096  // 50% of 8192 capacity
private let driftToleranceFrames: Int = 512  // ±12% tolerance band
private var effectiveOutputRate: Double = 44100.0
private let rateAdjustmentStep: Double = 0.0001  // Tiny nudges (0.01%)
private var conversionBuffer: UnsafeMutablePointer<Float>?
private let conversionBufferFrames: Int = 8192

// MARK: - Ring-level PLL for clock drift correction
// When both devices run at the same nominal rate (e.g. 44100 Hz),
// independent hardware oscillators drift apart by ~10-100 ppm.
// This PLL nudges frame consumption to keep the ring buffer stable.
fileprivate var pllDriftAccumulator: Int = 0
fileprivate let pllTargetFrames: Int = 3072    // ~37% of 8192 — steady-state target
fileprivate let pllDeadband: Int = 512         // ±512 frames tolerance before correcting
fileprivate let pllCorrectionInterval: Int = 100  // Check every 100 IOProc callbacks
fileprivate var pllCallbacksSinceLastCorrection: Int = 0

    // MARK: - Init

    private init() {
    let totalSamples = ringCapacityFrames * Int(channelCount)
    ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
    ringBuffer?.initialize(repeating: 0.0, count: totalSamples)

    let tempSamples = dspTempBufferFrames * Int(channelCount)
    dspTempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: tempSamples)
    dspTempBuffer?.initialize(repeating: 0.0, count: tempSamples)

    let srcSamples = srcBufferCapacity * Int(channelCount)
    srcBuffer = UnsafeMutablePointer<Float>.allocate(capacity: srcSamples)
    srcBuffer?.initialize(repeating: 0.0, count: srcSamples)
    
    // NEW: Allocate conversion buffer for ASRC
    let convSamples = conversionBufferFrames * Int(channelCount)
    conversionBuffer = UnsafeMutablePointer<Float>.allocate(capacity: convSamples)
    conversionBuffer?.initialize(repeating: 0.0, count: convSamples)
}

    deinit {
    stop()
    ringBuffer?.deallocate()
    dspTempBuffer?.deallocate()
    srcBuffer?.deallocate()
    conversionBuffer?.deallocate()  // NEW
    if let conv = audioConverter {
        AudioConverterDispose(conv)
    }
}

    // MARK: - Start / Stop

    func start() {
        logger.info("AudioEngine.start() ENTERED")
        guard !isRunning else {
            logger.info("AudioEngine.start() bailed: already running")
            return
        }

        guard let viperDevice = findViPERDevice() else {
            logger.error("Virtual device not found. Is the driver installed?")
            return
        }
        inputDeviceID = viperDevice

        let currentDefault = getDefaultOutputDevice()
        let viperUID = viperDeviceUID as String
        if getDeviceUID(currentDefault) != viperUID {
            originalDefaultDeviceID = currentDefault
        }

        guard let realDevice = findRealOutputDevice() else {
            logger.error("No real output device found.")
            return
        }
        outputDeviceID = realDevice

        if originalDefaultDeviceID == kAudioObjectUnknown {
            originalDefaultDeviceID = realDevice
        }

        let matchedRate: Float64 = 44100.0
        viperBridge.setSamplingRate(UInt32(matchedRate))
        logger.info("Hardcoded to 44100 Hz (no rate matching needed)")
        
        // Read buffer frame size AFTER rate change has settled
        inputBufferFrameSize = getBufferFrameSize(for: inputDeviceID)
        logger.info(
            "AudioEngine: virtual=\(viperDevice) output=\(realDevice) matchedRate=\(matchedRate) bufferFrames=\(inputBufferFrameSize)"
        )

        mapSharedMemory()

        guard setupInputIOProc() else {
            logger.error("Input IOProc setup failed")
            return
        }

        let outputRate = getSampleRate(for: outputDeviceID)

        inputASBD.mSampleRate = matchedRate
        inputASBD.mFormatID = kAudioFormatLinearPCM
        inputASBD.mFormatFlags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        inputASBD.mBitsPerChannel = 32
        inputASBD.mChannelsPerFrame = channelCount
        inputASBD.mBytesPerFrame = channelCount * UInt32(MemoryLayout<Float>.size)
        inputASBD.mFramesPerPacket = 1
        inputASBD.mBytesPerPacket = inputASBD.mBytesPerFrame

        setupAudioConverter(inputRate: matchedRate, outputRate: outputRate)

        guard setupOutputUnit() else {
            logger.error("Output AUHAL setup failed")
            teardownInputIOProc()
            return
        }

        settingDevice = true
        setDefaultOutputDevice(inputDeviceID)
        setDefaultSystemOutputDevice(inputDeviceID)
        settingDevice = false

        var status = AudioDeviceStart(inputDeviceID, inputIOProcID!)
        if status != noErr {
            logger.error("AudioDeviceStart failed: \(status)")
            settingDevice = true
            setDefaultOutputDevice(outputDeviceID)
            setDefaultSystemOutputDevice(outputDeviceID)
            settingDevice = false
            teardownInputIOProc()
            disposeOutputUnit()
            return
        }

        status = AudioOutputUnitStart(outputUnit!)
        if status != noErr {
            logger.error("AudioOutputUnitStart failed: \(status)")
            AudioDeviceStop(inputDeviceID, inputIOProcID!)
            settingDevice = true
            setDefaultOutputDevice(outputDeviceID)
            setDefaultSystemOutputDevice(outputDeviceID)
            settingDevice = false
            teardownInputIOProc()
            disposeOutputUnit()
            return
        }

        let actualDefault = getDefaultOutputDevice()
        let actualDefaultName = getDeviceName(actualDefault)
        logger.info("After start: default output is '\(actualDefaultName)' (should be ViPER4Mac)")

        isRunning = true
        installDeviceListListener()
        installVolumeListeners()
        logger.info(
            "Audio engine started. Virtual=\(inputDeviceID) Output=\(outputDeviceID) DSP=\(processingEnabled) matchedRate=\(matchedRate) outputRate=\(outputRate) bufferFrames=\(inputBufferFrameSize) converter=\(isConverterActive)"
        )
    }

    func stop() {
        guard isRunning else { return }

        removeDeviceListListener()
        removeVolumeListeners()

        if let procID = inputIOProcID {
            AudioDeviceStop(inputDeviceID, procID)
        }
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
        }

        teardownInputIOProc()
        disposeOutputUnit()
        disposeAudioConverter()
        unmapSharedMemory()

        var restoreDevice = originalDefaultDeviceID
        let viperUID = viperDeviceUID as String
        if restoreDevice == kAudioObjectUnknown || getDeviceUID(restoreDevice) == viperUID {
            restoreDevice = outputDeviceID
        }
        if restoreDevice != kAudioObjectUnknown && getDeviceUID(restoreDevice) != viperUID {
            settingDevice = true
            setDefaultOutputDevice(restoreDevice)
            setDefaultSystemOutputDevice(restoreDevice)
            settingDevice = false
        }

        ringWritePos = 0
        ringReadPos = 0

        os_unfair_lock_lock(&srcLock)
        srcBufferFrames = 0
        pllDriftAccumulator = 0
        pllCallbacksSinceLastCorrection = 0
        os_unfair_lock_unlock(&srcLock)

        inputCallbackCount = 0
        outputCallbackCount = 0

        isRunning = false
        logger.info("Audio engine stopped, restored output to device \(restoreDevice)")
    }

    // MARK: - Sample Rate Matching

@discardableResult
private func matchSampleRates() -> Float64 {
    let outputRate = getSampleRate(for: outputDeviceID)
    let currentVirtualRate = getSampleRate(for: inputDeviceID)

    logger.info("matchSampleRates: outputRate=\(outputRate) currentVirtualRate=\(currentVirtualRate)")

    if abs(currentVirtualRate - outputRate) < 1.0 {
        logger.info("matchSampleRates: already matched at \(outputRate)")
        // Even if already matched, wait for any in-progress IO restart to settle
        Thread.sleep(forTimeInterval: 0.3)
        return outputRate
    }

    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var rate = outputRate
    let setStatus = AudioObjectSetPropertyData(
        inputDeviceID, &propAddr, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &rate
    )

    if setStatus != noErr {
        logger.error("matchSampleRates: SetPropertyData failed status=\(setStatus)")
        return currentVirtualRate
    }

    // Phase 1: Wait for the rate to be acknowledged
    var actualRate: Float64 = currentVirtualRate
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
        actualRate = getSampleRate(for: inputDeviceID)
        if abs(actualRate - outputRate) < 1.0 {
            logger.info("matchSampleRates: rate confirmed=\(actualRate)")
            break
        }
        Thread.sleep(forTimeInterval: 0.02)
    }

    // Phase 2: CRITICAL — wait for HAL to complete StopIO/StartIO cycle
    // at the new rate. Without this, the driver's IO timeline is still
    // running at the old cadence when our IOProc attaches.
    // The HAL needs ~200-400ms to complete the IO restart sequence.
    logger.info("matchSampleRates: waiting for HAL IO restart at new rate...")
    Thread.sleep(forTimeInterval: 0.4)

    // Phase 3: Verify rate held after the restart
    let verifiedRate = getSampleRate(for: inputDeviceID)
    if abs(verifiedRate - outputRate) > 1.0 {
        logger.error("matchSampleRates: rate reverted after IO restart! verified=\(verifiedRate) wanted=\(outputRate)")
    } else {
        logger.info("matchSampleRates: rate stable after IO restart, verified=\(verifiedRate)")
    }

    logger.info("matchSampleRates: pushed=\(outputRate) final=\(verifiedRate)")
    return verifiedRate
}


    // MARK: - AudioConverter (ASRC)

fileprivate func setupAudioConverter(inputRate: Float64, outputRate: Float64) {
    disposeAudioConverter()

    converterInputRate = inputRate
    converterOutputRate = outputRate

    // Only activate converter when rates actually differ (e.g. 48000 → 44100).
    // Same-rate clock drift is handled by the ring-level PLL in the IOProc.
    if abs(inputRate - outputRate) < 1.0 {
        isConverterActive = false
        logger.info(
            "AudioConverter: rates match (\(inputRate) Hz) — using direct ring path with PLL drift correction"
        )
        return
    }

    var srcASBD = AudioStreamBasicDescription()
    srcASBD.mSampleRate = inputRate
    srcASBD.mFormatID = kAudioFormatLinearPCM
    srcASBD.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
    srcASBD.mBitsPerChannel = 32
    srcASBD.mChannelsPerFrame = channelCount
    srcASBD.mBytesPerFrame = channelCount * 4
    srcASBD.mFramesPerPacket = 1
    srcASBD.mBytesPerPacket = channelCount * 4

    var dstASBD = srcASBD
    dstASBD.mSampleRate = outputRate

    let status = AudioConverterNew(&srcASBD, &dstASBD, &audioConverter)
    if status != noErr {
        logger.error("AudioConverter: New failed status=\(status)")
        isConverterActive = false
        return
    }

    var quality = UInt32(kAudioConverterQuality_Max)
    AudioConverterSetProperty(
        audioConverter!,
        kAudioConverterSampleRateConverterQuality,
        UInt32(MemoryLayout<UInt32>.size),
        &quality
    )

    isConverterActive = true
    logger.info("AudioConverter: ACTIVE for rate conversion \(inputRate) → \(outputRate) Hz")
}

    private func disposeAudioConverter() {
        if let conv = audioConverter {
            AudioConverterDispose(conv)
            audioConverter = nil
        }
        isConverterActive = false
    }

    // MARK: - Shared Memory

    private func mapSharedMemory() {
        let shmPath = "/tmp/viper4mac_ring.bin"
        let fd = Darwin.open(shmPath, O_RDWR)
        if fd < 0 {
            logger.error("mapSHM: open failed errno=\(errno)")
            return
        }

        let structSize = MemoryLayout<ViPERSharedRing>.size
        logger.info("mapSHM: MemoryLayout<ViPERSharedRing>.size=\(structSize)")

        let ptr = Darwin.mmap(nil, structSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        Darwin.close(fd)

        if ptr == MAP_FAILED {
            logger.error("mapSHM: mmap failed errno=\(errno)")
            return
        }

        sharedRingPtr = ptr
        sharedMappedSize = structSize

        // FIX: Reset the SHM read pointer to match the current write pointer.
        // The driver starts writing to SHM as soon as coreaudiod loads it,
        // which can be seconds before the Swift app maps the memory and starts
        // its IOProc. Without this reset, the SHM ring is already full of stale
        // data when we start reading — we can never catch up, causing permanent
        // overflow in the driver and glitchy playback.
        let writePosPtr = ptr!.assumingMemoryBound(to: UInt64.self)
        let readPosPtr = ptr!.advanced(by: MemoryLayout<UInt64>.size).assumingMemoryBound(to: UInt64.self)
        let currentWP = writePosPtr.pointee
        readPosPtr.pointee = currentWP
        OSMemoryBarrier()
        logger.info("mapSHM: SUCCESS path=\(shmPath) size=\(structSize) — reset readPos to writePos=\(currentWP)")
    }

    private func unmapSharedMemory() {
        if let ptr = sharedRingPtr {
            munmap(ptr, sharedMappedSize)
            sharedRingPtr = nil
            sharedMappedSize = 0
        }
    }

    // MARK: - Input via IOProc (captures from virtual device)

    private func setupInputIOProc() -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            inputDeviceID,
            inputIOProcCallback,
            selfPtr,
            &procID
        )
        if status != noErr {
            logger.error("setupInputIOProc: CreateIOProcID err=\(status)")
            return false
        }
        inputIOProcID = procID
        return true
    }

    private func teardownInputIOProc() {
        if let procID = inputIOProcID {
            AudioDeviceDestroyIOProcID(inputDeviceID, procID)
            inputIOProcID = nil
        }
    }

    // MARK: - Output AUHAL (plays to real device)

    private func setupOutputUnit() -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            logger.error("setupOutputUnit: component not found")
            return false
        }

        var unit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let unit else {
            logger.error("setupOutputUnit: instance err=\(status)")
            return false
        }

        var deviceID = outputDeviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            kOutputBus,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.error("setupOutputUnit: SetDevice err=\(status)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        var asbd = inputASBD
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            kOutputBus,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if status != noErr {
            logger.error("setupOutputUnit: SetStreamFormat err=\(status)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: selfPtr
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            kOutputBus,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if status != noErr {
            logger.error("setupOutputUnit: SetRenderCallback err=\(status)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        status = AudioUnitInitialize(unit)
        if status != noErr {
            logger.error("setupOutputUnit: Initialize err=\(status)")
            AudioComponentInstanceDispose(unit)
            return false
        }

        outputUnit = unit
        return true
    }

    // MARK: - Dispose

    private func disposeOutputUnit() {
        if let unit = outputUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            outputUnit = nil
        }
    }

    // MARK: - Device Helpers

    private func getBufferFrameSize(for deviceID: AudioDeviceID) -> UInt32 {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 512
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &propAddr, 0, nil, &dataSize, &size
        )
        if status != noErr {
            logger.error("getBufferFrameSize: failed status=\(status), using 512")
            return 512
        }
        return size
    }

    // MARK: - Device Change Handling

    private func installDeviceListListener() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        if !deviceListenerInstalled {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                engineDeviceChangedCallback,
                selfPtr
            )
            if status == noErr {
                deviceListenerInstalled = true
            } else {
                logger.error("Failed to install default device listener: \(status)")
            }
        }

        if !deviceListChangedListenerInstalled {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                engineDeviceListChangedCallback,
                selfPtr
            )
            if status == noErr {
                deviceListChangedListenerInstalled = true
            } else {
                logger.error("Failed to install device list listener: \(status)")
            }
        }

        logger.info("Engine device listeners installed")
    }

    private func installVolumeListeners() {
        guard inputDeviceID != kAudioObjectUnknown else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let s1 = AudioObjectAddPropertyListener(
            inputDeviceID, &volAddr, engineVolumeChangedCallback, selfPtr
        )
        let s2 = AudioObjectAddPropertyListener(
            inputDeviceID, &muteAddr, engineVolumeChangedCallback, selfPtr
        )
        if s1 == noErr && s2 == noErr {
            volumeListenerInstalled = true
            logger.info("Volume/mute listeners installed on virtual device")
        } else {
            logger.error("Failed to install volume listeners: vol=\(s1) mute=\(s2)")
        }

        syncVolumeToOutput()
    }

    private func removeVolumeListeners() {
        guard volumeListenerInstalled, inputDeviceID != kAudioObjectUnknown else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListener(
            inputDeviceID, &volAddr, engineVolumeChangedCallback, selfPtr
        )
        AudioObjectRemovePropertyListener(
            inputDeviceID, &muteAddr, engineVolumeChangedCallback, selfPtr
        )
        volumeListenerInstalled = false
    }

    func syncVolumeToOutput() {
        guard inputDeviceID != kAudioObjectUnknown else { return }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(inputDeviceID, &volAddr, 0, nil, &size, &volume)

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(inputDeviceID, &muteAddr, 0, nil, &muteSize, &muted)

        os_unfair_lock_lock(&volumeLock)
        currentVolume = volume
        currentlyMuted = (muted != 0)
        os_unfair_lock_unlock(&volumeLock)

        logger.info("Volume cached: vol=\(volume) muted=\(muted)")
    }

    private func removeDeviceListListener() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        if deviceListenerInstalled {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                engineDeviceChangedCallback,
                selfPtr
            )
            deviceListenerInstalled = false
        }

        if deviceListChangedListenerInstalled {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                engineDeviceListChangedCallback,
                selfPtr
            )
            deviceListChangedListenerInstalled = false
        }
    }

    func handleDefaultDeviceChanged() {
        guard isRunning, !settingDevice else { return }
        let newDefault = getDefaultOutputDevice()
        let viperUID = viperDeviceUID as String

        if getDeviceUID(newDefault) == viperUID {
            if processingEnabled { return }
            guard let fallback = findRealOutputDevice() else {
                logger.error("No fallback output found")
                return
            }
            if fallback == outputDeviceID { return }
            switchOutputDevice(to: fallback)
            return
        }

        if newDefault == outputDeviceID { return }
        if !hasOutputStreams(newDefault) { return }
        if !isDeviceAlive(newDefault) {
            logger.info("Ignoring change to dead device: \(getDeviceName(newDefault))")
            return
        }
        switchOutputDevice(to: newDefault)
    }

    func handleDeviceListChanged() {
        guard isRunning, !settingDevice else { return }

        let viperUID = viperDeviceUID as String
        let allDevices = getAllDeviceIDs()
        let outputStillExists =
            allDevices.contains(outputDeviceID)
            && hasOutputStreams(outputDeviceID)
            && getDeviceUID(outputDeviceID) != viperUID
            && isDeviceAlive(outputDeviceID)

        if outputStillExists {
            let newDefault = getDefaultOutputDevice()
            if getDeviceUID(newDefault) != viperUID
                && newDefault != outputDeviceID
                && hasOutputStreams(newDefault)
                && isDeviceAlive(newDefault)
            {
                switchOutputDevice(to: newDefault)
            }
            return
        }

        guard let fallback = findRealOutputDevice() else {
            logger.error("Device disappeared but no fallback output found")
            return
        }

        logger.info(
            "Output device disappeared: \(getDeviceName(outputDeviceID)) -> \(getDeviceName(fallback))"
        )
        switchOutputDevice(to: fallback)
    }

    func switchOutputDevice(to newDevice: AudioDeviceID) {
        let oldName = getDeviceName(outputDeviceID)
        let newName = getDeviceName(newDevice)
        logger.info("Switching output: \(oldName) -> \(newName)")

        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
        }
        disposeOutputUnit()
        disposeAudioConverter()

        outputDeviceID = newDevice
        originalDefaultDeviceID = newDevice

        let matchedRate = matchSampleRates()
        viperBridge.setSamplingRate(UInt32(matchedRate))
        inputASBD.mSampleRate = matchedRate

        inputBufferFrameSize = getBufferFrameSize(for: inputDeviceID)
        logger.info("switchOutputDevice: new bufferFrameSize=\(inputBufferFrameSize)")

        let outputRate = getSampleRate(for: outputDeviceID)
        setupAudioConverter(inputRate: matchedRate, outputRate: outputRate)

        guard setupOutputUnit() else {
            logger.error("Failed to setup output unit for new device")
            return
        }

        let status = AudioOutputUnitStart(outputUnit!)
        if status != noErr {
            logger.error("Failed to start output unit for new device: \(status)")
            disposeOutputUnit()
            return
        }

        os_unfair_lock_lock(&ringLock)
        ringWritePos = 0
        ringReadPos = 0
        os_unfair_lock_unlock(&ringLock)

        os_unfair_lock_lock(&srcLock)
        srcBufferFrames = 0
        os_unfair_lock_unlock(&srcLock)
        pllDriftAccumulator = 0
        pllCallbacksSinceLastCorrection = 0


        if processingEnabled {
            settingDevice = true
            setDefaultOutputDevice(inputDeviceID)
            setDefaultSystemOutputDevice(inputDeviceID)
            settingDevice = false
        }

        onOutputDeviceChanged?()
        logger.info(
            "Output re-routed to \(newName) matchedRate=\(matchedRate) outputRate=\(outputRate) bufferFrames=\(inputBufferFrameSize) converter=\(isConverterActive)"
        )
    }

    // MARK: - Ring Buffer (Swift-side)

    fileprivate func writeToRing(_ data: UnsafePointer<Float>, frameCount: Int) {
        guard let ring = ringBuffer else { return }
        let samplesToWrite = frameCount * Int(channelCount)
        let capacity = ringCapacityFrames * Int(channelCount)

        os_unfair_lock_lock(&ringLock)

        let used = (ringWritePos - ringReadPos + capacity) % capacity
        let available = capacity - used - 1

        if samplesToWrite > available {
            os_unfair_lock_unlock(&ringLock)
            return
        }

        for i in 0 ..< samplesToWrite {
            ring[(ringWritePos + i) % capacity] = data[i]
        }
        ringWritePos = (ringWritePos + samplesToWrite) % capacity
        os_unfair_lock_unlock(&ringLock)
    }

    // MARK: - ASRC Write (adaptive resampling for clock drift)

fileprivate func writeToRingWithASRC(_ data: UnsafePointer<Float>, frameCount: Int) {
    guard let converter = audioConverter,
          let convBuffer = conversionBuffer else {
        // Fallback to direct write if converter not ready
        writeToRing(data, frameCount: frameCount)
        return
    }
    
    // Adjust effective output rate based on ring buffer level
    let ringAvail = availableFrames()
    let drift = ringAvail - targetRingLevel
    
    // Apply tiny rate adjustment to absorb clock drift
    if abs(drift) > driftToleranceFrames {
        // Positive drift → ring filling → speed up output (increase effective rate)
        // Negative drift → ring draining → slow down output (decrease effective rate)
        let adjustment = Double(drift) * rateAdjustmentStep
        effectiveOutputRate = converterOutputRate * (1.0 + adjustment)
        
        // Clamp to ±0.5% to avoid audible artifacts
        let minRate = converterOutputRate * 0.995
        let maxRate = converterOutputRate * 1.005
        effectiveOutputRate = max(minRate, min(maxRate, effectiveOutputRate))
        
        // Update converter output rate
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: effectiveOutputRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount) * 4,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        AudioConverterSetProperty(
            converter,
            kAudioConverterCurrentOutputStreamDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outFormat
        )
        
        if inputCallbackCount % 1000 == 1 {
            logger.debug("ASRC: drift=\(drift) effectiveRate=\(String(format: "%.2f", effectiveOutputRate)) ringAvail=\(ringAvail)")
        }
    }
    
    // Prepare input buffer list (interleaved)
    var inputBuffer = AudioBuffer(
        mNumberChannels: channelCount,
        mDataByteSize: UInt32(frameCount * Int(channelCount) * 4),
        mData: UnsafeMutableRawPointer(mutating: data)
    )
    var inputBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: inputBuffer
    )
    
    // Prepare output buffer list
    var outputBuffer = AudioBuffer(
        mNumberChannels: channelCount,
        mDataByteSize: UInt32(conversionBufferFrames * Int(channelCount) * 4),
        mData: UnsafeMutableRawPointer(convBuffer)  // ✅ No force unwrap
    )
    var outputBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: outputBuffer
    )
    
    // Convert
    var outputPacketCount = UInt32(conversionBufferFrames)
    
    let status = AudioConverterFillComplexBuffer(
        converter,
        { (_, ioNumberDataPackets, ioData, _, inUserData) -> OSStatus in
            // Simple passthrough provider
            guard let inUserData else {
                ioNumberDataPackets.pointee = 0
                return -1
            }
            let inputListPtr = inUserData.assumingMemoryBound(to: AudioBufferList.self)
            ioData.pointee = inputListPtr.pointee
            return noErr
        },
        &inputBufferList,
        &outputPacketCount,
        &outputBufferList,
        nil
    )
    
    if status == noErr {
        let convertedFrames = Int(outputPacketCount)
        writeToRing(convBuffer, frameCount: convertedFrames)  // ✅ FIXED: removed the !
    } else if status != -1 {  // -1 is expected when no data available
        logger.error("ASRC: Conversion failed status=\(status), using direct path")
        writeToRing(data, frameCount: frameCount)
    }
}

    fileprivate func readFromRing(_ data: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let ring = ringBuffer else { return }
        let samplesToRead = frameCount * Int(channelCount)
        let capacity = ringCapacityFrames * Int(channelCount)

        os_unfair_lock_lock(&ringLock)
        let used = (ringWritePos - ringReadPos + capacity) % capacity
        if samplesToRead > used {
            // Not enough data — output silence for missing samples
            let availSamples = used
            for i in 0 ..< availSamples {
                data[i] = ring[(ringReadPos + i) % capacity]
            }
            for i in availSamples ..< samplesToRead {
                data[i] = 0.0
            }
            ringReadPos = (ringReadPos + availSamples) % capacity
        } else {
            for i in 0 ..< samplesToRead {
                data[i] = ring[(ringReadPos + i) % capacity]
            }
            ringReadPos = (ringReadPos + samplesToRead) % capacity
        }
        os_unfair_lock_unlock(&ringLock)
    }

    fileprivate func availableFrames() -> Int {
        let capacity = ringCapacityFrames * Int(channelCount)
        os_unfair_lock_lock(&ringLock)
        let available = (ringWritePos - ringReadPos + capacity) % capacity
        os_unfair_lock_unlock(&ringLock)
        return available / Int(channelCount)
    }

    // MARK: - SRC Buffer (feeds AudioConverter)

    fileprivate func appendToSrcBuffer(_ data: UnsafePointer<Float>, frameCount: Int) {
        guard let buf = srcBuffer else { return }
        let ch = Int(channelCount)

        os_unfair_lock_lock(&srcLock)
        let spaceFrames = srcBufferCapacity - srcBufferFrames
        let framesActual = min(frameCount, spaceFrames)
        if framesActual > 0 {
            let dstOffset = srcBufferFrames * ch
            memcpy(buf + dstOffset, data, framesActual * ch * MemoryLayout<Float>.size)
            srcBufferFrames += framesActual
        }
        os_unfair_lock_unlock(&srcLock)
    }

    fileprivate func consumeFromSrcBuffer(
        _ outData: UnsafeMutablePointer<Float>,
        maxFrames: Int
    ) -> Int {
        guard let buf = srcBuffer else { return 0 }
        let ch = Int(channelCount)

        os_unfair_lock_lock(&srcLock)
        let framesActual = min(maxFrames, srcBufferFrames)
        if framesActual > 0 {
            memcpy(outData, buf, framesActual * ch * MemoryLayout<Float>.size)
            let remaining = srcBufferFrames - framesActual
            if remaining > 0 {
                memmove(buf, buf + framesActual * ch, remaining * ch * MemoryLayout<Float>.size)
            }
            srcBufferFrames = remaining
        }
        os_unfair_lock_unlock(&srcLock)
        return framesActual
    }

    fileprivate func srcBufferAvailableFrames() -> Int {
        os_unfair_lock_lock(&srcLock)
        let f = srcBufferFrames
        os_unfair_lock_unlock(&srcLock)
        return f
    }

    // MARK: - Device Discovery

    private func findViPERDevice() -> AudioDeviceID? {
        for deviceID in getAllDeviceIDs() {
            if getDeviceUID(deviceID) == viperDeviceUID as String {
                return deviceID
            }
        }
        return nil
    }

    private func findRealOutputDevice() -> AudioDeviceID? {
        let viperUID = viperDeviceUID as String
        for deviceID in getAllDeviceIDs() {
            let uid = getDeviceUID(deviceID)
            if uid == viperUID { continue }
            if isDeviceAlive(deviceID) && hasOutputStreams(deviceID) {
                logger.info("findRealOutputDevice: found \(uid)")
                return deviceID
            }
        }
        logger.error("findRealOutputDevice: NO REAL OUTPUT DEVICE FOUND")
        return nil
    }

    private func getAllDeviceIDs() -> [AudioDeviceID] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &propAddr, 0, nil, &dataSize, &uid
        ) == noErr else { return "" }
        return uid as String
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &propAddr, 0, nil, &dataSize
        ) == noErr else { return false }
        return dataSize > 0
    }

    private func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &propAddr, 0, nil, &dataSize, &isAlive
        )
        return status == noErr && isAlive != 0
    }

    private func getDefaultOutputDevice() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceID
        )
        return deviceID
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
    }

    private func setDefaultSystemOutputDevice(_ deviceID: AudioDeviceID) {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
    }

    private func getSampleRate(for deviceID: AudioDeviceID) -> Float64 {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 48000.0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &dataSize, &sampleRate)
        return sampleRate
    }

    func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &propAddr, 0, nil, &dataSize, &name
        ) == noErr else { return "Unknown" }
        return name as String
    }

    // MARK: - Public Accessors

    var outputDeviceName: String {
        guard outputDeviceID != kAudioObjectUnknown else { return "None" }
        return getDeviceName(outputDeviceID)
    }

    var virtualDeviceInstalled: Bool {
        findViPERDevice() != nil
    }

    fileprivate var lastNonSilentTime: UInt64 = 0
    var lastNonSilentTimeMs: UInt64 { lastNonSilentTime }

    func getAvailableOutputDevices() -> [OutputDeviceInfo] {
        let viperUID = viperDeviceUID as String
        return getAllDeviceIDs().compactMap { deviceID in
            let uid = getDeviceUID(deviceID)
            guard uid != viperUID,
                  hasOutputStreams(deviceID),
                  isDeviceAlive(deviceID)
            else { return nil }
            return OutputDeviceInfo(
                id: deviceID,
                name: getDeviceName(deviceID),
                uid: uid
            )
        }
    }
}

// MARK: - IOProc Callback
// Runs on the HAL real-time thread. NO allocation, NO locks except os_unfair_lock.
// Reads from SHM ring (written by driver) → DSP → volume → ASRC → ring buffer.

private let inputIOProcCallback: AudioDeviceIOProc = {
    _, _, _, _, outputData, _, clientData -> OSStatus in
    guard let clientData else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
    engine.inputCallbackCount += 1

    let ch = Int(engine.channelCount)

    guard let shmPtr = engine.sharedRingPtr else {
        if engine.inputCallbackCount == 1 {
            logger.error("IOPROC: no shared memory")
        }
        return noErr
    }

    // SHM ring layout: [writePos: UInt64][readPos: UInt64][samples: Float...]
    let ringCapacity = Int(VIPER_SHM_RING_SAMPLES)
    let writePosPtr = shmPtr.assumingMemoryBound(to: UInt64.self)
    let readPosPtr = shmPtr
        .advanced(by: MemoryLayout<UInt64>.size)
        .assumingMemoryBound(to: UInt64.self)
    let samplesBase = shmPtr
        .advanced(by: MemoryLayout<UInt64>.size * 2)
        .assumingMemoryBound(to: Float.self)

    OSMemoryBarrier()
    let wp = Int(writePosPtr.pointee % UInt64(ringCapacity))
    let rp = Int(readPosPtr.pointee % UInt64(ringCapacity))

    let availSamples = wp >= rp
        ? wp - rp
        : ringCapacity - rp + wp

    let halBufferFrames = Int(engine.inputBufferFrameSize)

    // ── Guard 1: Don't overfill the Swift ring ────────────────────────────────
    let ringAvailFrames = engine.availableFrames()
    let ringCapFrames = engine.ringCapacityFrames

    if ringAvailFrames > (ringCapFrames * 80 / 100) {
        if engine.inputCallbackCount % 1000 == 1 {
            logger.debug(
                "IOPROC: Ring throttle (skip) ringPct=\(ringAvailFrames * 100 / ringCapFrames)%"
            )
        }
        return noErr
    }

    // ── Guard 2: SHM backlog recovery ────────────────────────────────────────
    let shmHighWater = ringCapacity * 85 / 100
    let isBehind = availSamples > shmHighWater
    let nominalFrames = min(halBufferFrames, engine.dspTempBufferFrames)
    let maxFrames = isBehind ? engine.dspTempBufferFrames : nominalFrames

    let availFrames = availSamples / ch
    guard availFrames > 0 else {
        if engine.inputCallbackCount % 5000 == 1 {
            logger.debug("IOPROC: SHM underrun avail=\(availSamples)")
        }
        return noErr
    }

    // ── PLL drift correction (same-rate path only) ────────────────────────────
    // When both devices run at the same nominal rate, independent oscillators
    // drift apart by ±10–100 ppm. Without correction the ring slowly fills
    // (virtual runs fast) or drains (virtual runs slow), causing pitch shift
    // and eventual glitches.
    //
    // Strategy: every pllCorrectionInterval callbacks, measure drift against
    // pllTargetFrames. If we're outside the deadband, steal or add 1 frame
    // from this batch to nudge the level back.
    var frameCount = min(availFrames, maxFrames)

    if !engine.isConverterActive {
        engine.pllCallbacksSinceLastCorrection += 1

        if engine.pllCallbacksSinceLastCorrection >= engine.pllCorrectionInterval {
            engine.pllCallbacksSinceLastCorrection = 0
            let drift = ringAvailFrames - engine.pllTargetFrames

            if drift > engine.pllDeadband && frameCount > 1 {
                // Ring filling → consume 1 extra frame to drain slightly faster
                frameCount = min(frameCount + 1, engine.dspTempBufferFrames)
                engine.pllDriftAccumulator += 1
                if engine.inputCallbackCount % 500 == 1 {
                    logger.debug(
                        "PLL: ring HIGH drift=\(drift) → +1 frame accumulated=\(engine.pllDriftAccumulator)"
                    )
                }
            } else if drift < -engine.pllDeadband && frameCount > 1 {
                // Ring draining → consume 1 fewer frame to let it refill
                frameCount = max(frameCount - 1, 1)
                engine.pllDriftAccumulator -= 1
                if engine.inputCallbackCount % 500 == 1 {
                    logger.debug(
                        "PLL: ring LOW drift=\(drift) → -1 frame accumulated=\(engine.pllDriftAccumulator)"
                    )
                }
            }
        }
    }

    let samplesToRead = frameCount * ch
    guard let tempBuf = engine.dspTempBuffer else { return noErr }

    // ── Read from SHM ─────────────────────────────────────────────────────────
    let readStart = rp
    for i in 0 ..< samplesToRead {
        tempBuf[i] = samplesBase[(readStart + i) % ringCapacity]
    }
    let newRp = (rp + samplesToRead) % ringCapacity
    readPosPtr.pointee = UInt64(newRp)
    OSMemoryBarrier()

    // ── Track non-silent time ─────────────────────────────────────────────────
    var maxSample: Float = 0.0
    for i in 0 ..< samplesToRead {
        let s = abs(tempBuf[i])
        if s > maxSample { maxSample = s }
    }
    if maxSample > 1e-6 {
        engine.lastNonSilentTime = UInt64(Date().timeIntervalSince1970 * 1000)
    }

    if engine.inputCallbackCount % 5000 == 1 {
        let ringPct = ringAvailFrames * 100 / max(ringCapFrames, 1)
        logger.debug(
            "IOPROC: frames=\(frameCount) max=\(String(format: "%.4f", maxSample)) shmAvail=\(availSamples) ringAvail=\(ringAvailFrames) ringPct=\(ringPct)% halBuf=\(halBufferFrames) shmCatchUp=\(isBehind)"
        )
    }

    // ── DSP ───────────────────────────────────────────────────────────────────
    if engine.processingEnabled {
        engine.viperBridge.processAudio(tempBuf, frameCount: UInt32(frameCount))
    }

    // ── Software volume ───────────────────────────────────────────────────────
    os_unfair_lock_lock(&engine.volumeLock)
    let vol = engine.currentVolume
    let muted = engine.currentlyMuted
    os_unfair_lock_unlock(&engine.volumeLock)

    let gain: Float = muted ? 0.0 : vol
    if gain < 0.9999 {
        for i in 0 ..< samplesToRead {
            tempBuf[i] *= gain
        }
    }

    // ── Write to ring ─────────────────────────────────────────────────────────
    if engine.isConverterActive {
        // Rate-conversion path (e.g. 48000 → 44100): feed the src buffer
        engine.appendToSrcBuffer(tempBuf, frameCount: frameCount)
    } else {
        // Direct path (same rate) + PLL drift correction above
        engine.writeToRing(tempBuf, frameCount: frameCount)
    }

    return noErr
}

// MARK: - AudioConverter input data proc

private let converterDataProc: AudioConverterComplexInputDataProc = {
    converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData
    -> OSStatus in

    guard let inUserData else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let engine = Unmanaged<AudioEngine>.fromOpaque(inUserData).takeUnretainedValue()
    let ch = Int(engine.channelCount)
    let requestedFrames = Int(ioNumberDataPackets.pointee)

    guard let srcBuf = engine.srcBuffer else {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let availFrames = engine.srcBufferAvailableFrames()
    let framesToProvide = min(requestedFrames, availFrames)

    if framesToProvide == 0 {
        ioNumberDataPackets.pointee = 0
        return -1
    }

    let byteCount = framesToProvide * ch * MemoryLayout<Float>.size

    _ = engine.consumeFromSrcBuffer(srcBuf, maxFrames: framesToProvide)

    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    if !abl.isEmpty {
        abl[0].mNumberChannels = UInt32(ch)
        abl[0].mDataByteSize = UInt32(byteCount)
        abl[0].mData = UnsafeMutableRawPointer(srcBuf)
    }

    ioNumberDataPackets.pointee = UInt32(framesToProvide)
    return noErr
}

// MARK: - Output AUHAL Render Callback

private let outputCallback: AURenderCallback = {
    inRefCon, _, _, _, inNumberFrames, ioData -> OSStatus in
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    engine.outputCallbackCount += 1

    guard let ioData else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard let firstBuffer = abl.first, let dataPtr = firstBuffer.mData else { return noErr }

    let floatPtr = dataPtr.assumingMemoryBound(to: Float.self)
    let frameCount = Int(inNumberFrames)

    if engine.isConverterActive {
        // ── Rate-conversion path (different nominal rates) ────────────────
        let avail = engine.srcBufferAvailableFrames()

        if avail < 1024 {
            memset(dataPtr, 0, Int(firstBuffer.mDataByteSize))
            if engine.outputCallbackCount % 1000 == 1 {
                logger.debug("OUTPUT(conv): Priming... srcAvail=\(avail)")
            }
            return noErr
        }

        if let conv = engine.audioConverter {
            var outputABL = AudioBufferList()
            outputABL.mNumberBuffers = 1
            withUnsafeMutablePointer(to: &outputABL.mBuffers) { bufPtr in
                bufPtr.pointee.mNumberChannels = engine.channelCount
                bufPtr.pointee.mDataByteSize =
                    UInt32(frameCount * Int(engine.channelCount) * 4)
                bufPtr.pointee.mData = dataPtr
            }

            var outputFrames = UInt32(frameCount)
            let selfPtr = Unmanaged.passUnretained(engine).toOpaque()
            let status = AudioConverterFillComplexBuffer(
                conv,
                converterDataProc,
                selfPtr,
                &outputFrames,
                &outputABL,
                nil
            )
            if status != noErr && status != -1 {
                memset(dataPtr, 0, Int(firstBuffer.mDataByteSize))
                if engine.outputCallbackCount % 1000 == 1 {
                    logger.debug("OUTPUT(conv): converter err=\(status)")
                }
            }
        }
    } else {
        // ── Direct ring path (same nominal rate + PLL) ────────────────────
        let avail = engine.availableFrames()

        // Priming guard: need at least 2 buffer-lengths before starting
        if avail < frameCount * 2 {
            memset(dataPtr, 0, Int(firstBuffer.mDataByteSize))
            if engine.outputCallbackCount % 500 == 1 {
                logger.debug("OUTPUT: Priming... ringAvail=\(avail) need=\(frameCount * 2)")
            }
            return noErr
        }

        engine.readFromRing(floatPtr, frameCount: frameCount)
    }

    // ── Diagnostics ───────────────────────────────────────────────────────
    if engine.outputCallbackCount % 5000 == 1 {
        var maxOut: Float = 0.0
        let totalSamples = frameCount * Int(engine.channelCount)
        for i in 0 ..< totalSamples {
            let s = abs(floatPtr[i])
            if s > maxOut { maxOut = s }
        }
        let avail = engine.isConverterActive
            ? engine.srcBufferAvailableFrames()
            : engine.availableFrames()
        logger.debug(
            "OUTPUT: frames=\(frameCount) max=\(String(format: "%.4f", maxOut)) avail=\(avail) converter=\(engine.isConverterActive)"
        )
    }

    return noErr
}

// MARK: - Property Listener Callbacks

private let engineDeviceChangedCallback: AudioObjectPropertyListenerProc = {
    _, _, _, clientData -> OSStatus in
    guard let clientData else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { engine.handleDefaultDeviceChanged() }
    return noErr
}

private let engineDeviceListChangedCallback: AudioObjectPropertyListenerProc = {
    _, _, _, clientData -> OSStatus in
    guard let clientData else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { engine.handleDeviceListChanged() }
    return noErr
}

private let engineVolumeChangedCallback: AudioObjectPropertyListenerProc = {
    _, _, _, clientData -> OSStatus in
    guard let clientData else { return noErr }
    let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { engine.syncVolumeToOutput() }
    return noErr
}