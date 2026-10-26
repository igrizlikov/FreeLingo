// Native AppKit model manager. Downloads only from the built-in, audited HTTPS URLs.
// Called as methods within @implementation FLAppDelegate in main.m.
- (BOOL)hasActiveModel {
    return FLModelInstalled(FLActiveModelIndex());
}

- (void)createModelsWindow {
    _modelsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 330)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:NO];
    _modelsWindow.title = @"FreeLingo — локальные модели";
    _modelsWindow.releasedWhenClosed = NO;
    [_modelsWindow center];
    NSView *root = _modelsWindow.contentView;

    NSTextField *title = [NSTextField labelWithString:@"Выбери модель для перевода"];
    title.font = [NSFont boldSystemFontOfSize:19];
    title.frame = NSMakeRect(22, 278, 530, 30);
    [root addSubview:title];
    NSTextField *explanation = FLLabel(@"Hy-MT2 и TranslateGemma — отдельные переводчики. Сравни их на пяти языках.", 12);
    explanation.frame = NSMakeRect(22, 252, 540, 25);
    [root addSubview:explanation];

    _modelPicker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(22, 207, 552, 32) pullsDown:NO];
    for (NSDictionary *model in FLModels()) [_modelPicker addItemWithTitle:model[@"name"]];
    [_modelPicker selectItemAtIndex:FLActiveModelIndex()];
    _modelPicker.target = self;
    _modelPicker.action = @selector(modelPickerChanged:);
    [root addSubview:_modelPicker];

    _modelStatus = FLLabel(@"", 13);
    _modelStatus.frame = NSMakeRect(22, 171, 550, 24);
    [root addSubview:_modelStatus];

    _modelProgress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(22, 142, 552, 16)];
    _modelProgress.indeterminate = NO;
    _modelProgress.minValue = 0;
    _modelProgress.maxValue = 100;
    _modelProgress.doubleValue = 0;
    _modelProgress.hidden = YES;
    [root addSubview:_modelProgress];

    _modelDownload = FLButton(@"Скачать модель", self, @selector(downloadSelectedModel:));
    _modelDownload.frame = NSMakeRect(22, 89, 156, 31);
    [root addSubview:_modelDownload];
    _modelUse = FLButton(@"Использовать", self, @selector(useSelectedModel:));
    _modelUse.frame = NSMakeRect(190, 89, 120, 31);
    [root addSubview:_modelUse];
    _modelRemove = FLButton(@"Удалить", self, @selector(removeSelectedModel:));
    _modelRemove.frame = NSMakeRect(322, 89, 110, 31);
    [root addSubview:_modelRemove];
    _modelCancel = FLButton(@"Отмена", self, @selector(cancelModelDownload:));
    _modelCancel.frame = NSMakeRect(445, 89, 125, 31);
    [root addSubview:_modelCancel];

    NSButton *source = FLButton(@"Источник и лицензия ↗", self, @selector(openModelSource:));
    source.frame = NSMakeRect(22, 34, 205, 30);
    [root addSubview:source];
    NSTextField *location = FLLabel(@"Файлы: ~/Library/Application Support/FreeLingo/Models", 11);
    location.frame = NSMakeRect(235, 38, 345, 20);
    [root addSubview:location];
    [self updateModelUI];
}

- (void)updateModelUI {
    [self refreshGlassUI];
    NSInteger index = _modelPicker.indexOfSelectedItem;
    if (index < 0 || index >= (NSInteger)FLModels().count) return;
    BOOL installed = FLModelInstalled(index);
    BOOL busy = _modelTask != nil || _verifyingModel;
    _modelPicker.enabled = !busy;
    _modelDownload.enabled = !installed && !busy;
    _modelUse.enabled = installed && !busy;
    _modelRemove.enabled = installed && !busy;
    _modelCancel.enabled = _modelTask != nil && !_verifyingModel;
    if (!busy) {
        _modelProgress.hidden = YES;
        if (installed) {
            BOOL active = (index == FLActiveModelIndex());
            _modelStatus.stringValue = active ? @"Установлена · используется для перевода" : @"Установлена · можно переключиться";
        } else {
            _modelStatus.stringValue = @"Не установлена. После загрузки работает без интернета.";
        }
    }
}

