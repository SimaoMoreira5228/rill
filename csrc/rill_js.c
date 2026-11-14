#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#ifdef _WIN32
#include <windows.h>

static int64_t rill_now_ms(void) {
  return (int64_t)GetTickCount64();
}
#else
#include <time.h>

static int64_t rill_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
#endif

typedef struct rill_js {
  JSRuntime *runtime;
  JSContext *context;
  int64_t timeout_ms;
  int64_t deadline_ms;
} rill_js;

static char *rill_strdup(const char *value) {
  if (!value) {
    return NULL;
  }

  size_t size = strlen(value) + 1;
  char *copy = malloc(size);
  if (copy) {
    memcpy(copy, value, size);
  }
  return copy;
}

static char *rill_exception(JSContext *context) {
  JSValue exception = JS_GetException(context);
  const char *text = JS_ToCString(context, exception);
  char *copy = rill_strdup(text ? text : "JavaScript error");
  if (text) {
    JS_FreeCString(context, text);
  }
  JS_FreeValue(context, exception);
  return copy;
}

static int rill_interrupt(JSContext *context, void *opaque) {
  (void)context;
  rill_js *engine = opaque;
  return rill_now_ms() > engine->deadline_ms;
}

static void rill_begin(rill_js *engine) {
  JS_UpdateStackTop(engine->runtime);
  engine->deadline_ms = rill_now_ms() + engine->timeout_ms;
}

rill_js *rill_js_new(size_t memory_limit, size_t stack_size, int64_t timeout_ms) {
  rill_js *engine = calloc(1, sizeof(rill_js));
  if (!engine) {
    return NULL;
  }

  engine->timeout_ms = timeout_ms > 0 ? timeout_ms : 5000;
  engine->runtime = JS_NewRuntime();
  if (!engine->runtime) {
    free(engine);
    return NULL;
  }

  JS_SetMemoryLimit(engine->runtime, memory_limit);
  JS_SetMaxStackSize(engine->runtime, stack_size);
  JS_SetInterruptHandler(engine->runtime, rill_interrupt, engine);

  engine->context = JS_NewContext(engine->runtime);
  if (!engine->context) {
    JS_FreeRuntime(engine->runtime);
    free(engine);
    return NULL;
  }

  return engine;
}

void rill_js_free(rill_js *engine) {
  if (!engine) {
    return;
  }

  if (engine->context) {
    JS_FreeContext(engine->context);
  }
  if (engine->runtime) {
    JS_FreeRuntime(engine->runtime);
  }
  free(engine);
}

int rill_js_eval(rill_js *engine, const char *source, size_t source_len, char **error) {
  if (error) {
    *error = NULL;
  }
  if (!engine || !source) {
    return -1;
  }

  rill_begin(engine);
  JSValue value = JS_Eval(engine->context, source, source_len, "<rill>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) {
    if (error) {
      *error = rill_exception(engine->context);
    }
    JS_FreeValue(engine->context, value);
    return -1;
  }

  JS_FreeValue(engine->context, value);
  return 0;
}

int rill_js_call(
  rill_js *engine,
  const char *function,
  size_t function_len,
  const char *input,
  size_t input_len,
  char **result,
  char **error
) {
  (void)function_len;

  if (result) {
    *result = NULL;
  }
  if (error) {
    *error = NULL;
  }
  if (!engine || !function) {
    return -1;
  }

  rill_begin(engine);
  JSValue global = JS_GetGlobalObject(engine->context);
  JSValue callable = JS_GetPropertyStr(engine->context, global, function);
  if (!JS_IsFunction(engine->context, callable)) {
    if (error) {
      *error = rill_strdup("JavaScript function is not defined");
    }
    JS_FreeValue(engine->context, callable);
    JS_FreeValue(engine->context, global);
    return -1;
  }

  JSValue argument = JS_NewStringLen(engine->context, input ? input : "", input_len);
  JSValue value = JS_Call(engine->context, callable, global, 1, &argument);
  JS_FreeValue(engine->context, argument);
  JS_FreeValue(engine->context, callable);
  JS_FreeValue(engine->context, global);

  if (JS_IsException(value)) {
    if (error) {
      *error = rill_exception(engine->context);
    }
    JS_FreeValue(engine->context, value);
    return -1;
  }

  const char *text = JS_ToCString(engine->context, value);
  if (!text) {
    if (error) {
      *error = rill_strdup("JavaScript result is not convertible to a string");
    }
    JS_FreeValue(engine->context, value);
    return -1;
  }

  if (result) {
    *result = rill_strdup(text);
  }
  JS_FreeCString(engine->context, text);
  JS_FreeValue(engine->context, value);
  return result && *result ? 0 : -1;
}

void rill_js_free_string(char *value) {
  free(value);
}
