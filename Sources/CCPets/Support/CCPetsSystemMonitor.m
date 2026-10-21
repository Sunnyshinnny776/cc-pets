#import "CCPetsSystemMonitor.h"
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <mach/vm_statistics.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} CCPetsSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} CCPetsSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CCPetsSMCKeyInfoData;

typedef struct {
    uint32_t key;
    CCPetsSMCVersion version;
    CCPetsSMCPLimitData pLimitData;
    CCPetsSMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} CCPetsSMCParamStruct;

static uint32_t CCPetsFourCC(NSString *text) {
    if (text.length != 4) return 0;
    uint32_t value = 0;
    for (NSUInteger index = 0; index < 4; index++) {
        value = (value << 8) | (uint8_t)[text characterAtIndex:index];
    }
    return value;
}

static NSNumber *CCPetsReadSMCTemperature(NSString *key) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleSMC"));
    if (!service) return nil;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS || !connection) return nil;

    CCPetsSMCParamStruct input = {0};
    CCPetsSMCParamStruct output = {0};
    size_t outputSize = sizeof(output);
    input.key = CCPetsFourCC(key);
    input.data8 = 9; // kSMCGetKeyInfo
    result = IOConnectCallStructMethod(connection, 2, &input, sizeof(input),
        &output, &outputSize);
    if (result != KERN_SUCCESS || output.keyInfo.dataSize == 0 ||
        output.keyInfo.dataSize > sizeof(output.bytes)) {
        IOServiceClose(connection);
        return nil;
    }

    CCPetsSMCKeyInfoData keyInfo = output.keyInfo;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    outputSize = sizeof(output);
    input.key = CCPetsFourCC(key);
    input.keyInfo.dataSize = keyInfo.dataSize;
    input.data8 = 5; // kSMCReadKey
    result = IOConnectCallStructMethod(connection, 2, &input, sizeof(input),
        &output, &outputSize);
    IOServiceClose(connection);
    if (result != KERN_SUCCESS) return nil;

    double temperature = NAN;
    uint32_t type = keyInfo.dataType;
    if (type == CCPetsFourCC(@"sp78") && keyInfo.dataSize >= 2) {
        temperature = (double)(int16_t)((output.bytes[0] << 8) | output.bytes[1]) / 256.0;
    } else if (type == CCPetsFourCC(@"flt ") && keyInfo.dataSize >= sizeof(float)) {
        uint32_t bits = ((uint32_t)output.bytes[0] << 24) |
            ((uint32_t)output.bytes[1] << 16) |
            ((uint32_t)output.bytes[2] << 8) | output.bytes[3];
        float value = 0;
        memcpy(&value, &bits, sizeof(value));
        temperature = value;
    }
    return isfinite(temperature) && temperature >= 0 && temperature <= 125
        ? @(temperature) : nil;
}

// Apple Silicon 新机型（包括 M5）不再暴露 AppleSMC，但会把芯片温度作为
// IOHIDEventService 的 Temperature 事件提供。相关函数没有公开头文件，运行时解析
// 可以在旧系统上安全降级，不会形成私有符号的静态链接依赖。
static NSNumber *CCPetsReadHIDDieTemperature(void) {
    typedef CFTypeRef (*CreateClientFunction)(CFAllocatorRef);
    typedef CFArrayRef (*CopyServicesFunction)(CFTypeRef);
    typedef CFTypeRef (*CopyPropertyFunction)(CFTypeRef, CFStringRef);
    typedef CFTypeRef (*CopyEventFunction)(CFTypeRef, int64_t, int32_t, int64_t);
    typedef double (*GetFloatValueFunction)(CFTypeRef, int32_t);

    void *framework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY | RTLD_LOCAL);
    if (!framework) return nil;
    CreateClientFunction createClient =
        (CreateClientFunction)dlsym(framework, "IOHIDEventSystemClientCreate");
    CopyServicesFunction copyServices =
        (CopyServicesFunction)dlsym(framework, "IOHIDEventSystemClientCopyServices");
    CopyPropertyFunction copyProperty =
        (CopyPropertyFunction)dlsym(framework, "IOHIDServiceClientCopyProperty");
    CopyEventFunction copyEvent =
        (CopyEventFunction)dlsym(framework, "IOHIDServiceClientCopyEvent");
    GetFloatValueFunction getFloatValue =
        (GetFloatValueFunction)dlsym(framework, "IOHIDEventGetFloatValue");
    if (!createClient || !copyServices || !copyProperty || !copyEvent || !getFloatValue) {
        dlclose(framework);
        return nil;
    }

    CFTypeRef client = createClient(kCFAllocatorDefault);
    CFArrayRef services = client ? copyServices(client) : nil;
    double hottest = NAN;
    for (CFIndex index = 0; services && index < CFArrayGetCount(services); index++) {
        CFTypeRef service = CFArrayGetValueAtIndex(services, index);
        CFTypeRef productValue = copyProperty(service, CFSTR("Product"));
        NSString *product = productValue && CFGetTypeID(productValue) == CFStringGetTypeID()
            ? (__bridge NSString *)productValue : nil;
        BOOL isDieSensor = [product.lowercaseString containsString:@"tdie"];
        if (productValue) CFRelease(productValue);
        if (!isDieSensor) continue;

        // kIOHIDEventTypeTemperature = 15；Level 字段位于该类型的 field base。
        CFTypeRef event = copyEvent(service, 15, 0, 0);
        if (!event) continue;
        double value = getFloatValue(event, 15 << 16);
        CFRelease(event);
        if (isfinite(value) && value >= 0 && value <= 125 &&
            (!isfinite(hottest) || value > hottest)) hottest = value;
    }
    if (services) CFRelease(services);
    if (client) CFRelease(client);
    dlclose(framework);
    return isfinite(hottest) ? @(hottest) : nil;
}

