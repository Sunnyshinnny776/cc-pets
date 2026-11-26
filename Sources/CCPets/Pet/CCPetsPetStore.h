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

// 主窗口与 CLI 共用目录缓存、素材来源校验和安装格式。网络操作同步，调用方放到后台执行。
// pet-store 的缓存目录（~/.cc-pets/cache，可用 CC_PETS_HOME 覆盖）：清单、热门榜、目录预览图。
// 纯缓存，cc-pets clean 会整个删掉。
NSString *CCPetsPetStoreCacheDirectory(void);
NSArray<NSDictionary *> *CCPetsPetdexCatalog(NSString **error);
// 按安装量排在前面的若干只（网站画廊的默认顺序），元素是 @{slug, installCount}，名次从高到低。
// 和清单一样有本地缓存；拿不到时返回 nil，调用方按清单原顺序排即可。
NSArray<NSDictionary *> *CCPetsPetdexPopularPets(void);
NSURLRequest *CCPetsPetdexPreviewRequest(NSDictionary *pet);
// 网站卡片用的小图：只有待机一行（约 6 帧、每格 192×208），几十 KB；整张精灵图要 2MB 左右。
NSURLRequest *CCPetsPetdexThumbnailRequest(NSDictionary *pet);
BOOL CCPetsInstallPetdexPet(NSDictionary *pet, NSString **error);
NSString *CCPetsInstalledPetdexSlug(NSString *directory);
