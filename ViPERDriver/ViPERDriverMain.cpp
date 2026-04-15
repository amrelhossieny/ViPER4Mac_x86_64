#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// The XPC service for a HAL driver doesn't use AudioServerPlugInMain.
// coreaudiod launches this process, then calls our factory function
// (ViPER4Mac_Create) via CFPlugin mechanism.
// We just need to keep the runloop alive so coreaudiod can talk to us.

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    
    // Run forever — coreaudiod manages our lifecycle
    CFRunLoopRun();
    
    return 0;
}
