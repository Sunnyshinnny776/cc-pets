#import <Foundation/Foundation.h>

// `cc-pets pet <子命令>`：cc-pets 自己的素材仓库。
//
// 素材可以来自多个"源"（source），但一律落到 ~/.cc-pets/pets（CC_PETS_PETS_DIR 可覆盖），
// 不碰 ~/.petdex/pets 和 ~/.codex/pets——那两个目录是别的工具在写，混在一起就没法"只看自己装的宠物"。
//
// 目录名保持素材本名（boba 就是 boba），来源记在宠物目录内的 .source.json 里。这样桌宠端不需要知道
// "源"这回事，右键菜单里也不会出现 boba@petdex 这种名字；同名素材的冲突交给 --as 显式改名解决。
//
// arguments 不含 "pet" 本身。返回进程退出码。
int CCPetsPetStoreMain(NSArray<NSString *> *arguments);
