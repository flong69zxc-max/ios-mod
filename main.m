// ============================================================
// main.m - ФИНАЛЬНАЯ РАБОЧАЯ ВЕРСИЯ
// Используем стандартные Mach функции вместо deprecated
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <CommonCrypto/CommonCrypto.h>

// ============================================================
// КОНСТАНТЫ
// ============================================================

#define SERVER_URL @"https://evidebackendtesters.vercel.app/auth-module"
#define AUTH_KEY @"com.devicefingerprint.uniqueKey"
#define GAME_BINARY "blackrussia-client"
#define SCAN_SIZE 0x1400000
#define TARGET_VALUE1 0.15f
#define TARGET_VALUE2 0.2f
#define PATCH_OFFSET_STEP 0x20

// ============================================================
// ДАННЫЕ ДЛЯ ПАТЧА
// ============================================================

static const float NEW_HITBOXES[] = {
    2.0f, 2.5f, 3.0f, 3.5f, 4.0f, 
    4.5f, 5.0f, 5.5f, 6.0f, 6.5f
};

// ============================================================
// UIApplication EXTENSION
// ============================================================

@interface UIApplication (WindowExtensions)
+ (UIWindow *)getKeyWindow;
@end

@implementation UIApplication (WindowExtensions)

+ (UIWindow *)getKeyWindow {
    UIWindow *keyWindow = nil;
    
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && 
                scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
            }
        }
    }
    
    if (!keyWindow) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = UIApplication.sharedApplication.keyWindow;
        if (!keyWindow) {
            keyWindow = UIApplication.sharedApplication.windows.firstObject;
        }
        #pragma clang diagnostic pop
    }
    
    return keyWindow;
}

@end

// ============================================================
// МЕНЕДЖЕР УВЕДОМЛЕНИЙ
// ============================================================

@interface NotificationManager : NSObject
+ (void)showNotification:(NSString *)message color:(UIColor *)color;
+ (void)showNotification:(NSString *)message color:(UIColor *)color duration:(NSTimeInterval)duration;
@end

@implementation NotificationManager

+ (void)showNotification:(NSString *)message color:(UIColor *)color {
    [self showNotification:message color:color duration:2.0];
}

+ (void)showNotification:(NSString *)message color:(UIColor *)color duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = [UIApplication getKeyWindow];
        if (!keyWindow) return;
        
        CGFloat screenWidth = keyWindow.frame.size.width;
        CGFloat notificationWidth = screenWidth * 0.8;
        CGFloat notificationHeight = 50.0;
        CGFloat x = (screenWidth - notificationWidth) / 2.0;
        CGFloat y = -100.0;
        
        UIView *notificationView = [[UIView alloc] initWithFrame:CGRectMake(x, y, notificationWidth, notificationHeight)];
        notificationView.backgroundColor = [color colorWithAlphaComponent:0.9];
        notificationView.layer.cornerRadius = 15.0;
        notificationView.layer.shadowColor = [UIColor blackColor].CGColor;
        notificationView.layer.shadowOpacity = 0.3;
        notificationView.layer.shadowOffset = CGSizeMake(0, 4);
        notificationView.alpha = 0.0;
        
        UILabel *label = [[UILabel alloc] initWithFrame:notificationView.bounds];
        label.text = message;
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:16.0];
        label.numberOfLines = 2;
        [notificationView addSubview:label];
        
        [keyWindow addSubview:notificationView];
        
        [UIView animateWithDuration:0.3 
                              delay:0 
             usingSpringWithDamping:0.7 
              initialSpringVelocity:0.5 
                            options:UIViewAnimationOptionCurveEaseOut 
                         animations:^{
            CGRect frame = notificationView.frame;
            frame.origin.y = 15.0;
            notificationView.frame = frame;
            notificationView.alpha = 1.0;
        } completion:nil];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 
                                  delay:0 
                                options:UIViewAnimationOptionCurveEaseIn 
                             animations:^{
                CGRect frame = notificationView.frame;
                frame.origin.y = -100.0;
                notificationView.frame = frame;
                notificationView.alpha = 0.0;
            } completion:^(BOOL finished) {
                [notificationView removeFromSuperview];
            }];
        });
    });
}

@end

// ============================================================
// МЕНЕДЖЕР HWID
// ============================================================

