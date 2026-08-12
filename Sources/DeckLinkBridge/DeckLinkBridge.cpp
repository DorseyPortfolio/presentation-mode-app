#include "DeckLinkBridge.h"

#include "DeckLinkAPI.h"
#include "DeckLinkAPI_v15_3_1.h"
#include "DeckLinkAPIVideoOutput_v15_3_1.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

constexpr BMDTimeValue kFrameDuration = 1001;
constexpr BMDTimeScale kFrameTimeScale = 60000;
constexpr uint32_t kMaximumBufferedFrames = 3;
constexpr int32_t kOutputWidth = 1920;
constexpr int32_t kOutputHeight = 1080;

namespace {

// Desktop Video 16.0 added GetStringWithParam to
// IDeckLinkProfileAttributes and therefore assigned the interface a new IID.
// Querying only the 16.0 IID makes every attribute appear unavailable when the
// app runs against Desktop Video 15.3.1. Keep both interface layouts here so
// one binary can discover cards with either installed runtime.
class ProfileAttributes {
public:
    explicit ProfileAttributes(IDeckLink* device)
    {
        if (!device)
            return;

        if (device->QueryInterface(IID_IDeckLinkProfileAttributes,
                                   reinterpret_cast<void**>(&current_)) == S_OK && current_)
            return;

        current_ = nullptr;
        device->QueryInterface(IID_IDeckLinkProfileAttributes_v15_3_1,
                               reinterpret_cast<void**>(&legacy_));
    }

    ~ProfileAttributes()
    {
        if (current_)
            current_->Release();
        if (legacy_)
            legacy_->Release();
    }

    ProfileAttributes(const ProfileAttributes&) = delete;
    ProfileAttributes& operator=(const ProfileAttributes&) = delete;

    explicit operator bool() const { return current_ || legacy_; }

    HRESULT getInt(BMDDeckLinkAttributeID attribute, int64_t* value) const
    {
        if (current_)
            return current_->GetInt(attribute, value);
        if (legacy_)
            return legacy_->GetInt(attribute, value);
        return E_NOINTERFACE;
    }

private:
    IDeckLinkProfileAttributes* current_ = nullptr;
    IDeckLinkProfileAttributes_v15_3_1* legacy_ = nullptr;
};

void copyCFString(CFStringRef value, char* destination, size_t capacity)
{
    if (!destination || capacity == 0)
        return;

    destination[0] = '\0';
    if (!value)
        return;

    if (!CFStringGetCString(value, destination, capacity, kCFStringEncodingUTF8))
        std::strncpy(destination, "DeckLink output", capacity - 1);
    destination[capacity - 1] = '\0';
}

bool supportsOutputFormat(IDeckLinkOutput_v15_3_1* output, BMDPixelFormat pixelFormat)
{
    if (!output)
        return false;

    bool supported = false;
    BMDDisplayMode actualMode = bmdModeUnknown;
    return output->DoesSupportVideoMode(bmdVideoConnectionSDI,
                                        bmdModeHD1080p5994,
                                        pixelFormat,
                                        bmdNoVideoOutputConversion,
                                        bmdSupportedVideoModeDefault,
                                        &actualMode,
                                        &supported) == S_OK &&
           supported && actualMode == bmdModeHD1080p5994;
}

PMDeckLinkDeviceInfo inspectDevice(IDeckLink* device)
{
    PMDeckLinkDeviceInfo info{};
    info.subdevice_index = -1;

    CFStringRef displayName = nullptr;
    if (device->GetDisplayName(&displayName) == S_OK && displayName) {
        copyCFString(displayName, info.display_name, sizeof(info.display_name));
        CFRelease(displayName);
    }

    ProfileAttributes attributes(device);
    if (attributes) {
        int64_t value = 0;
        if (attributes.getInt(BMDDeckLinkPersistentID, &value) == S_OK)
            info.persistent_id = static_cast<uint64_t>(value);
        if (attributes.getInt(BMDDeckLinkSubDeviceIndex, &value) == S_OK)
            info.subdevice_index = value;
        if (attributes.getInt(BMDDeckLinkVideoIOSupport, &value) == S_OK)
            info.supports_playback = (value & bmdDeviceSupportsPlayback) != 0;
        info.is_active = true;
        if (attributes.getInt(BMDDeckLinkDuplex, &value) == S_OK)
            info.is_active = value != bmdDuplexInactive;
    }

    IDeckLinkOutput_v15_3_1* output = nullptr;
    if (info.supports_playback && info.is_active &&
        device->QueryInterface(IID_IDeckLinkOutput_v15_3_1,
                               reinterpret_cast<void**>(&output)) == S_OK && output) {
        // Some DeckLink models (notably Duo 2 configurations) support the
        // requested SDI timing but reject BGRA as a native output pixel format.
        // They remain usable by converting captured BGRA frames to 8-bit YUV.
        info.supports_1080p5994_bgra =
            supportsOutputFormat(output, bmdFormat8BitBGRA) ||
            supportsOutputFormat(output, bmdFormat8BitYUV);
        output->Release();
    }

    return info;
}

std::string stableID(IDeckLink* device)
{
    uint64_t persistentID = 0;
    int64_t subdeviceIndex = -1;
    ProfileAttributes attributes(device);
    if (attributes) {
        int64_t value = 0;
        if (attributes.getInt(BMDDeckLinkPersistentID, &value) == S_OK)
            persistentID = static_cast<uint64_t>(value);
        if (attributes.getInt(BMDDeckLinkSubDeviceIndex, &value) == S_OK)
            subdeviceIndex = value;
    }

    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%016llx:%lld",
                  static_cast<unsigned long long>(persistentID),
                  static_cast<long long>(subdeviceIndex));
    return buffer;
}

