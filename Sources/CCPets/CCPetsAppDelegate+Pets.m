// 宠物素材发现、切换与删除。
#import "CCPetsAppDelegate+Private.h"

@implementation AppDelegate (Pets)
- (NSDictionary *)petManifestInDirectory:(NSString *)directory {
    NSString *jsonPath = [directory stringByAppendingPathComponent:@"pet.json"];
    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
    if (!jsonData) return @{};
    id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : @{};
}
- (NSInteger)spriteVersionInDirectory:(NSString *)directory fallbackDirectory:(NSString *)fallbackDirectory {
    NSArray<NSString *> *directories = fallbackDirectory.length > 0
        ? @[directory, fallbackDirectory]
        : @[directory];
    for (NSString *candidate in directories) {
        id value = [self petManifestInDirectory:candidate][@"spriteVersionNumber"];
        if (![value isKindOfClass:NSNumber.class]) continue;
        NSInteger version = [value integerValue];
        if (version == 1 || version == 2) return version;
    }
    return 1;
}
- (NSInteger)spriteRowCountForVersion:(NSInteger)version {
    return version == 2 ? 11 : 9;
}
- (NSString *)spritePathInDirectory:(NSString *)directory {
    NSString *configuredName = nil;
    id value = [self petManifestInDirectory:directory][@"spritesheetPath"];
    if ([value isKindOfClass:NSString.class]) configuredName = [value lastPathComponent];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (configuredName.length > 0) [names addObject:configuredName];
    [names addObjectsFromArray:@[@"spritesheet.webp", @"spritesheet.png"]];
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) return path;
    }
    return nil;
}
- (NSArray<NSString *> *)petDirectoryNamesAtPath:(NSString *)root {
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@"."]) continue;
        BOOL isDirectory = NO;
        NSString *path = [root stringByAppendingPathComponent:entry];
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            [directories addObject:entry];
        }
    }
    return [directories sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}