@interface CCPetsSystemMonitor ()
@property dispatch_queue_t queue;
@property uint64_t previousUserTicks;
@property uint64_t previousSystemTicks;
@property uint64_t previousIdleTicks;
@property uint64_t previousNiceTicks;
@property NSNumber *cachedTemperature;
@property NSTimeInterval temperatureSampledAt;
@end

@implementation CCPetsSystemMonitor

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.universewang.cc-pets.system-monitor",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSNumber *)cpuPercent {
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    natural_t processors = 0;
    kern_return_t result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
        &processors, &info, &count);
    if (result != KERN_SUCCESS || !info) return nil;
    uint64_t user = 0, system = 0, idle = 0, nice = 0;
    for (natural_t index = 0; index < processors; index++) {
        processor_cpu_load_info_t load = (processor_cpu_load_info_t)info + index;
        user += load->cpu_ticks[CPU_STATE_USER];
        system += load->cpu_ticks[CPU_STATE_SYSTEM];
        idle += load->cpu_ticks[CPU_STATE_IDLE];
        nice += load->cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));

    uint64_t previousTotal = self.previousUserTicks + self.previousSystemTicks +
        self.previousIdleTicks + self.previousNiceTicks;
    uint64_t total = user + system + idle + nice;
    uint64_t totalDelta = total >= previousTotal ? total - previousTotal : 0;
    uint64_t idleDelta = idle >= self.previousIdleTicks ? idle - self.previousIdleTicks : 0;
    self.previousUserTicks = user;
    self.previousSystemTicks = system;
    self.previousIdleTicks = idle;
    self.previousNiceTicks = nice;
    if (totalDelta == 0) return nil;
    return @(fmax(0, fmin(100, 100.0 * (double)(totalDelta - idleDelta) /
        (double)totalDelta)));
}

- (NSNumber *)memoryPercent {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    if (host_page_size(host, &pageSize) != KERN_SUCCESS) return nil;
    vm_statistics64_data_t stats = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count) !=
        KERN_SUCCESS) return nil;
    uint64_t total = NSProcessInfo.processInfo.physicalMemory;
    if (total == 0) return nil;
    // 对齐活动监视器的“已使用内存”：物理内存减去空闲内存和可回收的文件缓存。
    // file-backed 对应活动监视器里的“已缓存文件”，speculative 也属于可立即回收页。
    uint64_t reclaimablePages = stats.free_count + stats.speculative_count +
        stats.external_page_count;
    uint64_t reclaimable = reclaimablePages * (uint64_t)pageSize;
    uint64_t used = total > reclaimable ? total - reclaimable : 0;
    return @(fmax(0, fmin(100, 100.0 * (double)used / (double)total)));
}

- (NSNumber *)temperature {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval interval = self.cachedTemperature ? 5 : 30;
    if (self.temperatureSampledAt > 0 && now - self.temperatureSampledAt < interval) {
        return self.cachedTemperature;
    }
    self.temperatureSampledAt = now;
    NSNumber *temperature = CCPetsReadHIDDieTemperature();
    if (!temperature) {
        // Intel 和部分早期 Apple Silicon 仍通过 AppleSMC 暴露这些 key。
        for (NSString *key in @[@"TC0P", @"TC0D", @"Tp09", @"Tp0T", @"Tp01", @"Tp05"]) {
            NSNumber *value = CCPetsReadSMCTemperature(key);
            if (value) {
                temperature = value;
                break;
            }
        }
    }
    self.cachedTemperature = temperature;
    return self.cachedTemperature;
}

- (void)sampleCPU:(BOOL)cpuEnabled memory:(BOOL)memoryEnabled
    temperature:(BOOL)temperatureEnabled
    completion:(void (^)(NSNumber *, NSNumber *, NSNumber *))completion {
    dispatch_async(self.queue, ^{
        NSNumber *cpu = cpuEnabled ? [self cpuPercent] : nil;
        NSNumber *memory = memoryEnabled ? [self memoryPercent] : nil;
        NSNumber *temperature = temperatureEnabled ? [self temperature] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(cpu, memory, temperature);
        });
    });
}

@end
