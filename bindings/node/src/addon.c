#include <node_api.h>

#include <rill.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  rill_download *handle;
} DownloadHandle;

typedef struct {
  napi_async_work work;
  napi_deferred deferred;
  char *url;
  char *options;
  int status;
  char *json;
  char *error;
  char *error_code;
} ExtractWork;

static char *get_string(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) {
    return NULL;
  }

  char *buffer = malloc(length + 1);
  if (buffer == NULL) {
    return NULL;
  }

  if (napi_get_value_string_utf8(env, value, buffer, length + 1, &length) != napi_ok) {
    free(buffer);
    return NULL;
  }

  return buffer;
}

static bool get_optional_string(napi_env env, napi_value value, char **out) {
  napi_valuetype type = napi_undefined;
  napi_typeof(env, value, &type);

  if (type == napi_undefined || type == napi_null) {
    *out = NULL;
    return true;
  }

  *out = get_string(env, value);
  return *out != NULL;
}

static void free_rill_string(char *value) {
  if (value != NULL) {
    rill_free_string(value);
  }
}

static void throw_status(napi_env env, int status, const char *message, const char *kind) {
  napi_value text;
  napi_value error;
  napi_value status_value;

  napi_create_string_utf8(env, message != NULL ? message : "rill error", NAPI_AUTO_LENGTH, &text);
  napi_create_error(env, NULL, text, &error);

  napi_create_int32(env, status, &status_value);
  napi_set_named_property(env, error, "status", status_value);

  if (kind != NULL) {
    napi_value kind_value;
    napi_create_string_utf8(env, kind, NAPI_AUTO_LENGTH, &kind_value);
    napi_set_named_property(env, error, "code", kind_value);
  }

  napi_throw(env, error);
}

static bool get_args(napi_env env, napi_callback_info info, size_t expected,
                     napi_value *argv, size_t *argc) {
  size_t count = expected;
  if (napi_get_cb_info(env, info, &count, argv, NULL, NULL) != napi_ok) {
    return false;
  }

  *argc = count;
  return true;
}

static napi_value AbiVersion(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value result;
  napi_create_int32(env, rill_abi_version(), &result);
  return result;
}

static napi_value Init(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc)) {
    return NULL;
  }

  uint32_t workers = 0;
  if (argc > 0) {
    napi_get_value_uint32(env, argv[0], &workers);
  }

  int status = rill_init(workers);
  if (status != RILL_OK) {
    throw_status(env, status, "rill_init failed", "internal");
    return NULL;
  }

  return NULL;
}

static napi_value Shutdown(napi_env env, napi_callback_info info) {
  (void)info;
  int status = rill_shutdown();
  if (status != RILL_OK) {
    throw_status(env, status, "rill_shutdown failed", "internal");
    return NULL;
  }

  return NULL;
}

static napi_value ExtractJsonSync(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  size_t argc = 0;
  if (!get_args(env, info, 2, argv, &argc)) {
    return NULL;
  }

  if (argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "URL is required", "invalid_argument");
    return NULL;
  }

  char *url = get_string(env, argv[0]);
  char *options = NULL;
  if (url == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "URL is invalid", "invalid_argument");
    return NULL;
  }
  if (argc > 1 && !get_optional_string(env, argv[1], &options)) {
    free(url);
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "options are invalid", "invalid_argument");
    return NULL;
  }

  char *json = NULL;
  char *error = NULL;
  char *kind = NULL;
  int status = rill_extract_json(url, options, &json, &error, &kind);

  free(url);
  free(options);

  if (status != RILL_OK) {
    throw_status(env, status, error, kind);
    free_rill_string(json);
    free_rill_string(error);
    free_rill_string(kind);
    return NULL;
  }

  napi_value result;
  napi_create_string_utf8(env, json != NULL ? json : "", NAPI_AUTO_LENGTH, &result);
  free_rill_string(json);
  free_rill_string(error);
  free_rill_string(kind);
  return result;
}

static void ExtractExecute(napi_env env, void *data) {
  (void)env;
  ExtractWork *work = data;
  work->status = rill_extract_json(work->url, work->options, &work->json,
                                   &work->error, &work->error_code);
}

