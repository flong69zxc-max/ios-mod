// norelpatch.mm - FINAL v11.0 (Works with br_anim.bpc)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <zlib.h>

static bool isPatched = NO;
static int retryCount = 0;
static const int MAX_RETRIES = 10;
static const int RETRY_DELAY = 3;

static void write_log(NSString *format, ...) {
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsPath = [paths firstObject];
        NSString *savesPath = [documentsPath stringByAppendingPathComponent:@"saves"];
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:savesPath]) {
            [fileManager createDirectoryAtPath:savesPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSString *logPath = [savesPath stringByAppendingPathComponent:@"NoReload.log"];
        
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
        
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        
        NSLog(@"%@", message);
    }
}

static void hex_dump(NSData *data, NSRange range) {
    if (range.length > 512) {
        write_log(@"      [Showing first 512 bytes of %lu]", (unsigned long)range.length);
        range.length = 512;
    }
    
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = range.location; i < range.location + range.length && i < data.length; i++) {
        [hex appendFormat:@"%02X ", bytes[i]];
        if ((i - range.location) % 16 == 15) {
            write_log(@"      %@", hex);
            hex = [NSMutableString string];
        }
    }
    if (hex.length > 0) {
        write_log(@"      %@", hex);
    }
}

static NSData* patch_reload_strings(NSData *data, NSString *fileName) {
    NSMutableData *newData = [data mutableCopy];
    int patched = 0;
    
    NSArray *searchStrings = @[
        @"python_reload",
        @"python_crouchreload",
        @"shotgun_reload",
        @"shotgun_crouchreload"
    ];
    
    for (NSString *search in searchStrings) {
        NSData *searchData = [search dataUsingEncoding:NSUTF8StringEncoding];
        NSRange searchRange = NSMakeRange(0, data.length);
        
        while (searchRange.location < data.length) {
            NSRange range = [data rangeOfData:searchData options:0 range:searchRange];
            if (range.location == NSNotFound) break;
            
            write_log(@"");
            write_log(@"🔍 Found '%@' in %@ at offset 0x%08lX", search, fileName, (unsigned long)range.location);
            
            NSString *replace = [search stringByReplacingOccurrencesOfString:@"_reload" withString:@"_idle"];
            NSData *replaceData = [replace dataUsingEncoding:NSUTF8StringEncoding];
            
            if (replaceData.length != range.length) {
                if (replaceData.length > range.length) {
                    replaceData = [replaceData subdataWithRange:NSMakeRange(0, range.length)];
                } else {
                    NSMutableData *padded = [NSMutableData dataWithData:replaceData];
                    uint8_t zero = 0;
                    for (NSUInteger i = replaceData.length; i < range.length; i++) {
                        [padded appendBytes:&zero length:1];
                    }
                    replaceData = padded;
                }
            }
            
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            write_log(@"   ✅ Replaced with '%@'", replace);
            patched++;
            
            searchRange.location = range.location + range.length;
        }
    }
    
    if (patched > 0) {
        write_log(@"📊 Patched %d string(s) in %@", patched, fileName);
        return newData;
    }
    return nil;
}

