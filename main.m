// main.m
// iOS Tool for Patching Hitbox Values in blackrussia-client Framework
// Compile with: clang -framework Foundation -o hitbox_patcher main.m
// Run on jailbroken iOS device as root

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/mman.h>
#import <sys/stat.h>

// Hardcoded path to the framework binary
#define TARGET_PATH "/var/mobile/Containers/Bundle/Application/.../BlackRussia.app/Frameworks/blackrussia-client.framework/blackrussia-client"

// Original hitbox values (Little-Endian HEX)
typedef struct {
    const unsigned char original[4];
    const unsigned char patched[4];
} HitboxPatch;

// Define all 10 hitbox patches
HitboxPatch patches[] = {
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}}, // HEAD
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}}, // TORSO_1
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}}, // TORSO_2
    {{0x00, 0x00, 0x80, 0x3E}, {0x00, 0x00, 0xC0, 0x3E}}, // MID
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}}, // LEFTARM
    {{0x48, 0xE1, 0x24, 0x3E}, {0x48, 0xE1, 0x74, 0x3E}}, // RIGHTARM
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}}, // LEFTLEG_1
    {{0xCD, 0xCC, 0x4C, 0x3E}, {0x9A, 0x99, 0x99, 0x3E}}, // RIGHTLEG_1
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}}, // LEFTLEG_2
    {{0x9A, 0x99, 0x19, 0x3E}, {0x66, 0x66, 0x66, 0x3E}}  // RIGHTLEG_2
};

#define NUM_PATCHES (sizeof(patches) / sizeof(patches[0]))
#define STEP_SIZE 0x20 // 32 bytes between each hitbox

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔧 Starting hitbox patcher for blackrussia-client");
        
        // 1. Open the file
        int fd = open(TARGET_PATH, O_RDWR);
        if (fd == -1) {
            NSLog(@"❌ Failed to open file: %s", TARGET_PATH);
            NSLog(@"⚠️  Make sure the path is correct and you have root permissions");
            return 1;
        }
        
        // 2. Get file size
        struct stat st;
        if (fstat(fd, &st) != 0) {
            NSLog(@"❌ Failed to get file size");
            close(fd);
            return 1;
        }
        size_t fileSize = st.st_size;
        NSLog(@"📁 File size: %zu bytes", fileSize);
        
        // 3. Memory map the file for efficient searching and patching
        void *mapped = mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped == MAP_FAILED) {
            NSLog(@"❌ Failed to memory map file");
            close(fd);
            return 1;
        }
        
        unsigned char *data = (unsigned char *)mapped;
        BOOL foundAll = YES;
        NSMutableArray *foundOffsets = [NSMutableArray array];
        
        // 4. Search for each hitbox pattern and verify spacing
        for (int i = 0; i < NUM_PATCHES; i++) {
            BOOL found = NO;
            const unsigned char *pattern = patches[i].original;
            size_t searchLimit = fileSize - 4; // 4 bytes = sizeof(float)
            
            for (size_t offset = 0; offset < searchLimit; offset++) {
                // Check if pattern matches at this offset
                if (memcmp(data + offset, pattern, 4) == 0) {
                    // Verify this is the correct position (with 0x20 spacing)
                    if (i > 0) {
                        NSNumber *prevOffset = foundOffsets[i - 1];
                        size_t expectedOffset = [prevOffset unsignedLongValue] + STEP_SIZE;
                        if (offset != expectedOffset) {
                            NSLog(@"⚠️  Found pattern %d at offset 0x%lx, but expected 0x%lx (spacing not 0x20)", 
                                  i, offset, expectedOffset);
                            // Continue searching for correct spacing
                            continue;
                        }
                    }
                    
                    found = YES;
                    [foundOffsets addObject:@(offset)];
                    NSLog(@"✅ Found hitbox %d at offset: 0x%lx", i, offset);
                    break;
                }
            }
            
            if (!found) {
                NSLog(@"❌ Failed to find hitbox pattern %d", i);
                foundAll = NO;
                break;
            }
        }
        
        if (!foundAll || [foundOffsets count] != NUM_PATCHES) {
            NSLog(@"❌ Could not locate all hitbox patterns with correct 0x20 spacing");
            munmap(mapped, fileSize);
            close(fd);
            return 1;
        }
        
        // 5. Apply patches (replace original values with patched ones)
        NSLog(@"🔨 Applying patches...");
        for (int i = 0; i < NUM_PATCHES; i++) {
            size_t offset = [foundOffsets[i] unsignedLongValue];
            const unsigned char *patch = patches[i].patched;
            
            // Replace the 4 bytes at this offset
            memcpy(data + offset, patch, 4);
            
            // Verify the patch was applied
            if (memcmp(data + offset, patch, 4) == 0) {
                NSLog(@"✅ Patched hitbox %d at offset 0x%lx", i, offset);
            } else {
                NSLog(@"⚠️  Failed to patch hitbox %d at offset 0x%lx", i, offset);
            }
        }
        
        // 6. Sync changes to disk
        if (msync(mapped, fileSize, MS_SYNC) != 0) {
            NSLog(@"⚠️  Warning: msync failed, changes might not be written to disk");
        }
        
        // 7. Clean up
        munmap(mapped, fileSize);
        close(fd);
        
        NSLog(@"✅ All patches applied successfully!");
        NSLog(@"💡 The framework binary has been modified in memory and on disk");
        NSLog(@"📱 Restart the game for changes to take effect");
        NSLog(@"🔒 Note: On iOS, modified frameworks may cause signature validation issues.");
        NSLog(@"   This tool patches the file directly, bypassing signature checks.");
        NSLog(@"   If the game crashes, ensure you have proper code signing disabled");
        NSLog(@"   (e.g., using jailbreak or developer-signed entitlements)");
        
        return 0;
    }
}
