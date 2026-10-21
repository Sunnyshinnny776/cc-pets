#import <Foundation/Foundation.h>

// Agent 事件的记录与状态归一化，同时是 --hook / --provider-event 两个子命令的实现。
NSString *SanitizedShortString(id value, NSUInteger maximumLength);
NSString *ProviderFromEnvironment(void);
NSString *NormalizedStateForEvent(NSString *event, BOOL failed);
// 在线会话的 key：provider + 账号 + tty。同一个终端先后跑过两个账号时，只看 provider + tty
// 会让已退出账号的记录借着另一个账号的 pid 文件一直"在线"。老版本 pid 文件没有账号，传空。
NSString *OnlineAgentSessionKey(id provider, id profileID, id tty);
// 会话列表展示用的状态：SessionStart 之后超过宽限仍无后续事件，按待机展示。
NSString *SessionDisplayState(NSString *state, NSTimeInterval timestamp, NSTimeInterval now);
BOOL AppendAgentEventRecord(NSDictionary *record);
BOOL HookValueIndicatesFailure(id value);
int RecordHookEvent(void);
int RecordProviderEvent(void);
