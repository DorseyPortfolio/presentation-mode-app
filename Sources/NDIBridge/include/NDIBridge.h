#ifndef PRESENTATION_MODE_NDI_BRIDGE_H
#define PRESENTATION_MODE_NDI_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PMNDISender PMNDISender;
PMNDISender* pm_ndi_sender_create(void);
void pm_ndi_sender_destroy(PMNDISender* sender);
int32_t pm_ndi_sender_start(PMNDISender* sender, const char* runtime_path,
                            const char* source_name, char* error, size_t capacity);
int32_t pm_ndi_sender_send_pixel_buffer(PMNDISender* sender, void* pixel_buffer,
                                        char* error, size_t capacity);
void pm_ndi_sender_stop(PMNDISender* sender);

#ifdef __cplusplus
}
#endif
#endif
