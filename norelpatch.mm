// norelpatch.mm - Works with br_anim.bpc (ZIP archive)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <zlib.h>
#include <zip.h>

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

static NSData* zip_read_file(NSString *zipPath, NSString *fileName) {
    // Открываем ZIP
    int err = 0;
    zip_t *zip = zip_open([zipPath fileSystemRepresentation], ZIP_RDONLY, &err);
    if (!zip) {
        write_log(@"❌ Can't open ZIP: %d", err);
        return nil;
    }
    
    // Ищем файл
    struct zip_stat st;
    zip_stat_init(&st);
    zip_stat(zip, [fileName UTF8String], 0, &st);
    
    if (!(st.valid & ZIP_STAT_SIZE)) {
        write_log(@"❌ File '%@' not found in ZIP", fileName);
        zip_close(zip);
        return nil;
    }
    
    // Читаем файл
    zip_file_t *file = zip_fopen(zip, [fileName UTF8String], 0);
    if (!file) {
        write_log(@"❌ Can't open file in ZIP");
        zip_close(zip);
        return nil;
    }
    
    NSMutableData *data = [NSMutableData dataWithLength:st.size];
    zip_fread(file, data.mutableBytes, st.size);
    zip_fclose(file);
    zip_close(zip);
    
    write_log(@"✅ Read '%@' from ZIP (%llu bytes)", fileName, st.size);
    return data;
}

static bool zip_write_file(NSString *zipPath, NSString *fileName, NSData *data) {
    // Открываем ZIP для записи
    int err = 0;
    zip_t *zip = zip_open([zipPath fileSystemRepresentation], ZIP_CREATE | ZIP_TRUNCATE, &err);
    if (!zip) {
        write_log(@"❌ Can't create ZIP: %d", err);
        return false;
    }
    
    // Добавляем файл
    zip_source_t *source = zip_source_buffer(zip, data.bytes, data.length, 0);
    if (!source) {
        write_log(@"❌ Can't create source");
        zip_close(zip);
        return false;
    }
    
    zip_int64_t index = zip_file_add(zip, [fileName UTF8String], source, ZIP_FL_OVERWRITE);
    if (index < 0) {
        write_log(@"❌ Can't add file to ZIP");
        zip_source_free(source);
        zip_close(zip);
        return false;
    }
    
    // Закрываем
    zip_close(zip);
    write_log(@"✅ Written '%@' to ZIP", fileName);
    return true;
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
            
            // Показываем контекст
            NSUInteger start = range.location > 16 ? range.location - 16 : 0;
            NSUInteger end = range.location + range.length + 16;
            if (end > data.length) end = data.length;
            NSRange contextRange = NSMakeRange(start, end - start);
            
            write_log(@"   Context (hex):");
            hex_dump(data, contextRange);
            
            // Заменяем на нули
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
    write_log(@"║  🔥 PATCHING br_anim.bpc (ZIP archive)                     ║");
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
    
    // Файлы которые нужно патчить внутри ZIP
    NSArray *filesToPatch = @[
        @"python.ani",
        @"shotgun.ani"
    ];
    
    bool anyPatched = false;
    
    for (NSString *fileName in filesToPatch) {
        write_log(@"");
        write_log(@"📂 Reading %@ from ZIP...", fileName);
        
        NSData *fileData = zip_read_file(zipPath, fileName);
        if (!fileData) {
            write_log(@"❌ Can't read %@ from ZIP", fileName);
            continue;
        }
        
        NSData *patchedData = patch_reload_strings(fileData, fileName);
        if (patchedData) {
            write_log(@"💾 Writing patched %@ back to ZIP...", fileName);
            
            // Пересоздаём ZIP с патченым файлом
            // Проще: читаем все файлы, патчим нужные, пересоздаём ZIP
            // Но для простоты - распаковываем, патчим, запаковываем
            
            NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"br_anim_patch"];
            [fm removeItemAtPath:tempDir error:nil];
            [fm createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];
            
            // Распаковываем весь ZIP во временную папку
            int err = 0;
            zip_t *zip = zip_open([zipPath fileSystemRepresentation], ZIP_RDONLY, &err);
            if (zip) {
                zip_int64_t numEntries = zip_get_num_entries(zip, 0);
                for (zip_int64_t i = 0; i < numEntries; i++) {
                    struct zip_stat st;
                    zip_stat_init(&st);
                    zip_stat_index(zip, i, 0, &st);
                    
                    NSString *name = [NSString stringWithUTF8String:st.name];
                    if (!name) continue;
                    
                    zip_file_t *file = zip_fopen_index(zip, i, 0);
                    if (file) {
                        NSMutableData *data = [NSMutableData dataWithLength:st.size];
                        zip_fread(file, data.mutableBytes, st.size);
                        zip_fclose(file);
                        
                        // Если это файл который патчим
                        if ([name hasSuffix:@".ani"] && [filesToPatch containsObject:name]) {
                            NSData *patched = patch_reload_strings(data, name);
                            if (patched) {
                                data = [patched mutableCopy];
                                anyPatched = true;
                            }
                        }
                        
                        NSString *outPath = [tempDir stringByAppendingPathComponent:name];
                        NSString *outDir = [outPath stringByDeletingLastPathComponent];
                        [fm createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
                        [data writeToFile:outPath atomically:YES];
                    }
                }
                zip_close(zip);
            }
            
            // Запаковываем обратно
            if (anyPatched) {
                write_log(@"📦 Repacking ZIP...");
                
                zip_t *newZip = zip_open([zipPath fileSystemRepresentation], ZIP_CREATE | ZIP_TRUNCATE, &err);
                if (newZip) {
                    NSArray *allFiles = [fm subpathsOfDirectoryAtPath:tempDir error:nil];
                    for (NSString *file in allFiles) {
                        NSString *fullPath = [tempDir stringByAppendingPathComponent:file];
                        BOOL isDir = NO;
                        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
                        if (isDir) continue;
                        
                        NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
                        if (fileData) {
                            zip_source_t *source = zip_source_buffer(newZip, fileData.bytes, fileData.length, 0);
                            if (source) {
                                zip_file_add(newZip, [file UTF8String], source, ZIP_FL_OVERWRITE);
                            }
                        }
                    }
                    zip_close(newZip);
                    write_log(@"✅ ZIP repacked successfully!");
                }
            }
            
            [fm removeItemAtPath:tempDir error:nil];
        }
    }
    
    if (anyPatched) {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ✅ PATCH COMPLETE!                                         ║");
        write_log(@"║  💾 Backup: br_anim.bpc.original                            ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
    } else {
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  ⚠️ NOTHING PATCHED!                                        ║");
        write_log(@"║  No reload strings found in .ani files                      ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
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
        write_log(@"║  🔥 NO RELOAD PATCHER v3.0 (ZIP SUPPORT)                   ║");
        write_log(@"║  ✅ Extracts br_anim.bpc, patches .ani files, repacks       ║");
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
