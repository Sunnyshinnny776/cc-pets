#import "CCPetsUsage+Internal.h"
#import "CCPetsPaths.h"
#import <sqlite3.h>

// 只补没有持久化会话的线程。不能把运行日志和 rollout 相加：同一次响应会同时出现
// 在两处，而且后台日志只给累计总量，没有可靠的输入、输出拆分。
static NSString *BackgroundMatch(NSString *text, NSString *pattern) {
    static NSMutableDictionary<NSString *, NSRegularExpression *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ patterns = [NSMutableDictionary dictionary]; });
    NSRegularExpression *regex;
    @synchronized (patterns) {
        regex = patterns[pattern];
        if (!regex) {
            regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            if (regex) patterns[pattern] = regex;
        }
    }
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0
        range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

static NSString *BackgroundColumn(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

static sqlite3 *BackgroundOpen(NSString *path) {
    sqlite3 *db = NULL;
    // 不创建数据库、不设置 journal_mode，也不执行任何写 SQL。
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, 100);
    return db;
}

static void BackgroundCoveredThreads(NSString *home, NSMutableDictionary *covered, double now) {
    // state 索引能在 rollout 尚未写完时排除主会话；归档/旧版本还要从文件名补齐。
    sqlite3 *db = BackgroundOpen([home stringByAppendingPathComponent:@"state_5.sqlite"]);
    sqlite3_stmt *statement = NULL;
    if (db && sqlite3_prepare_v2(db, "SELECT id FROM threads", -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSString *thread = BackgroundColumn(statement, 0);
            if (thread.length) covered[thread] = @(now);
        }
    }
    sqlite3_finalize(statement);
    if (db) sqlite3_close(db);
    for (NSString *directory in @[@"sessions", @"archived_sessions"]) {
        NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:
            [NSURL fileURLWithPath:[home stringByAppendingPathComponent:directory]]
            includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *file in files) {
            if (![file.pathExtension isEqualToString:@"jsonl"]) continue;
            NSString *thread = BackgroundMatch(file.lastPathComponent,
                @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.jsonl$");
            if (thread) covered[thread.lowercaseString] = @(now);
        }
    }
}

