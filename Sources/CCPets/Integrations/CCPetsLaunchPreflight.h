#import <Foundation/Foundation.h>

// 包装器在登记会话、发送 starting 和启动桌宠之前调用。
// 开关关闭时直接返回 0；检查失败时向 stderr 给出原因并返回非零。
int CCPetsLaunchPreflight(NSString *provider, NSArray<NSString *> *arguments);
