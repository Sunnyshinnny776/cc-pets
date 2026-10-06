#import <Foundation/Foundation.h>

// 界面多语言。
//
// 源码里直接写英文原文，它同时就是查表的 key（gettext 的做法）：
// - 英文界面不查表，原样返回；
// - 其他语言查 <语言>.lproj/Localizable.strings，查不到就退回英文原文。
// 英文是源语言：漏翻的条目显示英文，比让别的语言用户看到某种第三语言好接受；
// 新语言也从英文译。代价是改了英文原文要同步改各语言表的 key，
// scripts/check-l10n.mjs 会把漏掉的报出来。
//
// 带参数的文案照常写 %@ / %ld；参数顺序和译文语序不同时，两边都用 %1$@ / %2$@ 标位置。
//
// 支持哪些语言不写在代码里：英文之外，有 <语言>.lproj/Localizable.strings 的就算支持。
// 新增一种语言只需加文件，见 CONTRIBUTING.md 的「多语言」一节。每张表除了界面文案，
// 还要带两条约定的元信息（键见下方常量）：语言自己的名字、Release 说明里对应段落的标题。

// 语言偏好（NSUserDefaults）：system 或某个支持的语言标识（en、zh-Hans…）。
extern NSString *const CCPetsLanguageKey;
extern NSString *const CCPetsLanguageSystem;
// 源语言，也是什么都匹配不上时的兜底。
extern NSString *const CCPetsSourceLanguage;
// 表里的元信息键。"Language Name" 的值是菜单里显示的语言名（用该语言自己的写法）；
// "Release Notes Section" 是 GitHub Release 里该语言段落的标题，有多种写法时用 | 隔开。
extern NSString *const CCPetsLanguageNameKey;
extern NSString *const CCPetsReleaseNotesSectionKey;
// 切换语言后发出；常驻的界面（状态卡、额度面板、编辑器）收到后重绘。菜单每次现建，不用管。
extern NSNotificationName const CCPetsLanguageDidChangeNotification;

// 支持的语言：源语言在最前，其余按标识排序。
NSArray<NSString *> *CCPetsSupportedLanguages(void);
// 菜单里显示的语言名。
NSString *CCPetsLanguageDisplayName(NSString *language);
// Release 说明里该语言段落可能的标题。
NSArray<NSString *> *CCPetsReleaseNotesSectionTitles(NSString *language);

NSString *CCPetsLanguagePreference(void);
void CCPetsSetLanguagePreference(NSString *preference);
// 实际生效的语言，一定在 CCPetsSupportedLanguages() 里。
// 环境变量 CC_PETS_LANGUAGE 优先（测试用，也方便临时切换），其次是偏好，最后跟随系统：
// 系统首选语言里第一个能匹配上的说了算，都匹配不上就用源语言。
NSString *CCPetsCurrentLanguage(void);
BOOL CCPetsLanguageIsSource(void);
// 按给定的支持列表解析，不读任何全局状态，测试用。匹配规则：先找完全一致或前缀一致的
// （zh-Hans-CN → zh-Hans），再退到只比主语言（zh-Hant → zh-Hans、ja_JP → ja）。
NSString *CCPetsResolveLanguageAmong(NSString *preference, NSArray<NSString *> *systemLanguages,
    NSArray<NSString *> *supported);

NSString *CCPetsLocalized(NSString *text) NS_FORMAT_ARGUMENT(1);
#define L(text) CCPetsLocalized(text)

// ~/.cc-pets/language（可用 CC_PETS_HOME 覆盖）。桌宠把实际生效的语言写在这里，
// Node 端的 cc-pets / hook / CC Bridge 据此输出同一种语言。
NSString *CCPetsLanguageFilePath(void);
void CCPetsWriteLanguageFile(void);
