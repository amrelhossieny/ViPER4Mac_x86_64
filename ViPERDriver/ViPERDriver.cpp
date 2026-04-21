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
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <mutex>
#include <signal.h>
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

    void logv(const char *level, const char *category, const char *fmt, va_list args) {
        std::lock_guard<std::mutex> lock(mutex_);
        rotateIfNeeded();
        if (!file_) {
            openFile();
            if (!file_) return;
        }

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

static const char *kViPERPIDFile = "/tmp/viper4mac.pid";

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
        startLifecycleMonitor();
    }

    ~ViPERIOHandler() override {
        LOG_INFO("IOHandler", "Destroying — cleanup TPCircularBuffer + SHM + lifecycle");
        if (lifecycleTimer_) {
            dispatch_source_cancel(lifecycleTimer_);
            lifecycleTimer_ = nullptr;
        }
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

    // App lifecycle monitoring
    dispatch_source_t lifecycleTimer_ = nullptr;
    pid_t monitoredPID_ = 0;
    bool appWasPreviouslyAlive_ = false;
    uint64_t lifecycleCheckCount_ = 0;

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

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - App Lifecycle Monitor
    // ─────────────────────────────────────────────────────────────────────────

    void startLifecycleMonitor() {
        LOG_INFO("Lifecycle", "Starting app lifecycle monitor (polling every 2s)");

        dispatch_queue_t queue = dispatch_queue_create(
            "com.viper4mac.lifecycle", DISPATCH_QUEUE_SERIAL);

        lifecycleTimer_ = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);

        dispatch_source_set_timer(lifecycleTimer_,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            2 * NSEC_PER_SEC,
            NSEC_PER_SEC / 2);

        // Capture 'this' explicitly for the block
        ViPERIOHandler *handler = this;
        dispatch_source_set_event_handler(lifecycleTimer_, ^{
            handler->checkAppAlive();
        });

        dispatch_resume(lifecycleTimer_);
        LOG_INFO("Lifecycle", "Timer created and resumed on queue com.viper4mac.lifecycle");
    }

    void checkAppAlive() {
        lifecycleCheckCount_++;

        // Log every 30th check (~60s) to prove timer is ticking
        if (lifecycleCheckCount_ % 30 == 1) {
            LOG_DEBUG("Lifecycle",
                "Tick #%llu pid=%d wasAlive=%s",
                lifecycleCheckCount_, monitoredPID_,
                appWasPreviouslyAlive_ ? "yes" : "no");
        }

        // Try to read PID file
        FILE *f = fopen(kViPERPIDFile, "r");
        if (!f) {
            // No PID file exists
            if (appWasPreviouslyAlive_) {
                LOG_WARN("Lifecycle",
                    "PID file disappeared — app exited cleanly, switching output");
                appWasPreviouslyAlive_ = false;
                monitoredPID_ = 0;
                drainSHM();
                switchToNextOutput();
            }
            return;
        }

        char buf[32] = {0};
        if (fgets(buf, sizeof(buf), f) == nullptr) {
            fclose(f);
            LOG_WARN("Lifecycle", "PID file empty, ignoring");
            return;
        }
        fclose(f);

        // Strip newline
        size_t blen = strlen(buf);
        if (blen > 0 && buf[blen - 1] == '\n') buf[blen - 1] = '\0';

        pid_t pid = (pid_t) atoi(buf);
        if (pid <= 0) {
            LOG_WARN("Lifecycle", "Invalid PID in file: '%s'", buf);
            return;
        }

        // Track PID changes
        if (monitoredPID_ != pid) {
            LOG_INFO("Lifecycle", "Monitoring new PID=%d (was %d)", pid, monitoredPID_);
            monitoredPID_ = pid;
        }

        // Check if process is alive
        // kill(pid, 0) returns 0 if process exists, -1 otherwise
        // errno == ESRCH means no such process
        // errno == EPERM means process exists but we can't signal it (still alive)
        int result = kill(pid, 0);
        int err = errno;

        if (result == 0 || err == EPERM) {
            // Process is alive
            if (!appWasPreviouslyAlive_) {
                LOG_INFO("Lifecycle", "App now alive PID=%d", pid);
                appWasPreviouslyAlive_ = true;
            }
        } else {
            // Process is dead (ESRCH or other error)
            if (appWasPreviouslyAlive_) {
                LOG_WARN("Lifecycle",
                    "*** APP DIED PID=%d errno=%d(%s) — switching output ***",
                    pid, err, strerror(err));
                appWasPreviouslyAlive_ = false;
                monitoredPID_ = 0;

                // Remove stale PID file
                int unlinkResult = unlink(kViPERPIDFile);
                if (unlinkResult != 0) {
                    LOG_WARN("Lifecycle",
                        "unlink(%s) failed errno=%d(%s) — truncating instead",
                        kViPERPIDFile, errno, strerror(errno));
                    // Fallback: truncate the file to 0 bytes so we read nothing next tick
                    int tfd = open(kViPERPIDFile, O_WRONLY | O_TRUNC);
                    if (tfd >= 0) close(tfd);
                }

                // Drain SHM so it's clean for reconnection
                drainSHM();

                // Switch audio output away from ViPER4Mac
                switchToNextOutput();
            }
            // else: already handled, don't spam logs — silently wait for new PID file
        }
    }

    void drainSHM() {
        if (sharedRing_) {
            uint64_t wp = atomic_load_explicit(
                &sharedRing_->writePos, memory_order_relaxed);
            atomic_store_explicit(
                &sharedRing_->readPos, wp, memory_order_release);
            LOG_INFO("Lifecycle", "Drained SHM ring (readPos=writePos=%llu)", wp);
        }
    }

    void switchToNextOutput() {
        LOG_INFO("Lifecycle", "Looking for SwitchAudioSource...");

        const char *paths[] = {
            "/usr/local/bin/SwitchAudioSource",     // Intel Homebrew
            "/opt/homebrew/bin/SwitchAudioSource",   // Apple Silicon Homebrew
            nullptr
        };

        for (int i = 0; paths[i]; i++) {
            struct stat st;
            if (stat(paths[i], &st) == 0) {
                LOG_INFO("Lifecycle", "Found at %s — executing -n", paths[i]);

                char cmd[256];
                snprintf(cmd, sizeof(cmd), "%s -n 2>&1", paths[i]);

                FILE *pipe = popen(cmd, "r");
                if (pipe) {
                    char result[256] = {0};
                    fgets(result, sizeof(result), pipe);
                    int status = pclose(pipe);

                    // Strip trailing newline
                    size_t len = strlen(result);
                    if (len > 0 && result[len - 1] == '\n') {
                        result[len - 1] = '\0';
                    }

                    LOG_INFO("Lifecycle",
                        "SwitchAudioSource result: \"%s\" (exit=%d)", result, status);
                    return;
                } else {
                    LOG_ERROR("Lifecycle",
                        "popen(%s) failed errno=%d(%s)", paths[i], errno, strerror(errno));
                }
            } else {
                LOG_DEBUG("Lifecycle", "Not found at %s", paths[i]);
            }
        }

        LOG_ERROR("Lifecycle",
            "SwitchAudioSource not found — user must switch manually");
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

    OSStatus SetNominalSampleRateImpl(Float64 rate) override {
        Float64 oldRate = GetNominalSampleRate();
        LOG_INFO(
            "Device", "SetNominalSampleRate: requested=%.0f current=%.0f", rate, oldRate
        );

        if (abs(rate - oldRate) > 1.0) {
            LOG_WARN(
                "Device",
                "SetNominalSampleRate: unexpected rate change %.0f -> %.0f",
                oldRate,
                rate
            );
        }

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

    const Float64 initialRate = 44100.0;

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