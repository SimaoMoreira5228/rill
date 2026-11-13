#ifndef RILL_H
#define RILL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RILL_ABI_VERSION 1

typedef enum rill_status {
  RILL_OK = 0,
  RILL_ERROR_EXTRACTION = 1,
  RILL_ERROR_INTERNAL = 2,
  RILL_ERROR_INVALID_ARGUMENT = 3,
  RILL_ERROR_SHUTDOWN = 4
} rill_status;

// Opaque asynchronous extraction request.
typedef struct rill_job rill_job;

// Returned strings are owned by the caller and must be released with
// rill_free_string. A job transfers its result strings to rill_job_wait;
// rill_job_free releases anything that was not transferred.
//
// options_json accepts a JSON object with these optional keys:
//   user_agent, headers (object of string or string array), cookies (object),
//   connect_timeout_seconds, read_timeout_seconds, retry_delay_seconds,
//   max_redirects, retries, max_response_bytes.

int rill_abi_version(void);

// Starts the worker pool. Call once before any other function. worker_count 0
// selects one worker. Returns RILL_OK when the pool is ready or already running.
int rill_init(size_t worker_count);

// Stops the worker pool after in-flight and queued jobs are resolved. Terminal:
// later calls to rill_init fail. Safe to call more than once.
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

void rill_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
