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
    char display_name[256];
} PMDeckLinkDeviceInfo;

/// Returns the total device count. Copies up to `capacity` records when
/// `devices` is non-null. A negative result indicates that the runtime could
/// not create a DeckLink iterator.
int32_t pm_decklink_discover(PMDeckLinkDeviceInfo* devices, int32_t capacity);

typedef struct PMDeckLinkSession PMDeckLinkSession;

PMDeckLinkSession* pm_decklink_session_create(void);
void pm_decklink_session_destroy(PMDeckLinkSession* session);

/// Claims the selected outputs and enables 1080p59.94 BGRA scheduled playback.
/// Returns zero on success and writes a diagnostic to `error_message` on failure.
int32_t pm_decklink_session_start(PMDeckLinkSession* session,
                                  const char* const* output_ids,
                                  int32_t output_count,
                                  char* error_message,
                                  size_t error_capacity);

/// Fans one CVPixelBufferRef out to every selected output. The session keeps a
/// bounded three-frame hardware queue and drops input frames when that queue is
/// full so latency cannot grow without bound.
int32_t pm_decklink_session_enqueue_pixel_buffer(PMDeckLinkSession* session,
                                                 void* cv_pixel_buffer,
                                                 char* error_message,
                                                 size_t error_capacity);

/// Stops scheduled playback, disables video output, and releases all devices.
void pm_decklink_session_stop(PMDeckLinkSession* session);

#ifdef __cplusplus
}
#endif

#endif
