#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Показать UIAlert (если доступен UI)
static void showAlertIfPossible(void) {
    // Попытка получить активное окно (iOS 13+ и старые версии)
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                targetWindow = ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        targetWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }

    if (targetWindow && targetWindow.rootViewController) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"📢 Библиотека загружена"
                                                                       message:@"main.dylib успешно внедрена в процесс!"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [targetWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    } else {
        NSLog(@"ℹ️ UI не готов, уведомление выведено только в консоль.");
    }
}

// Конструктор – вызывается при загрузке dylib
__attribute__((constructor))
static void onLibraryLoad(void) {
    NSLog(@"🚀 main.dylib успешно загружена!");

    // Показываем UI-уведомление на главном потоке, когда приложение активно
    if (UIApplication.sharedApplication) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                showAlertIfPossible();
            } else {
                // Ждём активации приложения
                id observer = [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil
                                 queue:NSOperationQueue.mainQueue
                            usingBlock:^(NSNotification * _Nonnull note) {
                    showAlertIfPossible();
                    [[NSNotificationCenter defaultCenter] removeObserver:observer];
                }];
            }
        });
    } else {
        // Нет UIApplication (например, daemon) – только лог
        NSLog(@"ℹ️ UIApplication недоступен, только консольное уведомление.");
    }
}
