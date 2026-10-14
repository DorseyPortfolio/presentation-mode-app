#ifndef PRESENTATION_MODE_DECKLINK_BRIDGE_H
#define PRESENTATION_MODE_DECKLINK_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PMDeckLinkDeviceInfo {
    uint64_t persistent_id;
    int64_t subdevice_index;
    bool supports_playback;
    bool is_active;
    bool supports_1080p5994_bgra;
    bool supports_1080p50;
    bool supports_sync_group;
    int64_t physical_group;
    bool has_physical_group;
    uint32_t mode_mask;
    char display_name[256];
    char model_name[256];
} PMDeckLinkDeviceInfo;

/// Returns the total device count. Copies up to `capacity` records when
/// `devices` is non-null. A negative result indicates that the runtime could
/// not create a DeckLink iterator.
int32_t pm_decklink_discover(PMDeckLinkDeviceInfo* devices, int32_t capacity);

typedef struct PMDeckLinkModeInfo {
    uint32_t mode_id;
    int32_t width, height;
    int64_t frame_duration, time_scale;
    bool progressive, supports_bgra, supports_yuv;
    char name[128];
} PMDeckLinkModeInfo;
/// Enumerates the selected endpoint's actual SDI modes for BGRA/YUV without
/// enabling output. Returns total count, or -1 if missing/inactive/unavailable.
int32_t pm_decklink_output_modes(const char* stable_id, PMDeckLinkModeInfo*, int32_t capacity);

typedef struct PMDeckLinkSession PMDeckLinkSession;

PMDeckLinkSession* pm_decklink_session_create(void);
void pm_decklink_session_destroy(PMDeckLinkSession* session);

typedef struct PMDeckLinkRoute {
    const char* id;
    const char* label;
    int32_t group;
    bool key;
    int64_t duration;
} PMDeckLinkRoute;
/// Copies a validated route while stopped; never enumerates or enables hardware.
int32_t pm_decklink_session_configure(PMDeckLinkSession*, const PMDeckLinkRoute*, size_t, char*, size_t);
/// Starts the configured route, only when explicitly armed by environment.
int32_t pm_decklink_session_start(PMDeckLinkSession*, char*, size_t);
/// Copies latest BGRA desktop; the scheduler repeats it at each group's cadence.
int32_t pm_decklink_session_enqueue_pixel_buffer(PMDeckLinkSession*, void*, char*, size_t);
/// -1 failed, 0 stopped, 1 waiting for first frame, 2 all groups playing.
int32_t pm_decklink_session_status(PMDeckLinkSession*, char*, size_t);
/// Clear key outputs, disable/release outputs, restore previous playback groups.
int32_t pm_decklink_session_stop(PMDeckLinkSession*, char*, size_t);

#ifdef __cplusplus
}
#endif

#endif
