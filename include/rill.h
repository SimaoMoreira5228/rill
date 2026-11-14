#ifndef RILL_H
#define RILL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RILL_ABI_VERSION 2

typedef enum rill_status {
  RILL_OK = 0,
  RILL_ERROR_EXTRACTION = 1,
  RILL_ERROR_INTERNAL = 2,
  RILL_ERROR_INVALID_ARGUMENT = 3,
  RILL_ERROR_SHUTDOWN = 4,
  RILL_ERROR_CANCELLED = 5
} rill_status;

typedef enum rill_download_state {
  RILL_DOWNLOAD_QUEUED = 0,
  RILL_DOWNLOAD_RUNNING = 1,
  RILL_DOWNLOAD_COMPLETED = 2,
  RILL_DOWNLOAD_FAILED = 3,
  RILL_DOWNLOAD_CANCELLED = 4
} rill_download_state;

// Opaque asynchronous extraction request.
typedef struct rill_job rill_job;

// Opaque asynchronous download request.
typedef struct rill_job rill_download;

// Returned strings are owned by the caller and must be released with
// rill_free_string. A job transfers its result strings to rill_job_wait;
// rill_job_free releases anything that was not transferred.
//
// Extraction options_json accepts a JSON object with these optional keys:
//   user_agent, headers (object of string or string array), cookies (object),
//   connect_timeout_seconds, read_timeout_seconds, retry_delay_seconds,
//   max_redirects, retries, max_response_bytes.
//
// Download options_json accepts these optional keys:
//   request (an extraction options object), format_id, audio_only,
//   video_only, overwrite, resume, media_backend (auto, helper, system, off).

int rill_abi_version(void);

// Starts the worker pool. Call once before any other function. worker_count 0
// selects one worker. Returns RILL_OK when the pool is ready or already running.
int rill_init(size_t worker_count);

// Stops the worker pool. Queued jobs fail with RILL_ERROR_SHUTDOWN, active
// downloads are cancelled, and in-flight extraction calls finish normally.
// Terminal: later calls to rill_init fail. Safe to call more than once.
int rill_shutdown(void);

// Enqueues an extraction. Returns NULL only when the job cannot be allocated.
rill_job *rill_job_new(const char *url, const char *options_json);
int rill_job_wait(rill_job *job, char **json_out, char **error_out,
                  char **error_code_out);
void rill_job_free(rill_job *job);

// Blocking convenience wrapper around rill_job_new, rill_job_wait, and
// rill_job_free.
int rill_extract_json(const char *url, const char *options_json,
                      char **json_out, char **error_out,
                      char **error_code_out);

// Starts an asynchronous download. Returns NULL only when the job cannot be
// allocated. Poll it with short, non-blocking calls; never block a runtime's
// event loop on this API.
rill_download *rill_download_start(const char *url, const char *output_path,
                                   const char *options_json, char **error_out);
int rill_download_poll(rill_download *download, int *state, int64_t *downloaded,
                       int64_t *total);
char *rill_download_error(rill_download *download);
char *rill_download_error_code(rill_download *download);
int rill_download_cancel(rill_download *download);
void rill_download_free(rill_download *download);

void rill_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
