#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "rill.h"

#define THREADS 8
#define CALLS 20

static void assert_success(int status, char *json, char *error, char *code) {
  assert(status == RILL_OK);
  assert(json != NULL);
  assert(error == NULL);
  assert(code == NULL);
  assert(strstr(json, "\"title\": \"clip\"") != NULL);
  assert(strstr(json, "\"format_id\": \"direct\"") != NULL);
}

static void *worker(void *argument) {
  (void)argument;

  const char *options = "{\"user_agent\":\"c-api-smoke\"}";

  for (int i = 0; i < CALLS; i++) {
    char *json = NULL;
    char *error = NULL;
    char *code = NULL;

    int status = rill_extract_json(
        "https://example.com/clip.mp4", options, &json, &error, &code);
    assert_success(status, json, error, code);
    rill_free_string(json);
  }

  return NULL;
}

static void check_downloaded_file(const char *path) {
  FILE *file = fopen(path, "rb");
  assert(file != NULL);

  char buffer[64] = {0};
  size_t read = fread(buffer, 1, sizeof(buffer) - 1, file);
  fclose(file);

  assert(read == strlen("c-api-download"));
  assert(strcmp(buffer, "c-api-download") == 0);
}

static void test_download(const char *url, const char *output) {
  char *error = NULL;
  rill_download *download = rill_download_start(
      url, output, "{\"overwrite\":true}", &error);
  assert(download != NULL);
  assert(error == NULL);

  int state = -1;
  int64_t downloaded = 0;
  int64_t total = 0;

  for (int attempt = 0; attempt < 2000; attempt++) {
    assert(rill_download_poll(download, &state, &downloaded, &total) == RILL_OK);
    if (state >= RILL_DOWNLOAD_COMPLETED) {
      break;
    }
    usleep(10000);
  }

  if (state != RILL_DOWNLOAD_COMPLETED) {
    char *message = rill_download_error(download);
    fprintf(stderr, "download state=%d error=%s\n", state,
            message ? message : "(none)");
    rill_free_string(message);
  }
  assert(state == RILL_DOWNLOAD_COMPLETED);
  assert(downloaded > 0);
  assert(rill_download_error(download) == NULL);
  check_downloaded_file(output);
  rill_download_free(download);
}

static void test_download_cancel(const char *url, const char *output) {
  rill_download *download = rill_download_start(url, output, NULL, NULL);
  assert(download != NULL);
  assert(rill_download_cancel(download) == RILL_OK);

  int state = -1;
  int64_t downloaded = 0;
  int64_t total = 0;

  for (int attempt = 0; attempt < 2000; attempt++) {
    assert(rill_download_poll(download, &state, &downloaded, &total) == RILL_OK);
    if (state >= RILL_DOWNLOAD_COMPLETED) {
      break;
    }
    usleep(10000);
  }

  assert(state == RILL_DOWNLOAD_CANCELLED);
  if (state == RILL_DOWNLOAD_CANCELLED) {
    char *error = rill_download_error(download);
    assert(error != NULL);
    rill_free_string(error);
  }
  rill_download_free(download);
}

static void test_shutdown_cancels_download(const char *url, const char *output) {
  char *error = NULL;
  rill_download *download = rill_download_start(
      url, output, "{\"overwrite\":true}", &error);
  assert(download != NULL);
  assert(error == NULL);

  usleep(100000);

  struct timeval before;
  struct timeval after;
  gettimeofday(&before, NULL);
  assert(rill_shutdown() == RILL_OK);
  gettimeofday(&after, NULL);

  double elapsed = (after.tv_sec - before.tv_sec) +
                   (after.tv_usec - before.tv_usec) / 1000000.0;
  assert(elapsed < 5.0);

  int state = -1;
  int64_t downloaded = 0;
  int64_t total = 0;
  assert(rill_download_poll(download, &state, &downloaded, &total) == RILL_OK);
  assert(state == RILL_DOWNLOAD_CANCELLED);
  rill_download_free(download);
}

static void *shutdown_worker(void *argument) {
  (void)argument;

  for (int i = 0; i < 10; i++) {
    assert(rill_shutdown() == RILL_OK);
  }

  return NULL;
}

