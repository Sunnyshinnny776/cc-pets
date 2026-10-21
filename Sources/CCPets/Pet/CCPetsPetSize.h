#import <Cocoa/Cocoa.h>

extern NSString *const CCPetsPetScaleKey;
extern const CGFloat CCPetsPetMinimumScale;
extern const CGFloat CCPetsPetMaximumScale;
CGFloat CCPetsPetScalePreference(void);
// 状态卡与消息气泡随宠物缩小，放大时最多使用原尺寸。
CGFloat CCPetsBubbleScalePreference(void);
// 按滑动条的最大尺寸预解码，连续缩放时无需重新读文件。
NSSize CCPetsPetDecodeCellSize(void);