void writeError(char* destination, size_t capacity, const std::string& message)
{
    if (!destination || capacity == 0)
        return;
    std::strncpy(destination, message.c_str(), capacity - 1);
    destination[capacity - 1] = '\0';
}

} // namespace

struct OutputEndpoint {
    IDeckLink* device = nullptr;
    IDeckLinkOutput_v15_3_1* output = nullptr;
    IDeckLinkMacOutput* macOutput = nullptr;
    bool convertsToYUV = false;
    std::deque<IDeckLinkMutableVideoFrame*> retainedFrames;
    bool playbackStarted = false;

    void releaseFrames()
    {
        for (auto* frame : retainedFrames)
            frame->Release();
        retainedFrames.clear();
    }

    void stop()
    {
        if (output) {
            if (playbackStarted)
                output->StopScheduledPlayback(0, nullptr, kFrameTimeScale);
            output->DisableVideoOutput();
        }
        playbackStarted = false;
        releaseFrames();
        if (macOutput) {
            macOutput->Release();
            macOutput = nullptr;
        }
        if (output) {
            output->Release();
            output = nullptr;
        }
        if (device) {
            device->Release();
            device = nullptr;
        }
    }
};

struct PMDeckLinkSession {
    std::mutex mutex;
    std::vector<OutputEndpoint> endpoints;
    BMDTimeValue nextDisplayTime = 0;
    bool running = false;
    IDeckLinkVideoConversion* converter = nullptr;

    void stopUnlocked()
    {
        for (auto& endpoint : endpoints)
            endpoint.stop();
        endpoints.clear();
        if (converter) {
            converter->Release();
            converter = nullptr;
        }
        nextDisplayTime = 0;
        running = false;
    }
};

int32_t pm_decklink_discover(PMDeckLinkDeviceInfo* devices, int32_t capacity)
{
    IDeckLinkIterator* iterator = CreateDeckLinkIteratorInstance();
    if (!iterator)
        return -1;

    int32_t count = 0;
    IDeckLink* device = nullptr;
    while (iterator->Next(&device) == S_OK) {
        if (devices && count < std::max<int32_t>(capacity, 0))
            devices[count] = inspectDevice(device);
        ++count;
        device->Release();
        device = nullptr;
    }
    iterator->Release();
    return count;
}

