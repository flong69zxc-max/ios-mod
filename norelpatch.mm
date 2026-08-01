// norelpatch.mm - Extract ZIP, patch, repack (using system commands)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <zlib.h>

static bool isPatched = NO;
static int retryCount = 0;
static const int MAX_RETRIES = 10;

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
            
            NSUInteger start = range.location > 16 ? range.location - 16 : 0;
            NSUInteger end = range.location + range.length + 16;
            if (end > data.length) end = data.length;
            NSRange contextRange = NSMakeRange(start, end - start);
            
            write_log(@"   Context (hex):");
            hex_dump(data, contextRange);
            
            uint8_t zeros[64] = {0};
            NSData *replaceData = [NSData dataWithBytes:zeros length:range.length];
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            
            write_log(@"   ✅ Replaced '%@' with zeros (%lu bytes)", search, (unsigned long)range.length);
            patched++;
            
            searchRange.location = range.location + range.length;
        }
    }
    
    if (patched > 0) {
        write_log(@"📊 Total patches in %@: %d", fileName, patched);
        return newData;
    }
    
    return nil;
}

static void patch_zip(NSString *zipPath) {
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════════╗");
    write_log(@"║  🔥 PATCHING br_anim.bpc                                    ║");
    write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    write_log(@"");
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:zipPath]) {
        write_log(@"❌ File not found: %@", zipPath);
        return;
    }
    
    // Бэкап
    NSString *backupPath = [zipPath stringByAppendingString:@".original"];
    if (![fm fileExistsAtPath:backupPath]) {
        NSData *origData = [NSData dataWithContentsOfFile:zipPath];
        [origData writeToFile:backupPath atomically:YES];
        write_log(@"💾 Backup: %@", backupPath.lastPathComponent);
    }
    
    // Временная папка
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"br_anim_extract"];
    [fm removeItemAtPath:tempDir error:nil];
    [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
    write_log(@"📂 Temp dir: %@", tempDir);
    
    // Распаковываем используя /usr/bin/unzip (есть на iOS)
    NSTask *unzipTask = [[NSTask alloc] init];
    [unzipTask setLaunchPath:@"/usr/bin/unzip"];
    [unzipTask setArguments:@[@"-o", zipPath, @"-d", tempDir]];
    
    NSPipe *pipe = [NSPipe pipe];
    [unzipTask setStandardOutput:pipe];
    [unzipTask setStandardError:pipe];
    
    @try {
        [unzipTask launch];
        [unzipTask waitUntilExit];
        write_log(@"✅ Unzipped successfully");
    } @catch (NSException *e) {
        write_log(@"❌ Unzip failed: %@", e);
        [fm removeItemAtPath:tempDir error:nil];
        return;
    }
    
    // Ищем и патчим .ani файлы
    NSArray *aniFiles = @[@"python.ani", @"shotgun.ani"];
    bool anyPatched = false;
    
    for (NSString *aniFile in aniFiles) {
        NSString *aniPath = [tempDir stringByAppendingPathComponent:aniFile];
        if (![fm fileExistsAtPath:aniPath]) {
            write_log(@"⚠️ %@ not found in archive", aniFile);
            continue;
        }
        
        write_log(@"");
        write_log(@"📁 Found: %@", aniFile);
        
        NSData *aniData = [NSData dataWithContentsOfFile:aniPath];
        if (!aniData) {
            write_log(@"❌ Can't read %@", aniFile);
            continue;
        }
        
        NSData *patchedData = patch_reload_strings(aniData, aniFile);
        if (patchedData) {
            [patchedData writeToFile:aniPath atomically:YES];
            write_log(@"✅ %@ patched and saved", aniFile);
            anyPatched = true;
        }
    }
    
    if (!anyPatched) {
        write_log(@"");
        write_log(@"⚠️ Nothing to patch! No reload strings found.");
        [fm removeItemAtPath:tempDir error:nil];
        return;
    }
    
    // Запаковываем обратно
    write_log(@"");
    write_log(@"📦 Repacking ZIP...");
    
    NSTask *zipTask = [[NSTask alloc] init];
    [zipTask setLaunchPath:@"/usr/bin/zip"];
    [zipTask setArguments:@[@"-r", zipPath, @"."]];
    [zipTask setCurrentDirectoryPath:tempDir];
    
    NSPipe *zipPipe = [NSPipe pipe];
    [zipTask setStandardOutput:zipPipe];
    [zipTask setStandardError:zipPipe];
    
    @try {
        [zipTask launch];
        [zipTask waitUntilExit];
        write_log(@"✅ ZIP repacked successfully!");
    } @catch (NSException *e) {
        write_log(@"❌ Zip failed: %@", e);
        [fm removeItemAtPath:tempDir error:nil];
        return;
    }
    
    // Чистим
    [fm removeItemAtPath:tempDir error:nil];
    
    write_log(@"");
    write_log(@"╔═══════════════════════════════════════════════════════════════╗");
    write_log(@"║  ✅ PATCH COMPLETE!                                         ║");
    write_log(@"║  💾 Backup: br_anim.bpc.original                            ║");
    write_log(@"╚═══════════════════════════════════════════════════════════════╝");
}

static void patch_all(void) {
    @autoreleasepool {
        if (isPatched) {
            write_log(@"ℹ️ Already patched, skipping...");
            return;
        }
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  🔥 NO RELOAD PATCHER v3.0                                 ║");
        write_log(@"║  ✅ Extracts br_anim.bpc, patches .ani, repacks             ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libPath = [paths firstObject];
        NSString *zipPath = [[[[libPath stringByAppendingPathComponent:@"Application Support"]
                               stringByAppendingPathComponent:@"files"]
                              stringByAppendingPathComponent:@"mesh"]
                             stringByAppendingPathComponent:@"br_anim.bpc"];
        
        write_log(@"📂 Target: %@", zipPath);
        patch_zip(zipPath);
        isPatched = YES;
    }
}

static void patch_with_retry(void) {
    write_log(@"");
    write_log(@"🔄 Checking for game files (retry %d/%d)...", retryCount + 1, MAX_RETRIES);
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libPath = [paths firstObject];
    NSString *zipPath = [[[[libPath stringByAppendingPathComponent:@"Application Support"]
                           stringByAppendingPathComponent:@"files"]
                          stringByAppendingPathComponent:@"mesh"]
                         stringByAppendingPathComponent:@"br_anim.bpc"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:zipPath]) {
        write_log(@"✅ File found! Applying patch...");
        patch_all();
        return;
    }
    
    retryCount++;
    if (retryCount < MAX_RETRIES) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            patch_with_retry();
        });
    } else {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ❌ MAX RETRIES REACHED!                                    ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            patch_with_retry();
        } @catch (NSException *e) {
            write_log(@"❌ CRASH: %@", e);
        }
    });
}

extern "C" void __dummy_export(void) {}
