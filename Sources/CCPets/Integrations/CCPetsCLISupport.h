#import <Foundation/Foundation.h>

// 命令行子命令（安装 / 卸载集成、CC Bridge、doctor、pet）共用的小工具。
// 这些入口原先是 Node 脚本，行为上尽量对齐 Node：$HOME 可被覆盖、路径按 path.resolve 规则折叠、
// 文案参数用 {name} 占位。

void CCPetsPrintLine(FILE *stream, NSString *text);

// 非空的环境变量值，空字符串视同未设置（与 Node 里 `process.env.X || 默认值` 一致）。
NSString *CCPetsEnvironmentValue(NSString *name);

// 用 $HOME 而不是 NSHomeDirectory()：后者只看账户数据库，测试靠覆盖 HOME 做隔离。
NSString *CCPetsHomeDirectory(void);

// 对应 Node 的 path.resolve：补成绝对路径并折叠 . 和 ..，但不碰文件系统。
// 不用 stringByStandardizingPath：它会展开 ~，还会把 /private/tmp 改写成 /tmp。
NSString *CCPetsResolvePath(NSString *path);
NSString *CCPetsRealPath(NSString *path);
NSString *CCPetsShellQuote(NSString *value);
BOOL CCPetsDirectoryExists(NSString *path);
// home 开头的路径显示成 ~/…，输出常被贴进 issue。
NSString *CCPetsTildePath(NSString *path);

// 当前进程可执行文件的绝对路径（不解析软链）。
NSString *CCPetsExecutablePath(void);
long long CCPetsMilliseconds(void);

// 把译文里的 {name} 换成 values[name]，values 里没有的占位符原样保留。
// 写法：CCPetsInterpolate(L(@"Removed {name}."), @{@"name": name})，L() 里是表的 key。
NSString *CCPetsInterpolate(NSString *text, NSDictionary<NSString *, id> *values);

#pragma mark - 外部 CLI

// 生效的配置目录：CLAUDE_CONFIG_DIR / CODEX_HOME 指向哪里就是哪里（会话级，安装与 Bridge 都按它）。
NSString *CCPetsClaudeHome(void);
NSString *CCPetsCodexHome(void);
NSString *CCPetsShimDirectory(void);

// PATH 里真正的 codex / claude，跳过 cc-pets 自己的 shim 目录与 *-with-pet 包装器——安装完成后
// shim 排在 PATH 最前面，直接 which 只会命中自己。realBinVariable（CODEX_REAL_BIN 等）设置时直接用它。
NSString *CCPetsFindRealExecutable(NSString *name, NSString *realBinVariable);
// 同上，但在给定的 PATH 字符串里找（主窗口用登录 shell 的 PATH 代替自己的）。
NSString *CCPetsFindRealExecutableInPath(NSString *name, NSString *realBinVariable, NSString *searchPath);

// 用户登录 shell（-l -i，会加载 nvm 等 rc 配置）里的 PATH。Finder 拉起的 App 只有 launchd 的最小 PATH，
// 看不到终端里装的 CLI。会起一个子进程（最多等 5 秒），不要在主线程调；拿不到时返回 nil。
NSString *CCPetsLoginShellPath(void);

// 这台机器上有没有这家 CLI：配置目录已存在，或 PATH 里有真二进制。CC_PETS_ASSUME_CLI=1 或设置了
// CODEX_REAL_BIN / CLAUDE_REAL_BIN 时视为已安装（探测漏判时的逃生舱）。
BOOL CCPetsClaudeCLIInstalled(void);
BOOL CCPetsCodexCLIInstalled(void);

#pragma mark - 文件

// 先写同目录临时文件再 rename，中途失败不会留下半份文件；临时文件一创建就是目标权限。
BOOL CCPetsWriteFileAtomically(NSString *path, NSString *text, mode_t mode, NSString **errorMessage);

// 解析已有的 JSON 配置（保序，见 CCPetsJSON.h）。文件不存在返回 nil 且不设 errorMessage；
// 解析失败返回 nil 并给出原因；顶层不是对象时返回 NSNull。
id CCPetsReadConfig(NSString *path, NSString **errorMessage);

#pragma mark - 子进程

// 跑一个外部命令并收集输出。executable 不含 / 时按 PATH 查找。返回退出码；
// 启动失败（找不到、没权限）返回 CCPetsRunLaunchFailed，超时被杀返回 CCPetsRunTimedOut。
// environment 为 nil 时继承当前环境；directory 为 nil 时继承当前目录。
extern const int CCPetsRunLaunchFailed;
extern const int CCPetsRunTimedOut;
int CCPetsRun(NSString *executable, NSArray<NSString *> *arguments, NSString *directory,
    NSDictionary<NSString *, NSString *> *environment, NSTimeInterval timeout,
    NSString **output, NSString **errorOutput);

// 脱离当前会话在后台启动，不等待、不收集输出。
BOOL CCPetsSpawnDetached(NSString *executable, NSArray<NSString *> *arguments);
