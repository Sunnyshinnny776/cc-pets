#import <Foundation/Foundation.h>

// `cc-pets open [page]`：从终端打开主窗口并定位到页面。
//
// 桌宠已在运行：发分布式通知，由它开窗。不能借 reopen 事件——每个终端启动 CLI 都会
// `open -g` 一次桌宠，借它开窗会让每开一个终端就弹一次主窗口。
// 桌宠没在运行：不带 -g 地启动 App 并传 `--open-window [page]`，起来后自己开窗。
//
// arguments 是 "open" 之后的参数。返回进程退出码。
int CCPetsOpenMain(NSArray<NSString *> *arguments);

// 通知名带 uid：同一台机器上多个用户会话各有各的桌宠，别互相开窗。userInfo 的 page 为空串表示上次的页面。
NSString *CCPetsOpenWindowNotificationName(void);
