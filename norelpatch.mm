// norelpatch.mm - ULTIMATE v5.0 (10/10)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static bool isPatched = NO;
static int retryCount = 0;
static const int MAX_RETRIES = 15;
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

static BOOL is_file_already_patched(NSData *data) {
    // Проверяем наличие "idle" вместо "reload"
    NSData *idleData = [@"_idle" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *reloadData = [@"_reload" dataUsingEncoding:NSUTF8StringEncoding];
    
    NSRange idleRange = [data rangeOfData:idleData options:0 range:NSMakeRange(0, data.length)];
    NSRange reloadRange = [data rangeOfData:reloadData options:0 range:NSMakeRange(0, data.length)];
    
    // Если есть idle и нет reload - уже пропатчено
    if (idleRange.location != NSNotFound && reloadRange.location == NSNotFound) {
        return YES;
    }
    return NO;
}

static NSData* patch_reload_strings(NSData *data, NSString *fileName) {
    // Проверяем что файл еще не пропатчен
    if (is_file_already_patched(data)) {
        write_log(@"ℹ️ %@ already patched, skipping", fileName);
        return nil;
    }
    
    NSMutableData *newData = [data mutableCopy];
    int patched = 0;
    int totalFound = 0;
    
    // Ищем все строки с _reload
    NSData *reloadPattern = [@"_reload" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange searchRange = NSMakeRange(0, data.length);
    
    while (searchRange.location < data.length) {
        NSRange range = [data rangeOfData:reloadPattern options:0 range:searchRange];
        if (range.location == NSNotFound) break;
        
        totalFound++;
        
        // Находим начало имени анимации (ищем пробел или кавычку перед словом)
        NSUInteger start = range.location;
        while (start > 0) {
            unichar c = 0;
            if (start > 0) {
                [data getBytes:&c range:NSMakeRange(start - 1, 1)];
                if (c == ' ' || c == '"' || c == '\'' || c == '\n' || c == '\t') break;
                start--;
            } else break;
        }
        
        // Собираем полное имя анимации
        NSUInteger end = range.location + range.length;
        while (end < data.length) {
            unichar c = 0;
            [data getBytes:&c range:NSMakeRange(end, 1)];
            if (c == ' ' || c == '"' || c == '\'' || c == '\n' || c == '\t' || c == '\0') break;
            end++;
        }
        
        NSRange animRange = NSMakeRange(start, end - start);
        NSData *animData = [data subdataWithRange:animRange];
        NSString *animName = [[NSString alloc] initWithData:animData encoding:NSUTF8StringEncoding];
        
        if (!animName) {
            // Если не удалось распарсить - просто заменяем _reload на _idle
            write_log(@"");
            write_log(@"🔍 Found '_reload' in %@ at offset 0x%08lX", fileName, (unsigned long)range.location);
            
            NSData *replaceData = [@"_idle" dataUsingEncoding:NSUTF8StringEncoding];
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            
            write_log(@"   ✅ Replaced '_reload' with '_idle'");
            patched++;
            searchRange.location = range.location + range.length;
            continue;
        }
        
        write_log(@"");
        write_log(@"🔍 Found animation: '%@' in %@ at offset 0x%08lX", animName, fileName, (unsigned long)range.location);
        
        // Контекст
        NSUInteger ctxStart = animRange.location > 16 ? animRange.location - 16 : 0;
        NSUInteger ctxEnd = animRange.location + animRange.length + 16;
        if (ctxEnd > data.length) ctxEnd = data.length;
        NSRange contextRange = NSMakeRange(ctxStart, ctxEnd - ctxStart);
        
        write_log(@"   Context (hex):");
        hex_dump(data, contextRange);
        
        // Заменяем reload на idle
        NSString *newAnimName = [animName stringByReplacingOccurrencesOfString:@"_reload" withString:@"_idle"];
        NSData *replaceData = [newAnimName dataUsingEncoding:NSUTF8StringEncoding];
        
        // Проверка длины
        if (replaceData.length != animRange.length) {
            write_log(@"   ⚠️ Length mismatch! Original: %lu, New: %lu", (unsigned long)animRange.length, (unsigned long)replaceData.length);
            
            if (replaceData.length > animRange.length) {
                replaceData = [replaceData subdataWithRange:NSMakeRange(0, animRange.length)];
                write_log(@"   📏 Truncated to %lu bytes", (unsigned long)replaceData.length);
            } else {
                NSMutableData *padded = [NSMutableData dataWithData:replaceData];
                uint8_t zero = 0;
                for (NSUInteger i = replaceData.length; i < animRange.length; i++) {
                    [padded appendBytes:&zero length:1];
                }
                replaceData = padded;
                write_log(@"   📏 Padded to %lu bytes", (unsigned long)replaceData.length);
            }
        }
        
        [newData replaceBytesInRange:animRange withBytes:replaceData.bytes length:replaceData.length];
        
        write_log(@"   ✅ Replaced '%@' with '%@'", animName, newAnimName);
        patched++;
        
        searchRange.location = animRange.location + animRange.length;
    }
    
    if (patched > 0) {
        write_log(@"📊 Patched %d reload animation(s) in %@", patched, fileName);
        return newData;
    }
    
    // Если не нашли _reload, но нашли просто reload
    NSData *reloadSimple = [@"reload" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange simpleRange = [data rangeOfData:reloadSimple options:0 range:NSMakeRange(0, data.length)];
    
    if (simpleRange.location != NSNotFound) {
        write_log(@"");
        write_log(@"🔍 Found 'reload' (without underscore) in %@ at offset 0x%08lX", fileName, (unsigned long)simpleRange.location);
        
        NSData *replaceData = [@"idle" dataUsingEncoding:NSUTF8StringEncoding];
        if (replaceData.length != simpleRange.length) {
            if (replaceData.length > simpleRange.length) {
                replaceData = [replaceData subdataWithRange:NSMakeRange(0, simpleRange.length)];
            } else {
                NSMutableData *padded = [NSMutableData dataWithData:replaceData];
                uint8_t zero = 0;
                for (NSUInteger i = replaceData.length; i < simpleRange.length; i++) {
                    [padded appendBytes:&zero length:1];
                }
                replaceData = padded;
            }
        }
        
        [newData replaceBytesInRange:simpleRange withBytes:replaceData.bytes length:replaceData.length];
        write_log(@"   ✅ Replaced 'reload' with 'idle'");
        patched++;
    }
    
    if (patched > 0) {
        return newData;
    }
    
    write_log(@"ℹ️ No reload strings found in %@", fileName);
    return nil;
}

static void find_and_patch_ani_files(NSString *dirPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:dirPath]) return;
    
    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error) return;
    
    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        
        if (isDir) {
            find_and_patch_ani_files(fullPath);
            continue;
        }
        
        // Проверяем только .ani файлы
        if (![item hasSuffix:@".ani"]) continue;
        if ([item hasSuffix:@".original"]) continue;
        
        write_log(@"");
        write_log(@"═══════════════════════════════════════════════════════════════");
        write_log(@"📁 Found: %@", item);
        write_log(@"📂 Path: %@", fullPath);
        
        NSData *data = [NSData dataWithContentsOfFile:fullPath];
        if (!data) {
            write_log(@"❌ Can't read file");
            continue;
        }
        
        write_log(@"📊 Size: %lu bytes", (unsigned long)data.length);
        
        // Бэкап
        NSString *backupPath = [fullPath stringByAppendingString:@".original"];
        if (![fm fileExistsAtPath:backupPath]) {
            [data writeToFile:backupPath atomically:YES];
            write_log(@"💾 Backup: %@", backupPath.lastPathComponent);
        }
        
        NSData *patched = patch_reload_strings(data, item);
        if (patched) {
            [patched writeToFile:fullPath atomically:YES];
            write_log(@"✅ File saved");
            isPatched = YES;
        }
    }
}

