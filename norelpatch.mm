// norelpatch.mm - Remove reload animations (ULTIMATE v2 - FIXED)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static bool isPatched = NO;
static int retryCount = 0;
static const int MAX_RETRIES = 10;
static const int RETRY_DELAY = 1;

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

static void patch_anim_file(NSString *filePath) {
    write_log(@"");
    write_log(@"═══════════════════════════════════════════════════════════════");
    write_log(@"📁 FILE: %@", filePath.lastPathComponent);
    write_log(@"📂 PATH: %@", filePath);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:filePath]) {
        write_log(@"❌ FILE NOT FOUND!");
        write_log(@"   Expected: %@", filePath);
        write_log(@"═══════════════════════════════════════════════════════════════");
        return;
    }
    
    write_log(@"✅ FILE EXISTS");
    
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        write_log(@"❌ CANNOT READ FILE!");
        write_log(@"═══════════════════════════════════════════════════════════════");
        return;
    }
    
    write_log(@"📊 FILE SIZE: %lu bytes", (unsigned long)data.length);
    
    NSString *backupPath = [filePath stringByAppendingString:@".original"];
    if (![fm fileExistsAtPath:backupPath]) {
        BOOL backupSaved = [data writeToFile:backupPath atomically:YES];
        if (backupSaved) {
            write_log(@"💾 Original backed up: %@", backupPath.lastPathComponent);
        } else {
            write_log(@"⚠️ Failed to create backup!");
        }
    } else {
        write_log(@"ℹ️ Backup already exists: %@", backupPath.lastPathComponent);
    }
    
    NSArray *searchStrings = @[
        @"python_reload",
        @"python_crouchreload",
        @"shotgun_reload",
        @"shotgun_crouchreload",
        @"reload"
    ];
    
    NSMutableData *newData = [data mutableCopy];
    int totalPatched = 0;
    NSMutableArray *foundStrings = [NSMutableArray array];
    NSMutableArray *foundOffsets = [NSMutableArray array];
    
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
            write_log(@"   Length: %lu bytes", (unsigned long)range.length);
            
            NSUInteger start = range.location > 16 ? range.location - 16 : 0;
            NSUInteger end = range.location + range.length + 16;
            if (end > data.length) end = data.length;
            NSRange contextRange = NSMakeRange(start, end - start);
            
            write_log(@"   Context (hex):");
            hex_dump(data, contextRange);
            
            NSData *contextData = [data subdataWithRange:contextRange];
            NSString *contextStr = [[NSString alloc] initWithData:contextData encoding:NSUTF8StringEncoding];
            if (contextStr) {
                NSMutableString *ascii = [NSMutableString string];
                for (NSUInteger i = 0; i < contextStr.length; i++) {
                    unichar c = [contextStr characterAtIndex:i];
                    if (c >= 32 && c < 127) {
                        [ascii appendFormat:@"%C", c];
                    } else {
                        [ascii appendString:@"."];
                    }
                }
                write_log(@"   Context (ASCII): %@", ascii);
            }
            
            uint8_t zeros[128] = {0};
            NSData *replaceData = [NSData dataWithBytes:zeros length:range.length];
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            
            write_log(@"   ✅ Replaced with zeros (%lu bytes)", (unsigned long)range.length);
            
            NSData *verifyData = [newData subdataWithRange:range];
            const unsigned char *verifyBytes = (const unsigned char *)verifyData.bytes;
            BOOL allZero = YES;
            for (NSUInteger i = 0; i < verifyData.length; i++) {
                if (verifyBytes[i] != 0) { allZero = NO; break; }
            }
            write_log(@"   ✅ Verification: %@", allZero ? @"ALL ZERO" : @"⚠️ NOT ZERO!");
            
            totalPatched++;
            [foundStrings addObject:search];
            [foundOffsets addObject:@(range.location)];
            
            searchRange.location = range.location + range.length;
        }
        
        if (found > 0) {
            write_log(@"📊 Found '%@' %d time(s)", search, found);
        } else {
            write_log(@"ℹ️ '%@' not found", search);
        }
    }
    
    write_log(@"");
    write_log(@"─────────────────────────────────────────────────────────────");
    write_log(@"📊 SUMMARY:");
    write_log(@"   Total replacements: %d", totalPatched);
    if (totalPatched > 0) {
        write_log(@"   Replaced strings:");
        for (NSUInteger i = 0; i < foundStrings.count; i++) {
            write_log(@"     - %@ at offset 0x%08lX", foundStrings[i], (unsigned long)[foundOffsets[i] unsignedLongValue]);
        }
    } else {
        write_log(@"   ⚠️ NOTHING WAS REPLACED!");
        write_log(@"   Check if file contains reload strings");
    }
    
    if (totalPatched > 0) {
        NSError *error = nil;
        BOOL written = [newData writeToFile:filePath options:NSDataWritingAtomic error:&error];
        
        if (written) {
            write_log(@"");
            write_log(@"✅ FILE SAVED SUCCESSFULLY!");
            
            NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
            NSNumber *newSize = attrs[NSFileSize];
            write_log(@"   New file size: %@ bytes", newSize);
            
            NSData *verifyFile = [NSData dataWithContentsOfFile:filePath];
            if (verifyFile) {
                BOOL stillExists = NO;
                for (NSString *search in foundStrings) {
                    NSData *searchData = [search dataUsingEncoding:NSUTF8StringEncoding];
                    NSRange verifyRange = [verifyFile rangeOfData:searchData options:0 range:NSMakeRange(0, verifyFile.length)];
                    if (verifyRange.location != NSNotFound) {
                        write_log(@"   ⚠️ '%@' STILL EXISTS at offset 0x%08lX!", search, (unsigned long)verifyRange.location);
                        stillExists = YES;
                    }
                }
                if (!stillExists) {
                    write_log(@"   ✅ All reload strings successfully removed!");
                }
            }
            
        } else {
            write_log(@"❌ FAILED TO SAVE FILE!");
            write_log(@"   Error: %@", error);
        }
    }
    
    write_log(@"═══════════════════════════════════════════════════════════════");
}

