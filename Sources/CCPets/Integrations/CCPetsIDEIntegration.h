#import <Cocoa/Cocoa.h>

// Snapshot (disk + authenticated loopback queries): call off the main thread.
// state: connected / installed / pendingRestart / outdated / missing / disabled / unsupported.
// autoInstall is YES when the plugin folder is known well enough to install into it.
NSArray<NSDictionary *> *CCPetsIDEIntegrationSnapshot(void);
// Installs or updates the bundled plugin into one snapshot row's plugin folder. Blocking.
BOOL CCPetsInstallIDEPlugin(NSDictionary *ide, NSError **error);
// Confirms, installs in the background and reports failures; falls back to the manual
// installer when autoInstall is NO. completion runs on the main thread.
void CCPetsPromptInstallIDEPlugin(NSDictionary *ide, void (^completion)(void));
// Schedules exact focus without blocking AppKit. NO means this is not a JetBrains IDE target.
BOOL CCPetsRequestIDETerminalFocus(NSDictionary *target);
// Reveals the bundled ZIP and explains the IDE's own install-from-disk workflow.
void CCPetsShowIDEPluginInstaller(void);

// Shared with other IDE bridges (VS Code). Registrations live in
// ~/Library/Application Support/CC Pets/ide-instances/; accept filters validated records
// whose pid belongs to a running app at record[@"appPath"]. Both block: call off main.
NSArray<NSDictionary *> *CCPetsIDEBridgeInstances(BOOL (^accept)(NSDictionary *record, NSRunningApplication *app));
NSDictionary *CCPetsIDEBridgeRequest(NSDictionary *instance, NSString *route, NSDictionary *body);
