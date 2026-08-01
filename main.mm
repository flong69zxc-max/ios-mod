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
static MetalRenderer* g_renderer = nil;  // ← Добавить глобальную ссылку

// ============================================================================
// MARK: - ImGui Metal Backend
// ============================================================================

@interface MetalRenderer : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) CAMetalLayer* metalLayer;
@property (nonatomic, strong) UIWindow* window;
@property (nonatomic, strong) CADisplayLink* displayLink;
@property (nonatomic, assign) BOOL menuVisible;  // ← Добавить свойство
@end

@implementation MetalRenderer {
    // Убрать ImGui_ImplMetal_Data* _imguiMetalData; - он не нужен
    MTLRenderPassDescriptor* _renderPassDescriptor;
    id<MTLTexture> _depthTexture;
}

- (instancetype)initWithWindow:(UIWindow*)window {
    self = [super init];
    if (self) {
        _window = window;
        _menuVisible = NO;  // ← Инициализация
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
    
    // Исправление: используем screen bounds
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    _metalLayer.drawableSize = screenBounds.size;
    _metalLayer.frame = screenBounds;
    _metalLayer.backgroundColor = CGColorCreate(CGColorSpaceCreateDeviceRGB(), (CGFloat[]){0, 0, 0, 0});
    
    // Исправление: установка layer через rootViewController
    _window.rootViewController.view.layer = _metalLayer;
    _window.rootViewController.view.layer.opaque = NO;
    
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
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    io.DisplaySize = ImVec2(screenBounds.size.width, screenBounds.size.height);
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
    
    // Исправление: правильная инициализация Metal бэкенда
    ImGui_ImplMetal_Init(_device);
}

- (void)renderLoop {
    // Исправление: используем self.menuVisible
    if (!self.menuVisible && !g_floatButton.highlighted) {
        return;
    }
    
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        if (!drawable) return;
        
        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        
        _renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        
        // Отрисовка ImGui
        if (self.menuVisible) {
            ImGui_ImplMetal_NewFrame(_renderPassDescriptor);
            ImGui::NewFrame();
            
            [self drawMenu];
            
            ImGui::Render();
            
            // Исправление: правильный вызов RenderDrawData с 3 аргументами
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), commandBuffer, encoder);
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
    
    // Исправление: используем self.menuVisible
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
    
    // Быстрые множители - исправление std::to_string
    ImGui::Text("Quick Presets:");
    const float presets[2][3] = {{1.5f, 2.0f, 3.0f}, {4.0f, 6.0f, 10.0f}};
    for (int row = 0; row < 2; row++) {
        for (int col = 0; col < 3; col++) {
            float val = presets[row][col];
            // Исправление: используем sprintf вместо std::to_string
            char label[32];
            sprintf(label, "%.1fx##preset%d", val, row * 3 + col);
            if (ImGui::Button(label, ImVec2(60, 30))) {
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

// Остальные методы (saveConfig, loadConfig, dealloc) без изменений...

@end

// ============================================================================
// MARK: - Плавающая кнопка
// ============================================================================

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

- (void)buttonTapped {
    g_menuVisible = !g_menuVisible;
    // Исправление: обновляем состояние рендерера
    if (g_renderer) {
        g_renderer.menuVisible = g_menuVisible;
    }
    if (g_menuVisible) {
        self.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.9];
    } else {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:0.9];
    }
}

// Остальные методы без изменений...

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
        g_renderer = self.renderer;  // ← Сохраняем глобальную ссылку
    }
    return self;
}

@end

// ============================================================================
// MARK: - Основной инициализатор
// ============================================================================

@interface AppDelegate : NSObject
@end

@implementation AppDelegate

- (void)setupOverlay {
    // Исправление: используем scenes для iOS 15+
    UIWindow* mainWindow = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* windowScene = (UIWindowScene*)scene;
                for (UIWindow* window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        mainWindow = window;
                        break;
                    }
                }
            }
        }
    } else {
        // Fallback для старых версий
        for (UIWindow* window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                mainWindow = window;
                break;
            }
        }
    }
    
    if (!mainWindow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self setupOverlay];
        });
        return;
    }
    
    // Создаём оверлей - используем mainWindow.screen
    CGRect screenBounds = mainWindow.screen.bounds;
    g_overlayWindow = [[OverlayWindow alloc] initWithFrame:screenBounds];
    g_overlayWindow.hidden = NO;
    g_overlayWindow.alpha = 1.0;
    
    // Начинаем поиск адреса
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self findAddress];
    });
}

// Остальные методы без изменений...

@end
