// norelpatch.mm - Remove reload animations

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static void write_log(NSString *msg) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libPath = [paths firstObject];
        NSString *logPath = [[libPath stringByAppendingPathComponent:@"Caches"] stringByAppendingPathComponent:@"NoReload.log"];
        
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"%@", entry);
    }
}

static void patch_anim_file(NSString *filePath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:filePath]) {
        write_log([NSString stringWithFormat:@"❌ Not found: %@", filePath]);
        return;
    }
    
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        write_log([NSString stringWithFormat:@"❌ Can't read: %@", filePath]);
        return;
    }
    
    write_log([NSString stringWithFormat:@"📁 %@ (%lu bytes)", filePath.lastPathComponent, data.length]);
    
    // Ищем все строки с reload
    NSArray *searchStrings = @[
        @"python_reload",
        @"python_crouchreload",
        @"shotgun_reload",
        @"shotgun_crouchreload"
    ];
    
    NSMutableData *newData = [data mutableCopy];
    int patched = 0;
    
    for (NSString *search in searchStrings) {
        NSData *searchData = [search dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [data rangeOfData:searchData options:0 range:NSMakeRange(0, data.length)];
        
        if (range.location != NSNotFound) {
            // Заменяем на ту же строку + "1" или на "idle"
            // Лучше заменить на пустоту или на несуществующую анимацию
            uint8_t zeros[64] = {0};
            NSData *replaceData = [NSData dataWithBytes:zeros length:searchData.length];
            [newData replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            
            write_log([NSString stringWithFormat:@"  ✅ Patched '%@' at offset 0x%lx", search, range.location]);
            patched++;
        } else {
            write_log([NSString stringWithFormat:@"  ⚠️ '%@' not found", search]);
        }
    }
    
    if (patched > 0) {
        NSError *error = nil;
        [newData writeToFile:filePath options:NSDataWritingAtomic error:&error];
        if (error) {
            write_log([NSString stringWithFormat:@"  ❌ Write error: %@", error]);
        } else {
            write_log([NSString stringWithFormat:@"  ✅ %d patches applied", patched]);
        }
    } else {
        write_log(@"  ⚠️ Nothing to patch");
    }
}

static void patch_all(void) {
    @autoreleasepool {
        write_log(@"");
        write_log(@"=== NO RELOAD PATCHER ===");
        
        // Путь: Library/Application Support/files/mesh/br_anim.bpc/
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *libPath = [paths firstObject];
        NSString *meshPath = [[[libPath stringByAppendingPathComponent:@"Application Support"] 
                               stringByAppendingPathComponent:@"files"] 
                              stringByAppendingPathComponent:@"mesh/br_anim.bpc"];
        
        write_log([NSString stringWithFormat:@"📂 Path: %@", meshPath]);
        
        NSArray *files = @[
            [meshPath stringByAppendingPathComponent:@"python.ani"],
            [meshPath stringByAppendingPathComponent:@"shotgun.ani"]
        ];
        
        for (NSString *filePath in files) {
            patch_anim_file(filePath);
        }
        
        write_log(@"=== DONE ===");
        write_log(@"");
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            patch_all();
        } @catch (NSException *e) {
            write_log([NSString stringWithFormat:@"❌ Error: %@", e]);
        }
    });
}

extern "C" void __dummy_export(void) {}