@interface HWIDManager : NSObject
+ (NSString *)generateUniqueKey;
+ (NSString *)sysctlString:(const char *)name;
+ (NSString *)mgAnswer:(NSString *)key;
+ (NSString *)sha256Hex:(NSString *)input;
+ (void)keychainSave:(NSString *)value;
+ (NSString *)keychainLoad;
@end

@implementation HWIDManager

+ (NSString *)sysctlString:(const char *)name {
    size_t size = 0;
    sysctlbyname(name, NULL, &size, NULL, 0);
    if (size == 0) return nil;
    
    char *value = malloc(size);
    if (!value) return nil;
    
    sysctlbyname(name, value, &size, NULL, 0);
    NSString *result = [NSString stringWithCString:value encoding:NSUTF8StringEncoding];
    free(value);
    return result;
}

+ (NSString *)mgAnswer:(NSString *)key {
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!handle) return nil;
    
    id (*MGCopyAnswer)(CFStringRef) = dlsym(handle, "MGCopyAnswer");
    if (!MGCopyAnswer) {
        dlclose(handle);
        return nil;
    }
    
    id value = MGCopyAnswer((__bridge CFStringRef)key);
    dlclose(handle);
    
    if (!value) return nil;
    return [NSString stringWithFormat:@"%@", value];
}

+ (NSString *)sha256Hex:(NSString *)input {
    if (!input) return nil;
    
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", hash[i]];
    }
    
    return [output copy];
}

+ (void)keychainSave:(NSString *)value {
    if (!value) return;
    
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: AUTH_KEY,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    
    SecItemDelete((__bridge CFDictionaryRef)query);
    SecItemAdd((__bridge CFDictionaryRef)query, NULL);
}