static void patch_zip_archive(NSString *zipPath) {
    write_log(@"");
    write_log(@"═══════════════════════════════════════════════════════════════");
    write_log(@"📦 Processing: %@", zipPath.lastPathComponent);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:zipPath]) {
        write_log(@"❌ File not found!");
        return;
    }
    
    // Бэкап
    NSString *backupPath = [zipPath stringByAppendingString:@".original"];
    if (![fm fileExistsAtPath:backupPath]) {
        NSData *origData = [NSData dataWithContentsOfFile:zipPath];
        [origData writeToFile:backupPath atomically:YES];
        write_log(@"💾 Backup created");
    }
    
    NSData *zipData = [NSData dataWithContentsOfFile:zipPath];
    if (!zipData) {
        write_log(@"❌ Can't read file");
        return;
    }
    
    write_log(@"📊 ZIP size: %lu bytes", (unsigned long)zipData.length);
    
    // Создаем временную папку
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bpc_extract"];
    [fm removeItemAtPath:tempDir error:nil];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
    write_log(@"📂 Temp dir: %@", tempDir);
    
    // Распаковываем через unzip (единственный рабочий способ на iOS)
    const char *zipPathC = [zipPath UTF8String];
    const char *tempDirC = [tempDir UTF8String];
    
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "unzip -o '%s' -d '%s' 2>/dev/null", zipPathC, tempDirC);
    int result = system(cmd);
    
    if (result != 0) {
        write_log(@"⚠️ Unzip returned: %d", result);
    }
    
    // Ищем .ani файлы
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:tempDir];
    NSString *file;
    int found = 0;
    int patched = 0;
    
    while ((file = [enumerator nextObject])) {
        if ([file hasSuffix:@".ani"]) {
            NSString *aniPath = [tempDir stringByAppendingPathComponent:file];
            found++;
            
            write_log(@"");
            write_log(@"📁 Found: %@", file);
            
            NSData *data = [NSData dataWithContentsOfFile:aniPath];
            if (data) {
                NSData *patchedData = patch_reload_strings(data, file);
                if (patchedData) {
                    [patchedData writeToFile:aniPath atomically:YES];
                    write_log(@"✅ Saved");
                    patched++;
                }
            }
        }
    }
    
    write_log(@"📊 Found %d .ani files, patched %d", found, patched);
    
    if (patched == 0) {
        write_log(@"⚠️ Nothing to patch!");
        [fm removeItemAtPath:tempDir error:nil];
        return;
    }
    
    // Запаковываем обратно
    write_log(@"");
    write_log(@"📦 Repacking ZIP...");
    
    snprintf(cmd, sizeof(cmd), "cd '%s' && zip -r ../br_anim_new.bpc . 2>/dev/null", tempDirC);
    result = system(cmd);
    
    if (result != 0) {
        write_log(@"⚠️ Zip returned: %d", result);
    }
    
    // Заменяем оригинал
    NSString *newZipPath = [[tempDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"br_anim_new.bpc"];
    if ([fm fileExistsAtPath:newZipPath]) {
        [fm removeItemAtPath:zipPath error:nil];
        [fm moveItemAtPath:newZipPath toPath:zipPath error:nil];
        write_log(@"✅ Replaced original");
        isPatched = YES;
    } else {
        write_log(@"❌ New ZIP not created!");
    }
    
    // Чистим
    [fm removeItemAtPath:tempDir error:nil];
    write_log(@"🧹 Cleaned up");
    write_log(@"═══════════════════════════════════════════════════════════════");
}

static void find_and_patch(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSArray *searchPaths = @[
        @"/var/mobile/Containers/Data/Application",
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject],
        [[NSBundle mainBundle] bundlePath]
    ];
    
    for (NSString *basePath in searchPaths) {
        if (![fm fileExistsAtPath:basePath]) continue;
        
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
        NSString *file;
        
        while ((file = [enumerator nextObject])) {
            if ([file isEqualToString:@"br_anim.bpc"]) {
                NSString *fullPath = [basePath stringByAppendingPathComponent:file];
                write_log(@"");
                write_log(@"✅ Found: %@", fullPath);
                patch_zip_archive(fullPath);
                return;
            }
        }
    }
    
    write_log(@"❌ br_anim.bpc not found!");
}

static void patch_all(void) {
    @autoreleasepool {
        if (isPatched) {
            write_log(@"ℹ️ Already patched");
            return;
        }
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  🔥 NO RELOAD PATCHER v11.0                                ║");
        write_log(@"║  ✅ Extracts br_anim.bpc (ZIP)                             ║");
        write_log(@"║  ✅ Patches .ani files inside                              ║");
        write_log(@"║  ✅ Repacks ZIP                                            ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        find_and_patch();
    }
}

static void patch_with_retry(void) {
    retryCount++;
    
    if (retryCount > MAX_RETRIES) {
        write_log(@"❌ MAX RETRIES REACHED");
        return;
    }
    
    write_log(@"");
    write_log(@"🔄 Attempt %d/%d", retryCount, MAX_RETRIES);
    patch_all();
    
    if (!isPatched && retryCount < MAX_RETRIES) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RETRY_DELAY * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            patch_with_retry();
        });
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            patch_with_retry();
        } @catch (NSException *e) {
            write_log(@"❌ CRASH: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
