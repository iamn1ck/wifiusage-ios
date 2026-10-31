#import <Foundation/Foundation.h>
#import "WUDataUsageItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WUDataUsageSortOrder) {
    WUDataUsageSortOrderTotal = 0,
    WUDataUsageSortOrderWiFi = 1,
    WUDataUsageSortOrderCellular = 2
};

typedef NS_ENUM(NSInteger, WUDataUsagePeriodMode) {
    WUDataUsagePeriodModeAllTime = 0,
    WUDataUsagePeriodModeWeekly = 1,
    WUDataUsagePeriodModeMonthly = 2
};

FOUNDATION_EXPORT void WURequestDaemonRefresh(void);
FOUNDATION_EXPORT NSArray<WUDataUsageItemDict *> *WUSortItems(
    NSArray<WUDataUsageItemDict *> *items,
    WUDataUsageSortOrder sortOrder
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *WUFetchDataUsage(
    WUDataUsageSortOrder sortOrder
);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *WUFetchDataUsageForPeriod(
    WUDataUsageSortOrder sortOrder,
    WUDataUsagePeriodMode periodMode,
    NSInteger periodOffset
);

NS_ASSUME_NONNULL_END
