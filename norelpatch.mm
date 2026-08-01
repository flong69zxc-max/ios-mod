// norelpatch.mm - v6.0 (ZIP extraction + patch + repack)

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

static BOOL is_file_already_patched(NSData *data) {
    NSData *idleData = [@"_idle" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *reloadData = [@"_reload" dataUsingEncoding:NSUTF8StringEncoding];
    
    NSRange idleRange = [data rangeOfData:idleData options:0 range:NSMakeRange(0, data.length)];
    NSRange reloadRange = [data rangeOfData:reloadData options:0 range:NSMakeRange(0, data.length)];
    
    if (idleRange.location != NSNotFound && reloadRange.location == NSNotFound) {
        return YES;
    }
    return NO;
}

static NSData* patch_reload_strings(NSData *data, NSString *fileName) {
    if (is_file_already_patched(data)) {
        write_log(@"ℹ️ %@ already patched", fileName);
        return nil;
    }
    
    NSMutableData *newData = [data mutableCopy];
    int patched = 0;
    
    NSData *reloadPattern = [@"_reload" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange searchRange = NSMakeRange(0, data.length);
    
    while (searchRange.location < data.length) {
        NSRange range = [data rangeOfData:reloadPattern options:0 range:searchRange];
        if (range.location == NSNotFound) break;
        
        write_log(@"");
        write_log(@"🔍 Found '_reload' in %@ at offset 0x%08lX", fileName, (unsigned long)range.location);
        
        NSUInteger start = range.location;
        while (start > 0) {
            unichar c = 0;
            if (start > 0) {
                [data getBytes:&c range:NSMakeRange(start - 1, 1)];
                if (c == ' ' || c == '"' || c == '\'' || c == '\n' || c == '\t') break;
                start--;
            } else break;
        }
        
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
        
        if (animName) {
            write_log(@"   Animation: '%@'", animName);
            
            NSUInteger ctxStart = animRange.location > 16 ? animRange.location - 16 : 0;
            NSUInteger ctxEnd = animRange.location + animRange.length + 16;
            if (ctxEnd > data.length) ctxEnd = data.length;
            NSRange contextRange = NSMakeRange(ctxStart, ctxEnd - ctxStart);
            hex_dump(data, contextRange);
            
            NSString *newAnimName = [animName stringByReplacingOccurrencesOfString:@"_reload" withString:@"_idle"];
            NSData *replaceData = [newAnimName dataUsingEncoding:NSUTF8StringEncoding];
            
            if (replaceData.length != animRange.length) {
                if (replaceData.length > animRange.length) {
                    replaceData = [replaceData subdataWithRange:NSMakeRange(0, animRange.length)];
                } else {
                    NSMutableData *padded = [NSMutableData dataWithData:replaceData];
                    uint8_t zero = 0;
                    for (NSUInteger i = replaceData.length; i < animRange.length; i++) {
                        [padded appendBytes:&zero length:1];
                    }
                    replaceData = padded;
                }
            }
            
            [newData replaceBytesInRange:animRange withBytes:replaceData.bytes length:replaceData.length];
            write_log(@"   ✅ Replaced with '%@'", newAnimName);
            patched++;
        } else {
            NSData *replaceData = [@"_idle" dataUsingEncoding:NSUTF8StringEncoding];
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            write_log(@"   ✅ Replaced '_reload' with '_idle'");
            patched++;
        }
        
        searchRange.location = range.location + range.length;
    }
    
    if (patched > 0) {
        write_log(@"📊 Patched %d reload(s) in %@", patched, fileName);
        return newData;
    }
    
    return nil;
}

static void unzip_file(NSString *zipPath, NSString *destDir) {
    write_log(@"");
    write_log(@"📦 Extracting ZIP...");
    
    NSData *zipData = [NSData dataWithContentsOfFile:zipPath];
    if (!zipData) {
        write_log(@"❌ Can't read ZIP");
        return;
    }
    
    // Ищем центральный каталог ZIP
    const uint8_t *bytes = zipData.bytes;
    NSUInteger length = zipData.length;
    NSUInteger centralDirOffset = 0;
    
    for (NSUInteger i = length - 22; i > 0; i--) {
        if (i + 4 < length && bytes[i] == 0x50 && bytes[i+1] == 0x4B && bytes[i+2] == 0x05 && bytes[i+3] == 0x06) {
            // Нашли конец центрального каталога
            centralDirOffset = i - 16;
            if (centralDirOffset + 4 < length) {
                // Читаем смещение центрального каталога
                uint32_t dirOffset = 0;
                memcpy(&dirOffset, bytes + centralDirOffset + 12, 4);
                centralDirOffset = dirOffset;
                break;
            }
        }
    }
    
    if (centralDirOffset == 0) {
        write_log(@"❌ Invalid ZIP structure");
        return;
    }
    
    // Парсим центральный каталог
    NSUInteger pos = centralDirOffset;
    int fileCount = 0;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    
    while (pos + 46 < length) {
        if (!(bytes[pos] == 0x50 && bytes[pos+1] == 0x4B && bytes[pos+2] == 0x01 && bytes[pos+3] == 0x02)) break;
        
        uint16_t fileNameLength = 0;
        memcpy(&fileNameLength, bytes + pos + 28, 2);
        uint16_t extraFieldLength = 0;
        memcpy(&extraFieldLength, bytes + pos + 30, 2);
        uint16_t commentLength = 0;
        memcpy(&commentLength, bytes + pos + 32, 2);
        uint32_t compressedSize = 0;
        memcpy(&compressedSize, bytes + pos + 20, 4);
        uint32_t uncompressedSize = 0;
        memcpy(&uncompressedSize, bytes + pos + 24, 4);
        uint32_t localHeaderOffset = 0;
        memcpy(&localHeaderOffset, bytes + pos + 42, 4);
        
        if (fileNameLength > 0) {
            NSString *fileName = [[NSString alloc] initWithBytes:bytes + pos + 46 length:fileNameLength encoding:NSUTF8StringEncoding];
            if (fileName) {
                // Проверяем .ani файлы
                if ([fileName hasSuffix:@".ani"]) {
                    write_log(@"📁 Found: %@ (%lu bytes)", fileName, (unsigned long)uncompressedSize);
                    
                    // Читаем локальный заголовок
                    NSUInteger localPos = localHeaderOffset;
                    if (localPos + 30 < length && bytes[localPos] == 0x50 && bytes[localPos+1] == 0x4B && bytes[localPos+2] == 0x03 && bytes[localPos+3] == 0x04) {
                        
                        uint16_t localFileNameLength = 0;
                        memcpy(&localFileNameLength, bytes + localPos + 26, 2);
                        uint16_t localExtraLength = 0;
                        memcpy(&localExtraLength, bytes + localPos + 28, 2);
                        
                        NSUInteger dataStart = localPos + 30 + localFileNameLength + localExtraLength;
                        
                        if (dataStart + compressedSize <= length) {
                            NSData *fileData = [NSData dataWithBytes:bytes + dataStart length:compressedSize];
                            
                            // Если сжато - распаковываем
                            NSData *uncompressedData = fileData;
                            if (compressedSize != uncompressedSize) {
                                // Простая распаковка zlib
                                z_stream stream = {0};
                                inflateInit(&stream);
                                
                                stream.next_in = (Bytef*)fileData.bytes;
                                stream.avail_in = (uInt)fileData.length;
                                
                                NSMutableData *outData = [NSMutableData dataWithLength:uncompressedSize];
                                stream.next_out = outData.mutableBytes;
                                stream.avail_out = (uInt)uncompressedSize;
                                
                                inflate(&stream, Z_FINISH);
                                inflateEnd(&stream);
                                
                                if (stream.total_out == uncompressedSize) {
                                    uncompressedData = outData;
                                } else {
                                    write_log(@"   ⚠️ Decompress mismatch: %lu vs %lu", stream.total_out, (unsigned long)uncompressedSize);
                                }
                            }
                            
                            // Патчим
                            NSData *patched = patch_reload_strings(uncompressedData, fileName);
                            if (patched) {
                                // Сохраняем патченый файл во временную папку
                                NSString *outPath = [destDir stringByAppendingPathComponent:fileName];
                                [patched writeToFile:outPath atomically:YES];
                                write_log(@"   ✅ Saved patched: %@", fileName);
                                isPatched = YES;
                            }
                        }
                    }
                }
                fileCount++;
            }
        }
        
        pos += 46 + fileNameLength + extraFieldLength + commentLength;
    }
    
    write_log(@"📊 Total files in ZIP: %d", fileCount);
}

static void zip_folder(NSString *srcDir, NSString *destPath) {
    write_log(@"");
    write_log(@"📦 Repacking ZIP...");
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm subpathsOfDirectoryAtPath:srcDir error:nil];
    
    // Создаем новый ZIP
    NSMutableData *zipData = [NSMutableData data];
    
    NSMutableArray *centralDirEntries = [NSMutableArray array];
    uint32_t centralDirStart = 0;
    
    for (NSString *file in files) {
        NSString *fullPath = [srcDir stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:fullPath isDirectory:&isDir];
        if (isDir) continue;
        
        NSData *fileData = [NSData dataWithContentsOfFile:fullPath];
        if (!fileData) continue;
        
        NSData *fileNameData = [file dataUsingEncoding:NSUTF8StringEncoding];
        
        // Локальный заголовок
        uint32_t crc = 0;
        crc32(crc, fileData.bytes, (uInt)fileData.length);
        
        uint32_t compressedSize = (uint32_t)fileData.length;
        uint32_t uncompressedSize = (uint32_t)fileData.length;
        
        // Просто храним без сжатия (быстрее)
        NSMutableData *localHeader = [NSMutableData data];
        uint32_t sig = 0x04034b50; [localHeader appendBytes:&sig length:4];
        uint16_t version = 0x0A; [localHeader appendBytes:&version length:2];
        uint16_t flags = 0; [localHeader appendBytes:&flags length:2];
        uint16_t compression = 0; [localHeader appendBytes:&compression length:2];
        uint32_t time = 0; [localHeader appendBytes:&time length:4];
        uint32_t date = 0; [localHeader appendBytes:&date length:4];
        [localHeader appendBytes:&crc length:4];
        [localHeader appendBytes:&compressedSize length:4];
        [localHeader appendBytes:&uncompressedSize length:4];
        uint16_t fnLen = (uint16_t)fileNameData.length; [localHeader appendBytes:&fnLen length:2];
        uint16_t extraLen = 0; [localHeader appendBytes:&extraLen length:2];
        [localHeader appendData:fileNameData];
        
        uint32_t localOffset = (uint32_t)zipData.length;
        [zipData appendData:localHeader];
        [zipData appendData:fileData];
        
        // Запись центрального каталога
        NSMutableData *centralEntry = [NSMutableData data];
        uint32_t centralSig = 0x02014b50; [centralEntry appendBytes:&centralSig length:4];
        uint16_t verMade = 0x0A; [centralEntry appendBytes:&verMade length:2];
        uint16_t verNeed = 0x0A; [centralEntry appendBytes:&verNeed length:2];
        uint16_t flags2 = 0; [centralEntry appendBytes:&flags2 length:2];
        uint16_t compression2 = 0; [centralEntry appendBytes:&compression2 length:2];
        [centralEntry appendBytes:&time length:4];
        [centralEntry appendBytes:&date length:4];
        [centralEntry appendBytes:&crc length:4];
        [centralEntry appendBytes:&compressedSize length:4];
        [centralEntry appendBytes:&uncompressedSize length:4];
        [centralEntry appendBytes:&fnLen length:2];
        uint16_t extraLen2 = 0; [centralEntry appendBytes:&extraLen2 length:2];
        uint16_t commentLen = 0; [centralEntry appendBytes:&commentLen length:2];
        uint16_t diskNum = 0; [centralEntry appendBytes:&diskNum length:2];
        uint16_t internalAttr = 0; [centralEntry appendBytes:&internalAttr length:2];
        uint32_t externalAttr = 0; [centralEntry appendBytes:&externalAttr length:4];
        [centralEntry appendBytes:&localOffset length:4];
        [centralEntry appendData:fileNameData];
        
        [centralDirEntries addObject:centralEntry];
    }
    
    centralDirStart = (uint32_t)zipData.length;
    
    for (NSData *entry in centralDirEntries) {
        [zipData appendData:entry];
    }
    
    // Конец центрального каталога
    NSMutableData *endOfCentral = [NSMutableData data];
    uint32_t endSig = 0x06054b50; [endOfCentral appendBytes:&endSig length:4];
    uint16_t diskNum2 = 0; [endOfCentral appendBytes:&diskNum2 length:2];
    uint16_t centralDisk = 0; [endOfCentral appendBytes:&centralDisk length:2];
    uint16_t entriesOnDisk = (uint16_t)centralDirEntries.count; [endOfCentral appendBytes:&entriesOnDisk length:2];
    uint16_t totalEntries = (uint16_t)centralDirEntries.count; [endOfCentral appendBytes:&totalEntries length:2];
    uint32_t centralSize = (uint32_t)(zipData.length - centralDirStart); [endOfCentral appendBytes:&centralSize length:4];
    uint32_t centralOffset = centralDirStart; [endOfCentral appendBytes:&centralOffset length:4];
    uint16_t zipCommentLen = 0; [endOfCentral appendBytes:&zipCommentLen length:2];
    
    [zipData appendData:endOfCentral];
    
    [zipData writeToFile:destPath atomically:YES];
    write_log(@"✅ ZIP repacked: %lu bytes", (unsigned long)zipData.length);
}

static void find_and_patch_zip(void) {
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
            write_log(@"📦 Found ZIP: %@", fullPath);
            
            // Бэкап
            NSString *backupPath = [fullPath stringByAppendingString:@".original"];
            if (![fm fileExistsAtPath:backupPath]) {
                NSData *origData = [NSData dataWithContentsOfFile:fullPath];
                [origData writeToFile:backupPath atomically:YES];
                write_log(@"💾 Backup: %@", backupPath.lastPathComponent);
            }
            
            // Временная папка для распаковки
            NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"br_anim_patch"];
            [fm removeItemAtPath:tempDir error:nil];
            
            // Распаковываем
            unzip_file(fullPath, tempDir);
            
            if (isPatched) {
                // Запаковываем обратно
                zip_folder(tempDir, fullPath);
                write_log(@"✅ ZIP patched!");
            }
            
            [fm removeItemAtPath:tempDir error:nil];
            return;
        }
    }
    
    write_log(@"❌ br_anim.bpc not found!");
}

static void patch_all(void) {
    @autoreleasepool {
        if (isPatched) {
            write_log(@"ℹ️ Already patched, skipping...");
            return;
        }
        
        write_log(@"");
        write_log(@"╔═══════════════════════════════════════════════════════════════╗");
        write_log(@"║  🔥 NO RELOAD PATCHER v6.0 (10/10)                         ║");
        write_log(@"║  ✅ Extracts br_anim.bpc (ZIP)                              ║");
        write_log(@"║  ✅ Patches .ani files inside                               ║");
        write_log(@"║  ✅ Repacks ZIP                                             ║");
        write_log(@"╚═══════════════════════════════════════════════════════════════╝");
        write_log(@"");
        
        find_and_patch_zip();
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