int main(void) {
  assert(rill_abi_version() == RILL_ABI_VERSION);

  assert(rill_init(4) == RILL_OK);
  assert(rill_init(0) == RILL_OK);

  char *json = NULL;
  char *error = NULL;
  char *code = NULL;

  int status = rill_extract_json(
      "https://example.com/clip.mp4", NULL, &json, &error, &code);
  assert_success(status, json, error, code);
  rill_free_string(json);

  rill_job *job = rill_job_new(
      "https://example.com/clip.mp3", "{\"headers\":{\"X-Test\":\"yes\"}}");
  assert(job != NULL);
  status = rill_job_wait(job, &json, &error, &code);
  assert(status == RILL_OK);
  assert(json != NULL);
  assert(strstr(json, "\"container\": \"mp3\"") != NULL);
  rill_free_string(json);
  rill_job_free(job);

  status = rill_extract_json(
      "ftp://example.com/page.html", NULL, &json, &error, &code);
  assert(status == RILL_ERROR_EXTRACTION);
  assert(json == NULL);
  assert(error != NULL);
  assert(code != NULL);
  assert(strcmp(code, "unsupported_url") == 0);
  rill_free_string(error);
  rill_free_string(code);

  status = rill_extract_json(
      "https://example.com/clip.mp4", "{\"bogus\":1}", &json, &error, &code);
  assert(status == RILL_ERROR_INVALID_ARGUMENT);
  assert(json == NULL);
  assert(code != NULL);
  assert(strcmp(code, "invalid_options") == 0);
  rill_free_string(error);
  rill_free_string(code);

  status = rill_extract_json(
      "https://example.com/clip.mp4", "not json", &json, &error, &code);
  assert(status == RILL_ERROR_INVALID_ARGUMENT);
  assert(json == NULL);
  assert(code != NULL);
  assert(strcmp(code, "invalid_options") == 0);
  rill_free_string(error);
  rill_free_string(code);

  status = rill_extract_json(NULL, NULL, &json, &error, &code);
  assert(status == RILL_ERROR_INVALID_ARGUMENT);
  assert(json == NULL);
  assert(code != NULL);
  assert(strcmp(code, "invalid_argument") == 0);
  rill_free_string(error);
  rill_free_string(code);

  status = rill_extract_json(
      "https://example.com/clip.mp4", NULL, NULL, &error, &code);
  assert(status == RILL_ERROR_INVALID_ARGUMENT);

  rill_job *abandoned = rill_job_new("https://example.com/clip.mp4", NULL);
  assert(abandoned != NULL);
  rill_job_free(abandoned);

  pthread_t threads[THREADS];
  for (int i = 0; i < THREADS; i++) {
    assert(pthread_create(&threads[i], NULL, worker, NULL) == 0);
  }
  for (int i = 0; i < THREADS; i++) {
    assert(pthread_join(threads[i], NULL) == 0);
  }

  const char *download_url = getenv("RILL_C_API_TEST_URL");
  const char *download_output = getenv("RILL_C_API_TEST_OUTPUT");
  const char *slow_url = getenv("RILL_C_API_TEST_SLOW_URL");
  const char *cancel_output = getenv("RILL_C_API_TEST_CANCEL_OUTPUT");

  if (download_url && download_output) {
    test_download(download_url, download_output);
  }

  if (slow_url && cancel_output) {
    test_download_cancel(slow_url, cancel_output);
    test_shutdown_cancels_download(slow_url, cancel_output);
  }

  pthread_t stoppers[4];
  for (int i = 0; i < 4; i++) {
    assert(pthread_create(&stoppers[i], NULL, shutdown_worker, NULL) == 0);
  }
  for (int i = 0; i < 4; i++) {
    assert(pthread_join(stoppers[i], NULL) == 0);
  }

  assert(rill_shutdown() == RILL_OK);
  assert(rill_shutdown() == RILL_OK);

  status = rill_extract_json(
      "https://example.com/clip.mp4", NULL, &json, &error, &code);
  assert(status == RILL_ERROR_SHUTDOWN);
  assert(json == NULL);
  assert(error == NULL);
  assert(code == NULL);

  printf("c api smoke: ok\n");
  return EXIT_SUCCESS;
}
