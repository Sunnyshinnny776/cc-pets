#import <Cocoa/Cocoa.h>

// VS Code and its forks (Cursor, Windsurf, VSCodium, …) via the bundled CC Pets Terminal
// extension. A fork is recognised by Contents/Resources/app/product.json, not by bundle ID.

// YES for an installed app of the VS Code family. Cheap enough for the main thread.
BOOL CCPetsBundleIsVSCodeFamily(NSString *bundleID);

// Snapshot (disk + authenticated loopback queries): call off the main thread.
// state: connected / installed / pendingRestart / outdated / missing / disabled / unsupported.
// autoInstall is YES when the app ships its command line tool, which does the install.
NSArray<NSDictionary *> *CCPetsVSCodeIntegrationSnapshot(void);
// Installs or updates the bundled VSIX through the app's own CLI. Blocking.
BOOL CCPetsInstallVSCodeExtension(NSDictionary *app, NSError **error);
// Confirms, installs in the background and reports failures; falls back to the manual
// installer when autoInstall is NO. completion runs on the main thread.
void CCPetsPromptInstallVSCodeExtension(NSDictionary *app, void (^completion)(void));
// Reveals the bundled VSIX and explains "Install from VSIX…".
void CCPetsShowVSCodeExtensionInstaller(NSString *appName);

// Exact focus for a VS Code family target. NO when no connected window of that app could
// own the terminal, so the caller falls back to bringing the app forward.
BOOL CCPetsRequestVSCodeTerminalFocus(NSDictionary *target);
