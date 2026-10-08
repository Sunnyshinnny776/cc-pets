#import <Foundation/Foundation.h>

#ifndef CC_PETS_VERSION
#define CC_PETS_VERSION "unknown"
#endif

// 只接受严格的三段纯数字版本号；valid 为 NO 时返回值无意义。
// 自动更新会把比较结果作为是否升级的唯一依据，所以这里刻意不接受预发布号。
NSComparisonResult CompareStableVersions(NSString *left, NSString *right, BOOL *valid);
int RestartAfterPID(pid_t pid, NSString *appPath, BOOL managed);

// npm 安装日志里是否只是暂时性故障（值得自动重试一次），而不是真的装不上。
BOOL UpdateFailureIsTransient(NSString *log);

// 从 GitHub Release 描述里摘出更新要点，给更新弹窗用。Release 是多语言的：
// 有当前语言的标题段（英文是「English」，其他语言见各自表里的 "Release Notes Section"）
// 就只看那一段，没有对应段落时看全文。只取列表项，去掉 Markdown 标记，代码块整段跳过。
// 每条超过 maxLength 个字符截断加「…」；超过 limit 条时只返回前 limit 条并把 *truncated 置 YES。
// 没有列表项返回空数组——没写说明就不展示，不去猜正文。
// language 是 CCPetsSupportedLanguages() 里的某一种（见 CCPetsL10n.h）。
NSArray<NSString *> *ReleaseNoteHighlightsForLanguage(NSString *body, NSString *language,
    NSUInteger limit, NSUInteger maxLength, BOOL *truncated);
