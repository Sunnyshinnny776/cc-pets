#import <Cocoa/Cocoa.h>

// app 内置的台词编辑器。
//
// 为什么不用系统默认编辑器（原来是 openURL: 交给"文本编辑"）：那条路没有任何反馈。
// 用户改完保存、桌宠照旧，他无从知道是小节名拼错了、还是句子超了 30 字、还是槽位
// 写错了名字——这些全都是静默失效。编辑器存在的唯一理由就是把校验结果当场摆出来。
@interface PetPhrasesEditorController : NSWindowController

// 打开（已开着就前置）。窗口是单例，避免两个窗口各自编辑同一个文件互相覆盖。
+ (void)present;

// "试说一句"回调：把选中情境的一条台词交给桌宠当场说出来。
// 编辑器不认识气泡，也不该认识——它只负责给出文本。
+ (void)setSpeakHandler:(void (^)(NSString *text))handler;

@end
