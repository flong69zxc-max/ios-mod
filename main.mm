// main.mm - Black Russia Hitbox Modifier
// Компиляция: clang++ -arch arm64 -std=c++17 -O2 -fobjc-arc -dynamiclib -framework UIKit -framework Metal -framework MetalKit -framework Foundation -framework CoreGraphics -framework QuartzCore -I./imgui -I./imgui/backends main.mm -o blackrussia_hitbox.dylib

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <objc/runtime.h>

// ImGui
#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// MARK: - Конфигурация
// ============================================================================

#define HITBOX_COUNT 10
#define HITBOX_STRIDE 0x20
#define CACHE_FILE "br_cache.dat"
#define SEARCH_TIMEOUT 30.0

// Стоковые значения
static const float DEFAULT_HITBOXES[HITBOX_COUNT] = {
    0.15f, 0.20f, 0.25f, 0.25f, 0.16f, 0.16f, 0.20f, 0.20f, 0.15f, 0.15f
};

// Части тела
static const char* BODY_PART_NAMES[HITBOX_COUNT] = {
    "HEAD", "TORSO_1", "TORSO_2", "TORSO_3", 
    "L_ARM_UP", "L_ARM_LOW", "R_ARM_UP", "R_ARM_LOW",
    "L_LEG", "R_LEG"
};

// ============================================================================
// MARK: - Глобальные переменные
// ============================================================================

static float* g_hitboxAddress = NULL;
static float g_currentValues[HITBOX_COUNT];
static float g_originalValues[HITBOX_COUNT];
static bool g_menuVisible = false;
static bool g_initialized = false;
static float g_globalMultiplier = 1.0f;
static UIWindow* g_overlayWindow = nil;
static UIButton* g_floatButton = nil;
static dispatch_queue_t g_mainQueue = dispatch_get_main_queue();

// ============================================================================
// MARK: - Менеджер памяти
// ============================================================================

@interface MemoryManager : NSObject
+ (bool)writeFloatArray:(float*)data atAddress:(void*)address count:(size_t)count;
+ (bool)validateAddress:(void*)address;
+ (void*)findHitboxAddress;
@end

@implementation MemoryManager

+ (bool)writeFloatArray:(float*)data atAddress:(void*)address count:(size_t)count {
    if (!address || !data || count == 0) return false;
    
    size_t size = count * sizeof(float);
    vm_address_t pageStart = (vm_address_t)address & ~(vm_page_size - 1);
    vm_size_t pageSize = size + ((vm_address_t)address - pageStart);
    
    // Снимаем защиту
    kern_return_t kr = vm_protect(mach_task_self(), pageStart, pageSize, 0, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[BR] Не удалось снять защиту: %d", kr);
        return false;
    }
    
    // Записываем данные
    memcpy(address, data, size);
    
    // Возвращаем защиту
    kr = vm_protect(mach_task_self(), pageStart, pageSize, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[BR] Не удалось вернуть защиту: %d", kr);
    }
    
    return true;
}

+ (bool)validateAddress:(void*)address {
    if (!address) return false;
    
    float test[2];
    memcpy(test, address, sizeof(float) * 2);
    
    // Проверяем первое значение
    if (fabs(test[0] - DEFAULT_HITBOXES[0]) > 0.01f) return false;
    
    // Проверяем второе значение через stride
    float* second = (float*)((uintptr_t)address + HITBOX_STRIDE);
    memcpy(&test[1], second, sizeof(float));
    if (fabs(test[1] - DEFAULT_HITBOXES[1]) > 0.01f) return false;
    
    return true;
}

