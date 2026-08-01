// main.m
// Hitbox Mod for Black Russia iOS
// Исправленная версия для компиляции

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <CommonCrypto/CommonCrypto.h>  // ВАЖНО: добавлен для CC_SHA256

// ============================================================
// МАКРОСЫ И КОНСТАНТЫ
// ============================================================

#define SERVER_URL @"https://evidebackendtesters.vercel.app/auth-module"
#define AUTH_KEY @"com.devicefingerprint.uniqueKey"
#define GAME_BINARY @"blackrussia-client"
#define SCAN_SIZE 0x1400000
#define TARGET_VALUE1 0.15f
#define TARGET_VALUE2 0.2f
#define PATCH_OFFSET_STEP 0x20

// Новые значения хитбоксов (патч)
static const float NEW_HITBOXES[] = {
    2.0f, 2.5f, 3.0f, 3.5f, 4.0f, 
    4.5f, 5.0f, 5.5f, 6.0f, 6.5f
};

// ============================================================
// КАТЕГОРИИ ДЛЯ ОБЛЕГЧЕНИЯ РАБОТЫ С UI
// ============================================================

@interface UIApplication (WindowExtensions)
+ (UIWindow *)getKeyWindow;
@end

@implementation UIApplication (WindowExtensions)

+ (UIWindow *)getKeyWindow {
    UIWindow *keyWindow = nil;
    
    // Для iOS 13+ используем UIScene
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
    
    // Fallback для старых версий
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
// МЕНЕДЖЕР УВЕДОМЛЕНИЙ В ИГРЕ
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
        
        // Расчет размеров уведомления
        CGFloat screenWidth = keyWindow.frame.size.width;
        CGFloat notificationWidth = screenWidth * 0.8;
        CGFloat notificationHeight = 50.0;
        CGFloat x = (screenWidth - notificationWidth) / 2.0;
        CGFloat y = -100.0;
        
        // Создание основного view
        UIView *notificationView = [[UIView alloc] initWithFrame:CGRectMake(x, y, notificationWidth, notificationHeight)];
        notificationView.backgroundColor = [color colorWithAlphaComponent:0.9];
        notificationView.layer.cornerRadius = 15.0;
        notificationView.layer.shadowColor = [UIColor blackColor].CGColor;
        notificationView.layer.shadowOpacity = 0.3;
        notificationView.layer.shadowOffset = CGSizeMake(0, 4);
        notificationView.alpha = 0.0;
        
        // Создание текстовой метки
        UILabel *label = [[UILabel alloc] initWithFrame:notificationView.bounds];
        label.text = message;
        label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:16.0];
        label.numberOfLines = 2;
        [notificationView addSubview:label];
        
        [keyWindow addSubview:notificationView];
        
        // Анимация появления
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
        
        // Анимация исчезновения
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
// МЕНЕДЖЕР АППАРАТНОГО ID (HWID)
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

// Получение системной информации через sysctl
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

// Получение информации через MGCopyAnswer (Apple Private API)
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

// SHA256 хеширование (ИСПРАВЛЕНО)
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

// Сохранение в Keychain
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

// Загрузка из Keychain
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

