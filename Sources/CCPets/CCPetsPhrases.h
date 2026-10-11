#import <Foundation/Foundation.h>

// 桌宠说的话。全部来自用户词库文件，代码里不再留一份内置词库。
//
// 这一层刻意和"怎么显示""什么时候说"完全分开：取句子是一个纯函数式的接口，
// 以后换成大模型生成只是换掉这里的实现，气泡和触发逻辑一个字都不用动。
//
// 语义只有一条：**文件里有什么就说什么**。没有合并、没有 replace、没有兜底。
// 删掉一节就是那个情境不吭声。这样用户看到的文件就是桌宠的全部台词，
// 不存在"我明明删了它还在说"这种解释不清的状态。

// 情境标签。**这是发布给用户的稳定契约**，用户词库按它分组，不要随版本改名，
// 否则别人写好的词库会静默失效。
extern NSString *const PetPhraseTagDone;         // 任务完成
extern NSString *const PetPhraseTagFail;         // 任务失败
extern NSString *const PetPhraseTagQuotaLow;     // 额度告急
extern NSString *const PetPhraseTagLateNight;    // 深夜
extern NSString *const PetPhraseTagLongSession;  // 久坐
extern NSString *const PetPhraseTagWake;         // 久别重逢
extern NSString *const PetPhraseTagIdle;         // 闲着
extern NSString *const PetPhraseTagClickHeart;   // 连击后开心
extern NSString *const PetPhraseTagClickAnnoyed; // 连击过多后烦躁

// Agent 状态的宠物口吻文案。这些不是"额外说话"，而是状态卡副行的正文来源——
// 每个 hook 状态都由宠物来讲，所以不受说话预算限制。
// 前缀 state_ 是为了和上面那组情绪标签分开：情绪句会在关键时刻顶掉常规状态文案。
extern NSString *const PetPhraseTagStateStarting;
extern NSString *const PetPhraseTagStateIdle;
extern NSString *const PetPhraseTagStateThinking;
extern NSString *const PetPhraseTagStateAutoReview;
extern NSString *const PetPhraseTagStateApproval;
extern NSString *const PetPhraseTagStateSubagent;
extern NSString *const PetPhraseTagStateTool;      // 说不清是哪类工具时的兜底
extern NSString *const PetPhraseTagStateToolBash;  // 执行命令
extern NSString *const PetPhraseTagStateToolEdit;  // 编辑文件
extern NSString *const PetPhraseTagStateToolRead;  // 查找资料
extern NSString *const PetPhraseTagStateToolDone;
extern NSString *const PetPhraseTagStateToolFailed;
extern NSString *const PetPhraseTagStateCompleted;
extern NSString *const PetPhraseTagStateFailed;
extern NSString *const PetPhraseTagStateNotification;

// 全部标签，按模板里的出现顺序。校验器和"缺了哪节"的提示都靠它。
NSArray<NSString *> *PetPhraseAllTags(void);
// state_ 那组。它们是状态卡副行的唯一来源，每节至少要留一句，空了就拦下不给保存。
NSArray<NSString *> *PetPhraseStateTags(void);
// 标签的中文说明，给校验提示用（"缺少 [state_thinking]（正在思考）"）。
NSString *PetPhraseTagDescription(NSString *tag);

// 用户词库路径：~/.cc-pets/speech.txt。可用 CC_PETS_PHRASES_FILE 覆盖（测试用）。
//
// 纯文本而不是 JSON：普通用户写不了 JSON，而且少个逗号整个文件失效、我们静默降级，
// 用户只会觉得"改了没用"。纯文本一行一句，写错只丢那一行。
NSString *PetPhrasesFilePath(void);

// 宠物专属词库。通用词库（上面那个 speech.txt）是所有宠物的兜底，某只宠物想换口吻时，
// 在 ~/.cc-pets/speech/<petKey>.txt 里**只写想改的小节**，没写的照旧用通用的。
//
// 回落按小节（tag）整体做，不按行合并：专属文件里写了 [idle] 就只说专属那几句，
// 通用的那节一句都不参与。这和"文件里有什么就说什么"是同一条语义，只是多了一层。
// 小节写了标签但底下空着，表示这只宠物在这个情境闭嘴——所以判据是"这一节在不在"，
// 不是"这一节有没有内容"。
//
// 专属目录：~/.cc-pets/speech/。可用 CC_PETS_PHRASES_PET_DIR 覆盖（测试用）。
NSString *PetPhrasesPetDirectory(void);
// petID（builtin:默认.webp / external:哆啦A梦）转成文件名用的 key。
//
// petID 里的冒号、素材名里的斜杠都不能直接进文件名，内置素材的 .webp 后缀留着也只是
// 噪音，所以统一规整成 builtin-默认 / external-哆啦A梦。中文原样保留——用户要能在
// Finder 里一眼认出哪份是哪只的，转义成百分号编码就白瞎了。
NSString *PetPhrasesKeyForPetID(NSString *petID);
// 某只宠物的专属词库路径。petID 为空返回 nil。
NSString *PetPhrasesFilePathForPetID(NSString *petID);

// 全局台词来源偏好，切换宠物和重启后仍保留。未设置时保持原来的专属优先行为。
// 专属模式按小节回落到通用词库；默认模式只读通用词库，不改写任何台词文件。
extern NSString *const PetPhrasesSourcePet;
extern NSString *const PetPhrasesSourceDefault;
NSString *PetPhrasesSource(void);
void PetPhrasesSetSource(NSString *source);

