#import <Foundation/Foundation.h>

NSDictionary *CCBridgeSlackAPI(NSURLSession *http, NSString *method, NSString *token, NSDictionary *body);
// Return ids + thread, or paths. Failures contain error and an optional retry delay.
NSDictionary *CCBridgeSlackShareFiles(NSURLSession *http, NSString *token, NSDictionary *message, NSDictionary *peer,
    NSString *comment, NSString *thread);
NSDictionary *CCBridgeSlackFetchFiles(NSURLSession *http, NSString *token, NSArray *ids, NSDictionary *peer,
    NSString *thread, BOOL requireRoot, NSString *mid, NSString *day);
