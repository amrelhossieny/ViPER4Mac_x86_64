#include <CoreAudio/AudioServerPlugIn.h>

// This is the XPC service entry point for macOS 12+
// coreaudiod launches this as a separate process via XPC
// then calls our ViPER4Mac_Create factory function

int main(int argc, char *argv[]) {
    // AudioServerPlugInMain handles the XPC runloop for us
    // It will call our registered factory (ViPER4Mac_Create)
    // via the CFPlugin mechanism
    return AudioServerPlugInMain(argc, argv);
}
