#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace pm {
constexpr int64_t scale = 60000;
constexpr unsigned queueLimit = 3;
enum class Content { picture, whiteKey, blackKey };
struct Route { const char* id; const char* label; int group; bool key; int64_t duration; };
inline const std::array<Route, 5>& routes() {
    static const std::array<Route, 5> r{{
        {"00000000254a3ad3:3", "Side fill / Top Card (4)", 0, false, 1200},
        {"00000000254a3ad1:1", "Side key / Top Card (2)", 0, true, 1200},
        {"0000000002cf3ad0:0", "LED fill / Bottom Card (1)", 1, false, 1001},
        {"0000000002cf3ad3:3", "LED key / Bottom Card (4)", 1, true, 1001},
        {"0000000002cf3ad1:1", "Confidence / Bottom Card (2)", 2, false, 1001}
    }};
    return r;
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
    std::array<Group,3> groups{{{{0,1},1200},{{2,3},1001},{{4},1001}}};
    bool failed = false;
    std::string error;
    // One latest source is latched by the adapter for this whole tick. All
    // members prepare before either is scheduled. No per-member source drops.
    bool tick(Driver& driver) {
        if (failed) return false;
        for (int g=0;g<3;++g) {
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
                if (!driver.prepare(i,routes()[i].key?Content::whiteKey:Content::picture))
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
        for (int g=0;g<3;++g) { if (!driver.stop(g)) ok=false; groups[g].started=false; }
        for (size_t i=0;i<routes().size();++i) if (routes()[i].key && !driver.clear(i)) ok=false;
        driver.settleClear();
        for (size_t i=0;i<routes().size();++i) if (!driver.release(i)) ok=false;
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