+ (bool)scanRegion:(const struct mach_header_64*)header size:(size_t)size address:(void**)outAddress {
    uintptr_t start = (uintptr_t)header;
    uintptr_t end = start + size;
    
    // Сканируем с шагом 4 байта
    for (uintptr_t addr = start; addr < end - (HITBOX_COUNT * HITBOX_STRIDE); addr += 4) {
        float* current = (float*)addr;
        
        // Проверяем сигнатуру
        bool found = true;
        for (int i = 0; i < HITBOX_COUNT; i++) {
            float* checkAddr = (float*)(addr + i * HITBOX_STRIDE);
            if (fabs(*checkAddr - DEFAULT_HITBOXES[i]) > 0.01f) {
                found = false;
                break;
            }
        }
        
        if (found) {
            // Дополнительная проверка: HEAD < TORSO
            float* head = (float*)addr;
            float* torso1 = (float*)(addr + HITBOX_STRIDE);
            float* torso2 = (float*)(addr + 2 * HITBOX_STRIDE);
            
            if (*head < *torso1 && *torso1 <= *torso2) {
                *outAddress = (void*)addr;
                return true;
            }
        }
    }
    
    return false;
}

+ (void*)findHitboxAddress {
    // Проверяем кэш
    void* cached = [self loadCache];
    if (cached && [self validateAddress:cached]) {
        NSLog(@"[BR] Загружен адрес из кэша: %p", cached);
        return cached;
    }
    
    NSLog(@"[BR] Начинаем поиск адреса...");
    
    // Ищем библиотеку
    void* address = NULL;
    uint32_t imageCount = _dyld_image_count();
    
    for (uint32_t i = 0; i < imageCount; i++) {
        const char* name = _dyld_get_image_name(i);
        if (!name) continue;
        
        NSString* path = [NSString stringWithUTF8String:name];
        if ([path containsString:@"blackrussia-client"]) {
            const struct mach_header_64* header = (const struct mach_header_64*)_dyld_get_image_header(i);
            if (!header) continue;
            
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            
            // Сканируем сегменты
            uintptr_t cmdPtr = (uintptr_t)header + sizeof(struct mach_header_64);
            for (uint32_t j = 0; j < header->ncmds; j++) {
                struct load_command* cmd = (struct load_command*)cmdPtr;
                
                if (cmd->cmd == LC_SEGMENT_64) {
                    struct segment_command_64* seg = (struct segment_command_64*)cmd;
                    
                    // Сканируем только загруженные сегменты
                    if (seg->fileoff != 0) {
                        void* segAddr = (void*)(seg->vmaddr + slide);
                        if ([self scanRegion:(const struct mach_header_64*)segAddr 
                                         size:seg->vmsize 
                                     address:&address]) {
                            [self saveCache:address];
                            return address;
                        }
                    }
                }
                
                cmdPtr += cmd->cmdsize;
            }
        }
    }
    
    return NULL;
}

+ (void)saveCache:(void*)address {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    
    NSString* cachePath = [[paths firstObject] stringByAppendingPathComponent:@CACHE_FILE];
    uintptr_t addr = (uintptr_t)address;
    NSData* data = [NSData dataWithBytes:&addr length:sizeof(addr)];
    [data writeToFile:cachePath atomically:YES];
}

+ (void*)loadCache {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return NULL;
    
    NSString* cachePath = [[paths firstObject] stringByAppendingPathComponent:@CACHE_FILE];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cachePath]) return NULL;
    
    NSData* data = [NSData dataWithContentsOfFile:cachePath];
    if (data.length != sizeof(uintptr_t)) return NULL;
    
    uintptr_t addr;
    [data getBytes:&addr length:sizeof(addr)];
    return (void*)addr;
}

@end

// ============================================================================
// MARK: - ImGui Metal Backend
// ============================================================================

@interface MetalRenderer : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) CAMetalLayer* metalLayer;
@property (nonatomic, strong) UIWindow* window;
@property (nonatomic, strong) CADisplayLink* displayLink;
@end

@implementation MetalRenderer {
    ImGui_ImplMetal_Data* _imguiMetalData;
    MTLRenderPassDescriptor* _renderPassDescriptor;
    id<MTLTexture> _depthTexture;
}

- (instancetype)initWithWindow:(UIWindow*)window {
    self = [super init];
    if (self) {
        _window = window;
        [self setupMetal];
        [self setupImGui];
    }
    return self;
}

