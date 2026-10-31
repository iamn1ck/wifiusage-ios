#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *WUStr(const char * _Nullable cstr) {
    if (!cstr) {
        cstr = "";
    }
    CFStringRef ref = CFStringCreateWithCString(kCFAllocatorDefault, cstr, kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)ref;
}

static inline NSNumber *WUBool(BOOL val) {
    return [NSNumber numberWithBool:val];
}

static inline NSNumber *WUInt(NSInteger val) {
    return [NSNumber numberWithInteger:val];
}

static inline NSNumber *WUUInt(NSUInteger val) {
    return [NSNumber numberWithUnsignedInteger:val];
}

static inline NSNumber *WUU64(uint64_t val) {
    return [NSNumber numberWithUnsignedLongLong:val];
}

static inline NSNumber *WUDouble(double val) {
    return [NSNumber numberWithDouble:val];
}

typedef NS_ENUM(NSInteger, WUDataUsageCategory) {
    WUDataUsageCategoryApp = 0,
    WUDataUsageCategorySystem = 1
};

typedef NSDictionary<NSString *, id> WUDataUsageItemDict;
typedef NSDictionary<NSString *, id> WUDataUsageSummaryDict;

FOUNDATION_EXPORT NSString *WUFormatBytes(uint64_t bytes);
FOUNDATION_EXPORT UIImage *WUResolvedIconForItem(WUDataUsageItemDict *item);

NS_ASSUME_NONNULL_END