+ (NSString *)keychainLoad {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: AUTH_KEY,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    
    if (status != errSecSuccess || !result) return nil;
    
    NSData *data = (__bridge NSData *)result;
    CFRelease(result);
    
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (NSString *)generateUniqueKey {
    NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionary];
    
    NSArray *mgKeys = @[
        @"UniqueChipID", @"BoardId", 
        @"SerialNumber", @"DeviceClass", 
        @"ProductType"
    ];
    
    for (NSString *key in mgKeys) {
        NSString *value = [self mgAnswer:key];
        if (value) {
            deviceInfo[key] = value;
        }
    }
    
    NSArray *sysctlKeys = @[@"hw.machine", @"hw.model"];
    for (NSString *key in sysctlKeys) {
        NSString *value = [self sysctlString:key.UTF8String];
        if (value) {
            deviceInfo[key] = value;
        }
    }
    
    NSUInteger processorCount = [NSProcessInfo processInfo].processorCount;
    deviceInfo[@"cpu.count"] = [NSString stringWithFormat:@"%lu", (unsigned long)processorCount];
    
    NSArray *sortedKeys = [deviceInfo.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *components = [NSMutableArray array];
    
    for (NSString *key in sortedKeys) {
        NSString *value = deviceInfo[key];
        [components addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    
    NSString *rawString = [components componentsJoinedByString:@"|"];
    NSString *hash = [self sha256Hex:rawString];
    
    if (!hash) return nil;
    
    NSString *savedKey = [self keychainLoad];
    if (!savedKey) {
        [self keychainSave:hash];
        return hash;
    }
    
    if (![savedKey isEqualToString:hash]) {
        [self keychainSave:hash];
        return hash;
    }
    
    return savedKey;
}

@end

// ============================================================
// KittyMemory - РАБОТА С ПАМЯТЬЮ (ИСПРАВЛЕННАЯ ВЕРСИЯ)
// ============================================================

@interface KittyMemory : NSObject
+ (unsigned long long)getAbsoluteAddress:(const char *)name offset:(unsigned long long)offset;
+ (BOOL)memRead:(void *)address buffer:(void *)buffer size:(size_t)size;
+ (BOOL)memWrite:(void *)address bytes:(void *)bytes size:(size_t)size;
@end

@implementation KittyMemory

+ (unsigned long long)getAbsoluteAddress:(const char *)name offset:(unsigned long long)offset {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (imageName && strstr(imageName, name)) {
            const struct mach_header *header = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            return (unsigned long long)header + slide + offset;
        }
    }
    return 0;
}

+ (BOOL)memRead:(void *)address buffer:(void *)buffer size:(size_t)size {
    if (!address || !buffer || size == 0) return NO;
    
    vm_size_t readSize = 0;
    kern_return_t kr = vm_read_overwrite(
        mach_task_self(),
        (vm_address_t)address,
        size,
        (vm_address_t)buffer,
        &readSize
    );
    
    return (kr == KERN_SUCCESS && readSize == size);
}

+ (BOOL)memWrite:(void *)address bytes:(void *)bytes size:(size_t)size {
    if (!address || !bytes || size == 0) return NO;
    
    task_t task = mach_task_self();
    
    // Получаем информацию о странице через vm_region
    vm_address_t addr = (vm_address_t)address;
    vm_size_t pageSize = 0;
    natural_t depth = 0x1000;
    struct vm_region_submap_short_info_64 info;
    mach_msg_type_number_t infoCnt = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    
    kern_return_t kr = vm_region_recurse_64(
        task,
        &addr,
        &pageSize,
        &depth,
        (vm_region_recurse_info_t)&info,
        &infoCnt
    );
    
    if (kr != KERN_SUCCESS) return NO;
    
    // Вычисляем начало страницы
    long pageSizeSys = sysconf(_SC_PAGESIZE);
    vm_address_t pageStart = (vm_address_t)address & ~(pageSizeSys - 1);
    vm_size_t pageSizeAligned = ((vm_address_t)address + size + pageSizeSys - 1) & ~(pageSizeSys - 1) - pageStart;
    
    // Меняем защиту если нужно
    if (!(info.protection & VM_PROT_WRITE)) {
        kr = vm_protect(task, pageStart, pageSizeAligned, 0, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) return NO;
        
        kr = vm_write(task, (vm_address_t)address, (vm_offset_t)bytes, (mach_msg_type_number_t)size);
        if (kr != KERN_SUCCESS) {
            vm_protect(task, pageStart, pageSizeAligned, 0, info.protection);
            return NO;
        }
        
        vm_protect(task, pageStart, pageSizeAligned, 0, info.protection);
    } else {
        kr = vm_write(task, (vm_address_t)address, (vm_offset_t)bytes, (mach_msg_type_number_t)size);
        if (kr != KERN_SUCCESS) return NO;
    }
    
    // Очистка кэша
    sys_icache_invalidate((void *)pageStart, pageSizeAligned);
    
    return YES;
}

@end

// ============================================================
// KittyScanner - ПОИСК В ПАМЯТИ
// ============================================================

@interface KittyScanner : NSObject
+ (unsigned long long)scanForFloat:(float)value atOffset:(unsigned long long)offset inLibrary:(const char *)libraryName;
@end

@implementation KittyScanner

+ (unsigned long long)scanForFloat:(float)value atOffset:(unsigned long long)offset inLibrary:(const char *)libraryName {
    unsigned long long baseAddress = [KittyMemory getAbsoluteAddress:libraryName offset:0];
    if (!baseAddress) return 0;
    
    float readValue = 0.0f;
    unsigned long long currentAddress = baseAddress + offset;
    unsigned long long endAddress = baseAddress + SCAN_SIZE;
    
    while (currentAddress < endAddress) {
        if ([KittyMemory memRead:(void *)currentAddress buffer:&readValue size:sizeof(float)]) {
            if (readValue == TARGET_VALUE1) {
                float secondValue = 0.0f;
                unsigned long long secondAddress = currentAddress + 0x20;
                if ([KittyMemory memRead:(void *)secondAddress buffer:&secondValue size:sizeof(float)]) {
                    if (secondValue == TARGET_VALUE2) {
                        return currentAddress;
                    }
                }
            }
        }
        currentAddress += 4;
    }
    
    return 0;
}

@end

// ============================================================
// ОСНОВНАЯ ЛОГИКА
// ============================================================

@interface HitboxEngine : NSObject
+ (void)performAuthentication;
+ (void)startMemoryScan;
+ (void)applyPatchAtOffset:(unsigned long long)offset;
+ (void)runAutoPatch;
@end

@implementation HitboxEngine

+ (void)runAutoPatch {
    [NotificationManager showNotification:@"🔍 Starting scan..." 
                                    color:[UIColor darkGrayColor] 
                                 duration:1.5];
    [self startMemoryScan];
}

+ (void)applyPatchAtOffset:(unsigned long long)offset {
    unsigned long long baseAddress = [KittyMemory getAbsoluteAddress:GAME_BINARY offset:0];
    if (!baseAddress) {
        [NotificationManager showNotification:@"❌ Failed to find game" 
                                        color:[UIColor systemRedColor]];
        return;
    }
    
    unsigned long long targetAddress = baseAddress + offset;
    
    for (int i = 0; i < 10; i++) {
        void *address = (void *)(targetAddress + (unsigned long long)i * PATCH_OFFSET_STEP);
        float value = NEW_HITBOXES[i];
        
        if ([KittyMemory memWrite:address bytes:&value size:sizeof(float)]) {
            NSLog(@"[+] Applied patch at %p: %f", address, value);
        }
    }
    
    [NotificationManager showNotification:@"✅ Hitbox mod activated!" 
                                    color:[UIColor systemGreenColor] 
                                 duration:3.0];
}

+ (void)startMemoryScan {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NotificationManager showNotification:@"🔍 Scanning memory..." 
                                        color:[UIColor darkGrayColor] 
                                     duration:1.0];
        
        unsigned long long foundAddress = [KittyScanner scanForFloat:TARGET_VALUE1 
                                                             atOffset:0 
                                                            inLibrary:GAME_BINARY];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (foundAddress != 0) {
                NSLog(@"[+] Found target at: 0x%llx", foundAddress);
                [NotificationManager showNotification:@"🎯 Target found!" 
                                                color:[UIColor systemGreenColor] 
                                             duration:1.0];
                
                unsigned long long offset = foundAddress - [KittyMemory getAbsoluteAddress:GAME_BINARY offset:0];
                [self applyPatchAtOffset:offset];
            } else {
                NSLog(@"[-] Target not found");
                [NotificationManager showNotification:@"❌ Target not found" 
                                                color:[UIColor systemRedColor] 
                                             duration:2.0];
            }
        });
    });
}

