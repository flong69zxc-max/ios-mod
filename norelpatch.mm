// norelpatch.mm - v8.0 (direct binary patch)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static bool isPatched = NO;
static int retryCount = 0;
static const int MAX_RETRIES = 5;
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

static void patch_bpc_file(NSString *filePath) {
    write_log(@"");
    write_log(@"═══════════════════════════════════════════════════════════════");
    write_log(@"📁 PATCHING: %@", filePath.lastPathComponent);
    write_log(@"📂 PATH: %@", filePath);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:filePath]) {
        write_log(@"❌ FILE NOT FOUND!");
        return;
    }
    
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        write_log(@"❌ CAN'T READ FILE!");
        return;
    }
    
    write_log(@"📊 FILE SIZE: %lu bytes", (unsigned long)data.length);
    
    // Бэкап
    NSString *backupPath = [filePath stringByAppendingString:@".original"];
    if (![fm fileExistsAtPath:backupPath]) {
        [data writeToFile:backupPath atomically:YES];
        write_log(@"💾 Backup: %@", backupPath.lastPathComponent);
    }
    
    NSMutableData *newData = [data mutableCopy];
    int totalPatched = 0;
    
    NSArray *searchStrings = @[
        @"python_reload",
        @"python_crouchreload",
        @"shotgun_reload",
        @"shotgun_crouchreload"
    ];
    
    for (NSString *search in searchStrings) {
        NSData *searchData = [search dataUsingEncoding:NSUTF8StringEncoding];
        NSRange searchRange = NSMakeRange(0, data.length);
        int found = 0;
        
        while (searchRange.location < data.length) {
            NSRange range = [data rangeOfData:searchData options:0 range:searchRange];
            if (range.location == NSNotFound) break;
            
            found++;
            write_log(@"");
            write_log(@"🔍 Found '%@' #%d at offset 0x%08lX", search, found, (unsigned long)range.location);
            
            // Контекст
            NSUInteger start = range.location > 16 ? range.location - 16 : 0;
            NSUInteger end = range.location + range.length + 16;
            if (end > data.length) end = data.length;
            NSRange contextRange = NSMakeRange(start, end - start);
            
            write_log(@"   Context (hex):");
            hex_dump(data, contextRange);
            
            // Заменяем на idle
            NSString *replace = [search stringByReplacingOccurrencesOfString:@"_reload" withString:@"_idle"];
            NSData *replaceData = [replace dataUsingEncoding:NSUTF8StringEncoding];
            
            // Проверка длины
            if (replaceData.length != range.length) {
                if (replaceData.length > range.length) {
                    replaceData = [replaceData subdataWithRange:NSMakeRange(0, range.length)];
                    write_log(@"   📏 Truncated to %lu bytes", (unsigned long)replaceData.length);
                } else {
                    NSMutableData *padded = [NSMutableData dataWithData:replaceData];
                    uint8_t zero = 0;
                    for (NSUInteger i = replaceData.length; i < range.length; i++) {
                        [padded appendBytes:&zero length:1];
                    }
                    replaceData = padded;
                    write_log(@"   📏 Padded to %lu bytes", (unsigned long)replaceData.length);
                }
            }
            
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            write_log(@"   ✅ Replaced '%@' with '%@'", search, replace);
            totalPatched++;
            
            searchRange.location = range.location + range.length;
        }
        
        if (found > 0) {
            write_log(@"📊 Found '%@' %d time(s)", search, found);
        } else {
            write_log(@"ℹ️ '%@' not found", search);
        }
    }
    
    if (totalPatched > 0) {
        write_log(@"");
        write_log(@"─────────────────────────────────────────────────────────────");
        write_log(@"📊 Total patches: %d", totalPatched);
        
        NSError *error = nil;
        [newData writeToFile:filePath options:NSDataWritingAtomic error:&error];
        
        if (error) {
            write_log(@"❌ Write error: %@", error);
        } else {
            write_log(@"✅ File saved!");
            
            // Верификация
            NSData *verifyData = [NSData dataWithContentsOfFile:filePath];
            if (verifyData) {
                BOOL stillExists = NO;
                for (NSString *search in searchStrings) {
                    NSData *searchData = [search dataUsingEncoding:NSUTF8StringEncoding];
                    NSRange verifyRange = [verifyData rangeOfData:searchData options:0 range:NSMakeRange(0, verifyData.length)];
                    if (verifyRange.location != NSNotFound) {
                        write_log(@"⚠️ '%@' STILL EXISTS at offset 0x%08lX!", search, (unsigned long)verifyRange.location);
                        stillExists = YES;
                    }
                }
                if (!stillExists) {
                    write_log(@"✅ All strings successfully removed!");
                    isPatched = YES;
                }
            }
        }
    } else {
        write_log(@"");
        write_log(@"⚠️ NOTHING PATCHED!");
    }
    
    write_log(@"═══════════════════════════════════════════════════════════════");
}

static void find_and_patch_bpc(void) {
    NSArray *searchPaths = @[
        @"/var/mobile/Containers/Data/Application",
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject],
        [[NSBundle mainBundle] bundlePath]
    ];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    for (NSString *basePath in searchPaths) {
        if (![fm fileExistsAtPath:basePath]) continue;
        
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
        NSString *file;
        
        while ((file = [enumerator nextObject])) {
            if (![file hasSuffix:@"br_anim.bpc"]) continue;
            
            NSString *fullPath = [basePath stringByAppendingPathComponent:file];
            write_log(@"");
            write_log(@"📦 Found: %@", fullPath);
            patch_bpc_file(fullPath);
            
            if (isPatched) {
                write_log(@"✅ Done!");
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
        write_log(@"║  🔥 NO RELOAD PATCHER v8.0                                 ║");
        write_log(@"║  ✅ Direct binary patch in br_anim.bpc                      ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        find_and_patch_bpc();
    }
}

static void patch_with_retry(void) {
    retryCount++;
    
    if (retryCount > MAX_RETRIES) {
        write_log(@"❌ MAX RETRIES (%d) REACHED", MAX_RETRIES);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            patch_with_retry();
        } @catch (NSException *e) {
            write_log(@"❌ CRASH: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