PMDeckLinkSession* pm_decklink_session_create(void)
{
    return new PMDeckLinkSession();
}

void pm_decklink_session_destroy(PMDeckLinkSession* session)
{
    if (!session)
        return;
    pm_decklink_session_stop(session);
    delete session;
}

int32_t pm_decklink_session_start(PMDeckLinkSession* session,
                                  const char* const* outputIDs,
                                  int32_t outputCount,
                                  char* errorMessage,
                                  size_t errorCapacity)
{
    if (!session || !outputIDs || outputCount <= 0) {
        writeError(errorMessage, errorCapacity, "No DeckLink outputs were selected.");
        return -1;
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    session->stopUnlocked();

    std::unordered_set<std::string> requested;
    for (int32_t index = 0; index < outputCount; ++index) {
        if (outputIDs[index])
            requested.emplace(outputIDs[index]);
    }

    IDeckLinkIterator* iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) {
        writeError(errorMessage, errorCapacity, "The DeckLink runtime could not create a device iterator.");
        return -2;
    }

    IDeckLink* device = nullptr;
    while (iterator->Next(&device) == S_OK) {
        const auto id = stableID(device);
        if (requested.find(id) == requested.end()) {
            device->Release();
            device = nullptr;
            continue;
        }

        IDeckLinkOutput_v15_3_1* output = nullptr;
        IDeckLinkMacOutput* macOutput = nullptr;
        HRESULT result = device->QueryInterface(IID_IDeckLinkOutput_v15_3_1,
                                                reinterpret_cast<void**>(&output));
        const bool supportsBGRA = result == S_OK && supportsOutputFormat(output, bmdFormat8BitBGRA);
        const bool supportsYUV = result == S_OK && supportsOutputFormat(output, bmdFormat8BitYUV);
        if (result == S_OK && (supportsBGRA || supportsYUV))
            result = output->QueryInterface(IID_IDeckLinkMacOutput,
                                            reinterpret_cast<void**>(&macOutput));
        if (result == S_OK && macOutput)
            result = output->EnableVideoOutput(bmdModeHD1080p5994, bmdVideoOutputFlagDefault);

        if (result != S_OK || (!supportsBGRA && !supportsYUV) || !macOutput) {
            if (macOutput)
                macOutput->Release();
            if (output)
                output->Release();
            device->Release();
            iterator->Release();
            session->stopUnlocked();
            writeError(errorMessage, errorCapacity,
                       "A selected DeckLink endpoint could not enable 1080p59.94 playback (HRESULT " +
                       std::to_string(static_cast<uint32_t>(result)) + ").");
            return -3;
        }

        OutputEndpoint endpoint;
        endpoint.device = device;
        endpoint.output = output;
        endpoint.macOutput = macOutput;
        endpoint.convertsToYUV = !supportsBGRA && supportsYUV;
        session->endpoints.emplace_back(std::move(endpoint));
        requested.erase(id);
        device = nullptr;
    }
    iterator->Release();

    if (!requested.empty() || session->endpoints.empty()) {
        session->stopUnlocked();
        writeError(errorMessage, errorCapacity,
                   "One or more selected DeckLink outputs are unavailable in the current card profile.");
        return -4;
    }


    if (std::any_of(session->endpoints.begin(), session->endpoints.end(),
                    [](const OutputEndpoint& endpoint) { return endpoint.convertsToYUV; })) {
        session->converter = CreateVideoConversionInstance();
        if (!session->converter) {
            session->stopUnlocked();
            writeError(errorMessage, errorCapacity,
                       "DeckLink could not create the BGRA-to-YUV converter required by this output.");
            return -5;
        }
    }

    session->running = true;
    return 0;
}

