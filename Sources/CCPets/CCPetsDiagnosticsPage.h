#import <Cocoa/Cocoa.h>

// 主窗口的「诊断」页：渲染 `cc-pets doctor` 的同一套检查（CCPetsDoctorSectionsForApp：PATH 顺序那一项
// 在桌宠进程里看不准，改成去终端确认的提示，其余相同）。
// 要处理的问题置顶，每条带修复命令；正常项折叠成一行。
//
// v1 只读：修复建议给出命令让用户自己复制执行，不在这里改 shell / 配置。
@interface CCPetsDiagnosticsPage : NSViewController
@end

// 检查结果的缓存，诊断页、侧边栏角标、概览的提醒共用一份。检查要读配置、探测 CLI，在后台队列做；
// 主窗口打开时检查一次（结果十分钟内算新鲜），之后只有点"重新检查"才再跑，不开定时器。
extern NSNotificationName const CCPetsDiagnosticsDidChangeNotification;
@interface CCPetsDiagnosticsStore : NSObject
// 还没检查过时为 nil。
@property(class, nonatomic, readonly) NSArray<NSDictionary *> *sections;
@property(class, nonatomic, readonly) BOOL running;
@property(class, nonatomic, readonly) NSDate *checkedAt;
// warn + fail 的条数：侧边栏角标和概览提醒的数字。
@property(class, nonatomic, readonly) NSUInteger issueCount;
+ (void)refreshIfStale;
+ (void)refresh;
@end
