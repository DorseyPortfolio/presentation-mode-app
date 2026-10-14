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
#include <CoreVideo/CoreVideo.h>
#include <chrono>
#include <condition_variable>
#include <thread>
#include <unistd.h>
#include <cstdlib>
#include "PlayoutCore.hpp"

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

    HRESULT getFlag(BMDDeckLinkAttributeID attribute, bool* value) const {
        if (current_) return current_->GetFlag(attribute, value);
        if (legacy_) return legacy_->GetFlag(attribute, value);
        return E_NOINTERFACE;
    }

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

bool supportsOutputFormat(IDeckLinkOutput_v15_3_1* output, BMDPixelFormat pixelFormat, BMDDisplayMode mode = bmdModeHD1080p5994)
{
    if (!output)
        return false;

    bool supported = false;
    BMDDisplayMode actualMode = bmdModeUnknown;
    return output->DoesSupportVideoMode(bmdVideoConnectionSDI,
                                        mode,
                                        pixelFormat,
                                        bmdNoVideoOutputConversion,
                                        bmdSupportedVideoModeDefault,
                                        &actualMode,
                                        &supported) == S_OK &&
           supported && actualMode == mode;
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
        info.supports_1080p50 = supportsOutputFormat(output, bmdFormat8BitBGRA, bmdModeHD1080p50) || supportsOutputFormat(output, bmdFormat8BitYUV, bmdModeHD1080p50);
        attributes.getFlag(BMDDeckLinkSupportsSynchronizeToPlaybackGroup, &info.supports_sync_group);
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
    IDeckLink* device=nullptr;
    IDeckLinkOutput_v15_3_1* output=nullptr;
    IDeckLinkMacOutput* macOutput=nullptr;
    IDeckLinkConfiguration* config=nullptr;
    int64_t oldGroup=0;
    int64_t physicalGroup=0;
    bool grouped=false, enabled=false, convertsToYUV=false;
    IDeckLinkMutableVideoFrame* prepared=nullptr;
    std::deque<IDeckLinkMutableVideoFrame*> retained;
};

struct PMDeckLinkSession : pm::Driver {
    std::mutex mutex;
    std::condition_variable wake;
    bool running=false, terminate=false;
    std::thread worker;
    std::array<OutputEndpoint,5> endpoints;
    std::array<bool,3> started{{false,false,false}};
    pm::Scheduler scheduler;
    CVPixelBufferRef latest=nullptr, white=nullptr, black=nullptr;
    IDeckLinkVideoConversion* converter=nullptr;
    std::string lastError;

