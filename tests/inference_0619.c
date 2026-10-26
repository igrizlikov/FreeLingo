// Real Rust FFI + bundled llama-server smoke, synthetic text only.
#include "../native/FreeLingoCore.h"
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static atomic_int done, passed, streamed;
static void completion(char *text, int status, void *context) {
    (void)context;
    if (status == 2) atomic_fetch_add(&streamed, 1);
    else {
        atomic_store(&passed, status == 1 && text && strlen(text) > 0);
        printf("terminal=%d streamed_updates=%d output=%s\n", status, atomic_load(&streamed), text ? text : "");
        atomic_store(&done, 1);
    }
    if (text) fl_free_string(text);
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    fl_work_async_diagnostic("The library opens at nine in the morning. You can borrow books for two weeks.\n\nPlease return the books on time so that other readers can enjoy them too.", "en>ru", "translate", argv[1], "main", "en", completion, NULL);
    for (int i=0; i<2400 && !atomic_load(&done); i++) usleep(100000);
    int ok = atomic_load(&done) && atomic_load(&passed) && atomic_load(&streamed)>0;
    fl_shutdown();
    printf("%s: TranslateGemma 12B real FFI translation + streaming\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
