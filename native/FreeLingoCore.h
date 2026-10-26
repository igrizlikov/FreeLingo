#ifndef FREELINGO_CORE_H
#define FREELINGO_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Callback is invoked on a background thread; caller must dispatch UI updates to main.
// success=2 delivers provisional streaming text (context remains owned by Rust caller).
// success=0/1 ends the request and consumes the retained callback context.
typedef void (*fl_completion)(char *result, int success, void *context);
void fl_work_async(const char *text, const char *target, const char *operation,
                   const char *model, fl_completion done, void *context);
// Same translator, with a fixed provenance identifier for private diagnostics.
void fl_work_async_diagnostic(const char *text, const char *target, const char *operation,
                              const char *model, const char *origin, const char *source_language,
                              fl_completion done, void *context);
void fl_free_string(char *result);
// 0 = automatic, 1 = Flash Attention forced on, 2 = forced off. 12B only.
void fl_set_flash_attention(int mode);
// 0 = existing automatic KV prompt cache; 1 = disable cache reuse for 12B.
void fl_set_kv_cache_mode(int mode);
// Runs six fixed-text 12B translations on a background thread; callback once.
void fl_benchmark_kv_async(const char *model, fl_completion done, void *context);
void fl_shutdown(void);
#ifdef __cplusplus
}
#endif
#endif
