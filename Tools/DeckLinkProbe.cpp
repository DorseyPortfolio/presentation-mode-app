#include "DeckLinkBridge.h"

#include <cstdio>
#include <vector>

int main()
{
    const int32_t count = pm_decklink_discover(nullptr, 0);
    if (count < 0) {
        std::fputs("DeckLink runtime unavailable\n", stderr);
        return 1;
    }

    std::vector<PMDeckLinkDeviceInfo> records(static_cast<size_t>(count));
    const int32_t discovered = pm_decklink_discover(records.data(), count);
    if (discovered < 0) {
        std::fputs("DeckLink discovery failed\n", stderr);
        return 1;
    }

    std::printf("DeckLink devices: %d\n", discovered);
    for (int32_t index = 0; index < discovered && index < count; ++index) {
        const auto& record = records[static_cast<size_t>(index)];
        std::printf("%016llx:%lld | %s | playback=%d active=%d 1080p59.94-bgra=%d\n",
                    static_cast<unsigned long long>(record.persistent_id),
                    static_cast<long long>(record.subdevice_index),
                    record.display_name,
                    record.supports_playback,
                    record.is_active,
                    record.supports_1080p5994_bgra);
    }
    return 0;
}
