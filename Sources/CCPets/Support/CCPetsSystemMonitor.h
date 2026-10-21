#import <Foundation/Foundation.h>

@interface CCPetsSystemMonitor : NSObject
- (void)sampleCPU:(BOOL)cpuEnabled memory:(BOOL)memoryEnabled
    temperature:(BOOL)temperatureEnabled
    completion:(void (^)(NSNumber *cpuPercent, NSNumber *memoryPercent,
        NSNumber *temperatureCelsius))completion;
@end