NSDictionary *CodexBackgroundModelDays(NSString *home, NSTimeInterval start, NSTimeInterval end) {
    NSString *path = TokenSummaryCachePath(@"codex-background", home);
    NSMutableDictionary *cache = LoadTokenSummaryCache(path);
    NSMutableDictionary *events = [cache[@"events"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *covered = [cache[@"covered"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *cursor = cache[@"cursor"] ?: @{};
    double now = NSDate.date.timeIntervalSince1970;
    // 与用量页 90 天窗口一致，留 10 天余量；先采集所有仍保留的记录，再做日桶切片。
    double retentionStart = now - 100 * 86400.0;
    BackgroundCoveredThreads(home, covered, now);
    NSString *dbPath = [home stringByAppendingPathComponent:@"logs_2.sqlite"];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:dbPath error:nil];
    NSString *identity = [NSString stringWithFormat:@"%@/%@", attributes[NSFileSystemNumber],
        attributes[NSFileSystemFileNumber]];
    sqlite3 *db = BackgroundOpen(dbPath);
    if (db) {
        sqlite3_stmt *statement = NULL;
        sqlite3_int64 maximum = 0;
        BOOL hasMaximum = NO;
        if (sqlite3_prepare_v2(db, "SELECT MAX(id) FROM logs", -1, &statement, NULL) == SQLITE_OK &&
                sqlite3_step(statement) == SQLITE_ROW) {
            maximum = sqlite3_column_int64(statement, 0);
            hasMaximum = YES;
        }
        sqlite3_finalize(statement);
        statement = NULL;
        sqlite3_int64 lastID = [cursor[@"id"] longLongValue];
        if (![cursor[@"identity"] isEqual:identity] || maximum < lastID) lastID = 0;
        // MAX(id) 给这一批固定上界。按主键推进，不为每次刷新扫描全部运行日志。
        // 首次扫描虽有时间过滤，但不假设 ts 有索引。
        const char *sql = "SELECT id, ts, ts_nanos, feedback_log_body, thread_id FROM logs "
            "WHERE id > ? AND id <= ? AND ts >= ? "
            "AND feedback_log_body LIKE '%post sampling token usage%' ORDER BY id";
        if (hasMaximum && sqlite3_prepare_v2(db, sql, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(statement, 1, lastID);
            sqlite3_bind_int64(statement, 2, maximum);
            sqlite3_bind_double(statement, 3, retentionStart);
            int status;
            while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
                @autoreleasepool {
                    NSString *body = BackgroundColumn(statement, 3) ?: @"";
                    NSString *thread = BackgroundMatch(body, @"thread_id=\"?([0-9a-fA-F-]{36})")
                        ?: BackgroundColumn(statement, 4);
                    NSString *turn = BackgroundMatch(body, @"turn_id=\"?([0-9a-fA-F-]{36})");
                    NSString *total = BackgroundMatch(body, @"total_usage_tokens=([0-9]+)");
                    NSString *model = BackgroundMatch(body, @"\\bmodel=\"?([^\\s\"}]+)");
                    if (!thread.length || !turn.length || !total.length) continue;
                    thread = thread.lowercaseString;
                    if (covered[thread]) continue;
                    // 同一轮可多次采样，甚至重置后回到相同累计值，不能只用 turn/total 去重。
                    // 时间戳标识一次采样；重复累计快照稍后求差为 0，不增加请求数。
                    NSString *key = [NSString stringWithFormat:@"%@/%@/%lld/%lld/%@", thread, turn,
                        sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2), total];
                    if (events[key]) continue;
                    events[key] = @{@"thread": thread, @"turn": turn,
                        @"model": model ?: @"unknown", @"total": @([total longLongValue]),
                        @"timestamp": @(sqlite3_column_double(statement, 1) +
                            sqlite3_column_double(statement, 2) / 1e9),
                        @"id": @(sqlite3_column_int64(statement, 0))};
                }
            }
            // 锁冲突/读取失败时不推进游标；已经读到的事件有稳定标识，重读不会重复计算。
            if (status == SQLITE_DONE) cache[@"cursor"] = @{@"id": @(maximum), @"identity": identity};
        }
        sqlite3_finalize(statement);
        sqlite3_close(db);
    }
    for (NSString *key in covered.allKeys) {
        if ([covered[key] doubleValue] < retentionStart) [covered removeObjectForKey:key];
    }
    // 长期运行的临时线程跨越保留边界时，保留边界前最后一个快照作基线，
    // 否则删掉旧快照会把新窗口首条累计值误当成全部新增量。
    NSMutableSet *recentThreads = [NSMutableSet set];
    NSMutableDictionary *baselineKeys = [NSMutableDictionary dictionary];
    for (NSString *key in events.allKeys) {
        NSDictionary *event = events[key];
        NSString *thread = event[@"thread"];
        if (covered[thread]) { [events removeObjectForKey:key]; continue; }
        if ([event[@"timestamp"] doubleValue] >= retentionStart) [recentThreads addObject:thread];
        else {
            NSString *oldKey = baselineKeys[thread];
            if (!oldKey || [event[@"timestamp"] doubleValue] > [events[oldKey][@"timestamp"] doubleValue]) {
                baselineKeys[thread] = key;
            }
        }
    }
    for (NSString *key in events.allKeys) {
        NSDictionary *event = events[key];
        NSString *thread = event[@"thread"];
        if ([event[@"timestamp"] doubleValue] < retentionStart &&
            !([recentThreads containsObject:thread] && [baselineKeys[thread] isEqual:key])) {
            [events removeObjectForKey:key];
        }
    }
    cache[@"events"] = events;
    cache[@"covered"] = covered;
    SaveTokenSummaryCache(cache, path);

    NSArray *ordered = [events.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"timestamp"] compare:b[@"timestamp"]];
        return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
    }];
    NSMutableDictionary *previous = [NSMutableDictionary dictionary];
    NSMutableDictionary *days = [NSMutableDictionary dictionary];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    for (NSDictionary *event in ordered) {
        NSString *thread = event[@"thread"];
        if (covered[thread]) continue;
        unsigned long long total = [event[@"total"] unsignedLongLongValue];
        unsigned long long baseline = [previous[thread] unsignedLongLongValue];
        previous[thread] = @(total);
        unsigned long long delta = total >= baseline ? total - baseline : total;
        double timestamp = [event[@"timestamp"] doubleValue];
        // 留 10 秒等主会话文件/索引落盘，下一轮刷新再展示，不提前把它冒充后台用量。
        if (!delta || timestamp < start || timestamp >= end || timestamp > now - 10) continue;
        NSDateComponents *date = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
            fromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
        NSString *day = [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)date.year, (long)date.month, (long)date.day];
        NSMutableDictionary *models = days[day];
        if (!models) { models = [NSMutableDictionary dictionary]; days[day] = models; }
        NSString *model = event[@"model"];
        NSMutableDictionary *counts = models[model];
        if (!counts) { counts = [NSMutableDictionary dictionary]; models[model] = counts; }
        counts[@"background"] = @([counts[@"background"] unsignedLongLongValue] + delta);
        counts[@"requests"] = @([counts[@"requests"] unsignedLongLongValue] + 1);
    }
    return days;
}