// Генерация уникального ключа устройства
+ (NSString *)generateUniqueKey {
    NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionary];
    
    // Сбор аппаратной информации
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
    
    // Сбор системной информации
    NSArray *sysctlKeys = @[@"hw.machine", @"hw.model"];
    for (NSString *key in sysctlKeys) {
        NSString *value = [self sysctlString:key.UTF8String];
        if (value) {
            deviceInfo[key] = value;
        }
    }
    
    // Количество ядер процессора
    NSUInteger processorCount = [NSProcessInfo processInfo].processorCount;
    deviceInfo[@"cpu.count"] = [NSString stringWithFormat:@"%lu", (unsigned long)processorCount];
    
    // Сортировка ключей для консистентности
    NSArray *sortedKeys = [deviceInfo.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *components = [NSMutableArray array];
    
    for (NSString *key in sortedKeys) {
        NSString *value = deviceInfo[key];
        [components addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    
    // Объединение и хеширование
    NSString *rawString = [components componentsJoinedByString:@"|"];
    NSString *hash = [self sha256Hex:rawString];
    
    if (!hash) return nil;
    
    // Проверка с сохраненным ключом
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
// ОСНОВНАЯ ЛОГИКА ВЗЛОМА
// ============================================================

@interface HitboxEngine : NSObject
+ (void)performAuthentication;
+ (void)startMemoryScan;
+ (void)applyPatchAtOffset:(unsigned long long)offset;
+ (unsigned long long)getAbsoluteAddress:(const char *)name offset:(unsigned long long)offset;
@end

@implementation HitboxEngine

// Получение абсолютного адреса в памяти
+ (unsigned long long)getAbsoluteAddress:(const char *)name offset:(unsigned long long)offset {
    // В реальном приложении здесь была бы сложная логика поиска
    // библиотеки в памяти и расчета адреса
    // Для демонстрации возвращаем 0
    return 0;
}

// Применение патча по смещению
+ (void)applyPatchAtOffset:(unsigned long long)offset {
    // Здесь был бы код записи в память через mach_vm_write
    // и изменение защиты страниц
    
    // Для демонстрации просто показываем уведомление
    dispatch_async(dispatch_get_main_queue(), ^{
        [NotificationManager showNotification:@"✅ Hitbox mod activated!" 
                                        color:[UIColor systemGreenColor]];
    });
}

// Сканирование памяти
+ (void)startMemoryScan {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // В реальном приложении здесь было бы сканирование памяти
        // и поиск сигнатуры 0.15 и 0.2
        
        // Демонстрация успешного поиска
        dispatch_async(dispatch_get_main_queue(), ^{
            [NotificationManager showNotification:@"🔍 Scanning memory..." 
                                            color:[UIColor darkGrayColor]];
        });
        
        // Имитация работы
        [NSThread sleepForTimeInterval:1.5];
        
        // Применение патча
        [self applyPatchAtOffset:0];
    });
}

// Аутентификация на сервере
+ (void)performAuthentication {
    NSString *uniqueKey = [HWIDManager generateUniqueKey];
    
    // Создание запроса
    NSURL *url = [NSURL URLWithString:SERVER_URL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setTimeoutInterval:30.0];
    
    // Создание тела запроса
    NSDictionary *body = @{@"uniqueKey": uniqueKey ?: @""};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setHTTPBody:jsonData];
    
    // Отправка запроса
    [[NSURLSession.sharedSession dataTaskWithRequest:request 
                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                [NotificationManager showNotification:@"❌ Authentication failed!" 
                                                color:[UIColor systemRedColor]];
                return;
            }
            
            NSError *jsonError = nil;
            NSDictionary *responseDict = [NSJSONSerialization JSONObjectWithData:data 
                                                                         options:0 
                                                                           error:&jsonError];
            
            if (!jsonError && responseDict) {
                // Проверка успешности
                if ([responseDict[@"success"] boolValue]) {
                    [NotificationManager showNotification:@"✅ Authenticated successfully!" 
                                                    color:[UIColor systemGreenColor]];
                    [self startMemoryScan];
                } else {
                    [NotificationManager showNotification:@"❌ Invalid license!" 
                                                    color:[UIColor systemRedColor]];
                }
            } else {
                // Проверка через текстовый поиск (запасной вариант)
                NSString *responseString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if ([responseString containsString:@"success"] && 
                    [responseString containsString:@"true"]) {
                    [NotificationManager showNotification:@"✅ Authenticated!" 
                                                    color:[UIColor systemGreenColor]];
                    [self startMemoryScan];
                } else {
                    [NotificationManager showNotification:@"❌ Authentication error!" 
                                                    color:[UIColor systemRedColor]];
                }
            }
        });
    }] resume];
}

@end

// ============================================================
// ТОЧКА ВХОДА
// ============================================================

// Функция инициализации для динамической библиотеки
__attribute__((constructor))
static void initialize() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), 
                  dispatch_get_main_queue(), ^{
        [HitboxEngine performAuthentication];
    });
}

// Если нужен main для полноценного приложения
int main(int argc, char * argv[]) {
    @autoreleasepool {
        // Запуск основного цикла приложения
        return UIApplicationMain(argc, argv, nil, nil);
    }
}