// 桌宠只扫 OwnPetsDirectory() 加包内素材，无条件、不看那里有没有东西。~/.petdex/pets 和
// ~/.codex/pets 由别的工具写入，直接扫就永远分不清哪只是自己装的；要用 Codex 的素材就打开
// "导入 Codex 素材"开关，由 ImportCodexPets 复制进来，之后它们和自己装的没有区别。
- (NSArray<NSDictionary *> *)discoverPetOptions {
    NSString *ownRoot = OwnPetsDirectory();
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];

    for (NSString *name in [self petDirectoryNamesAtPath:ownRoot]) {
        NSString *directory = [ownRoot stringByAppendingPathComponent:name];
        NSString *path = [self spritePathInDirectory:directory];
        if (!path) continue;
        NSInteger version = [self spriteVersionInDirectory:directory fallbackDirectory:nil];
        [result addObject:@{
            @"id": [@"external:" stringByAppendingString:name],
            @"name": name,
            @"path": path,
            @"spriteVersionNumber": @(version),
            @"spriteRowCount": @([self spriteRowCountForVersion:version])
        }];
    }

    NSArray<NSString *> *bundled = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:self.binaryDirectory error:nil] ?: @[];
    for (NSString *fileName in [bundled sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSString *extension = fileName.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"webp"] && ![extension isEqualToString:@"png"]) continue;
        [result addObject:@{
            @"id": [@"builtin:" stringByAppendingString:fileName],
            @"name": fileName.stringByDeletingPathExtension,
            @"path": [self.binaryDirectory stringByAppendingPathComponent:fileName],
            @"spriteVersionNumber": @1,
            @"spriteRowCount": @9
        }];
    }
    return result;
}
// 素材目录的 mtime。目录里增删条目会改动它，而 `cc-pets pet add` / `remove` 正是在增删
// 条目——所以这一个时间戳就足以判断列表是否需要重扫，不必每次打开菜单都遍历目录。
- (NSDate *)petOptionsStamp {
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:OwnPetsDirectory() error:nil];
    return attributes[NSFileModificationDate];
}
- (void)invalidatePetOptionsCache {
    self.cachedPetOptions = nil;
    self.cachedPetOptionsStamp = nil;
}
- (NSArray<NSDictionary *> *)petOptions {
    NSDate *stamp = [self petOptionsStamp];
    BOOL stale = !self.cachedPetOptions ||
        (stamp == nil) != (self.cachedPetOptionsStamp == nil) ||
        (stamp && ![stamp isEqualToDate:self.cachedPetOptionsStamp]);
    if (stale) {
        self.cachedPetOptions = [self discoverPetOptions];
        self.cachedPetOptionsStamp = stamp;
    }
    return self.cachedPetOptions;
}
- (NSDictionary *)petOptionWithID:(NSString *)petID inOptions:(NSArray<NSDictionary *> *)options {
    for (NSDictionary *option in options) if ([option[@"id"] isEqualToString:petID]) return option;
    return nil;
}
- (NSArray<NSDictionary *> *)waitForPetOptions {
    while (YES) {
        // 这个循环就是"重新扫描"按钮的实现，必须绕开缓存。
        [self invalidatePetOptionsCache];
        NSArray<NSDictionary *> *options = [self petOptions];
        if (options.count > 0) return options;

        [NSApp activateIgnoringOtherApps:YES];
        NSAlert *alert = [NSAlert new];
        alert.messageText = L(@"No Pet Sprites Found");
        alert.informativeText = L(@"Download one with `cc-pets pet add <name>`, or put a PNG / WebP sprite sheet in ~/.cc-pets/pets/<name>/. CC Pets doesn't read ~/.petdex/pets/ or ~/.codex/pets/; to use Codex pets, turn on “Import Codex pets” in the right-click menu. Then click “Rescan”.");
        [alert addButtonWithTitle:L(@"Rescan")];
        [alert addButtonWithTitle:L(@"Open Pets Folder")];
        [alert addButtonWithTitle:L(@"Quit")];
        NSModalResponse response = [alert runModal];
        if (response == NSAlertSecondButtonReturn) {
            NSString *directory = OwnPetsDirectory();
            [NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:nil];
            [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:directory]];
        } else if (response == NSAlertThirdButtonReturn) {
            return @[];
        }
    }
}
- (void)switchPetToID:(NSString *)petID {
    NSArray<NSDictionary *> *options = [self petOptions];
    NSDictionary *option = [self petOptionWithID:petID inOptions:options];
    if (!option) return;
    NSInteger spriteRowCount = [option[@"spriteRowCount"] integerValue] ?: 9;
    NSImage *image = LoadPetSpriteImage(option[@"path"], CCPetsPetDecodeCellSize(), spriteRowCount);
    if (!image) return;
    [self.petView applySheet:image petID:petID rowCount:spriteRowCount];
    PetPhrasesSetCurrentPetID(petID);
    [NSUserDefaults.standardUserDefaults setObject:petID forKey:@"CCPetsSelectedSprite"];
}
- (BOOL)deletePetWithID:(NSString *)petID {
    if (![petID hasPrefix:@"external:"]) return NO;
    NSArray<NSDictionary *> *options = [self petOptions];
    NSDictionary *option = [self petOptionWithID:petID inOptions:options];
    if (!option) return NO;

    NSString *name = [petID substringFromIndex:@"external:".length];
    if (name.length == 0 || [name containsString:@"/"] || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."]) return NO;
    NSString *root = OwnPetsDirectory().stringByStandardizingPath;
    NSString *directory = [root stringByAppendingPathComponent:name].stringByStandardizingPath;
    NSString *optionDirectory = [[option[@"path"] stringByDeletingLastPathComponent] stringByStandardizingPath];
    if (![directory.stringByDeletingLastPathComponent isEqualToString:root] ||
        ![optionDirectory isEqualToString:directory]) return NO;

    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:directory error:&error]) {
        [self showAlertWithTitle:L(@"Can't Delete Pet")
            message:error.localizedDescription ?: L(@"Failed to delete the pet folder.")];
        return NO;
    }

    [self invalidatePetOptionsCache];
    if ([self.petView.currentPetID isEqualToString:petID]) {
        NSDictionary *fallback = [self petOptions].firstObject;
        if (fallback) [self switchPetToID:fallback[@"id"]];
        else {
            PetPhrasesSetCurrentPetID(nil);
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"CCPetsSelectedSprite"];
        }
    }
    return YES;
}
@end