static void ExtractComplete(napi_env env, napi_status status, void *data) {
  (void)status;
  ExtractWork *work = data;

  if (work->status == RILL_OK) {
    napi_value result;
    napi_create_string_utf8(env, work->json != NULL ? work->json : "",
                            NAPI_AUTO_LENGTH, &result);
    napi_resolve_deferred(env, work->deferred, result);
  } else {
    napi_value text;
    napi_value error;
    napi_value status_value;
    napi_create_string_utf8(env, work->error != NULL ? work->error : "extraction failed",
                            NAPI_AUTO_LENGTH, &text);
    napi_create_error(env, NULL, text, &error);
    napi_create_int32(env, work->status, &status_value);
    napi_set_named_property(env, error, "status", status_value);
    if (work->error_code != NULL) {
      napi_value kind;
      napi_create_string_utf8(env, work->error_code, NAPI_AUTO_LENGTH, &kind);
      napi_set_named_property(env, error, "code", kind);
    }
    napi_reject_deferred(env, work->deferred, error);
  }

  napi_delete_async_work(env, work->work);
  free(work->url);
  free(work->options);
  free_rill_string(work->json);
  free_rill_string(work->error);
  free_rill_string(work->error_code);
  free(work);
}

static napi_value ExtractJson(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  size_t argc = 0;
  if (!get_args(env, info, 2, argv, &argc)) {
    return NULL;
  }

  if (argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "URL is required", "invalid_argument");
    return NULL;
  }

  ExtractWork *work = calloc(1, sizeof(ExtractWork));
  if (work == NULL) {
    throw_status(env, RILL_ERROR_INTERNAL, "out of memory", "internal");
    return NULL;
  }

  work->url = get_string(env, argv[0]);
  if (work->url == NULL) {
    free(work);
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "URL is invalid", "invalid_argument");
    return NULL;
  }

  if (argc > 1 && !get_optional_string(env, argv[1], &work->options)) {
    free(work->url);
    free(work);
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "options are invalid", "invalid_argument");
    return NULL;
  }

  napi_value promise;
  napi_create_promise(env, &work->deferred, &promise);
  napi_value resource_name;
  napi_create_string_utf8(env, "rill_extract", NAPI_AUTO_LENGTH, &resource_name);

  if (napi_create_async_work(env, NULL, resource_name, ExtractExecute,
                             ExtractComplete, work, &work->work) != napi_ok) {
    free(work->url);
    free(work->options);
    free(work);
    throw_status(env, RILL_ERROR_INTERNAL, "cannot create async work", "internal");
    return NULL;
  }

  napi_queue_async_work(env, work->work);
  return promise;
}

static void DownloadFinalize(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  DownloadHandle *download = data;
  if (download->handle != NULL) {
    rill_download_free(download->handle);
  }
  free(download);
}

static napi_value DownloadStart(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  size_t argc = 0;
  if (!get_args(env, info, 3, argv, &argc)) {
    return NULL;
  }

  if (argc < 2) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "URL and output are required",
                 "invalid_argument");
    return NULL;
  }

  char *url = get_string(env, argv[0]);
  char *output = get_string(env, argv[1]);
  char *options = NULL;

  if (url == NULL || output == NULL ||
      (argc > 2 && !get_optional_string(env, argv[2], &options))) {
    free(url);
    free(output);
    free(options);
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download arguments are invalid",
                 "invalid_argument");
    return NULL;
  }

  char *error = NULL;
  rill_download *handle = rill_download_start(url, output, options, &error);

  free(url);
  free(output);
  free(options);

  if (handle == NULL) {
    throw_status(env, RILL_ERROR_INTERNAL, error, "internal");
    free_rill_string(error);
    return NULL;
  }
  free_rill_string(error);

  DownloadHandle *download = malloc(sizeof(DownloadHandle));
  if (download == NULL) {
    rill_download_free(handle);
    throw_status(env, RILL_ERROR_INTERNAL, "out of memory", "internal");
    return NULL;
  }
  download->handle = handle;

  napi_value external;
  napi_create_external(env, download, DownloadFinalize, NULL, &external);
  return external;
}

static DownloadHandle *get_download(napi_env env, napi_value value) {
  void *data = NULL;
  if (napi_get_value_external(env, value, &data) != napi_ok) {
    return NULL;
  }

  return data;
}

