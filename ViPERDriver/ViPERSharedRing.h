// ViPERSharedRing.h
#ifndef VIPER_SHARED_RING_H
#define VIPER_SHARED_RING_H

#include <stdatomic.h>
#include <stdint.h>

// CONSISTENCY FIX: Use /tmp path for both C++ and Swift open()
#define VIPER_SHM_PATH "/tmp/viper4mac_ring.bin" 
#define VIPER_SHM_RING_FRAMES 16384
#define VIPER_SHM_CHANNELS 2
#define VIPER_SHM_RING_SAMPLES (VIPER_SHM_RING_FRAMES * VIPER_SHM_CHANNELS)

typedef struct {
    _Atomic uint64_t writePos;
    _Atomic uint64_t readPos;
    float samples[VIPER_SHM_RING_SAMPLES];
} ViPERSharedRing;

#define VIPER_SHM_SIZE sizeof(ViPERSharedRing)

#endif