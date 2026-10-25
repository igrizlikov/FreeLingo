#include <stdlib.h>
#include <string.h>
// Imported into main.m after Cocoa / CommonCrypto. FreeLingo model manifest.
// SHA256 fingerprints are official on the linked Hugging Face file pages.
static NSArray<NSDictionary<NSString *, NSString *> *> *FLModels(void) {
    return @[
        @{ @"id": @"qwen3-0.6b", @"name": @"Qwen3 0.6B · очень быстрая · 484 МБ",
           @"file": @"Qwen3-0.6B.Q4_K_M.gguf", @"size": @"484 МБ", @"minBytes": @"400000000",
           @"url": @"https://huggingface.co/QuantFactory/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B.Q4_K_M.gguf",
           @"sha256": @"7af3fdf842f87b24672f8a7f1dd50404043f0bfb71093ff91c31d2b49df4631d" },
        @{ @"id": @"qwen3-1.7b", @"name": @"Qwen3 1.7B · быстрая (начальная) · 1,28 ГБ",
           @"file": @"Qwen3-1.7B-Q4_K_M.gguf", @"size": @"1,28 ГБ", @"minBytes": @"1080000000",
           @"url": @"https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
           @"sha256": @"d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5" },
        @{ @"id": @"qwen3-4b", @"name": @"Qwen3 4B · универсальная · 2,5 ГБ",
           @"file": @"Qwen3-4B-Q4_K_M.gguf", @"size": @"2,5 ГБ", @"minBytes": @"2100000000",
           @"url": @"https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
           @"sha256": @"7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5" },
        @{ @"id": @"qwen3-8b", @"name": @"Qwen3 8B · лучшее качество · 5,03 ГБ",
           @"file": @"Qwen3-8B-Q4_K_M.gguf", @"size": @"5,03 ГБ", @"minBytes": @"4600000000",
           @"url": @"https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
           @"sha256": @"d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785" },
        @{ @"id": @"hy-mt2-7b", @"name": @"Hy-MT2 7B · качественный перевод · 4,62 ГБ",
           @"file": @"Hy-MT2-7B-Q4_K_M.gguf", @"size": @"4,62 ГБ", @"minBytes": @"4200000000",
           @"url": @"https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/main/Hy-MT2-7B-Q4_K_M.gguf",
           @"sha256": @"9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b" },
        @{ @"id": @"translategemma-4b", @"name": @"TranslateGemma 4B · сравнение качества · 2,49 ГБ",
           @"file": @"translategemma-4b_Q4_K_M.gguf", @"size": @"2,49 ГБ", @"minBytes": @"2200000000",
           @"url": @"https://huggingface.co/SandLogicTechnologies/translategemma-4b-it-GGUF/resolve/main/translategemma-4b_Q4_K_M.gguf",
           @"sha256": @"526747309109c016db547c6fc1c7b0c9c286b5e7a7556827b5419fd9543a09cd" },
        @{ @"id": @"hy-mt2-1.8b", @"name": @"Hy-MT2 1.8B · быстрый перевод · 1,13 ГБ",
           @"file": @"Hy-MT2-1.8B-Q4_K_M.gguf", @"size": @"1,13 ГБ", @"minBytes": @"1000000000",
           @"url": @"https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf",
           @"sha256": @"dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699" }
    ];
}

static NSURL *FLModelsDirectory(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    NSURL *url = [[support URLByAppendingPathComponent:@"FreeLingo" isDirectory:YES]
        URLByAppendingPathComponent:@"Models" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES
        attributes:nil error:nil];
    return url;
}
static NSURL *FLModelURL(NSInteger index) {
    if (index < 0 || index >= (NSInteger)FLModels().count) return nil;
    return [FLModelsDirectory() URLByAppendingPathComponent:FLModels()[(NSUInteger)index][@"file"]];
}
static BOOL FLModelInstalled(NSInteger index) {
    NSURL *url = FLModelURL(index);
    if (!url) return NO;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    // Size-only checks accepted truncated 1.7B / 4B GGUF files as installed.
    // Each model declares its own minimum size, avoiding out-of-range fixed tables
    // when a new translation model is added. SHA-256 is verified at download.
    unsigned long long minimumBytes = (unsigned long long)[FLModels()[(NSUInteger)index][@"minBytes"] longLongValue];
    if (!minimumBytes || [attributes[NSFileSize] unsignedLongLongValue] < minimumBytes) return NO;
    // All selected models are GGUF. Reject an HTML error page or non-GGUF download.
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:url.path];
    if (!handle) return NO;
    NSData *magic = nil;
    @try { magic = [handle readDataOfLength:4]; }
    @catch (NSException *exception) { (void)exception; return NO; }
    @finally { [handle closeFile]; }
    return magic.length == 4 && memcmp(magic.bytes, "GGUF", 4) == 0;
}
static NSInteger FLActiveModelIndex(void) {
    NSString *id = [NSUserDefaults.standardUserDefaults stringForKey:@"modelID"];
    for (NSInteger i = 0; i < (NSInteger)FLModels().count; i++) {
        if ([FLModels()[(NSUInteger)i][@"id"] isEqualToString:id]) return i;
    }
    return 1;
}
static NSString *FLHashFile(NSURL *url) {
    NSInputStream *input = [NSInputStream inputStreamWithURL:url];
    [input open];
    if (input.streamStatus == NSStreamStatusError || input.streamStatus == NSStreamStatusNotOpen) {
        [input close];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    // Use the heap, not the small GCD worker-thread stack. A 1-MB stack buffer
    // crashed older versions of FreeLingo on completion of the download.
    uint8_t *buffer = malloc(64 * 1024);
    if (!buffer) { [input close]; return nil; }
    NSInteger amount;
    while ((amount = [input read:buffer maxLength:64 * 1024]) > 0)
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)amount);
    free(buffer);
    [input close];
    if (amount < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
