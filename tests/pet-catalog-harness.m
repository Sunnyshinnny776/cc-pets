#import <Foundation/Foundation.h>
#import "CCPetsCatalogModel.h"

// 在线宠物目录的纯逻辑：精灵图行数、页码位置、热门榜解析与排序、安装量文案。

static int failures = 0;

static void Expect(BOOL condition, NSString *message) {
    if (condition) return;
    failures++;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

static NSString *Slots(NSInteger count, NSInteger current) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSNumber *slot in CCPetsCatalogPageSlots(count, current)) {
        [parts addObject:slot.integerValue < 0 ? @"…" : [NSString stringWithFormat:@"%ld", (long)slot.integerValue + 1]];
    }
    return [parts componentsJoinedByString:@" "];
}

static void ExpectSlots(NSInteger count, NSInteger current, NSString *expected) {
    NSString *actual = Slots(count, current);
    Expect([actual isEqualToString:expected], [NSString stringWithFormat:@"页码 %ld/%ld：期望 %@，实际 %@",
        (long)current + 1, (long)count, expected, actual]);
}

int main(void) {
    @autoreleasepool {
        // v1 9 行、v2 11 行；Petdex 卡片小图（1 行）不会被误判成 11 行；尺寸缺失时按 9 行。
        Expect(CCPetsCatalogSheetRowCount(1536, 1872) == 9, @"1536×1872 应为 9 行");
        Expect(CCPetsCatalogSheetRowCount(1536, 2288) == 11, @"1536×2288 应为 11 行");
        Expect(CCPetsCatalogSheetRowCount(768, 936) == 9, @"缩小一半的 v1 仍为 9 行");
        Expect(CCPetsCatalogSheetRowCount(768, 1144) == 11, @"缩小一半的 v2 仍为 11 行");
        Expect(CCPetsCatalogSheetRowCount(0, 0) == 9, @"尺寸缺失时按 9 行");

        // 页码：页数不多时全列出；多时固定 7 个位置，首末页常驻。
        Expect(CCPetsCatalogPageSlots(0, 0).count == 0, @"没有结果时不显示页码");
        ExpectSlots(1, 0, @"1");
        ExpectSlots(7, 6, @"1 2 3 4 5 6 7");
        ExpectSlots(214, 0, @"1 2 3 4 5 … 214");
        ExpectSlots(214, 3, @"1 2 3 4 5 … 214");
        ExpectSlots(214, 4, @"1 … 4 5 6 … 214");
        ExpectSlots(214, 8, @"1 … 8 9 10 … 214");
        ExpectSlots(214, 209, @"1 … 209 210 211 … 214");
        ExpectSlots(214, 210, @"1 … 210 211 212 213 214");
        ExpectSlots(214, 213, @"1 … 210 211 212 213 214");
        ExpectSlots(214, 999, @"1 … 210 211 212 213 214");
        for (NSInteger count = 8; count <= 40; count++) {
            for (NSInteger current = 0; current < count; current++) {
                NSArray *slots = CCPetsCatalogPageSlots(count, current);
                Expect(slots.count == 7, [NSString stringWithFormat:@"%ld 页第 %ld 页应固定 7 个位置",
                    (long)count, (long)current + 1]);
                Expect([slots containsObject:@(current)], [NSString stringWithFormat:@"%ld 页第 %ld 页应包含当前页",
                    (long)count, (long)current + 1]);
            }
        }

        // 热门榜：接口格式和本地缓存格式读出来的安装量一致（缓存读回不能变成 0）。
        id api = @{@"pets": @[
            @{@"slug": @"boba", @"metrics": @{@"installCount": @12858}},
            @{@"slug": @"lulu", @"metrics": @{@"installCount": @5580}},
            @{@"slug": @"broken"},
            @"not a pet",
        ]};
        NSArray *entries = CCPetsCatalogPopularEntries(api);
        Expect(entries.count == 3, @"接口格式应解析出 3 条");
        Expect([entries[0][@"installCount"] isEqual:@12858], @"接口格式应读出 metrics.installCount");
        Expect([entries[2][@"installCount"] isEqual:@0], @"没有安装量时记为 0");
        NSData *cached = [NSJSONSerialization dataWithJSONObject:@{@"pets": entries} options:0 error:nil];
        NSArray *reread = CCPetsCatalogPopularEntries([NSJSONSerialization JSONObjectWithData:cached options:0 error:nil]);
        Expect([reread isEqualToArray:entries], @"缓存写出再读回应与原数据一致");
        Expect(CCPetsCatalogPopularEntries(@[]) == nil, @"格式不对时返回 nil");

        // 排序：热门榜按名次在前并带上安装量，其余保持清单顺序；榜上但清单里没有的跳过。
        NSArray *manifest = @[@{@"slug": @"a"}, @{@"slug": @"lulu"}, @{@"slug": @"b"}, @{@"slug": @"boba"}];
        NSArray *popular = @[@{@"slug": @"boba", @"installCount": @12858}, @{@"slug": @"gone", @"installCount": @9},
                             @{@"slug": @"lulu", @"installCount": @5580}, @{@"slug": @"boba", @"installCount": @1}];
        NSArray *sorted = CCPetsCatalogSortByPopularity(manifest, popular);
        Expect([[sorted valueForKey:@"slug"] isEqualToArray:@[@"boba", @"lulu", @"a", @"b"]], @"热门在前，其余保持原顺序");
        Expect([sorted[0][@"installCount"] isEqual:@12858], @"热门条目带上安装量，重复条目以第一次为准");
        Expect(sorted[2][@"installCount"] == nil, @"不在榜上的不带安装量");
        Expect(CCPetsCatalogSortByPopularity(manifest, nil) == manifest, @"没有热门榜时保持清单原顺序");

        // 安装量文案。
        Expect([CCPetsCatalogInstallText(@{}) isEqualToString:@""], @"没有安装量时为空");
        Expect([CCPetsCatalogInstallText(@{@"installCount": @956}) isEqualToString:@"↓956"], @"千以下原样显示");
        Expect([CCPetsCatalogInstallText(@{@"installCount": @3000}) isEqualToString:@"↓3K"], @"整千去掉 .0");
        Expect([CCPetsCatalogInstallText(@{@"installCount": @12858}) isEqualToString:@"↓12.9K"], @"保留一位小数");
    }
    if (failures) return EXIT_FAILURE;
    printf("在线宠物目录逻辑测试通过\n");
    return EXIT_SUCCESS;
}