static void list_directory(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    write_log(@"");
    write_log(@"📂 CHECKING: %@", path);
    
    if (![fm fileExistsAtPath:path]) {
        write_log(@"❌ NOT FOUND!");
        return;
    }
    
    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
    
    if (error) {
        write_log(@"❌ Can't read: %@", error);
        return;
    }
    
    write_log(@"📊 Contents (%lu items):", (unsigned long)contents.count);
    for (NSString *item in contents) {
        NSString *fullPath = [path stringByAppendingPathComponent:item];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        NSNumber *size = attrs[NSFileSize];
        write_log(@"   - %@ (%@ bytes)", item, size);
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
        write_log(@"║  🔥 NO RELOAD PATCHER v2.0                                 ║");
        write_log(@"║  ✅ Backup created before patching                          ║");
        write_log(@"║  ✅ Double verification                                     ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libPath = [paths firstObject];
        NSString *bpc = [[[[libPath stringByAppendingPathComponent:@"Application Support"]
                           stringByAppendingPathComponent:@"files"]
                          stringByAppendingPathComponent:@"mesh"]
                         stringByAppendingPathComponent:@"br_anim.bpc"];
        
        write_log(@"📂 Target path: %@", bpc);
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:bpc]) {
            write_log(@"❌ br_anim.bpc directory NOT FOUND!");
            write_log(@"   Full path: %@", bpc);
            
            NSString *appSupport = [libPath stringByAppendingPathComponent:@"Application Support"];
            list_directory(appSupport);
            
            NSString *files = [appSupport stringByAppendingPathComponent:@"files"];
            list_directory(files);
            
            NSString *mesh = [files stringByAppendingPathComponent:@"mesh"];
            list_directory(mesh);
            
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════════╗");
            write_log(@"║  ❌ PATH NOT FOUND!                                         ║");
            write_log(@"╚═══════════════════════════════════════════════════════════════╝");
            return;
        }
        
        list_directory(bpc);
        
        NSArray *filesToPatch = @[
            [bpc stringByAppendingPathComponent:@"python.ani"],
            [bpc stringByAppendingPathComponent:@"shotgun.ani"]
        ];
        
        for (NSString *filePath in filesToPatch) {
            patch_anim_file(filePath);
        }
        
        isPatched = YES;
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ✅ NO RELOAD PATCHER FINISHED                              ║");
        write_log(@"║  📝 Log: Documents/saves/NoReload.log                       ║");
        write_log(@"║  💾 Backups: *.ani.original                                 ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
    }
}

static void patch_with_retry(void) {
    write_log(@"");
    write_log(@"🔄 Checking for game files (retry %d/%d)...", retryCount + 1, MAX_RETRIES);
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libPath = [paths firstObject];
    NSString *bpc = [[[[libPath stringByAppendingPathComponent:@"Application Support"]
                       stringByAppendingPathComponent:@"files"]
                      stringByAppendingPathComponent:@"mesh"]
                     stringByAppendingPathComponent:@"br_anim.bpc"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:bpc]) {
        write_log(@"✅ Files found! Applying patch...");
        patch_all();
        return;
    }
    
    retryCount++;
    if (retryCount < MAX_RETRIES) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, RETRY_DELAY * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            patch_with_retry();
        });
    } else {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ❌ MAX RETRIES REACHED!                                    ║");
        write_log(@"║  Game files not found after %d attempts", MAX_RETRIES);
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
            write_log(@"");
            write_log(@"╔═══════════════════════════════════════════════════════════════╗");
            write_log(@"║  ❌ CRASH!                                                   ║");
            write_log(@"║  Exception: %@", e);
            write_log(@"║  Reason: %@", e.reason);
            write_log(@"╚═══════════════════════════════════════════════════════════════╝");
            write_log(@"");
        }
    });
}

extern "C" void __dummy_export(void) {}
