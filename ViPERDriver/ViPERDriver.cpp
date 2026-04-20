// ViPERDriver/ViPERDriver.cpp

#include <CoreAudio/AudioServerPlugIn.h>
#include <aspl/Device.hpp>
#include <aspl/Driver.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <fcntl.h>
#include <mutex>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#if defined(__x86_64__)
#include <pmmintrin.h>
#include <xmmintrin.h>
static void enableFlushToZero() {
    _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
    _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
}
#else
static void enableFlushToZero() {}
#endif

#include "TPCircularBuffer.h"
#include "ViPERSharedRing.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DriverLogger (mirrors Swift FileLogger style)
// ─────────────────────────────────────────────────────────────────────────────

static const char *kViPERLogDir = "/Library/Logs/ViPER4Mac";
static const char *kViPERLogFile = "/Library/Logs/ViPER4Mac/driver.log";
static const char *kViPERLogOld = "/Library/Logs/ViPER4Mac/driver.old.log";
static const size_t kMaxLogFileSize = 2 * 1024 * 1024; // 2 MB, same as Swift side

class DriverLogger {
public:
    static DriverLogger &shared() {
        static DriverLogger instance;
        return instance;
    }

    void debug(const char *category, const char *fmt, ...)
        __attribute__((format(printf, 3, 4))) {
        va_list args;
        va_start(args, fmt);
        logv("DEBUG", category, fmt, args);
        va_end(args);
    }

    void info(const char *category, const char *fmt, ...)
        __attribute__((format(printf, 3, 4))) {
        va_list args;
        va_start(args, fmt);
        logv("INFO", category, fmt, args);
        va_end(args);
    }

    void warning(const char *category, const char *fmt, ...)
        __attribute__((format(printf, 3, 4))) {
        va_list args;
        va_start(args, fmt);
        logv("WARN", category, fmt, args);
        va_end(args);
    }

    void error(const char *category, const char *fmt, ...)
        __attribute__((format(printf, 3, 4))) {
        va_list args;
        va_start(args, fmt);
        logv("ERROR", category, fmt, args);
        va_end(args);
    }

private:
    std::mutex mutex_;
    FILE *file_ = nullptr;

    DriverLogger() {
        mkdir(kViPERLogDir, 0755);
        openFile();
    }

    ~DriverLogger() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (file_) {
            fclose(file_);
            file_ = nullptr;
        }
    }

    void openFile() { file_ = fopen(kViPERLogFile, "a"); }

    void rotateIfNeeded() {
        if (!file_) return;
        struct stat st;
        if (stat(kViPERLogFile, &st) == 0 && (size_t) st.st_size > kMaxLogFileSize) {
            fclose(file_);
            file_ = nullptr;
            unlink(kViPERLogOld);
            rename(kViPERLogFile, kViPERLogOld);
            openFile();
        }
    }

    // Format: "2026-04-20 14:33:07.123 [Category][LEVEL] message\n"
    void logv(const char *level, const char *category, const char *fmt, va_list args) {
        std::lock_guard<std::mutex> lock(mutex_);
        rotateIfNeeded();
        if (!file_) {
            openFile();
            if (!file_) return;
        }

        // Timestamp with milliseconds — matches Swift dateFormatter exactly
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);

        char timestamp[32];
        int len = (int) strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &tm);
        snprintf(
            timestamp + len, sizeof(timestamp) - len, ".%03d", (int) (tv.tv_usec / 1000)
        );

        fprintf(file_, "%s [%s][%s] ", timestamp, category, level);
        vfprintf(file_, fmt, args);
        fprintf(file_, "\n");
        fflush(file_);
    }
};

// Convenience macros so call sites stay clean
#define LOG_DEBUG(cat, ...) DriverLogger::shared().debug(cat, __VA_ARGS__)
#define LOG_INFO(cat, ...) DriverLogger::shared().info(cat, __VA_ARGS__)
#define LOG_WARN(cat, ...) DriverLogger::shared().warning(cat, __VA_ARGS__)
#define LOG_ERROR(cat, ...) DriverLogger::shared().error(cat, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Constants
// ─────────────────────────────────────────────────────────────────────────────

