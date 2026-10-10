#import "CCPetsPetSize.h"
#import <math.h>

NSString *const CCPetsPetScaleKey = @"CCPetsPetScale";
const CGFloat CCPetsPetMinimumScale = 0.5;
const CGFloat CCPetsPetMaximumScale = 2.0;

CGFloat CCPetsPetScalePreference(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:CCPetsPetScaleKey];
    if (![value isKindOfClass:NSNumber.class]) return 1.0;
    double scale = [value doubleValue];
    return isfinite(scale) ? MAX(CCPetsPetMinimumScale, MIN(CCPetsPetMaximumScale, scale)) : 1.0;
}

NSSize CCPetsPetDecodeCellSize(void) {
    return NSMakeSize(140 * CCPetsPetMaximumScale, 150 * CCPetsPetMaximumScale);
}

CGFloat CCPetsBubbleScalePreference(void) {
    return MIN(CCPetsPetScalePreference(), 1.0);
}
