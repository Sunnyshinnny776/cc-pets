#import <Foundation/Foundation.h>

NSString *CCBridgeSlackConfigPath(void);
BOOL CCBridgeSlackAutoStartEnabled(void);
BOOL CCBridgeSlackAdapterRunning(void);

// Foreground Socket Mode adapter, also used as the desktop app's child process.
int CCBridgeRunSlack(NSArray<NSString *> *arguments);