- (void)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];
    
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.drawableSize = _window.bounds.size;
    _metalLayer.frame = _window.bounds;
    
    _window.layer = _metalLayer;
    _window.layer.opaque = NO;
    
    _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderLoop)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)setupImGui {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2(_window.bounds.size.width, _window.bounds.size.height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    
    // iOS стиль
    ImGuiStyle& style = ImGui::GetStyle();
    style.Colors[ImGuiCol_WindowBg] = ImVec4(0.1f, 0.1f, 0.15f, 0.95f);
    style.Colors[ImGuiCol_TitleBg] = ImVec4(0.2f, 0.2f, 0.3f, 1.0f);
    style.Colors[ImGuiCol_TitleBgActive] = ImVec4(0.3f, 0.3f, 0.4f, 1.0f);
    style.Colors[ImGuiCol_Button] = ImVec4(0.2f, 0.4f, 0.8f, 0.8f);
    style.Colors[ImGuiCol_ButtonHovered] = ImVec4(0.3f, 0.5f, 0.9f, 1.0f);
    style.Colors[ImGuiCol_FrameBg] = ImVec4(0.15f, 0.15f, 0.2f, 0.8f);
    style.Colors[ImGuiCol_SliderGrab] = ImVec4(0.2f, 0.6f, 1.0f, 1.0f);
    style.FrameRounding = 8.0f;
    style.WindowRounding = 12.0f;
    style.PopupRounding = 8.0f;
    style.ScrollbarRounding = 6.0f;
    style.GrabRounding = 6.0f;
    
    ImGui_ImplMetal_Init(_device);
}

- (void)renderLoop {
    if (!_menuVisible && !g_floatButton.highlighted) {
        return;
    }
    
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        if (!drawable) return;
        
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        
        _renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        
        // Отрисовка ImGui
        if (_menuVisible) {
            ImGui_ImplMetal_NewFrame(_renderPassDescriptor);
            ImGui::NewFrame();
            
            [self drawMenu];
            
            ImGui::Render();
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), encoder);
        }
        
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}