// 当前是哪只宠物。取词层本来是纯函数，这里是唯一的外部状态——桌宠启动和每次切换
// 宠物时由 AppDelegate 推进来。做成 setter 而不是让 PetPhraseForTag 多带一个参数：
// 说话的调用点散在十几处，每处都传一遍 petID 只会让人漏传，而漏传的表现是"专属台词
// 偶尔不生效"，最难查。
void PetPhrasesSetCurrentPetID(NSString *petID);
NSString *PetPhrasesCurrentPetID(void);
// 当前宠物的专属词库路径。还没设过宠物时返回 nil。
NSString *PetPhrasesCurrentPetFilePath(void);
// 默认词库路径：app bundle 里当前语言的 phrases.default.<语言>.txt，没有就用英文那份。
// 可用 CC_PETS_PHRASES_DEFAULT_FILE 覆盖（测试用）。
NSString *PetPhrasesDefaultFilePath(void);
// 用户词库不存在就从默认词库拷一份出来。返回是否可用。
//
// 默认词库是一个随 app 打包的文本文件，不是代码里的字典：默认台词只在"生成文件"
// 这一刻出现一次，之后运行时只认用户文件。两份词库同时存在于运行期就必然要回答
// "以谁为准"，那正是 merge/replace 那套让人看不懂的根源。
BOOL PetPhrasesEnsureFileExists(void);
// 用户词库和"另一种语言"的默认词库一字不差（也就是从没改过）时，换成当前语言的默认词库。
// 改过一个字都不动：那是用户自己的台词，语言切换不该替他做主。返回是否替换了。
BOOL PetPhrasesAdoptLanguageDefaults(void);
// 给升级用户补一次新加入的连击互动小节；已有小节（包括用户主动留空）绝不覆盖。
BOOL PetPhrasesEnsureInteractionSections(void);

// 取一条填好槽位的话。取不到返回 nil（调用方应当直接不说话，而不是显示占位符）。
// slots 的键是白名单里的槽位名（不含花括号），值统一按字符串处理。
NSString *PetPhraseForTag(NSString *tag, NSDictionary<NSString *, NSString *> *slots);
// 从一段还没保存的文本里取某个标签的一条，供编辑器的"试说一句"用。
NSString *PetPhraseForTagInText(NSString *tag, NSString *text,
    NSDictionary<NSString *, NSString *> *slots);

// 允许出现在模板里的槽位。白名单制：没列在这里的一律原样留着，不做替换。
NSArray<NSString *> *PetPhraseSlotNames(void);

// 单条模板的长度上限（字符）。超了直接丢弃——气泡布局撑不下，
// 与其截断出半句话不如不说。
// 含中日韩字符的句子按 PetPhraseMaxLength，纯拉丁文字的按 PetPhraseMaxLatinLength。
extern const NSUInteger PetPhraseMaxLength;
extern const NSUInteger PetPhraseMaxLatinLength;
NSUInteger PetPhraseMaxLengthForText(NSString *text);

// 校验结果的一条。
typedef NS_ENUM(NSInteger, PetPhraseIssueLevel) {
    // 提示：可以保存，只是有一部分不会生效或情境会静默。
    PetPhraseIssueLevelWarning = 0,
    // 错误：拦下不给保存。目前只有一种——state_ 小节空了。
    PetPhraseIssueLevelError = 1,
};

@interface PetPhraseIssue : NSObject
@property(nonatomic) NSInteger line;   // 1 起。0 表示不针对具体某一行
@property(nonatomic) PetPhraseIssueLevel level;
@property(nonatomic, copy) NSString *message;
@end

// 把被删掉的标签行补回原位。返回补好的文本，restored 带回补了哪些标签（按文件顺序）。
//
// 标签删掉之后，用户在编辑器里看不到任何线索——他既不知道少的是哪一个，也不知道该写成
// 什么样。光报错等于把人卡死在那儿，所以保存时直接补回去，再告诉他补了什么。
//
// 补的位置有讲究：标签被删而台词还在时，那串台词会变成"不在任何 [情境] 下面"的散句，
// 标签必须插回那串散句的**前面**，它们才会重新归位；插到别处的话台词就真的丢了。
// restored 可以传 NULL。
NSString *PetPhraseTextWithRestoredTags(NSString *text, NSArray<NSString *> **restored);

// 校验一段文本。保存时调用，不做实时校验——边打边标红只会干扰输入。
// 这是通用词库的规则：22 个标签一个都不能少，state_ 那组还必须留一句。
NSArray<PetPhraseIssue *> *PetPhraseValidateText(NSString *text);
// 专属词库的校验。规则松得多：缺小节是正常状态（缺就回落到通用），所以"标签不能删"
// 和"state_ 至少留一句"这两条一律不适用。留下的只有逐行的那些——超长、槽位拼错、
// 小节名写错、散句无处安放。
//
// 不共用一个函数是因为两边的"错误"含义相反：专属文件只写一节是常态，套通用规则的话
// 用户想改一句话就得先抄一整份 22 节的文件过来。
NSArray<PetPhraseIssue *> *PetPhraseValidateTextForPet(NSString *text);

// 这段文本里有没有 [tag] 这一节。编辑器判断"专属文件是否接管了这个情境"用，
// 判据和取词一致：标签在就算接管，底下有没有台词不影响。
BOOL PetPhraseTextContainsTag(NSString *text, NSString *tag);
// 有没有致命错误。有就不能保存。
BOOL PetPhraseIssuesHaveError(NSArray<PetPhraseIssue *> *issues);