static const char *kViPERDeviceUID = "ViPER4Mac_VirtualDevice";
static const char *kViPERDeviceName = "ViPER4Mac";
static const UInt32 kViPERChannelCount = 2;
static const UInt32 kViPERDefaultSampleRate = 48000;
static const UInt32 kViPERRingBufferFrames = 16384;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ViPERIOHandler
// ─────────────────────────────────────────────────────────────────────────────

class ViPERIOHandler : public aspl::IORequestHandler {
public:
    ViPERIOHandler() {
        LOG_INFO(
            "IOHandler",
            "Initializing TPCircularBuffer capacity=%u bytes",
            kViPERRingBufferFrames * kViPERChannelCount * (UInt32) sizeof(Float32)
        );
        TPCircularBufferInit(
            &ringBuffer_, kViPERRingBufferFrames * kViPERChannelCount * sizeof(Float32)
        );
        initSharedMemory();
    }

    ~ViPERIOHandler() override {
        LOG_INFO("IOHandler", "Destroying — cleanup TPCircularBuffer + SHM");
        TPCircularBufferCleanup(&ringBuffer_);
        if (sharedRing_) {
            munmap(sharedRing_, VIPER_SHM_SIZE);
            sharedRing_ = nullptr;
        }
    }

    void OnProcessMixedOutput(
        const std::shared_ptr<aspl::Stream> &stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32 *frames,
        UInt32 frameCount,
        UInt32 channelCount
    ) override {}

    void OnWriteMixedOutput(
        const std::shared_ptr<aspl::Stream> &stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void *bytes,
        UInt32 bytesCount
    ) override {
        TPCircularBufferProduceBytes(&ringBuffer_, bytes, bytesCount);

        if (sharedRing_) {
            const float *src = static_cast<const float *>(bytes);
            uint32_t sampleCount = bytesCount / sizeof(float);
            uint64_t wp =
                atomic_load_explicit(&sharedRing_->writePos, memory_order_relaxed);
            uint64_t rp =
                atomic_load_explicit(&sharedRing_->readPos, memory_order_acquire);
            uint64_t used = (wp >= rp) ? (wp - rp) : (VIPER_SHM_RING_SAMPLES - rp + wp);
            uint64_t available = VIPER_SHM_RING_SAMPLES - used - 1;
            if (sampleCount <= available) {
                for (uint32_t i = 0; i < sampleCount; i++) {
                    sharedRing_->samples[(wp + i) % VIPER_SHM_RING_SAMPLES] = src[i];
                }
                atomic_store_explicit(
                    &sharedRing_->writePos,
                    (wp + sampleCount) % VIPER_SHM_RING_SAMPLES,
                    memory_order_release
                );
            } else {
                // Log SHM overflow (drop-on-full)
                shmOverflowCount_++;
                if (shmOverflowCount_ <= 3 || shmOverflowCount_ % 1000 == 0) {
                    LOG_WARN(
                        "IOHandler",
                        "SHM ring overflow #%llu: need=%u avail=%llu used=%llu wp=%llu "
                        "rp=%llu",
                        shmOverflowCount_.load(),
                        sampleCount,
                        available,
                        used,
                        wp,
                        rp
                    );
                }
            }
        }

        writeCount_++;

        // Periodic diagnostic — every 5000 writes (~5 seconds at typical callback rates)
        if (writeCount_ % 5000 == 1) {
            const float *src = static_cast<const float *>(bytes);
            uint32_t sampleCount = bytesCount / sizeof(float);
            uint32_t frameCount = sampleCount / kViPERChannelCount;
            float maxVal = 0.0f;
            for (uint32_t i = 0; i < sampleCount; i++) {
                float v = src[i] < 0 ? -src[i] : src[i];
                if (v > maxVal) maxVal = v;
            }

            uint64_t wp = 0, rp = 0;
            if (sharedRing_) {
                wp = atomic_load_explicit(&sharedRing_->writePos, memory_order_relaxed);
                rp = atomic_load_explicit(&sharedRing_->readPos, memory_order_relaxed);
            }

            LOG_DEBUG(
                "IOHandler",
                "WriteMixed: count=%llu bytes=%u frames=%u samples=%u "
                "shm=%s max=%.6f shmWP=%llu shmRP=%llu shmUsed=%llu",
                writeCount_.load(),
                bytesCount,
                frameCount,
                sampleCount,
                sharedRing_ ? "yes" : "no",
                maxVal,
                wp,
                rp,
                (wp >= rp) ? (wp - rp) : (VIPER_SHM_RING_SAMPLES - rp + wp)
            );
        }
    }

