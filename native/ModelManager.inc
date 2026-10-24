// Imported into main.m after Cocoa / CommonCrypto. FreeLingo model manifest.
// SHA256 fingerprints are official on the linked Hugging Face file pages.
static NSArray<NSDictionary<NSString *, NSString *> *> *FLModels(void) {
    return @[
        @{ @"id": @"qwen3-0.6b", @"name": @"Qwen3 0.6B · быстрая · 484 МБ",
           @"file": @"Qwen3-0.6B.Q4_K_M.gguf", @"size": @"484 МБ",
           @"url": @"https://huggingface.co/QuantFactory/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B.Q4_K_M.gguf",
           @"sha256": @"7af3fdf842f87b24672f8a7f1dd50404043f0bfb71093ff91c31d2b49df4631d" },
        @{ @"id": @"qwen3-1.7b", @"name": @"Qwen3 1.7B · сбалансированная · 1,28 ГБ",
           @"file": @"Qwen3-1.7B-Q4_K_M.gguf", @"size": @"1,28 ГБ",
           @"url": @"https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
           @"sha256": @"d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5" },
        @{ @"id": @"qwen3-4b", @"name": @"Qwen3 4B · качественная · 2,5 ГБ",
           @"file": @"Qwen3-4B-Q4_K_M.gguf", @"size": @"2,5 ГБ",
           @"url": @"https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
           @"sha256": @"7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5" }
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
    NSDictionary *attributes = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] : nil;
    return [attributes[NSFileSize] unsignedLongLongValue] > 400 * 1024 * 1024;
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
    if (input.streamStatus == NSStreamStatusError) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buffer[1024 * 1024];
    NSInteger amount;
    while ((amount = [input read:buffer maxLength:sizeof(buffer)]) > 0)
        CC_SHA256_Update(&ctx, buffer, (CC_LONG)amount);
    [input close];
    if (amount < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