- (void)showModels:(id)sender {
    (void)sender;
    [_modelsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self updateModelUI];
}

- (void)modelPickerChanged:(id)sender { (void)sender; [self updateModelUI]; }

- (void)useSelectedModel:(id)sender {
    (void)sender;
    NSInteger index = _modelPicker.indexOfSelectedItem;
    if (!FLModelInstalled(index)) return;
    [NSUserDefaults.standardUserDefaults setObject:FLModels()[(NSUInteger)index][@"id"] forKey:@"modelID"];
    _statusLabel.stringValue = [NSString stringWithFormat:@"Модель: %@", FLModels()[(NSUInteger)index][@"id"]];
    [self updateModelUI];
}

- (void)openModelSource:(id)sender {
    (void)sender;
    NSInteger index = _modelPicker.indexOfSelectedItem;
    if (index < 0) return;
    NSString *url = FLModels()[(NSUInteger)index][@"url"];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}

- (void)downloadSelectedModel:(id)sender {
    (void)sender;
    if (_modelTask || _verifyingModel) return;
    NSInteger index = _modelPicker.indexOfSelectedItem;
    if (index < 0 || FLModelInstalled(index)) return;
    NSURL *url = [NSURL URLWithString:FLModels()[(NSUInteger)index][@"url"]];
    if (![url.scheme isEqualToString:@"https"] || ![url.host isEqualToString:@"huggingface.co"]) return;
    _downloadingModelIndex = index;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 90;
    config.timeoutIntervalForResource = 7200;
    _modelSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    _modelTask = [_modelSession downloadTaskWithURL:url];
    _modelProgress.hidden = NO;
    _modelProgress.indeterminate = NO;
    _modelProgress.doubleValue = 0;
    _modelStatus.stringValue = @"Начинается загрузка…";
    [self updateModelUI];
    _modelProgress.hidden = NO;
    [_modelTask resume];
}

- (void)cancelModelDownload:(id)sender {
    (void)sender;
    [_modelTask cancel];
    _modelStatus.stringValue = @"Отмена загрузки…";
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
        didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
        totalBytesExpectedToWrite:(int64_t)expected {
    (void)session; (void)bytesWritten;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Old progress callbacks can arrive after verification starts or the
        // download has already been cancelled/replaced.
        if (task != self->_modelTask || self->_verifyingModel) return;
        if (expected > 0) {
            self->_modelProgress.doubleValue = MIN(100, (double)total * 100.0 / expected);
            self->_modelStatus.stringValue = [NSString stringWithFormat:@"Загружено %.1f из %.1f ГБ · %.0f%%",
                (double)total / 1e9, (double)expected / 1e9, self->_modelProgress.doubleValue];
        } else {
            self->_modelStatus.stringValue = [NSString stringWithFormat:@"Загружено %.0f МБ", (double)total / 1e6];
        }
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
        didFinishDownloadingToURL:(NSURL *)location {
    // NSURLSession owns `location` only until this callback returns, so move it
    // synchronously before hashing it on our own background queue.
    if (session != _modelSession || task != _modelTask) return;
    NSInteger index = _downloadingModelIndex;
    NSURL *destination = FLModelURL(index);
    // Session temporary URL is only valid during this delegate callback.
    NSURL *partial = [destination URLByAppendingPathExtension:@"part"];
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager removeItemAtURL:partial error:nil];
    NSError *moveError = nil;
    BOOL moved = [manager moveItemAtURL:location toURL:partial error:&moveError];
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_verifyingModel = YES;
        self->_modelCancel.enabled = NO;
        self->_modelStatus.stringValue = @"Проверка SHA-256 загруженной модели…";
    });
    if (!moved) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session == self->_modelSession)
                [self modelDownloadFinished:NO message:moveError.localizedDescription ?: @"Ошибка сохранения файла" index:index];
        });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *sha = FLHashFile(partial);
        BOOL valid = (sha != nil && [sha isEqualToString:FLModels()[(NSUInteger)index][@"sha256"]]);
        NSError *error = nil;
        BOOL saved = NO;
        if (valid) {
            // Never remove a previously installed model before the new one is
            // safely in place. The UI normally disallows replacing installed files.
            saved = [manager moveItemAtURL:partial toURL:destination error:&error];
        }
        if (!saved) [manager removeItemAtURL:partial error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (session != self->_modelSession || !self->_verifyingModel) return;
            NSString *message = saved ? @"Загрузка завершена. SHA-256 совпадает, модель готова." :
                (valid ? (error.localizedDescription ?: @"Ошибка установки модели") :
                 (sha ? @"Не совпадает SHA-256. Файл удалён; повтори загрузку." : @"Не удалось прочитать скачанный файл для SHA-256."));
            [self modelDownloadFinished:saved message:message index:index];
        });
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (!error) return; // Successful downloads are finalized after SHA-256 verification.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self->_modelSession || task != self->_modelTask || self->_verifyingModel) return;
        [self modelDownloadFinished:NO message:(error.code == NSURLErrorCancelled ? @"Загрузка отменена" : error.localizedDescription) index:self->_downloadingModelIndex];
    });
}

