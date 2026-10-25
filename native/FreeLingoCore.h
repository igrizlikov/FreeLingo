#ifndef FREELINGO_CORE_H
#define FREELINGO_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Callback is invoked on a background thread; caller must dispatch UI updates to main.
typedef void (*fl_completion)(char *result, int success, void *context);
void fl_work_async(const char *text, const char *target, const char *operation,
                   const char *model, fl_completion done, void *context);
// Trace metadata JSON contains only request id, source origin, ephemeral HMAC,
// and language codes; NEVER source or translation contents.
void fl_work_async_traced(const char *text, const char *target, const char *operation,
                          const char *model, const char *trace_json,
                          fl_completion done, void *context);
void fl_free_string(char *result);
void fl_shutdown(void);
#ifdef __cplusplus
}
#endif
#endif
