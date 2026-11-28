#import <Foundation/Foundation.h>

// 在线宠物目录里不碰界面、不碰网络的那部分逻辑：排序、分页、文案格式、精灵图行数判断、
// 热门榜数据解析。单独成文件，测试只需编译它（tests/pet-catalog-harness.m）。

// Petdex 素材每格 192×208、每行 8 格：v1 是 9 行（1536×1872），v2 是 11 行（1536×2288）。
// 按宽高比判断，不依赖清单里的 spriteVersionNumber（旧缓存里可能没有）。
NSInteger CCPetsCatalogSheetRowCount(size_t width, size_t height);

// 页码栏的 7 个位置（总页数不到 7 时全列出），元素是从 0 开始的页号，-1 表示省略号。
// 首页、末页常驻，当前页附近的连着排；位置数固定，翻页时整组宽度不变。
NSArray<NSNumber *> *CCPetsCatalogPageSlots(NSInteger count, NSInteger current);

// 热门榜条目：接口返回的 {slug, metrics: {installCount}} 和本地缓存的精简 {slug, installCount} 都认。
// 返回 @{slug, installCount}，保持原顺序；slug 是否安全由调用方再校验。
NSArray<NSDictionary *> *CCPetsCatalogPopularEntries(id body);

// 默认顺序：热门榜上的按名次排在最前（带上 installCount），其余保持清单原顺序。
NSArray<NSDictionary *> *CCPetsCatalogSortByPopularity(NSArray<NSDictionary *> *pets, NSArray<NSDictionary *> *popular);

// 安装量，写法同网站：↓12.9K、↓3K、↓956。没有数据返回空串。
NSString *CCPetsCatalogInstallText(NSDictionary *pet);