- (void)drawMenu {
    if (!g_hitboxAddress) {
        ImGui::Begin("BlackRussia Hitbox", NULL, ImGuiWindowFlags_AlwaysAutoResize);
        ImGui::TextColored(ImVec4(1, 0.3f, 0.3f, 1), "❌ Адрес не найден!");
        ImGui::Text("Введите адрес в hex:");
        
        static char addrInput[16] = "";
        ImGui::InputText("0x", addrInput, sizeof(addrInput));
        
        if (ImGui::Button("Set")) {
            uintptr_t addr = strtoull(addrInput, NULL, 16);
            if (addr) {
                g_hitboxAddress = (float*)addr;
                if ([MemoryManager validateAddress:g_hitboxAddress]) {
                    [MemoryManager saveCache:g_hitboxAddress];
                    memcpy(g_currentValues, g_hitboxAddress, sizeof(g_currentValues));
                    memcpy(g_originalValues, g_currentValues, sizeof(g_originalValues));
                    ImGui::CloseCurrentPopup();
                }
            }
        }
        ImGui::End();
        return;
    }
    
    ImGui::Begin("BlackRussia Hitbox", &_menuVisible, ImGuiWindowFlags_AlwaysAutoResize);
    
    // Заголовок с адресом
    ImGui::Text("HEAD addr: 0x%llX", (uint64_t)g_hitboxAddress);
    ImGui::Separator();
    
    // Глобальный множитель
    if (ImGui::SliderFloat("Global Multiplier", &g_globalMultiplier, 0.5f, 10.0f, "%.1fx")) {
        for (int i = 0; i < HITBOX_COUNT; i++) {
            g_currentValues[i] = g_originalValues[i] * g_globalMultiplier;
        }
        [MemoryManager writeFloatArray:g_currentValues atAddress:g_hitboxAddress count:HITBOX_COUNT];
    }
    
    ImGui::Separator();
    
    // Быстрые множители
    ImGui::Text("Quick Presets:");
    const float presets[2][3] = {{1.5f, 2.0f, 3.0f}, {4.0f, 6.0f, 10.0f}};
    for (int row = 0; row < 2; row++) {
        for (int col = 0; col < 3; col++) {
            float val = presets[row][col];
            if (ImGui::Button(("%.1fx##preset" + std::to_string(row * 3 + col)).c_str(), ImVec2(60, 30))) {
                g_globalMultiplier = val;
                for (int i = 0; i < HITBOX_COUNT; i++) {
                    g_currentValues[i] = g_originalValues[i] * val;
                }
                [MemoryManager writeFloatArray:g_currentValues atAddress:g_hitboxAddress count:HITBOX_COUNT];
            }
            if (col < 2) ImGui::SameLine();
        }
    }
    
    ImGui::Separator();
    
    // Ползунки для каждой части тела
    ImGui::Text("Body Parts:");
    for (int i = 0; i < HITBOX_COUNT; i++) {
        ImGui::PushID(i);
        if (ImGui::SliderFloat(BODY_PART_NAMES[i], &g_currentValues[i], 0.05f, 0.50f, "%.3f")) {
            [MemoryManager writeFloatArray:g_currentValues atAddress:g_hitboxAddress count:HITBOX_COUNT];
        }
        ImGui::PopID();
    }
    
    ImGui::Separator();
    
    // Кнопки управления
    if (ImGui::Button("Reset", ImVec2(80, 35))) {
        g_globalMultiplier = 1.0f;
        memcpy(g_currentValues, g_originalValues, sizeof(g_currentValues));
        [MemoryManager writeFloatArray:g_currentValues atAddress:g_hitboxAddress count:HITBOX_COUNT];
    }
    
    ImGui::SameLine();
    
    if (ImGui::Button("Save Config", ImVec2(80, 35))) {
        [self saveConfig];
    }
    
    ImGui::SameLine();
    
    if (ImGui::Button("Load Config", ImVec2(80, 35))) {
        [self loadConfig];
    }
    
    ImGui::End();
}

- (void)saveConfig {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    
    NSString* path = [[paths firstObject] stringByAppendingPathComponent:@"hitbox_config.json"];
    NSMutableDictionary* config = [NSMutableDictionary dictionary];
    
    NSMutableArray* values = [NSMutableArray array];
    for (int i = 0; i < HITBOX_COUNT; i++) {
        [values addObject:@(g_currentValues[i])];
    }
    config[@"hitboxes"] = values;
    config[@"multiplier"] = @(g_globalMultiplier);
    
    NSData* json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:path atomically:YES];
    NSLog(@"[BR] Конфиг сохранён: %@", path);
}

- (void)loadConfig {
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return;
    
    NSString* path = [[paths firstObject] stringByAppendingPathComponent:@"hitbox_config.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    
    NSData* json = [NSData dataWithContentsOfFile:path];
    if (!json) return;
    
    NSDictionary* config = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (!config) return;
    
    NSArray* values = config[@"hitboxes"];
    if (values.count == HITBOX_COUNT) {
        for (int i = 0; i < HITBOX_COUNT; i++) {
            g_currentValues[i] = [values[i] floatValue];
        }
        [MemoryManager writeFloatArray:g_currentValues atAddress:g_hitboxAddress count:HITBOX_COUNT];
    }
    
    g_globalMultiplier = [config[@"multiplier"] floatValue];
    NSLog(@"[BR] Конфиг загружен: %@", path);
}

- (void)dealloc {
    [_displayLink invalidate];
    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext();
}

@end

// ============================================================================
// MARK: - Плавающая кнопка
// ============================================================================

@interface FloatButton : UIButton
@property (nonatomic, strong) UIPanGestureRecognizer* panGesture;
@property (nonatomic, strong) UILongPressGestureRecognizer* longPress;
@end

@implementation FloatButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:0.9];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.5;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
        
        // Иконка
        UILabel* label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"H";
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:24];
        label.textColor = [UIColor whiteColor];
        label.userInteractionEnabled = NO;
        [self addSubview:label];
        
        // Жесты
        self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:self.panGesture];
        
        self.longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:self.longPress];
        
        [self addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)handlePan:(UIPanGestureRecognizer*)gesture {
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:self.superview];
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        
        // Границы
        CGFloat halfWidth = self.frame.size.width / 2;
        newCenter.x = MAX(halfWidth, MIN(newCenter.x, self.superview.bounds.size.width - halfWidth));
        newCenter.y = MAX(halfWidth + 20, MIN(newCenter.y, self.superview.bounds.size.height - halfWidth - 20));
        
        self.center = newCenter;
        [gesture setTranslation:CGPointZero inView:self.superview];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer*)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // Можно добавить вибрацию
    }
}