static void patch_all(void) {
    @autoreleasepool {
        if (isPatched) {
            write_log(@"ℹ️ Already patched, skipping...");
            return;
        }
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  🔥 NO RELOAD PATCHER v5.0 (10/10)                         ║");
        write_log(@"║  ✅ Replaces '_reload' with '_idle' in all .ani files       ║");
        write_log(@"║  ✅ Safe length handling                                    ║");
        write_log(@"║  ✅ Duplicate protection                                   ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        // Пути для поиска
        NSMutableArray *searchPaths = [NSMutableArray array];
        
        // 1. /var/mobile/Containers/Data/Application
        [searchPaths addObject:@"/var/mobile/Containers/Data/Application"];
        
        // 2. Documents
        NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (docPath) [searchPaths addObject:docPath];
        
        // 3. Library
        NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        if (libPath) [searchPaths addObject:libPath];
        
        // 4. Bundle
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        if (bundlePath) [searchPaths addObject:bundlePath];
        
        // 5. Application Support
        if (libPath) {
            NSString *appSupport = [libPath stringByAppendingPathComponent:@"Application Support"];
            if (appSupport) [searchPaths addObject:appSupport];
        }
        
        int totalDirs = 0;
        int totalFiles = 0;
        
        for (NSString *basePath in searchPaths) {
            if (!basePath) continue;
            
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:basePath]) continue;
            
            write_log(@"");
            write_log(@"📂 Searching: %@", basePath);
            
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:basePath];
            NSString *file;
            int found = 0;
            
            while ((file = [enumerator nextObject])) {
                if ([file hasSuffix:@".ani"] && ![file hasSuffix:@".original"]) {
                    NSString *fullPath = [basePath stringByAppendingPathComponent:file];
                    totalFiles++;
                    found++;
                    
                    write_log(@"");
                    write_log(@"─────────────────────────────────────────────────────────────");
                    write_log(@"📁 %@", file);
                    
                    NSData *data = [NSData dataWithContentsOfFile:fullPath];
                    if (!data) {
                        write_log(@"❌ Can't read");
                        continue;
                    }
                    
                    // Бэкап
                    NSString *backupPath = [fullPath stringByAppendingString:@".original"];
                    if (![fm fileExistsAtPath:backupPath]) {
                        [data writeToFile:backupPath atomically:YES];
                        write_log(@"💾 Backup created");
                    }
                    
                    NSData *patched = patch_reload_strings(data, file);
                    if (patched) {
                        [patched writeToFile:fullPath atomically:YES];
                        write_log(@"✅ Patched!");
                        isPatched = YES;
                    }
                }
            }
            
            write_log(@"📊 Found %d .ani files in %@", found, basePath);
            totalDirs++;
        }
        
        write_log(@"");
        write_log(@"─────────────────────────────────────────────────────────────");
        write_log(@"📊 SEARCH SUMMARY:");
        write_log(@"   Directories searched: %d", totalDirs);
        write_log(@"   Total .ani files found: %d", totalFiles);
        write_log(@"   Patched: %@", isPatched ? @"YES ✅" : @"NO ⚠️");
        
        if (isPatched) {
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════════╗");
            write_log(@"║  ✅ PATCH COMPLETE!                                         ║");
            write_log(@"║  All reload animations replaced with idle                   ║");
            write_log(@"║  💾 Backups: *.original                                    ║");
            write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        } else {
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════════╗");
            write_log(@"║  ⚠️ NO .ani FILES FOUND WITH RELOAD                        ║");
            write_log(@"║  Either game not installed or files not accessible         ║");
            write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        }
    }
}

static void patch_with_retry(void) {
    retryCount++;
    
    if (retryCount > MAX_RETRIES) {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ❌ MAX RETRIES REACHED (%d)", MAX_RETRIES);
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
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
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════════╗");
            write_log(@"║  ❌ CRASH!                                                   ║");
            write_log(@"║  %@", e);
            write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        }
    });
}

extern "C" void __dummy_export(void) {}
