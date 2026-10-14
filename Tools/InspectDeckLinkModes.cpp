// Read-only SDK inventory. No sessions, output enabling, profile switching,
// playback, or device configuration writes are used here.
#include "DeckLinkBridge.h"
#include <cstdio>
#include <vector>
int main() {
    int n=pm_decklink_discover(nullptr,0);
    if(n<0) {std::fprintf(stderr,"DeckLink runtime unavailable\n");return 1;}
    std::vector<PMDeckLinkDeviceInfo> devices(n);
    int found=pm_decklink_discover(devices.data(),n);
    if(found<0 || found>n) {std::fprintf(stderr,"Inventory changed; rerun\n");return 1;}
    for(int i=0;i<found;++i) {
        const auto& d=devices[i];char id[64];
        std::snprintf(id,sizeof(id),"%016llx:%lld",(unsigned long long)d.persistent_id,(long long)d.subdevice_index);
        std::printf("OUTPUT %s | model=%s | connector=%s | cardGroup=%s%016llx | active=%d playback=%d sync=%d\n",id,d.model_name,d.display_name,d.has_physical_group?"":"unknown:",(unsigned long long)d.physical_group,d.is_active,d.supports_playback,d.supports_sync_group);
        if(!d.is_active || !d.supports_playback) continue;
        int count=pm_decklink_output_modes(id,nullptr,0);
        if(count<0) {std::fprintf(stderr,"Mode discovery failed for %s\n",id);return 1;}
        std::vector<PMDeckLinkModeInfo> modes(count);
        int actual=pm_decklink_output_modes(id,modes.data(),count);
        if(actual<0 || actual>count) {std::fprintf(stderr,"Modes changed; rerun\n");return 1;}
        std::printf("  SDK_SUPPORTED_MODES %d\n",actual);
        for(int m=0;m<actual;++m) {
            const auto& mode=modes[m];
            std::printf("  %s id=%08x %dx%d %lld/%lld progressive=%d BGRA=%d YUV=%d\n",mode.name,mode.mode_id,mode.width,mode.height,(long long)mode.time_scale,(long long)mode.frame_duration,mode.progressive,mode.supports_bgra,mode.supports_yuv);
        }
    }
}
