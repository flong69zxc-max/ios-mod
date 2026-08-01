// norelpatch.mm - v12.0 (Memory patch, no filesystem access)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <dlfcn.h>

static bool isPatched = NO;

static void write_log(NSString *msg) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *logPath = [[paths firstObject] stringByAppendingPathComponent:@"saves/NoReload.log"];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"%@", msg);
}

// Хук на NSData чтение файлов
static NSData* (*orig_dataWithContentsOfFile)(id self, SEL _cmd, NSString *path);

static NSData* hooked_dataWithContentsOfFile(id self, SEL _cmd, NSString *path) {
    NSData *data = orig_dataWithContentsOfFile(self, _cmd, path);
    
    if (!data) return data;
    if (![path hasSuffix:@".ani"]) return data;
    
    // Проверяем что это не бэкап
    if ([path hasSuffix:@".original"]) return data;
    
    write_log([NSString stringWithFormat:@"📁 Intercepted: %@", path.lastPathComponent]);
    
    // Патчим в памяти
    NSMutableData *patched = [data mutableCopy];
    int modified = 0;
    
    NSArray *search = @[@"python_reload", @"python_crouchreload", @"shotgun_reload", @"shotgun_crouchreload"];
    NSArray *replace = @[@"python_idle", @"python_crouchidle", @"shotgun_idle", @"shotgun_crouchidle"];
    
    for (int i = 0; i < search.count; i++) {
        NSData *searchData = [search[i] dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [data rangeOfData:searchData options:0 range:NSMakeRange(0, data.length)];
        
        if (range.location != NSNotFound) {
            NSData *replaceData = [replace[i] dataUsingEncoding:NSUTF8StringEncoding];
            [patched replaceBytesInRange:range withBytes:replaceData.bytes length:replaceData.length];
            write_log([NSString stringWithFormat:@"  ✅ Patched: %@ → %@", search[i], replace[i]]);
            modified++;
        }
    }
    
    if (modified > 0) {
        write_log([NSString stringWithFormat:@"✅ %@ patched in memory", path.lastPathComponent]);
        return patched;
    }
    
    return data;
}

static void init_hook(void) {
    // Хукинг NSData
    Method originalMethod = class_getClassMethod([NSData class], @selector(dataWithContentsOfFile:));
    Method hookedMethod = class_getClassMethod([NSData class], @selector(hooked_dataWithContentsOfFile:));
    
    if (originalMethod && hookedMethod) {
        method_exchangeImplementations(originalMethod, hookedMethod);
        write_log(@"✅ NSData hook installed");
        isPatched = YES;
    } else {
        write_log(@"❌ Hook failed");
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try {
            init_hook();
        } @catch (NSException *e) {
            write_log([NSString stringWithFormat:@"❌ Error: %@", e]);
        }
    });
}

extern "C" void __dummy_export(void) {}
