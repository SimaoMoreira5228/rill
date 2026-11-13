#ifndef RILL_MEDIA_H
#define RILL_MEDIA_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Remuxes one video-only input and one audio-only input into a single file.
// Streams are copied; no decoding or encoding happens. Returns 0 on success.
int rill_media_merge(const char *video_path, const char *audio_path,
                     const char *output_path, int overwrite, char *error,
                     size_t error_size);

const char *rill_media_version(void);

#ifdef __cplusplus
}
#endif

#endif