+ (void)performAuthentication {
    NSString *uniqueKey = [HWIDManager generateUniqueKey];
    
    if (!uniqueKey) {
        [NotificationManager showNotification:@"❌ Failed to generate key" 
                                        color:[UIColor systemRedColor]];
        return;
    }
    
    [NotificationManager showNotification:@"🔑 Authenticating..." 
                                    color:[UIColor systemBlueColor] 
                                 duration:2.0];
    
    NSURL *url = [NSURL URLWithString:SERVER_URL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setTimeoutInterval:30.0];
    
    NSDictionary *body = @{@"uniqueKey": uniqueKey};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setHTTPBody:jsonData];
    
    [[NSURLSession.sharedSession dataTaskWithRequest:request 
                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                [NotificationManager showNotification:@"❌ Auth failed!" 
                                                color:[UIColor systemRedColor] 
                                             duration:2.0];
                return;
            }
            
            NSError *jsonError = nil;
            NSDictionary *responseDict = [NSJSONSerialization JSONObjectWithData:data 
                                                                         options:0 
                                                                           error:&jsonError];
            
            BOOL success = NO;
            
            if (!jsonError && responseDict) {
                success = [responseDict[@"success"] boolValue];
            }
            
            if (!success) {
                NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([responseString containsString:@"success"] && 
                    [responseString containsString:@"true"]) {
                    success = YES;
                }
            }
            
            if (success) {
                [NotificationManager showNotification:@"✅ Authenticated!" 
                                                color:[UIColor systemGreenColor] 
                                             duration:1.5];
                [self runAutoPatch];
            } else {
                [NotificationManager showNotification:@"❌ Invalid license!" 
                                                color:[UIColor systemRedColor] 
                                             duration:2.0];
            }
        });
    }] resume];
}

@end

// ============================================================
// ТОЧКА ВХОДА
// ============================================================

__attribute__((constructor))
static void initialize() {
    NSLog(@"[+] Hitbox Mod loaded!");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), 
                  dispatch_get_main_queue(), ^{
        [HitboxEngine performAuthentication];
    });
}

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, nil);
    }
}

// ============================================================
// КОНЕЦ ФАЙЛА
// ============================================================
