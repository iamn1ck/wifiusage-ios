#import <UIKit/UIKit.h>
#import "WUDataUsageItem.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UITableViewCell *WUDequeueAndConfigureUsageCell(
    UITableView *tableView,
    WUDataUsageItemDict *item,
    uint64_t maxReferenceBytes
);

NS_ASSUME_NONNULL_END