- (void)modelDownloadFinished:(BOOL)success message:(NSString *)message index:(NSInteger)index {
    if (!_modelSession) return;
    _modelTask = nil;
    [_modelSession finishTasksAndInvalidate];
    _modelSession = nil;
    _verifyingModel = NO;
    if (success) {
        // A/B installation of the experimental 12B must not silently replace
        // the user's current trusted 4B model. They can click «Использовать».
        NSString *downloadedID = FLModels()[(NSUInteger)index][@"id"];
        if (![downloadedID isEqualToString:@"translategemma-12b"]) {
            [NSUserDefaults.standardUserDefaults setObject:downloadedID forKey:@"modelID"];
        }
        _statusLabel.stringValue = @"Локальная модель готова · ⌘4";
    }
    [self updateModelUI];
    _modelStatus.stringValue = message ?: @"Ошибка загрузки";
}

- (void)removeSelectedModel:(id)sender {
    (void)sender;
    NSInteger index = _modelPicker.indexOfSelectedItem;
    if (index < 0 || !FLModelInstalled(index) || _modelTask || _verifyingModel) return;
    NSAlert *confirmation = [NSAlert new];
    confirmation.messageText = @"Удалить модель с Mac?";
    confirmation.informativeText = @"Скачанный GGUF-файл будет удалён. При необходимости его можно скачать заново.";
    [confirmation addButtonWithTitle:@"Удалить"];
    [confirmation addButtonWithTitle:@"Отмена"];
    if ([confirmation runModal] != NSAlertFirstButtonReturn) return;
    BOOL wasActive = (index == FLActiveModelIndex());
    if (wasActive) {
        NSInteger fallback = -1;
        for (NSInteger i = 0; i < (NSInteger)FLModels().count; i++) {
            if (i != index && FLModelInstalled(i)) { fallback = i; break; }
        }
        NSString *nextID = (fallback >= 0) ? FLModels()[(NSUInteger)fallback][@"id"] : @"none";
        [NSUserDefaults.standardUserDefaults setObject:nextID forKey:@"modelID"];
        _statusLabel.stringValue = (fallback >= 0) ? @"Активная модель переключена" : @"Выбери и скачай модель";
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:FLModelURL(index) error:&error])
        [self presentMessage:error.localizedDescription ?: @"Не удалось удалить модель"];
    [self updateModelUI];
}
