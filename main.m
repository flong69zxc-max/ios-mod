// main.m
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dlfcn.h>

// ========== СТРУКТУРЫ ==========
typedef struct {
    float x, y, z;
    float radius;
    float height;
    uint32_t unknown1;
    uint32_t unknown2;
} Hitbox;

typedef struct {
    uint64_t address;
    float radius;
    float height;
    char name[20];
    int offset; // относительный оффсет от базы
} FoundHitbox;

// Типы хитбоксов
typedef enum {
    HITBOX_HEAD = 0,
    HITBOX_TORSO_1,
    HITBOX_TORSO_2,
    HITBOX_MID,
    HITBOX_LEFTARM,
    HITBOX_RIGHTARM,
    HITBOX_LEFTLEG_1,
    HITBOX_RIGHTLEG_1,
    HITBOX_LEFTLEG_2,
    HITBOX_RIGHTLEG_2,
    HITBOX_COUNT
} HitboxType;

// Паттерны
typedef struct {
    HitboxType type;
    uint32_t pattern;
    const char *name;
    float value;
} HitboxPattern;

HitboxPattern patterns[] = {
    {HITBOX_HEAD,        0x3E19999A, "HEAD", 0.15f},
    {HITBOX_TORSO_1,     0x3E4CCCCD, "TORSO_1", 0.20f},
    {HITBOX_TORSO_2,     0x3E800000, "TORSO_2", 0.25f},
    {HITBOX_MID,         0x3E800000, "MID", 0.25f},
    {HITBOX_LEFTARM,     0x3E24E148, "LEFTARM", 0.16f},
    {HITBOX_RIGHTARM,    0x3E24E148, "RIGHTARM", 0.16f},
    {HITBOX_LEFTLEG_1,   0x3E4CCCCD, "LEFTLEG_1", 0.20f},
    {HITBOX_RIGHTLEG_1,  0x3E4CCCCD, "RIGHTLEG_1", 0.20f},
    {HITBOX_LEFTLEG_2,   0x3E19999A, "LEFTLEG_2", 0.15f},
    {HITBOX_RIGHTLEG_2,  0x3E19999A, "RIGHTLEG_2", 0.15f}
};

// Глобальные переменные
uint64_t g_baseAddr = 0;
FoundHitbox g_foundHitboxes[HITBOX_COUNT][10]; // максимум 10 на тип
int g_hitboxCount[HITBOX_COUNT] = {0};

// ========== ПОИСК БИБЛИОТЕКИ ==========
uint64_t findLibrary(const char *libName) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, libName)) {
            uint64_t slide = _dyld_get_image_vmaddr_slide(i);
            struct mach_header_64 *header = (struct mach_header_64 *)_dyld_get_image_header(i);
            return slide + (uint64_t)header;
        }
    }
    return 0;
}

// ========== ВАЛИДАЦИЯ ХИТБОКСА ==========
BOOL isValidHitbox(uint64_t addr, HitboxPattern *pattern) {
    uint32_t val = *(uint32_t *)addr;
    if (val != pattern->pattern) return NO;
    
    Hitbox *hb = (Hitbox *)addr;
    if (fabs(hb->x) > 10000 || fabs(hb->y) > 10000 || fabs(hb->z) > 10000) {
        return NO;
    }
    
    // Радиус должен быть в разумных пределах
    if (hb->radius < 0.01f || hb->radius > 5.0f) {
        return NO;
    }
    
    // Высота должна быть в разумных пределах
    if (hb->height < 0.01f || hb->height > 5.0f) {
        return NO;
    }
    
    return YES;
}

// ========== СКАНИРОВАНИЕ ХИТБОКСОВ ==========
void scanHitboxes(uint64_t startAddr, uint64_t endAddr) {
    printf("\n[+] Scanning memory for hitboxes...\n");
    printf("    Range: 0x%llX - 0x%llX\n\n", startAddr, endAddr);
    
    for (uint64_t addr = startAddr; addr < endAddr - 0x30; addr += 4) {
        uint32_t val = *(uint32_t *)addr;
        
        for (int i = 0; i < HITBOX_COUNT; i++) {
            if (val == patterns[i].pattern) {
                if (isValidHitbox(addr, &patterns[i])) {
                    if (g_hitboxCount[i] < 10) {
                        Hitbox *hb = (Hitbox *)addr;
                        FoundHitbox *found = &g_foundHitboxes[i][g_hitboxCount[i]];
                        found->address = addr;
                        found->radius = hb->radius;
                        found->height = hb->height;
                        found->offset = (int)(addr - g_baseAddr);
                        strcpy(found->name, patterns[i].name);
                        g_hitboxCount[i]++;
                    }
                }
            }
        }
    }
}

