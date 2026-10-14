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
#include "LargoProfile.hpp"

constexpr BMDTimeValue kFrameDuration = 2002;
constexpr BMDTimeScale kFrameTimeScale = 120000;
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

BMDDisplayMode modeForDuration(int64_t d) {
    switch(d) {
    case 5005:return bmdModeHD1080p2398; case 5000:return bmdModeHD1080p24;
    case 4800:return bmdModeHD1080p25; case 4004:return bmdModeHD1080p2997;
    case 4000:return bmdModeHD1080p30; case 2400:return bmdModeHD1080p50;
    case 2002:return bmdModeHD1080p5994; case 2000:return bmdModeHD1080p6000;
    default:return bmdModeUnknown;
    }
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

    CFStringRef modelName = nullptr;
    if (device->GetModelName(&modelName) == S_OK && modelName) {
        copyCFString(modelName, info.model_name, sizeof(info.model_name));
        CFRelease(modelName);
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
        info.has_physical_group = attributes.getInt(BMDDeckLinkDeviceGroupID, &info.physical_group) == S_OK;
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
        const int64_t durations[]={5005,5000,4800,4004,4000,2400,2002,2000};
        for(unsigned i=0;i<8;++i) if(supportsOutputFormat(output,bmdFormat8BitBGRA,modeForDuration(durations[i])) || supportsOutputFormat(output,bmdFormat8BitYUV,modeForDuration(durations[i]))) info.mode_mask |= 1u<<i;
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
    std::vector<pm::Route> routes=pm::routes();
    std::vector<OutputEndpoint> endpoints=std::vector<OutputEndpoint>(routes.size());
    std::vector<bool> started=std::vector<bool>(3,false);
    pm::Scheduler scheduler{routes};
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
        if(std::any_of(endpoints.begin(),endpoints.end(),[](const OutputEndpoint& e){return e.enabled;}))
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
        scheduler=pm::Scheduler{routes};lastError.clear();
        white=solidBuffer(true);black=solidBuffer(false);
        if(!white || !black) return reject("Cannot allocate solid key frames");
        auto* iterator=CreateDeckLinkIteratorInstance();
        if(!iterator) return reject("DeckLink runtime cannot enumerate outputs");
        IDeckLink* device=nullptr;
        while(iterator->Next(&device)==S_OK) {
            auto id=stableID(device);
            auto r=std::find_if(routes.begin(),routes.end(),[&](const pm::Route& r){return id==r.id;});
            if(r==routes.end()) {device->Release();continue;}
            auto i=static_cast<size_t>(r-routes.begin());auto& e=endpoints[i];e.device=device;
        }
        iterator->Release();
        // Complete all capability checks before enabling any output.
        for(size_t i=0;i<endpoints.size();++i) {
            auto& e=endpoints[i];const auto& r=routes[i];
            if(!e.device) return reject(std::string("Missing verified endpoint: ")+r.label+" ["+r.id+"]");
            ProfileAttributes attr(e.device);int64_t duplex=bmdDuplexInactive;
            if(!attr || attr.getInt(BMDDeckLinkDuplex,&duplex)!=S_OK || duplex==bmdDuplexInactive)
                return reject(std::string("Inactive endpoint: ")+r.label);
            if(e.device->QueryInterface(IID_IDeckLinkOutput_v15_3_1,reinterpret_cast<void**>(&e.output))!=S_OK || !e.output)
                return reject(std::string("No playback interface: ")+r.label);
            auto mode=modeForDuration(r.duration);
            bool bgra=supportsOutputFormat(e.output,bmdFormat8BitBGRA,mode);
            bool yuv=supportsOutputFormat(e.output,bmdFormat8BitYUV,mode);
            e.convertsToYUV=!bgra && yuv;
            if((!bgra && !yuv) || e.output->QueryInterface(IID_IDeckLinkMacOutput,reinterpret_cast<void**>(&e.macOutput))!=S_OK || !e.macOutput)
                return reject(std::string("Unsupported verified format: ")+r.label);
            if(scheduler.groups[r.group].indices.size()==2) {
                bool sync=false;
                if(attr.getFlag(BMDDeckLinkSupportsSynchronizeToPlaybackGroup,&sync)!=S_OK || !sync ||
                   attr.getInt(BMDDeckLinkDeviceGroupID,&e.physicalGroup)!=S_OK ||
                   e.device->QueryInterface(IID_IDeckLinkConfiguration,reinterpret_cast<void**>(&e.config))!=S_OK || !e.config ||
                   e.config->GetInt(bmdDeckLinkConfigPlaybackGroup,&e.oldGroup)!=S_OK)
                    return reject(std::string("Synchronized playback unavailable: ")+r.label);
            }
        }
        for(const auto& group:scheduler.groups)
            if(group.indices.size()==2 && endpoints[group.indices[0]].physicalGroup!=endpoints[group.indices[1]].physicalGroup)
                return reject("Fill/key pair must share a physical card");
        if(std::any_of(endpoints.begin(),endpoints.end(),[](const OutputEndpoint& e){return e.convertsToYUV;})) {
            converter=CreateVideoConversionInstance();if(!converter) return reject("Video conversion unavailable");
        }
        // Capture this log during validation: the runtime grouping setting can
        // survive a process crash until reboot. Normal shutdown restores it.
        for(size_t i=0;i<endpoints.size();++i)
            std::fprintf(stderr,"Playback group rollback: %s previous=%lld\n",routes[i].id.c_str(),static_cast<long long>(endpoints[i].oldGroup));
        std::fflush(stderr);
        for(size_t i=0;i<endpoints.size();++i) {
            auto& e=endpoints[i];const auto& r=routes[i];
            if(scheduler.groups[r.group].indices.size()==2) {
                e.grouped=true; // Restore even after a failed/uncertain SetInt.
                int64_t group=0x504d00000000LL+(static_cast<int64_t>(getpid())<<8)+r.group;
                if(e.config->SetInt(bmdDeckLinkConfigPlaybackGroup,group)!=S_OK) return reject("Cannot configure synchronized pair");
            }
            auto flags=scheduler.groups[r.group].indices.size()==2?bmdVideoOutputSynchronizeToPlaybackGroup:bmdVideoOutputFlagDefault;
            auto mode=modeForDuration(r.duration);
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

int32_t pm_decklink_output_modes(const char* id, PMDeckLinkModeInfo* records, int32_t capacity) {
    if(!id || !*id) return -1;
    auto* iterator=CreateDeckLinkIteratorInstance();
    if(!iterator) return -1;
    IDeckLink* device=nullptr;
    IDeckLinkOutput_v15_3_1* output=nullptr;
    while(iterator->Next(&device)==S_OK) {
        if(stableID(device)==id) {
            auto info=inspectDevice(device);
            if(info.supports_playback && info.is_active)
                device->QueryInterface(IID_IDeckLinkOutput_v15_3_1,reinterpret_cast<void**>(&output));
            device->Release();break;
        }
        device->Release();
    }
    iterator->Release();
    if(!output) return -1;
    IDeckLinkDisplayModeIterator* modes=nullptr;
    if(output->GetDisplayModeIterator(&modes)!=S_OK || !modes) {output->Release();return -1;}
    int32_t count=0;
    IDeckLinkDisplayMode* mode=nullptr;
    while(modes->Next(&mode)==S_OK) {
        PMDeckLinkModeInfo info{};
        info.mode_id=mode->GetDisplayMode();
        info.width=static_cast<int32_t>(mode->GetWidth());
        info.height=static_cast<int32_t>(mode->GetHeight());
        info.progressive=mode->GetFieldDominance()==bmdProgressiveFrame;
        info.supports_bgra=supportsOutputFormat(output,bmdFormat8BitBGRA,mode->GetDisplayMode());
        info.supports_yuv=supportsOutputFormat(output,bmdFormat8BitYUV,mode->GetDisplayMode());
        if(mode->GetFrameRate(&info.frame_duration,&info.time_scale)==S_OK && info.frame_duration>0 && info.time_scale>0 && (info.supports_bgra || info.supports_yuv)) {
            CFStringRef name=nullptr;
            if(mode->GetName(&name)==S_OK && name) {copyCFString(name,info.name,sizeof(info.name));CFRelease(name);}
            if(records && count<std::max<int32_t>(capacity,0)) records[count]=info;
            ++count;
        }
        mode->Release();
    }
    modes->Release();output->Release();return count;
}

PMDeckLinkSession* pm_decklink_session_create(void) { return new PMDeckLinkSession(); }
void pm_decklink_session_destroy(PMDeckLinkSession* session) { delete session; }
int32_t pm_decklink_session_configure(PMDeckLinkSession* session,const PMDeckLinkRoute* records,size_t count,char* error,size_t capacity) {
    if(!session) return -1;
    std::lock_guard<std::mutex> lock(session->mutex);
    if(session->running) {writeError(error,capacity,"Stop outputs before applying a profile");return -1;}
    if(!records || count==0 || count>32) {writeError(error,capacity,"Invalid route count");return -1;}
    std::vector<pm::Route> routes;
    for(size_t i=0;i<count;++i) {
        const auto& r=records[i];
        if(!r.id || !r.label) {writeError(error,capacity,"Missing route identity");return -1;}
        routes.push_back({r.id,r.label,r.group,r.key,r.duration});
    }
    auto validation=pm::validateRoutes(routes);
    if(!validation.empty()) {writeError(error,capacity,validation);return -1;}
    if(!session->stopUnlocked()) {writeError(error,capacity,session->lastError);return -1;}
    session->routes=routes;
    session->scheduler=pm::Scheduler{routes};
    session->endpoints.resize(routes.size());
    session->started.assign(session->scheduler.groups.size(),false);
    session->lastError.clear();return 0;
}
int32_t pm_decklink_session_start(PMDeckLinkSession* session,char* error,size_t capacity) {
    if(!session) return -1;
    // Offline lifecycle tests must never enumerate devices or claim live outputs.
    // Packaged apps are ready for the operator's explicit Canva Mode action.
    #ifdef PM_OFFLINE_TEST_BUILD
    writeError(error,capacity,"Offline test build: hardware output is disabled.");return -1;
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