    PMDeckLinkSession() { worker=std::thread([this] { run(); }); }
    ~PMDeckLinkSession() {
        { std::lock_guard<std::mutex> lock(mutex); stopUnlocked(); terminate=true; }
        wake.notify_one();worker.join();
    }
    static CVPixelBufferRef solidBuffer(bool whiteValue) {
        CVPixelBufferRef p=nullptr;
        if(CVPixelBufferCreate(nullptr,kOutputWidth,kOutputHeight,kCVPixelFormatType_32BGRA,nullptr,&p)!=kCVReturnSuccess) return nullptr;
        if(CVPixelBufferLockBaseAddress(p,0)!=kCVReturnSuccess) { CVPixelBufferRelease(p);return nullptr; }
        auto* bytes=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(p));
        if(bytes) pm::solid(bytes,CVPixelBufferGetBytesPerRow(p),kOutputWidth,kOutputHeight,whiteValue);
        CVPixelBufferUnlockBaseAddress(p,0);
        if(!bytes) { CVPixelBufferRelease(p);return nullptr; }
        return p;
    }
    void run() {
        std::unique_lock<std::mutex> lock(mutex);
        while(!terminate) {
            wake.wait_for(lock,std::chrono::milliseconds(4),[this]{return terminate;});
            if(terminate) break;
            if(running && latest && !scheduler.tick(*this)) {
                lastError=scheduler.error;
                running=false;
                freeBuffers();
            }
        }
    }
    bool buffered(size_t i,unsigned& count) override {
        auto& e=endpoints[i];uint32_t n=0;
        if(!e.output || e.output->GetBufferedVideoFrameCount(&n)!=S_OK) return false;
        while(e.retained.size()>n) {e.retained.front()->Release();e.retained.pop_front();}
        count=n;return true;
    }
    bool prepare(size_t i,pm::Content content) override {
        auto& e=endpoints[i];
        if(e.prepared) {e.prepared->Release();e.prepared=nullptr;}
        auto buffer=content==pm::Content::picture?latest:content==pm::Content::whiteKey?white:black;
        if(!buffer || !e.macOutput) return false;
        IDeckLinkMutableVideoFrame* source=nullptr;
        if(e.macOutput->CreateVideoFrameFromCVPixelBufferRef(buffer,&source)!=S_OK || !source) return false;
        if(!e.convertsToYUV) { e.prepared=source;return true; }
        auto result=e.output->CreateVideoFrame(kOutputWidth,kOutputHeight,kOutputWidth*2,bmdFormat8BitYUV,bmdFrameFlagDefault,&e.prepared);
        if(result==S_OK && e.prepared && converter) result=converter->ConvertFrame(source,e.prepared);
        else result=E_FAIL;
        source->Release();
        return result==S_OK && e.prepared;
    }
    bool schedule(size_t i,int64_t time,int64_t duration) override {
        auto& e=endpoints[i];
        if(!e.prepared || e.output->ScheduleVideoFrame(e.prepared,time,duration,pm::scale)!=S_OK) return false;
        e.prepared->AddRef();e.retained.push_back(e.prepared);return true;
    }
    bool start(int g) override {
        started[g]=true; // Also stop after an uncertain failed start.
        return endpoints[scheduler.groups[g].indices.front()].output->StartScheduledPlayback(0,pm::scale,1.0)==S_OK;
    }
    bool stop(int g) override {
        if(!started[g]) return true;
        started[g]=false;
        auto* output=endpoints[scheduler.groups[g].indices.front()].output;
        return output && output->StopScheduledPlayback(0,nullptr,pm::scale)==S_OK;
    }
    bool clear(size_t i) override {
        auto& e=endpoints[i];
        if(!e.enabled) return true;
        return prepare(i,pm::Content::blackKey) && e.output->DisplayVideoFrameSync(e.prepared)==S_OK;
    }
    void settleClear() override {
        if(endpoints[1].enabled || endpoints[3].enabled)
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
    }
    bool release(size_t i) override {
        auto& e=endpoints[i];bool ok=true;
        if(e.enabled && e.output->DisableVideoOutput()!=S_OK) ok=false;
        e.enabled=false;
        if(e.grouped && e.config && e.config->SetInt(bmdDeckLinkConfigPlaybackGroup,e.oldGroup)!=S_OK) ok=false;
        e.grouped=false;
        if(e.prepared) e.prepared->Release();
        for(auto* f:e.retained) f->Release();
        if(e.macOutput) e.macOutput->Release();
        if(e.output) e.output->Release();
        if(e.config) e.config->Release();
        if(e.device) e.device->Release();
        e=OutputEndpoint{};
        return ok;
    }
    void freeBuffers() {
        if(latest) CVPixelBufferRelease(latest);
        if(white) CVPixelBufferRelease(white);
        if(black) CVPixelBufferRelease(black);
        latest=white=black=nullptr;
        if(converter) converter->Release();converter=nullptr;
    }
    bool stopUnlocked() {
        running=false;
        bool ok=scheduler.shutdown(*this);
        if(!ok) { lastError=scheduler.error;std::fprintf(stderr,"%s\n",lastError.c_str());std::fflush(stderr); }
        freeBuffers();return ok;
    }
    bool reject(const std::string& error) {
        lastError=error;
        if(!stopUnlocked()) lastError=error+" "+scheduler.error;
        return false;
    }
    bool initialize() {
        scheduler=pm::Scheduler{};lastError.clear();
        white=solidBuffer(true);black=solidBuffer(false);
        if(!white || !black) return reject("Cannot allocate solid key frames");
        auto* iterator=CreateDeckLinkIteratorInstance();
        if(!iterator) return reject("DeckLink runtime cannot enumerate outputs");
        IDeckLink* device=nullptr;
        while(iterator->Next(&device)==S_OK) {
            auto id=stableID(device);
            auto r=std::find_if(pm::routes().begin(),pm::routes().end(),[&](const pm::Route& r){return id==r.id;});
            if(r==pm::routes().end()) {device->Release();continue;}
            auto i=static_cast<size_t>(r-pm::routes().begin());auto& e=endpoints[i];e.device=device;
        }
        iterator->Release();
        // Complete all capability checks before enabling any output.
        for(size_t i=0;i<endpoints.size();++i) {
            auto& e=endpoints[i];const auto& r=pm::routes()[i];
            if(!e.device) return reject(std::string("Missing verified endpoint: ")+r.label+" ["+r.id+"]");
            ProfileAttributes attr(e.device);int64_t duplex=bmdDuplexInactive;
            if(!attr || attr.getInt(BMDDeckLinkDuplex,&duplex)!=S_OK || duplex==bmdDuplexInactive)
                return reject(std::string("Inactive endpoint: ")+r.label);
            if(e.device->QueryInterface(IID_IDeckLinkOutput_v15_3_1,reinterpret_cast<void**>(&e.output))!=S_OK || !e.output)
                return reject(std::string("No playback interface: ")+r.label);
            auto mode=r.duration==1200?bmdModeHD1080p50:bmdModeHD1080p5994;
            bool bgra=supportsOutputFormat(e.output,bmdFormat8BitBGRA,mode);
            bool yuv=supportsOutputFormat(e.output,bmdFormat8BitYUV,mode);
            e.convertsToYUV=!bgra && yuv;
            if((!bgra && !yuv) || e.output->QueryInterface(IID_IDeckLinkMacOutput,reinterpret_cast<void**>(&e.macOutput))!=S_OK || !e.macOutput)
                return reject(std::string("Unsupported verified format: ")+r.label);
            if(r.group<2) {
                bool sync=false;
                if(attr.getFlag(BMDDeckLinkSupportsSynchronizeToPlaybackGroup,&sync)!=S_OK || !sync ||
                   attr.getInt(BMDDeckLinkDeviceGroupID,&e.physicalGroup)!=S_OK ||
                   e.device->QueryInterface(IID_IDeckLinkConfiguration,reinterpret_cast<void**>(&e.config))!=S_OK || !e.config ||
                   e.config->GetInt(bmdDeckLinkConfigPlaybackGroup,&e.oldGroup)!=S_OK)
                    return reject(std::string("Synchronized playback unavailable: ")+r.label);
            }
        }
        if(endpoints[0].physicalGroup!=endpoints[1].physicalGroup || endpoints[2].physicalGroup!=endpoints[3].physicalGroup)
            return reject("A verified fill/key pair no longer shares a physical card");
        if(std::any_of(endpoints.begin(),endpoints.end(),[](const OutputEndpoint& e){return e.convertsToYUV;})) {
            converter=CreateVideoConversionInstance();if(!converter) return reject("Video conversion unavailable");
        }
        // Capture this log during validation: the runtime grouping setting can
        // survive a process crash until reboot. Normal shutdown restores it.
        for(size_t i=0;i<4;++i)
            std::fprintf(stderr,"Playback group rollback: %s previous=%lld\n",pm::routes()[i].id,static_cast<long long>(endpoints[i].oldGroup));
        std::fflush(stderr);
        for(size_t i=0;i<endpoints.size();++i) {
            auto& e=endpoints[i];const auto& r=pm::routes()[i];
            if(r.group<2) {
                e.grouped=true; // Restore even after a failed/uncertain SetInt.
                int64_t group=0x504d00000000LL+(static_cast<int64_t>(getpid())<<8)+r.group;
                if(e.config->SetInt(bmdDeckLinkConfigPlaybackGroup,group)!=S_OK) return reject("Cannot configure synchronized pair");
            }
            auto flags=r.group<2?bmdVideoOutputSynchronizeToPlaybackGroup:bmdVideoOutputFlagDefault;
            auto mode=r.duration==1200?bmdModeHD1080p50:bmdModeHD1080p5994;
            if(e.output->EnableVideoOutput(mode,flags)!=S_OK) return reject(std::string("Cannot enable output: ")+r.label);
            e.enabled=true;
            if(r.key && !clear(i)) return reject(std::string("Cannot initialize key to off: ")+r.label);
        }
        running=true;return true;
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

PMDeckLinkSession* pm_decklink_session_create(void) { return new PMDeckLinkSession(); }
void pm_decklink_session_destroy(PMDeckLinkSession* session) { delete session; }
int32_t pm_decklink_session_start(PMDeckLinkSession* session,char* error,size_t capacity) {
    if(!session) return -1;
    // An isolated candidate cannot drive outputs simply by being opened.
    #ifndef PM_PRODUCTION_BUILD
    const char* gate=std::getenv("PRESENTATION_MODE_ENABLE_HARDWARE");
    if(!gate || std::strcmp(gate,"1")!=0) {
        writeError(error,capacity,"Validation candidate: hardware output is not armed.");return -1;
    }
    #endif
    std::lock_guard<std::mutex> lock(session->mutex);
    if(session->running) {writeError(error,capacity,"Already running");return -1;}
    if(!session->initialize()) {writeError(error,capacity,session->lastError);return -1;}
    return 0;
}
int32_t pm_decklink_session_enqueue_pixel_buffer(PMDeckLinkSession* session,void* opaque,char* error,size_t capacity) {
    if(!session || !opaque) return -1;
    auto submissionFailure=[&](const char* reason) {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->reject(reason);writeError(error,capacity,session->lastError);return int32_t(-1);
    };
    auto input=static_cast<CVPixelBufferRef>(opaque);
    if(CVPixelBufferGetPixelFormatType(input)!=kCVPixelFormatType_32BGRA || CVPixelBufferGetWidth(input)!=kOutputWidth || CVPixelBufferGetHeight(input)!=kOutputHeight) {
        return submissionFailure("Capture must supply 1920x1080 BGRA");
    }
    CVPixelBufferRef copy=nullptr;
    if(CVPixelBufferCreate(nullptr,kOutputWidth,kOutputHeight,kCVPixelFormatType_32BGRA,nullptr,&copy)!=kCVReturnSuccess) return submissionFailure("Cannot allocate capture copy");
    if(CVPixelBufferLockBaseAddress(input,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) {CVPixelBufferRelease(copy);return submissionFailure("Cannot read capture frame");}
    if(CVPixelBufferLockBaseAddress(copy,0)!=kCVReturnSuccess) {CVPixelBufferUnlockBaseAddress(input,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(copy);return submissionFailure("Cannot write capture copy");}
    auto* source=static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(input));auto* destination=static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(copy));
    bool valid=source && destination;
    if(valid) pm::opaqueCopy(source,CVPixelBufferGetBytesPerRow(input),destination,CVPixelBufferGetBytesPerRow(copy),kOutputWidth,kOutputHeight);
    CVPixelBufferUnlockBaseAddress(copy,0);CVPixelBufferUnlockBaseAddress(input,kCVPixelBufferLock_ReadOnly);
    if(!valid) {CVPixelBufferRelease(copy);return submissionFailure("Capture buffer has no pixel data");}
    std::lock_guard<std::mutex> lock(session->mutex);
    if(!session->running) {CVPixelBufferRelease(copy);writeError(error,capacity,session->lastError);return -1;}
    if(session->latest) CVPixelBufferRelease(session->latest);
    session->latest=copy;return 0;
}
int32_t pm_decklink_session_status(PMDeckLinkSession* session,char* error,size_t capacity) {
    if(!session) return -1;
    std::lock_guard<std::mutex> lock(session->mutex);
    writeError(error,capacity,session->lastError);
    if(!session->lastError.empty()) return -1;
    if(!session->running) return 0;
    return std::all_of(session->scheduler.groups.begin(),session->scheduler.groups.end(),[](const pm::Group& g){return g.started;})?2:1;
}
int32_t pm_decklink_session_stop(PMDeckLinkSession* session,char* error,size_t capacity) {
    if(!session) return 0;
    std::lock_guard<std::mutex> lock(session->mutex);
    bool ok=session->stopUnlocked();writeError(error,capacity,session->lastError);return ok?0:-1;
}