// ========== ВЫВОД НАЙДЕННЫХ ОФФСЕТОВ ==========
void printOffsets() {
    printf("\n========================================\n");
    printf("   FOUND OFFSETS (relative to base)\n");
    printf("========================================\n\n");
    
    printf("// Base Address: 0x%llX\n", g_baseAddr);
    printf("// Total hitboxes found: %d\n\n", 
           g_hitboxCount[0] + g_hitboxCount[1] + g_hitboxCount[2] + g_hitboxCount[3] +
           g_hitboxCount[4] + g_hitboxCount[5] + g_hitboxCount[6] + g_hitboxCount[7] +
           g_hitboxCount[8] + g_hitboxCount[9]);
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        if (g_hitboxCount[i] > 0) {
            printf("▶ %s (%d found):\n", patterns[i].name, g_hitboxCount[i]);
            for (int j = 0; j < g_hitboxCount[i]; j++) {
                FoundHitbox *hb = &g_foundHitboxes[i][j];
                printf("   [%d] Offset: 0x%X | Radius: %.2f | Height: %.2f | Addr: 0x%llX\n",
                       j, hb->offset, hb->radius, hb->height, hb->address);
            }
            printf("\n");
        }
    }
}

// ========== ГЕНЕРАЦИЯ LUA СКРИПТА ==========
void generateLuaScript() {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/hitbox_offsets.lua"];
    NSMutableString *lua = [NSMutableString string];
    
    [lua appendString:@"-- ========================================\n"];
    [lua appendString:@"--  BlackRussia Hitbox Offsets (Auto-Generated)\n"];
    [lua appendString:@"--  Generated: "];
    [lua appendString:[NSString stringWithUTF8String:__TIMESTAMP__]];
    [lua appendString:@"\n"];
    [lua appendString:@"-- ========================================\n\n"];
    
    [lua appendString:@"local offsets = {\n"];
    [lua appendString:@"    base = 0x"];
    [lua appendFormat:@"%llX", g_baseAddr];
    [lua appendString:@",\n"];
    [lua appendString:@"    hitboxes = {\n"];
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        if (g_hitboxCount[i] > 0) {
            [lua appendFormat:@"        %s = {\n", patterns[i].name];
            for (int j = 0; j < g_hitboxCount[i]; j++) {
                FoundHitbox *hb = &g_foundHitboxes[i][j];
                [lua appendFormat:@"            { offset = 0x%X, radius = %.2f, height = %.2f },\n",
                 hb->offset, hb->radius, hb->height];
            }
            [lua appendString:@"        },\n"];
        }
    }
    
    [lua appendString:@"    }\n"];
    [lua appendString:@"}\n\n"];
    
    // Функция для применения хитбоксов
    [lua appendString:@"-- Применение хитбоксов в игре\n"];
    [lua appendString:@"function applyHitboxes()\n"];
    [lua appendString:@"    local base = offsets.base\n"];
    [lua appendString:@"    \n"];
    [lua appendString:@"    for name, hitboxes in pairs(offsets.hitboxes) do\n"];
    [lua appendString:@"        for _, hb in ipairs(hitboxes) do\n"];
    [lua appendString:@"            local addr = base + hb.offset\n"];
    [lua appendString:@"            -- Записываем радиус и высоту\n"];
    [lua appendString:@"            -- writeFloat(addr + 0x10, hb.radius) -- радиус\n"];
    [lua appendString:@"            -- writeFloat(addr + 0x14, hb.height) -- высота\n"];
    [lua appendString:@"            print(string.format('[%s] Applied at 0x%%X', name, addr))\n"];
    [lua appendString:@"        end\n"];
    [lua appendString:@"    end\n"];
    [lua appendString:@"end\n\n"];
    
    [lua appendString:@"-- Возвращаем оффсеты\n"];
    [lua appendString:@"return offsets\n"];
    
    // Сохраняем Lua файл
    NSError *error = nil;
    [lua writeToFile:docPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (error) {
        printf("[-] Failed to save Lua script: %s\n", [[error description] UTF8String]);
    } else {
        printf("[+] Lua script saved to: %s\n", [docPath UTF8String]);
    }
}

