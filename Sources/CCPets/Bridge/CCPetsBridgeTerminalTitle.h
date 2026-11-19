#import <Foundation/Foundation.h>
#import <sys/types.h>

BOOL CCBridgeTerminalTitleEnabled(void);
// The launch token binds a local terminal to the exact conversation registered by its hook.
void CCBridgeBindTerminalTitle(NSString *launchToken, NSString *provider, NSString *sessionID);
void CCBridgeBindTerminalTitleIfUnbound(NSString *launchToken, NSString *provider, NSString *sessionID);
void CCBridgeClearTerminalTitleBinding(NSString *launchToken);
NSString *CCBridgeTerminalTitleName(NSString *provider, NSString *launchToken, pid_t childPID);
NSString *CCBridgeTerminalTitleNameForSession(NSString *sessionID, NSString *provider);
NSString *CCBridgeComposeTerminalTitle(NSString *base, NSString *nickname);
int CCBridgePrintAntigravityTitle(NSString *originalTitle);