- (void)buttonTapped {
    g_menuVisible = !g_menuVisible;
    if (g_menuVisible) {
        self.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9];
    } else {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:0.9];
    }
}

@end

// ============================================================================
// MARK: - UIWindow для оверлея
// ============================================================================

@interface OverlayWindow : UIWindow
@property (nonatomic, strong) MetalRenderer* renderer;
@property (nonatomic, strong) FloatButton* floatButton;
@end

@implementation OverlayWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.rootViewController = [UIViewController new];
        self.rootViewController.view.backgroundColor = [UIColor clearColor];
        
        // Плавающая кнопка
        CGFloat buttonSize = 44;
        CGFloat x = frame.size.width - buttonSize - 20;
        CGFloat y = 60; // под safe area
        self.floatButton = [[FloatButton alloc] initWithFrame:CGRectMake(x, y, buttonSize, buttonSize)];
        [self.rootViewController.view addSubview:self.floatButton];
        
        // Metal рендерер
        self.renderer = [[MetalRenderer alloc] initWithWindow:self];
    }
    return self;
}

- (void)dealloc {
    self.renderer = nil;
}

@end

// ============================================================================
// MARK: - Основной инициализатор
// ============================================================================

@interface AppDelegate : NSObject
@end

@implementation AppDelegate

- (void)setupOverlay {
    UIWindow* mainWindow = nil;
    for (UIWindow* window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            mainWindow = window;
            break;
        }
    }
    
    if (!mainWindow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self setupOverlay];
        });
        return;
    }
    
    // Создаём оверлей
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    g_overlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
    g_overlayWindow.hidden = NO;
    g_overlayWindow.alpha = 1.0;
    
    // Начинаем поиск адреса
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self findAddress];
    });
}

- (void)findAddress {
    // Ждём загрузки игры
    sleep(5);
    
    // Ищем адрес
    g_hitboxAddress = (float*)[MemoryManager findHitboxAddress];
    
    if (g_hitboxAddress) {
        memcpy(g_currentValues, g_hitboxAddress, sizeof(g_currentValues));
        memcpy(g_originalValues, g_currentValues, sizeof(g_originalValues));
        NSLog(@"[BR] ✅ Адрес найден: %p", g_hitboxAddress);
        
        // Показываем в UI
        dispatch_async(dispatch_get_main_queue(), ^{
            g_menuVisible = true;
        });
    } else {
        NSLog(@"[BR] ❌ Адрес не найден! Используйте ручной ввод.");
        dispatch_async(dispatch_get_main_queue(), ^{
            g_menuVisible = true;
        });
    }
}

@end

// ============================================================================
// MARK: - Конструктор библиотеки
// ============================================================================

__attribute__((constructor))
static void initLibrary() {
    NSLog(@"[BR] 🔥 BlackRussia Hitbox Modifier v1.0 загружен");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // Создаём делегат
        AppDelegate* delegate = [AppDelegate new];
        [delegate setupOverlay];
        
        // Удерживаем делегат
        static AppDelegate* staticDelegate = nil;
        staticDelegate = delegate;
    });
}

__attribute__((destructor))
static void deinitLibrary() {
    NSLog(@"[BR] 👋 BlackRussia Hitbox Modifier выгружен");
}
