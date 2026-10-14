#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>
#include <set>

namespace pm {
constexpr int64_t scale = 120000;
constexpr unsigned queueLimit = 3;
enum class Content { picture, whiteKey, blackKey };
struct Route { std::string id; std::string label; int group; bool key; int64_t duration; };
inline bool validDuration(int64_t d) {
    return d==5005 || d==5000 || d==4800 || d==4004 || d==4000 || d==2400 || d==2002 || d==2000;
}
inline std::string validateRoutes(const std::vector<Route>& routes) {
    if(routes.empty() || routes.size()>32) return "Choose between 1 and 32 endpoints";
    std::set<std::string> ids;
    int group=-1; int members=0; int64_t duration=0;
    for(const auto& r:routes) {
        if(r.id.empty() || !ids.insert(r.id).second) return "Each endpoint must be assigned only once";
        if(!validDuration(r.duration)) return "Unsupported 1080p timing";
        if(r.group==group+1) {
            if(r.key) return "A destination must begin with a picture output";
            group=r.group; members=1; duration=r.duration;
        } else if(r.group==group && members==1 && r.key && r.duration==duration) { ++members; }
        else return "Destination must contain one picture and an optional matching key";
    }
    return {};
}
struct Driver {
    virtual ~Driver() = default;
    virtual bool buffered(size_t index, unsigned& count) = 0;
    virtual bool prepare(size_t index, Content content) = 0;
    virtual bool schedule(size_t index, int64_t time, int64_t duration) = 0;
    virtual bool start(int group) = 0;
    virtual bool stop(int group) = 0;
    virtual bool clear(size_t keyIndex) = 0;
    virtual void settleClear() = 0;
    virtual bool release(size_t index) = 0;
};
struct Group { std::vector<size_t> indices; int64_t duration; int64_t next = 0; bool started = false; };
class Scheduler {
public:
    std::vector<Route> routes;
    std::vector<Group> groups;
    explicit Scheduler(std::vector<Route> configured): routes(std::move(configured)) {
        error=validateRoutes(routes); failed=!error.empty();
        if(failed) { routes.clear(); return; }
        for(size_t i=0;i<routes.size();++i) {
            const auto& r=routes[i];
            if(static_cast<size_t>(r.group)==groups.size()) groups.push_back(Group{{},r.duration});
            groups[r.group].indices.push_back(i);
        }
    }
    bool failed = false;
    std::string error;
    // One latest source is latched by the adapter for this whole tick. All
    // members prepare before either is scheduled. No per-member source drops.
    bool tick(Driver& driver) {
        if (failed) return false;
        for (int g=0;g<static_cast<int>(groups.size());++g) {
            auto& group=groups[g];
            unsigned maximum=0, minimum=queueLimit;
            for (auto i:group.indices) {
                unsigned n=0;
                if (!driver.buffered(i,n)) return fail(driver,"Cannot read output queue");
                if (n>queueLimit) return fail(driver,"Unexpected output queue depth");
                maximum=std::max(maximum,n); minimum=std::min(minimum,n);
            }
            if (group.started && minimum==0) return fail(driver,"Output underrun; keys cleared");
            if (maximum-minimum>1) return fail(driver,"Fill/key queues diverged; keys cleared");
            if (maximum==queueLimit) continue;
            for (auto i:group.indices)
                if (!driver.prepare(i,routes[i].key?Content::whiteKey:Content::picture))
                    return fail(driver,"Cannot prepare paired output frames");
            for (unsigned n=maximum;n<queueLimit;++n) {
                for (auto i:group.indices)
                    if (!driver.schedule(i,group.next,group.duration))
                        return fail(driver,"Cannot schedule paired frame; keys cleared");
                group.next+=group.duration;
            }
            if (!group.started) {
                // Native synchronized group start is one call, not two races.
                if (!driver.start(g)) return fail(driver,"Cannot start output group");
                group.started=true;
            }
        }
        return true;
    }
    bool shutdown(Driver& driver) {
        bool ok=true;
        // Stop paired clocks first, clear only key endpoints, give the black
        // matte time to leave SDI, then disable and restore prior group values.
        for (int g=0;g<static_cast<int>(groups.size());++g) { if (!driver.stop(g)) ok=false; groups[g].started=false; }
        for (size_t i=0;i<routes.size();++i) if (routes[i].key && !driver.clear(i)) ok=false;
        driver.settleClear();
        for (size_t i=0;i<routes.size();++i) if (!driver.release(i)) ok=false;
        if (!ok) { failed=true; error += " Output cleanup failed; inspect hardware before reuse."; }
        return ok;
    }
private:
    bool fail(Driver& d,const char* reason) { failed=true;error=reason;shutdown(d);return false; }
};
// BGRA helpers are shared with the adapter and directly exercised offline.
inline void opaqueCopy(const uint8_t* input,size_t inStride,uint8_t* output,size_t outStride,size_t width,size_t height) {
    for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x) {
        const auto* s=input+y*inStride+4*x; auto* d=output+y*outStride+4*x;
        d[0]=s[0]; d[1]=s[1]; d[2]=s[2]; d[3]=255;
    }
}
inline void solid(uint8_t* output,size_t stride,size_t width,size_t height,bool white) {
    for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x) {
        auto* d=output+y*stride+4*x;d[0]=d[1]=d[2]=white?255:0;d[3]=255;
    }
}
}