    void OnReadClientInput(
        const std::shared_ptr<aspl::Client> &client,
        const std::shared_ptr<aspl::Stream> &stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void *bytes,
        UInt32 bytesCount
    ) override {
        uint32_t availableBytes = 0;
        void *head = TPCircularBufferTail(&ringBuffer_, &availableBytes);

        if (head && availableBytes >= bytesCount) {
            memcpy(bytes, head, bytesCount);
            TPCircularBufferConsume(&ringBuffer_, bytesCount);
        } else {
            memset(bytes, 0, bytesCount);
            readUnderrunCount_++;
            if (readUnderrunCount_ <= 5 || readUnderrunCount_ % 1000 == 0) {
                LOG_WARN(
                    "IOHandler",
                    "ReadClientInput underrun #%llu: need=%u avail=%u",
                    readUnderrunCount_.load(),
                    bytesCount,
                    availableBytes
                );
            }
        }
    }

private:
    TPCircularBuffer ringBuffer_;
    std::atomic<uint64_t> writeCount_{0};
    std::atomic<uint64_t> shmOverflowCount_{0};
    std::atomic<uint64_t> readUnderrunCount_{0};
    ViPERSharedRing *sharedRing_ = nullptr;

    void initSharedMemory() {
        LOG_INFO("SHM", "Initializing shared memory at %s", VIPER_SHM_PATH);

        unlink(VIPER_SHM_PATH);

        int fd = open(VIPER_SHM_PATH, O_CREAT | O_RDWR | O_TRUNC, 0666);
        if (fd < 0) {
            LOG_ERROR(
                "SHM",
                "open(%s) failed errno=%d (%s)",
                VIPER_SHM_PATH,
                errno,
                strerror(errno)
            );
            return;
        }
        fchmod(fd, 0666);

        size_t shmSize = VIPER_SHM_SIZE;
        int trunc = ftruncate(fd, shmSize);
        if (trunc != 0) {
            LOG_ERROR(
                "SHM",
                "ftruncate failed errno=%d (%s) size=%zu",
                errno,
                strerror(errno),
                shmSize
            );
            close(fd);
            return;
        }

        LOG_INFO(
            "SHM",
            "File created fd=%d size=%zu ringFrames=%u channels=%u ringSamples=%u",
            fd,
            shmSize,
            VIPER_SHM_RING_FRAMES,
            VIPER_SHM_CHANNELS,
            VIPER_SHM_RING_SAMPLES
        );

        void *ptr = mmap(nullptr, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);

        if (ptr == MAP_FAILED) {
            LOG_ERROR(
                "SHM",
                "mmap failed errno=%d (%s) size=%zu",
                errno,
                strerror(errno),
                shmSize
            );
            return;
        }

        sharedRing_ = static_cast<ViPERSharedRing *>(ptr);

        atomic_store_explicit(&sharedRing_->writePos, 0, memory_order_relaxed);
        atomic_store_explicit(&sharedRing_->readPos, 0, memory_order_relaxed);
        memset(sharedRing_->samples, 0, sizeof(sharedRing_->samples));

        // Verify file permissions
        struct stat st;
        if (stat(VIPER_SHM_PATH, &st) == 0) {
            LOG_INFO(
                "SHM",
                "OK ptr=%p size=%zu permissions=%o owner=%d:%d",
                ptr,
                shmSize,
                st.st_mode & 0777,
                st.st_uid,
                st.st_gid
            );
        } else {
            LOG_INFO("SHM", "OK ptr=%p size=%zu (stat failed)", ptr, shmSize);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ViPERDevice
// ─────────────────────────────────────────────────────────────────────────────

class ViPERDevice : public aspl::Device {
public:
    ViPERDevice(
        std::shared_ptr<aspl::Context> context, const aspl::DeviceParameters &params
    ) :
        aspl::Device(std::move(context), params) {
        LOG_INFO(
            "Device",
            "ViPERDevice constructed sampleRate=%.0f channels=%u",
            params.SampleRate,
            params.ChannelCount
        );
    }

    UInt32 GetTransportType() const override { return kAudioDeviceTransportTypeBuiltIn; }

    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override {
        LOG_INFO("Device", "StartIO clientID=%u startCount=%u", clientID, startCount);
        OSStatus status = aspl::Device::StartIOImpl(clientID, startCount);
        if (status != kAudioHardwareNoError) {
            LOG_ERROR("Device", "StartIO base class failed status=%d", (int) status);
        }
        return status;
    }

    OSStatus StopIOImpl(UInt32 clientID, UInt32 startCount) override {
        LOG_INFO("Device", "StopIO clientID=%u startCount=%u", clientID, startCount);
        OSStatus status = aspl::Device::StopIOImpl(clientID, startCount);
        if (status != kAudioHardwareNoError) {
            LOG_ERROR("Device", "StopIO base class failed status=%d", (int) status);
        }
        return status;
    }

    // Replace the entire SetNominalSampleRateImpl with this minimal version:
    OSStatus SetNominalSampleRateImpl(Float64 rate) override {
        Float64 oldRate = GetNominalSampleRate();
        LOG_INFO(
            "Device", "SetNominalSampleRate: requested=%.0f current=%.0f", rate, oldRate
        );

        // Just verify we're already at the requested rate (we always will be now)
        if (abs(rate - oldRate) > 1.0) {
            LOG_WARN(
                "Device",
                "SetNominalSampleRate: unexpected rate change %.0f -> %.0f",
                oldRate,
                rate
            );
        }

        // Update ZeroTimeStampPeriod (should already match)
        UInt32 newPeriod = (UInt32) rate;
        SetZeroTimeStampPeriodAsync(newPeriod);

        return kAudioHardwareNoError;
    }

    OSStatus WillDoIOOperationImpl(
        UInt32 clientID, UInt32 operationID, Boolean *outWillDo, Boolean *outWillDoInPlace
    ) override {
        switch (operationID) {
            case kAudioServerPlugInIOOperationReadInput:
            case kAudioServerPlugInIOOperationMixOutput:
            case kAudioServerPlugInIOOperationWriteMix:
                *outWillDo = true;
                *outWillDoInPlace = true;
                break;
            default:
                break;
        }
        return kAudioHardwareNoError;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Driver Entry Point
// ─────────────────────────────────────────────────────────────────────────────

static std::shared_ptr<aspl::Driver> s_driver;

extern "C" void *ViPER4Mac_Create(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    (void) allocator;

    LOG_INFO("Plugin", "ViPER4Mac_Create called");

    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        // Log the UUID we received for debugging
        CFStringRef desc = CFCopyDescription(typeUUID);
        if (desc) {
            char buf[256];
            CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8);
            LOG_ERROR(
                "Plugin", "Wrong typeUUID: %s (expected kAudioServerPlugInTypeUUID)", buf
            );
            CFRelease(desc);
        } else {
            LOG_ERROR("Plugin", "Wrong typeUUID (could not describe)");
        }
        return nullptr;
    }

    LOG_INFO("Plugin", "typeUUID matches kAudioServerPlugInTypeUUID — proceeding");

    // NOTE: We cannot query kAudioHardwarePropertyDefaultOutputDevice here
    // because AudioServerPlugIn.h deliberately excludes client-side HAL APIs.
    // The Swift app calls matchSampleRates() on startup which immediately
    // pushes the correct rate via SetNominalSampleRateImpl — so starting at
    // 48000 and letting it be corrected within ~60ms is correct behavior.
    const Float64 initialRate = 44100.0; // ← CHANGE THIS LINE

    LOG_INFO("Plugin", "Creating context and IOHandler");
    auto context = std::make_shared<aspl::Context>();
    auto ioHandler = std::make_shared<ViPERIOHandler>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = kViPERDeviceName;
    deviceParams.DeviceUID = kViPERDeviceUID;
    deviceParams.SampleRate = initialRate;
    deviceParams.ZeroTimeStampPeriod = (UInt32) initialRate;
    deviceParams.ChannelCount = kViPERChannelCount;
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = true;
    deviceParams.Latency = 0;
    deviceParams.SafetyOffset = 0;
    // ZeroTimeStampPeriod MUST equal SampleRate — this controls audio playback speed.
    // SetNominalSampleRateImpl updates this when the Swift app changes the rate.
    deviceParams.ZeroTimeStampPeriod = (UInt32) initialRate;
    deviceParams.ClockIsStable = true;

    LOG_INFO(
        "Plugin",
        "DeviceParams: name=%s uid=%s rate=%.0f ch=%u period=%u",
        kViPERDeviceName,
        kViPERDeviceUID,
        initialRate,
        kViPERChannelCount,
        (UInt32) initialRate
    );

    auto device = std::make_shared<ViPERDevice>(context, deviceParams);
    device->SetIOHandler(ioHandler);
    LOG_INFO("Plugin", "Device created, IOHandler attached");

    AudioStreamBasicDescription format = {};
    format.mSampleRate = initialRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian
                          | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = kViPERChannelCount;
    format.mBytesPerFrame = kViPERChannelCount * sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = kViPERChannelCount * sizeof(Float32);

    LOG_INFO(
        "Plugin",
        "StreamFormat: rate=%.0f fmt=LinearPCM float32 ch=%u bpf=%u",
        initialRate,
        kViPERChannelCount,
        format.mBytesPerFrame
    );

    aspl::StreamParameters outputStreamParams;
    outputStreamParams.Direction = aspl::Direction::Output;
    outputStreamParams.Format = format;
    device->AddStreamAsync(outputStreamParams);
    LOG_INFO("Plugin", "Output stream added");

    aspl::StreamParameters inputStreamParams;
    inputStreamParams.Direction = aspl::Direction::Input;
    inputStreamParams.Format = format;
    device->AddStreamAsync(inputStreamParams);
    LOG_INFO("Plugin", "Input stream added");

    std::vector<AudioValueRange> availableRates = {
        {44100.0, 44100.0},
        {48000.0, 48000.0},
        {88200.0, 88200.0},
        {96000.0, 96000.0},
    };
    device->SetAvailableSampleRatesAsync(availableRates);
    LOG_INFO("Plugin", "Available sample rates set: 44100, 48000, 88200, 96000");

    device->AddVolumeControlAsync(kAudioObjectPropertyScopeOutput);
    device->AddMuteControlAsync(kAudioObjectPropertyScopeOutput);
    LOG_INFO("Plugin", "Volume + Mute controls added");

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);
    LOG_INFO("Plugin", "Device added to plugin");

    s_driver = std::make_shared<aspl::Driver>(context, plugin);

    void *ref = s_driver->GetReference();
    LOG_INFO(
        "Plugin",
        "ViPER4Mac_Create COMPLETE: initialRate=%.0f period=%u ref=%p",
        initialRate,
        (UInt32) initialRate,
        ref
    );

    return ref;
}