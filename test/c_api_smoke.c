#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
      "https://example.com/page.html", NULL, &json, &error, &code);
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
