#include "NDIBridge.h"
#include "Processing.NDI.Lib.h"

#include <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <cstring>
#include <mutex>
#include <string>

namespace {
void writeError(char* destination, size_t capacity, const std::string& message) {
    if (!destination || capacity == 0) return;
    std::strncpy(destination, message.c_str(), capacity - 1);
    destination[capacity - 1] = '\0';
}
}

struct PMNDISender {
    std::mutex mutex;
    void* library = nullptr;
    const NDIlib_v6* api = nullptr;
    NDIlib_send_instance_t instance = nullptr;

    void stopUnlocked() {
        if (instance && api) api->send_destroy(instance);
        instance = nullptr;
        if (api) api->destroy();
        api = nullptr;
        if (library) dlclose(library);
        library = nullptr;
    }
};

PMNDISender* pm_ndi_sender_create(void) { return new PMNDISender(); }
void pm_ndi_sender_destroy(PMNDISender* sender) {
    if (!sender) return;
    pm_ndi_sender_stop(sender);
    delete sender;
}

int32_t pm_ndi_sender_start(PMNDISender* sender, const char* runtimePath,
                            const char* sourceName, char* error, size_t capacity) {
    if (!sender || !runtimePath || !sourceName) return -1;
    std::lock_guard<std::mutex> lock(sender->mutex);
    sender->stopUnlocked();
    sender->library = dlopen(runtimePath, RTLD_LOCAL | RTLD_NOW);
    if (!sender->library) {
        writeError(error, capacity, std::string("Could not load the NDI runtime: ") + dlerror());
        return -2;
    }
    auto load = reinterpret_cast<const NDIlib_v6* (*)(void)>(dlsym(sender->library, "NDIlib_v6_load"));
    if (!load || !(sender->api = load()) || !sender->api->initialize()) {
        writeError(error, capacity, "The NDI 6 runtime could not initialize.");
        sender->stopUnlocked();
        return -3;
    }
    NDIlib_send_create_t settings{};
    settings.p_ndi_name = sourceName;
    settings.clock_video = false;
    settings.clock_audio = false;
    sender->instance = sender->api->send_create(&settings);
    if (!sender->instance) {
        writeError(error, capacity, "The NDI sender could not be created.");
        sender->stopUnlocked();
        return -4;
    }
    return 0;
}

int32_t pm_ndi_sender_send_pixel_buffer(PMNDISender* sender, void* opaquePixelBuffer,
                                        char* error, size_t capacity) {
    if (!sender || !opaquePixelBuffer) return -1;
    std::lock_guard<std::mutex> lock(sender->mutex);
    if (!sender->instance || !sender->api) return -2;
    auto pixelBuffer = static_cast<CVPixelBufferRef>(opaquePixelBuffer);
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        writeError(error, capacity, "NDI requires a readable BGRA capture frame.");
        return -3;
    }
    NDIlib_video_frame_v2_t frame{};
    frame.xres = static_cast<int>(CVPixelBufferGetWidth(pixelBuffer));
    frame.yres = static_cast<int>(CVPixelBufferGetHeight(pixelBuffer));
    frame.FourCC = NDIlib_FourCC_type_BGRA;
    frame.frame_rate_N = 60000;
    frame.frame_rate_D = 1001;
    frame.picture_aspect_ratio = 16.0f / 9.0f;
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = NDIlib_send_timecode_synthesize;
    frame.p_data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer));
    frame.line_stride_in_bytes = static_cast<int>(CVPixelBufferGetBytesPerRow(pixelBuffer));
    sender->api->send_send_video_v2(sender->instance, &frame);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return 0;
}

void pm_ndi_sender_stop(PMNDISender* sender) {
    if (!sender) return;
    std::lock_guard<std::mutex> lock(sender->mutex);
    sender->stopUnlocked();
}
