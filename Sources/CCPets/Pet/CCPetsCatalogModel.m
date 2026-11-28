#import "CCPetsCatalogModel.h"

NSInteger CCPetsCatalogSheetRowCount(size_t width, size_t height) {
    if (!width || !height) return 9;
    double rows = (double)height * 8 * 192 / ((double)width * 208);
    return rows > 10 ? 11 : 9;
}

NSArray<NSNumber *> *CCPetsCatalogPageSlots(NSInteger count, NSInteger current) {
    NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
    if (count <= 0) return slots;
    current = MAX(0, MIN(current, count - 1));
    NSNumber *gap = @(-1);
    if (count <= 7) {
        for (NSInteger page = 0; page < count; page++) [slots addObject:@(page)];
    } else if (current <= 3) {
        for (NSInteger page = 0; page < 5; page++) [slots addObject:@(page)];
        [slots addObjectsFromArray:@[gap, @(count - 1)]];
    } else if (current >= count - 4) {
        [slots addObjectsFromArray:@[@0, gap]];
        for (NSInteger page = count - 5; page < count; page++) [slots addObject:@(page)];
    } else {
        [slots addObjectsFromArray:@[@0, gap, @(current - 1), @(current), @(current + 1), gap, @(count - 1)]];
    }
    return slots;
}

NSArray<NSDictionary *> *CCPetsCatalogPopularEntries(id body) {
    if (![body isKindOfClass:NSDictionary.class] || ![body[@"pets"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *entries = [NSMutableArray array];
    for (id pet in body[@"pets"]) {
        if (![pet isKindOfClass:NSDictionary.class] || ![pet[@"slug"] isKindOfClass:NSString.class]) continue;
        // 接口返回的在 metrics.installCount 里；本地缓存是精简过的，直接是 installCount。
        id metrics = pet[@"metrics"];
        id installs = [metrics isKindOfClass:NSDictionary.class] ? metrics[@"installCount"] : pet[@"installCount"];
        [entries addObject:@{@"slug": pet[@"slug"],
                             @"installCount": [installs isKindOfClass:NSNumber.class] ? installs : @0}];
    }
    return entries;
}

NSArray<NSDictionary *> *CCPetsCatalogSortByPopularity(NSArray<NSDictionary *> *pets, NSArray<NSDictionary *> *popular) {
    if (!popular.count) return pets;
    NSMutableDictionary<NSString *, NSDictionary *> *bySlug = [NSMutableDictionary dictionaryWithCapacity:pets.count];
    for (NSDictionary *pet in pets) bySlug[pet[@"slug"]] = pet;
    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:pets.count];
    NSMutableSet *ranked = [NSMutableSet set];
    for (NSDictionary *entry in popular) {
        NSDictionary *pet = bySlug[entry[@"slug"]];
        if (!pet || [ranked containsObject:entry[@"slug"]]) continue;
        NSMutableDictionary *copy = [pet mutableCopy];
        copy[@"installCount"] = entry[@"installCount"];
        [sorted addObject:copy];
        [ranked addObject:entry[@"slug"]];
    }
    for (NSDictionary *pet in pets) if (![ranked containsObject:pet[@"slug"]]) [sorted addObject:pet];
    return sorted;
}

NSString *CCPetsCatalogInstallText(NSDictionary *pet) {
    NSInteger count = [pet[@"installCount"] isKindOfClass:NSNumber.class] ? [pet[@"installCount"] integerValue] : 0;
    if (count <= 0) return @"";
    if (count < 1000) return [NSString stringWithFormat:@"↓%ld", (long)count];
    NSString *value = [NSString stringWithFormat:@"%.1f", count / 1000.0];
    if ([value hasSuffix:@".0"]) value = [value substringToIndex:value.length - 2];
    return [NSString stringWithFormat:@"↓%@K", value];
}