static napi_value DownloadPoll(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc) || argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is required",
                 "invalid_argument");
    return NULL;
  }

  DownloadHandle *download = get_download(env, argv[0]);
  if (download == NULL || download->handle == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is closed",
                 "invalid_argument");
    return NULL;
  }

  int state = 0;
  int64_t downloaded = 0;
  int64_t total = 0;
  int status = rill_download_poll(download->handle, &state, &downloaded, &total);
  if (status != RILL_OK) {
    throw_status(env, status, "rill_download_poll failed", "internal");
    return NULL;
  }

  napi_value result;
  napi_value state_value;
  napi_value downloaded_value;
  napi_value total_value;

  napi_create_object(env, &result);
  napi_create_int32(env, state, &state_value);
  napi_create_int64(env, downloaded, &downloaded_value);
  napi_create_int64(env, total, &total_value);
  napi_set_named_property(env, result, "state", state_value);
  napi_set_named_property(env, result, "downloaded", downloaded_value);
  napi_set_named_property(env, result, "total", total_value);
  return result;
}

static napi_value DownloadCancel(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc) || argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is required",
                 "invalid_argument");
    return NULL;
  }

  DownloadHandle *download = get_download(env, argv[0]);
  if (download == NULL || download->handle == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is closed",
                 "invalid_argument");
    return NULL;
  }

  int status = rill_download_cancel(download->handle);
  if (status != RILL_OK) {
    throw_status(env, status, "rill_download_cancel failed", "internal");
    return NULL;
  }

  return NULL;
}

static napi_value DownloadError(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc) || argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is required",
                 "invalid_argument");
    return NULL;
  }

  DownloadHandle *download = get_download(env, argv[0]);
  if (download == NULL || download->handle == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is closed",
                 "invalid_argument");
    return NULL;
  }

  char *message = rill_download_error(download->handle);
  napi_value result;
  napi_create_string_utf8(env, message != NULL ? message : "", NAPI_AUTO_LENGTH, &result);
  free_rill_string(message);
  return result;
}

static napi_value DownloadErrorCode(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc) || argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is required",
                 "invalid_argument");
    return NULL;
  }

  DownloadHandle *download = get_download(env, argv[0]);
  if (download == NULL || download->handle == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is closed",
                 "invalid_argument");
    return NULL;
  }

  char *kind = rill_download_error_code(download->handle);
  napi_value result;
  napi_create_string_utf8(env, kind != NULL ? kind : "", NAPI_AUTO_LENGTH, &result);
  free_rill_string(kind);
  return result;
}

static napi_value DownloadClose(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  size_t argc = 0;
  if (!get_args(env, info, 1, argv, &argc) || argc < 1) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is required",
                 "invalid_argument");
    return NULL;
  }

  DownloadHandle *download = get_download(env, argv[0]);
  if (download == NULL) {
    throw_status(env, RILL_ERROR_INVALID_ARGUMENT, "download handle is invalid",
                 "invalid_argument");
    return NULL;
  }

  if (download->handle != NULL) {
    rill_download_free(download->handle);
    download->handle = NULL;
  }

  return NULL;
}

NAPI_MODULE_INIT() {
  napi_property_descriptor properties[] = {
      {"abiVersion", NULL, AbiVersion, NULL, NULL, NULL, napi_default, NULL},
      {"init", NULL, Init, NULL, NULL, NULL, napi_default, NULL},
      {"shutdown", NULL, Shutdown, NULL, NULL, NULL, napi_default, NULL},
      {"extractJsonSync", NULL, ExtractJsonSync, NULL, NULL, NULL, napi_default, NULL},
      {"extractJson", NULL, ExtractJson, NULL, NULL, NULL, napi_default, NULL},
      {"downloadStart", NULL, DownloadStart, NULL, NULL, NULL, napi_default, NULL},
      {"downloadPoll", NULL, DownloadPoll, NULL, NULL, NULL, napi_default, NULL},
      {"downloadCancel", NULL, DownloadCancel, NULL, NULL, NULL, napi_default, NULL},
      {"downloadError", NULL, DownloadError, NULL, NULL, NULL, napi_default, NULL},
      {"downloadErrorCode", NULL, DownloadErrorCode, NULL, NULL, NULL, napi_default, NULL},
      {"downloadClose", NULL, DownloadClose, NULL, NULL, NULL, napi_default, NULL},
  };

  napi_define_properties(env, exports,
                         sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}