int32_t pm_decklink_session_enqueue_pixel_buffer(PMDeckLinkSession* session,
                                                 void* pixelBuffer,
                                                 char* errorMessage,
                                                 size_t errorCapacity)
{
    if (!session || !pixelBuffer)
        return -1;

    std::lock_guard<std::mutex> lock(session->mutex);
    if (!session->running || session->endpoints.empty())
        return -2;

    uint32_t minimumSpace = kMaximumBufferedFrames;
    for (auto& endpoint : session->endpoints) {
        uint32_t buffered = 0;
        if (endpoint.output->GetBufferedVideoFrameCount(&buffered) != S_OK)
            return -3;
        while (endpoint.retainedFrames.size() > buffered) {
            endpoint.retainedFrames.front()->Release();
            endpoint.retainedFrames.pop_front();
        }
        minimumSpace = std::min(minimumSpace,
                                buffered >= kMaximumBufferedFrames ? 0U : kMaximumBufferedFrames - buffered);
    }

    if (minimumSpace == 0)
        return 1; // Bounded queue is full; dropping this source frame is intentional.

    const uint32_t copies = session->nextDisplayTime == 0 ? kMaximumBufferedFrames : 1;
    for (uint32_t copy = 0; copy < copies; ++copy) {
        for (auto& endpoint : session->endpoints) {
            IDeckLinkMutableVideoFrame* sourceFrame = nullptr;
            HRESULT result = endpoint.macOutput->CreateVideoFrameFromCVPixelBufferRef(pixelBuffer, &sourceFrame);
            if (result != S_OK || !sourceFrame) {
                writeError(errorMessage, errorCapacity,
                           "DeckLink could not wrap the captured BGRA pixel buffer.");
                return -4;
            }

            IDeckLinkMutableVideoFrame* frame = sourceFrame;
            if (endpoint.convertsToYUV) {
                frame = nullptr;
                result = endpoint.output->CreateVideoFrame(kOutputWidth,
                                                           kOutputHeight,
                                                           kOutputWidth * 2,
                                                           bmdFormat8BitYUV,
                                                           bmdFrameFlagDefault,
                                                           &frame);
                if (result == S_OK && frame)
                    result = session->converter->ConvertFrame(sourceFrame, frame);
                sourceFrame->Release();
                if (result != S_OK || !frame) {
                    if (frame)
                        frame->Release();
                    writeError(errorMessage, errorCapacity,
                               "DeckLink could not convert the captured BGRA frame to 8-bit YUV.");
                    return -5;
                }
            }
            result = endpoint.output->ScheduleVideoFrame(frame,
                                                         session->nextDisplayTime,
                                                         kFrameDuration,
                                                         kFrameTimeScale);
            if (result != S_OK) {
                frame->Release();
                writeError(errorMessage, errorCapacity,
                           "DeckLink rejected a scheduled video frame (HRESULT " +
                           std::to_string(static_cast<uint32_t>(result)) + ").");
                return -6;
            }
            endpoint.retainedFrames.push_back(frame);
        }
        session->nextDisplayTime += kFrameDuration;
    }

    if (!session->endpoints.front().playbackStarted) {
        for (auto& endpoint : session->endpoints) {
            HRESULT result = endpoint.output->StartScheduledPlayback(0, kFrameTimeScale, 1.0);
            if (result != S_OK) {
                writeError(errorMessage, errorCapacity,
                           "DeckLink could not start scheduled playback (HRESULT " +
                           std::to_string(static_cast<uint32_t>(result)) + ").");
                session->stopUnlocked();
                return -7;
            }
            endpoint.playbackStarted = true;
        }
    }

    return 0;
}

void pm_decklink_session_stop(PMDeckLinkSession* session)
{
    if (!session)
        return;
    std::lock_guard<std::mutex> lock(session->mutex);
    session->stopUnlocked();
}