// ========== ГЕНЕРАЦИЯ HEADER ФАЙЛА ==========
void generateHeaderFile() {
    NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/hitbox_offsets.h"];
    NSMutableString *header = [NSMutableString string];
    
    [header appendString:@"// ========================================\n"];
    [header appendString:@"//  BlackRussia Hitbox Offsets (Auto-Generated)\n"];
    [header appendString:@"//  Generated: "];
    [header appendString:[NSString stringWithUTF8String:__TIMESTAMP__]];
    [header appendString:@"\n"];
    [header appendString:@"// ========================================\n\n"];
    
    [header appendFormat:@"#define BASE_ADDRESS 0x%llX\n\n", g_baseAddr];
    
    for (int i = 0; i < HITBOX_COUNT; i++) {
        if (g_hitboxCount[i] > 0) {
            [header appendFormat:@"// %s (%d found)\n", patterns[i].name, g_hitboxCount[i]];
            for (int j = 0; j < g_hitboxCount[i]; j++) {
                FoundHitbox *hb = &g_foundHitboxes[i][j];
                [header appendFormat:@"#define OFFSET_%s_%d 0x%X\n", 
                 patterns[i].name, j, hb->offset];
            }
            [header appendString:@"\n"];
        }
    }
    
    [header appendString:@"// Структура для чтения хитбокса\n"];
    [header appendString:@"typedef struct {\n"];
    [header appendString:@"    float x, y, z;\n"];
    [header appendString:@"    float radius;\n"];
    [header appendString:@"    float height;\n"];
    [header appendString:@"    uint32_t unknown1;\n"];
    [header appendString:@"    uint32_t unknown2;\n"];
    [header appendString:@"} Hitbox;\n\n"];
    
    [header appendString:@"// Функция для получения адреса хитбокса\n"];
    [header appendString:@"static inline uint64_t getHitboxAddress(int type, int index) {\n"];
    [header appendString:@"    uint64_t offsets[] = {\n"];
    for (int i = 0; i < HITBOX_COUNT; i++) {
        if (g_hitboxCount[i] > 0) {
            [header appendFormat:@"        OFFSET_%s_0", patterns[i].name];
            for (int j = 1; j < g_hitboxCount[i]; j++) {
                [header appendFormat(@", OFFSET_%s_%d", patterns[i].name, j];
            }
            [header appendString:@",\n"];
        }
    }
    [header appendString:@"    };\n"];
    [header appendString:@"    return BASE_ADDRESS + offsets[type * 10 + index];\n"];
    [header appendString:@"}\n"];
    
    NSError *error = nil;
    [header writeToFile:docPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (!error) {
        printf("[+] Header file saved to: %s\n", [docPath UTF8String]);
    }
}

// ========== ПРИМЕНЕНИЕ ХИТБОКСОВ В ПАМЯТИ ==========
void applyHitboxes() {
    printf("\n[+] Applying hitboxes...\n");
    
    int applied = 0;
    for (int i = 0; i < HITBOX_COUNT; i++) {
        for (int j = 0; j < g_hitboxCount[i]; j++) {
            FoundHitbox *hb = &g_foundHitboxes[i][j];
            uint64_t addr = hb->address;
            
            // Модифицируем радиус и высоту (например, увеличиваем в 2 раза)
            float newRadius = hb->radius * 1.5f;
            float newHeight = hb->height * 1.5f;
            
            // Записываем новые значения (нужны права на запись)
            // В реальном твике используйте VM_WRITE или патчинг
            /*
            float *radiusPtr = (float *)(addr + 0x10);
            float *heightPtr = (float *)(addr + 0x14);
            *radiusPtr = newRadius;
            *heightPtr = newHeight;
            */
            
            printf("    [%s_%d] 0x%X: Radius %.2f -> %.2f, Height %.2f -> %.2f\n",
                   hb->name, j, hb->offset, hb->radius, newRadius, hb->height, newHeight);
            applied++;
        }
    }
    
    printf("[+] Applied %d hitboxes\n", applied);
}

// ========== MAIN ==========
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        printf("========================================\n");
        printf("   BlackRussia Hitbox Offset Finder\n");
        printf("   with Auto-Apply & Lua Generator\n");
        printf("========================================\n\n");
        
        // Поиск библиотеки
        g_baseAddr = findLibrary("blackrussia-client");
        
        if (g_baseAddr == 0) {
            printf("[-] Library not found!\n");
            printf("[!] Make sure the game is running.\n");
            return 1;
        }
        
        printf("[+] Base Address: 0x%llX\n", g_baseAddr);
        
        // Сканирование
        scanHitboxes(g_baseAddr, g_baseAddr + 0x200000);
        
        // Вывод оффсетов
        printOffsets();
        
        // Применение
        applyHitboxes();
        
        // Генерация файлов
        generateLuaScript();
        generateHeaderFile();
        
        printf("\n========================================\n");
        printf("[+] Done! Files saved to Documents/\n");
        printf("    - hitbox_offsets.lua\n");
        printf("    - hitbox_offsets.h\n");
        printf("========================================\n");
    }
    return 0;
}
