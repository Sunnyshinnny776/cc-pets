#import <Foundation/Foundation.h>

// `cc-pets bridge <子命令>` 的入口。
//
// 面向用户：enable / configure / disable / status / list / send / name / inbox
// 面向 CLI 集成（由 hooks / MCP 配置调用）：hook / watch / mcp / notify-idle
// 面向安装流程：refresh / teardown
//
// arguments 不含 "bridge" 本身。返回进程退出码。
int CCBridgeCommandMain(NSArray<NSString *> *arguments);
