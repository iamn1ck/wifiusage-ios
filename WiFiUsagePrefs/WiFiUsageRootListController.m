#import "WiFiUsageRootListController.h"
#import "WUDataUsageItem.h"
#import "WUDataUsageManager.h"
#import "WUSummaryHeaderView.h"
#import "WUUsageCell.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

@interface NSObject (WUActions)
- (void)handleManualRefresh;
- (void)periodModeSegmentChanged:(id)sender;
- (void)previousPeriodTapped;
- (void)nextPeriodTapped;
- (void)resetToCurrentPeriodTapped;
- (void)categorySegmentChanged:(id)sender;
- (void)sortSegmentChanged:(id)sender;
@end

typedef NS_ENUM(NSInteger, WUTableSection) {
    WUTableSectionPeriod = 0,
    WUTableSectionSummary = 1,
    WUTableSectionControls = 2,
    WUTableSectionItems = 3,
    WUTableSectionCount = 4
};

typedef NS_ENUM(NSInteger, WUFilterTab) {
    WUFilterTabApps = 0,
    WUFilterTabSystem = 1,
    WUFilterTabAll = 2
};

static const void *kControllerStateKey = &kControllerStateKey;
static const char *const kNotifyUpdated = "com.n1ck.wifiusage.updated";

static NSMutableDictionary *WUGetState(id self) {
    NSMutableDictionary *state = objc_getAssociatedObject(self, kControllerStateKey);
    if (!state) {
        state = [NSMutableDictionary dictionary];
        state[WUStr("selectedPeriodMode")] = WUInt(WUDataUsagePeriodModeAllTime);
        state[WUStr("periodOffset")] = WUInt(0);
        state[WUStr("selectedTab")] = WUInt(WUFilterTabApps);
        state[WUStr("selectedSortOrder")] = WUInt(WUDataUsageSortOrderTotal);
        state[WUStr("searchQuery")] = WUStr("");
        state[WUStr("appItems")] = [NSArray array];
        state[WUStr("systemItems")] = [NSArray array];
        state[WUStr("allItems")] = [NSArray array];
        state[WUStr("displayedItems")] = [NSArray array];
        state[WUStr("isLoading")] = WUBool(NO);
        objc_setAssociatedObject(self, kControllerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void WUApplyFiltersAndReload(id self) {
    NSMutableDictionary *state = WUGetState(self);
    WUFilterTab selectedTab = (WUFilterTab)[state[WUStr("selectedTab")] integerValue];
    NSArray<WUDataUsageItemDict *> *baseList = nil;

    switch (selectedTab) {
        case WUFilterTabApps:
            baseList = state[WUStr("appItems")];
            break;
        case WUFilterTabSystem:
            baseList = state[WUStr("systemItems")];
            break;
        case WUFilterTabAll:
        default:
            baseList = state[WUStr("allItems")];
            break;
    }

    NSString *rawQuery = state[WUStr("searchQuery")] ?: WUStr("");
    NSString *trimmedQuery = [rawQuery stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmedQuery.length == 0) {
        state[WUStr("displayedItems")] = baseList ?: [NSArray array];
    } else {
        NSMutableArray<WUDataUsageItemDict *> *filtered = [NSMutableArray array];
        NSString *kName = WUStr("displayName");
        NSString *kBundle = WUStr("bundleId");
        NSString *kProc = WUStr("procName");
        NSString *empty = WUStr("");

        for (WUDataUsageItemDict *item in baseList) {
            NSString *name = item[kName] ?: empty;
            NSString *bundle = item[kBundle] ?: empty;
            NSString *proc = item[kProc] ?: empty;
            if ([name localizedCaseInsensitiveContainsString:trimmedQuery] ||
                [bundle localizedCaseInsensitiveContainsString:trimmedQuery] ||
                [proc localizedCaseInsensitiveContainsString:trimmedQuery]) {
                [filtered addObject:item];
            }
        }
        state[WUStr("displayedItems")] = filtered;
    }

    UITableView *tableView = state[WUStr("tableView")];
    [tableView reloadData];
}

static void WUReloadDataFromSources(id self) {
    NSMutableDictionary *state = WUGetState(self);
    if ([state[WUStr("isLoading")] boolValue]) {
        return;
    }
    state[WUStr("isLoading")] = WUBool(YES);

    WUDataUsageSortOrder sortOrder =
        (WUDataUsageSortOrder)[state[WUStr("selectedSortOrder")] integerValue];
    WUDataUsagePeriodMode periodMode =
        (WUDataUsagePeriodMode)[state[WUStr("selectedPeriodMode")] integerValue];
    NSInteger periodOffset = [state[WUStr("periodOffset")] integerValue];
    NSDictionary<NSString *, id> *result = WUFetchDataUsageForPeriod(sortOrder, periodMode, periodOffset);

    state[WUStr("isLoading")] = WUBool(NO);
    WUDataUsageSummaryDict *summary = result[WUStr("summary")];
    if (summary) {
        state[WUStr("summary")] = summary;
    }
    state[WUStr("appItems")] = result[WUStr("appItems")] ?: [NSArray array];
    state[WUStr("systemItems")] = result[WUStr("systemItems")] ?: [NSArray array];
    state[WUStr("allItems")] = result[WUStr("allItems")] ?: [NSArray array];

    WUApplyFiltersAndReload(self);

    UIRefreshControl *rc = state[WUStr("refreshControl")];
    if ([rc isRefreshing]) {
        [rc endRefreshing];
    }
}

static void WUUpdatedMainCallback(void *context) {
    if (!context) {
        return;
    }
    id controller = (__bridge id)context;
    WUReloadDataFromSources(controller);
}

static void WUDarwinUpdatedCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
) {
    if (!observer) {
        return;
    }
    dispatch_async_f(dispatch_get_main_queue(), observer, WUUpdatedMainCallback);
}

#pragma mark - Dynamic Method Implementations

static void WU_viewDidLoad(UIViewController *self, SEL _cmd) {
    Class superCls = class_getSuperclass(object_getClass(self));
    struct objc_super sup = { .receiver = self, .super_class = superCls };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);

    NSMutableDictionary *state = WUGetState(self);

    NSString *navTitle = WUStr("Wi-Fi & Cellular Usage");
    self.title = navTitle;
    self.navigationItem.title = navTitle;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UIBarButtonItem *refreshBtn =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:sel_registerName("handleManualRefresh")];
    self.navigationItem.rightBarButtonItem = refreshBtn;

    UITableView *tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                          style:UITableViewStyleInsetGrouped];
    tableView.translatesAutoresizingMaskIntoConstraints = NO;
    tableView.dataSource = (id<UITableViewDataSource>)self;
    tableView.delegate = (id<UITableViewDelegate>)self;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.estimatedRowHeight = 88.0;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:tableView];
    state[WUStr("tableView")] = tableView;

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        nil
    ]];

    UISearchBar *searchBar =
        [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.bounds.size.width, 52.0)];
    searchBar.placeholder = WUStr("Search apps, bundle IDs, or daemons...");
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.delegate = (id<UISearchBarDelegate>)self;
    searchBar.showsCancelButton = NO;
    tableView.tableHeaderView = searchBar;
    state[WUStr("searchBar")] = searchBar;

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self
                       action:sel_registerName("handleManualRefresh")
             forControlEvents:UIControlEventValueChanged];
    tableView.refreshControl = refreshControl;
    state[WUStr("refreshControl")] = refreshControl;

    CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
    CFStringRef notifName = (__bridge CFStringRef)WUStr(kNotifyUpdated);
    CFNotificationCenterRemoveObserver(darwinCenter, (__bridge const void *)self, notifName, NULL);
    CFNotificationCenterAddObserver(
        darwinCenter,
        (__bridge const void *)self,
        WUDarwinUpdatedCallback,
        notifName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    WURequestDaemonRefresh();
    WUReloadDataFromSources(self);
}

static void WU_viewWillDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
    Class superCls = class_getSuperclass(object_getClass(self));
    struct objc_super sup = { .receiver = self, .super_class = superCls };
    ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, animated);

    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
        CFStringRef notifName = (__bridge CFStringRef)WUStr(kNotifyUpdated);
        CFNotificationCenterRemoveObserver(darwinCenter, (__bridge const void *)self, notifName, NULL);
    }
}

static UITableView *WU_table(id self, SEL _cmd) {
    return WUGetState(self)[WUStr("tableView")];
}

static NSArray *WU_specifiers(id self, SEL _cmd) {
    return [NSArray array];
}

static void WU_reloadSpecifiers(id self, SEL _cmd) {
    WUReloadDataFromSources(self);
}

static BOOL WU_canBeShownFromSuspendedState(id self, SEL _cmd) {
    return YES;
}

static void WU_handleManualRefresh(id self, SEL _cmd) {
    WURequestDaemonRefresh();
    WUReloadDataFromSources(self);
}

static void WU_periodModeSegmentChanged(id self, SEL _cmd, UISegmentedControl *sender) {
    NSMutableDictionary *state = WUGetState(self);
    WUDataUsagePeriodMode mode = (WUDataUsagePeriodMode)sender.selectedSegmentIndex;
    state[WUStr("selectedPeriodMode")] = WUInt(mode);
    state[WUStr("periodOffset")] = WUInt(0);
    WUReloadDataFromSources(self);
}

static void WU_previousPeriodTapped(id self, SEL _cmd) {
    NSMutableDictionary *state = WUGetState(self);
    NSInteger currentOffset = [state[WUStr("periodOffset")] integerValue];
    state[WUStr("periodOffset")] = WUInt(currentOffset - 1);
    WUReloadDataFromSources(self);
}

static void WU_nextPeriodTapped(id self, SEL _cmd) {
    NSMutableDictionary *state = WUGetState(self);
    NSInteger currentOffset = [state[WUStr("periodOffset")] integerValue];
    if (currentOffset < 0) {
        state[WUStr("periodOffset")] = WUInt(currentOffset + 1);
        WUReloadDataFromSources(self);
    }
}

static void WU_resetToCurrentPeriodTapped(id self, SEL _cmd) {
    NSMutableDictionary *state = WUGetState(self);
    NSInteger currentOffset = [state[WUStr("periodOffset")] integerValue];
    if (currentOffset != 0) {
        state[WUStr("periodOffset")] = WUInt(0);
        WUReloadDataFromSources(self);
    }
}

static void WU_categorySegmentChanged(id self, SEL _cmd, UISegmentedControl *sender) {
    NSMutableDictionary *state = WUGetState(self);
    state[WUStr("selectedTab")] = WUInt(sender.selectedSegmentIndex);
    WUApplyFiltersAndReload(self);
}

static void WU_sortSegmentChanged(id self, SEL _cmd, UISegmentedControl *sender) {
    NSMutableDictionary *state = WUGetState(self);
    WUDataUsageSortOrder order = (WUDataUsageSortOrder)sender.selectedSegmentIndex;
    state[WUStr("selectedSortOrder")] = WUInt(order);
    state[WUStr("appItems")] = WUSortItems(state[WUStr("appItems")], order);
    state[WUStr("systemItems")] = WUSortItems(state[WUStr("systemItems")], order);
    state[WUStr("allItems")] = WUSortItems(state[WUStr("allItems")], order);
    WUApplyFiltersAndReload(self);
}

static NSInteger WU_numberOfSectionsInTableView(id self, SEL _cmd, UITableView *tableView) {
    return WUTableSectionCount;
}

static NSInteger WU_numberOfRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSMutableDictionary *state = WUGetState(self);
    NSArray *displayed = state[WUStr("displayedItems")];
    WUDataUsagePeriodMode periodMode =
        (WUDataUsagePeriodMode)[state[WUStr("selectedPeriodMode")] integerValue];

    switch (section) {
        case WUTableSectionPeriod:
            return (periodMode == WUDataUsagePeriodModeAllTime) ? 1 : 2;
        case WUTableSectionSummary:
            return 1;
        case WUTableSectionControls:
            return 2;
        case WUTableSectionItems:
            return MAX(1, (NSInteger)displayed.count);
        default:
            return 0;
    }
}

static NSString *WU_titleForHeaderInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSMutableDictionary *state = WUGetState(self);
    WUDataUsagePeriodMode periodMode =
        (WUDataUsagePeriodMode)[state[WUStr("selectedPeriodMode")] integerValue];

    switch (section) {
        case WUTableSectionPeriod:
            return WUStr("TIME PERIOD & HISTORY");
        case WUTableSectionSummary:
            if (periodMode == WUDataUsagePeriodModeWeekly) {
                return WUStr("WEEKLY DATA USAGE SUMMARY");
            } else if (periodMode == WUDataUsagePeriodModeMonthly) {
                return WUStr("MONTHLY DATA USAGE SUMMARY");
            }
            return WUStr("ALL-TIME DATA USAGE SUMMARY");
        case WUTableSectionControls:
            return WUStr("SPLIT PER APP / SYSTEM & SORT");
        case WUTableSectionItems: {
            WUFilterTab selectedTab = (WUFilterTab)[state[WUStr("selectedTab")] integerValue];
            WUDataUsageSortOrder sortOrder =
                (WUDataUsageSortOrder)[state[WUStr("selectedSortOrder")] integerValue];
            NSArray *displayed = state[WUStr("displayedItems")];

            NSString *catName = WUStr("APPLICATIONS");
            if (selectedTab == WUFilterTabSystem) {
                catName = WUStr("SYSTEM SERVICES & DAEMONS");
            } else if (selectedTab == WUFilterTabAll) {
                catName = WUStr("ALL APPS & SYSTEM PROCESSES");
            }
            NSString *sortName = WUStr("TOTAL");
            if (sortOrder == WUDataUsageSortOrderWiFi) {
                sortName = WUStr("WI-FI");
            } else if (sortOrder == WUDataUsageSortOrderCellular) {
                sortName = WUStr("CELLULAR");
            }
            return [NSString stringWithFormat:WUStr("%@ (%lu) — BY %@"),
                    catName,
                    (unsigned long)displayed.count,
                    sortName];
        }
        default:
            return nil;
    }
}

static NSString *WU_titleForFooterInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSMutableDictionary *state = WUGetState(self);
    WUDataUsageSummaryDict *summary = state[WUStr("summary")];
    WUDataUsagePeriodMode periodMode =
        (WUDataUsagePeriodMode)[state[WUStr("selectedPeriodMode")] integerValue];
    NSInteger periodOffset = [state[WUStr("periodOffset")] integerValue];

    if (section == WUTableSectionPeriod && summary) {
        NSDate *earliest = summary[WUStr("earliestDate")];
        NSString *earliestStr = nil;
        if ([earliest isKindOfClass:[NSDate class]]) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateStyle = NSDateFormatterMediumStyle;
            df.timeStyle = NSDateFormatterNoStyle;
            earliestStr = [df stringFromDate:earliest];
        }
        if (periodMode == WUDataUsagePeriodModeAllTime) {
            return earliestStr
                ? [NSString stringWithFormat:WUStr("Showing all recorded traffic since %@."), earliestStr]
                : WUStr("Showing cumulative traffic across all recorded history.");
        }
        if (periodOffset < 0) {
            return earliestStr
                ? [NSString stringWithFormat:WUStr("Tap center date to return to current period • History since %@"), earliestStr]
                : WUStr("Tap center date to return to the current period.");
        }
        return earliestStr
            ? [NSString stringWithFormat:WUStr("Use ◀ and ▶ to browse previous %@ • History since %@"),
               (periodMode == WUDataUsagePeriodModeWeekly) ? WUStr("weeks") : WUStr("months"),
               earliestStr]
            : WUStr("Use ◀ and ▶ to step through previous weeks or months.");
    }

    if (section == WUTableSectionSummary && summary) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateStyle = NSDateFormatterNoStyle;
        df.timeStyle = NSDateFormatterMediumStyle;
        NSDate *updated = summary[WUStr("lastUpdatedDate")];
        NSString *timeStr = [updated isKindOfClass:[NSDate class]]
            ? [df stringFromDate:updated]
            : WUStr("Just now");
        return [NSString stringWithFormat:WUStr("Sources: %@ • Updated: %@"),
                summary[WUStr("activeSourcesDescription")] ?: WUStr("System DB"),
                timeStr];
    }
    return nil;
}

static UITableViewCell *WU_cellForRowAtIndexPath(
    id self,
    SEL _cmd,
    UITableView *tableView,
    NSIndexPath *indexPath
) {
    NSMutableDictionary *state = WUGetState(self);

    if (indexPath.section == WUTableSectionPeriod) {
        if (indexPath.row == 0) {
            NSString *cellId = WUStr("WUPeriodModeCell");
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            UISegmentedControl *seg = nil;

            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:cellId];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

                NSArray *items = [NSArray arrayWithObjects:WUStr("All Time"), WUStr("Weekly"), WUStr("Monthly"), nil];
                seg = [[UISegmentedControl alloc] initWithItems:items];
                seg.translatesAutoresizingMaskIntoConstraints = NO;
                seg.tag = 2000;
                [seg addTarget:self
                        action:sel_registerName("periodModeSegmentChanged:")
              forControlEvents:UIControlEventValueChanged];
                [cell.contentView addSubview:seg];

                [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
                    [seg.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:14.0],
                    [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14.0],
                    [seg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
                    [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8.0],
                    nil
                ]];
            } else {
                seg = (UISegmentedControl *)[cell.contentView viewWithTag:2000];
            }

            seg.selectedSegmentIndex = [state[WUStr("selectedPeriodMode")] integerValue];
            return cell;
        } else {
            NSString *cellId = WUStr("WUPeriodNavigatorCell");
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            UIButton *prevBtn = nil;
            UIButton *nextBtn = nil;
            UILabel *titleLabel = nil;
            UILabel *subtitleLabel = nil;

            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                              reuseIdentifier:cellId];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

                UIImageSymbolConfiguration *symCfg =
                    [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                                    weight:UIImageSymbolWeightSemibold];

                prevBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                prevBtn.translatesAutoresizingMaskIntoConstraints = NO;
                prevBtn.tag = 2001;
                [prevBtn setImage:[UIImage systemImageNamed:WUStr("chevron.left.circle.fill")
                                          withConfiguration:symCfg]
                         forState:UIControlStateNormal];
                prevBtn.tintColor = [UIColor systemBlueColor];
                [prevBtn addTarget:self
                            action:sel_registerName("previousPeriodTapped")
                  forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:prevBtn];

                nextBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                nextBtn.translatesAutoresizingMaskIntoConstraints = NO;
                nextBtn.tag = 2002;
                [nextBtn setImage:[UIImage systemImageNamed:WUStr("chevron.right.circle.fill")
                                          withConfiguration:symCfg]
                         forState:UIControlStateNormal];
                nextBtn.tintColor = [UIColor systemBlueColor];
                [nextBtn addTarget:self
                            action:sel_registerName("nextPeriodTapped")
                  forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:nextBtn];

                titleLabel = [[UILabel alloc] init];
                titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
                titleLabel.tag = 2003;
                titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
                titleLabel.textColor = [UIColor labelColor];
                titleLabel.textAlignment = NSTextAlignmentCenter;
                titleLabel.adjustsFontSizeToFitWidth = YES;
                [cell.contentView addSubview:titleLabel];

                subtitleLabel = [[UILabel alloc] init];
                subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
                subtitleLabel.tag = 2004;
                subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
                subtitleLabel.textColor = [UIColor secondaryLabelColor];
                subtitleLabel.textAlignment = NSTextAlignmentCenter;
                subtitleLabel.adjustsFontSizeToFitWidth = YES;
                [cell.contentView addSubview:subtitleLabel];

                UIButton *centerResetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
                centerResetBtn.translatesAutoresizingMaskIntoConstraints = NO;
                centerResetBtn.tag = 2005;
                [centerResetBtn addTarget:self
                                   action:sel_registerName("resetToCurrentPeriodTapped")
                         forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:centerResetBtn];

                [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
                    [prevBtn.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12.0],
                    [prevBtn.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                    [prevBtn.widthAnchor constraintEqualToConstant:40.0],
                    [prevBtn.heightAnchor constraintEqualToConstant:40.0],

                    [nextBtn.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12.0],
                    [nextBtn.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                    [nextBtn.widthAnchor constraintEqualToConstant:40.0],
                    [nextBtn.heightAnchor constraintEqualToConstant:40.0],

                    [titleLabel.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:9.0],
                    [titleLabel.leadingAnchor constraintEqualToAnchor:prevBtn.trailingAnchor constant:8.0],
                    [titleLabel.trailingAnchor constraintEqualToAnchor:nextBtn.leadingAnchor constant:-8.0],

                    [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],
                    [subtitleLabel.leadingAnchor constraintEqualToAnchor:prevBtn.trailingAnchor constant:8.0],
                    [subtitleLabel.trailingAnchor constraintEqualToAnchor:nextBtn.leadingAnchor constant:-8.0],
                    [subtitleLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-9.0],

                    [centerResetBtn.leadingAnchor constraintEqualToAnchor:prevBtn.trailingAnchor],
                    [centerResetBtn.trailingAnchor constraintEqualToAnchor:nextBtn.leadingAnchor],
                    [centerResetBtn.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
                    [centerResetBtn.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
                    nil
                ]];
            } else {
                prevBtn = (UIButton *)[cell.contentView viewWithTag:2001];
                nextBtn = (UIButton *)[cell.contentView viewWithTag:2002];
                titleLabel = (UILabel *)[cell.contentView viewWithTag:2003];
                subtitleLabel = (UILabel *)[cell.contentView viewWithTag:2004];
            }

            WUDataUsageSummaryDict *summary = state[WUStr("summary")];
            NSInteger periodOffset = [state[WUStr("periodOffset")] integerValue];
            BOOL canNext = (periodOffset < 0);

            titleLabel.text = summary[WUStr("periodTitle")] ?: WUStr("Current Period");
            NSString *subText = summary[WUStr("periodSubtitle")] ?: WUStr("");
            if (periodOffset < 0 && subText.length > 0) {
                subtitleLabel.text = [NSString stringWithFormat:WUStr("%@  •  Return to Current"), subText];
                subtitleLabel.textColor = [UIColor systemBlueColor];
            } else {
                subtitleLabel.text = subText;
                subtitleLabel.textColor = [UIColor secondaryLabelColor];
            }

            nextBtn.enabled = canNext;
            nextBtn.alpha = canNext ? 1.0 : 0.30;
            return cell;
        }
    }

    if (indexPath.section == WUTableSectionSummary) {
        return WUDequeueAndConfigureSummaryCell(tableView, state[WUStr("summary")]);
    }

    if (indexPath.section == WUTableSectionControls) {
        BOOL isCategoryRow = (indexPath.row == 0);
        NSString *cellId = isCategoryRow
            ? WUStr("WUCategoryControlCell")
            : WUStr("WUSortControlCell");
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        UISegmentedControl *seg = nil;

        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:cellId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];

            UILabel *label = [[UILabel alloc] init];
            label.translatesAutoresizingMaskIntoConstraints = NO;
            label.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
            label.textColor = [UIColor secondaryLabelColor];
            label.text = isCategoryRow ? WUStr("Split") : WUStr("Sort By");
            [cell.contentView addSubview:label];

            NSArray *items = isCategoryRow
                ? [NSArray arrayWithObjects:WUStr("Apps"), WUStr("System"), WUStr("All"), nil]
                : [NSArray arrayWithObjects:WUStr("Total"), WUStr("Wi-Fi"), WUStr("Cellular"), nil];
            seg = [[UISegmentedControl alloc] initWithItems:items];
            seg.translatesAutoresizingMaskIntoConstraints = NO;
            seg.tag = 1001;
            if (isCategoryRow) {
                [seg addTarget:self
                        action:sel_registerName("categorySegmentChanged:")
              forControlEvents:UIControlEventValueChanged];
            } else {
                [seg addTarget:self
                        action:sel_registerName("sortSegmentChanged:")
              forControlEvents:UIControlEventValueChanged];
            }
            [cell.contentView addSubview:seg];

            [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
                [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16.0],
                [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [label.widthAnchor constraintEqualToConstant:58.0],

                [seg.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:8.0],
                [seg.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14.0],
                [seg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
                [seg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8.0],
                nil
            ]];
        } else {
            seg = (UISegmentedControl *)[cell.contentView viewWithTag:1001];
        }

        NSArray *appItems = state[WUStr("appItems")];
        NSArray *sysItems = state[WUStr("systemItems")];
        NSArray *allItems = state[WUStr("allItems")];

        if (isCategoryRow && seg.numberOfSegments == 3) {
            [seg setTitle:[NSString stringWithFormat:WUStr("Apps (%lu)"), (unsigned long)appItems.count]
        forSegmentAtIndex:WUFilterTabApps];
            [seg setTitle:[NSString stringWithFormat:WUStr("System (%lu)"), (unsigned long)sysItems.count]
        forSegmentAtIndex:WUFilterTabSystem];
            [seg setTitle:[NSString stringWithFormat:WUStr("All (%lu)"), (unsigned long)allItems.count]
        forSegmentAtIndex:WUFilterTabAll];
            seg.selectedSegmentIndex = [state[WUStr("selectedTab")] integerValue];
        } else if (!isCategoryRow && seg.numberOfSegments == 3) {
            seg.selectedSegmentIndex = [state[WUStr("selectedSortOrder")] integerValue];
        }

        return cell;
    }

    NSArray<WUDataUsageItemDict *> *displayed = state[WUStr("displayedItems")];
    if (displayed.count == 0) {
        NSString *emptyId = WUStr("WUEmptyCell");
        UITableViewCell *emptyCell = [tableView dequeueReusableCellWithIdentifier:emptyId];
        if (!emptyCell) {
            emptyCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                               reuseIdentifier:emptyId];
            emptyCell.selectionStyle = UITableViewCellSelectionStyleNone;
            emptyCell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        }
        BOOL loading = [state[WUStr("isLoading")] boolValue];
        WUDataUsagePeriodMode periodMode =
            (WUDataUsagePeriodMode)[state[WUStr("selectedPeriodMode")] integerValue];
        emptyCell.textLabel.text = loading
            ? WUStr("Loading data usage statistics...")
            : ((periodMode == WUDataUsagePeriodModeAllTime)
               ? WUStr("No matching usage records found")
               : WUStr("No usage recorded during this period"));
        emptyCell.textLabel.textColor = [UIColor secondaryLabelColor];
        emptyCell.detailTextLabel.text = (periodMode == WUDataUsagePeriodModeAllTime)
            ? WUStr("Pull down to refresh or adjust your search filter.")
            : WUStr("Use ◀ / ▶ above to browse other weeks or months, or adjust your search filter.");
        emptyCell.detailTextLabel.textColor = [UIColor tertiaryLabelColor];
        return emptyCell;
    }

    WUDataUsageItemDict *item = displayed[indexPath.row];
    uint64_t maxRef = [displayed.firstObject[WUStr("totalBytes")] unsignedLongLongValue];
    return WUDequeueAndConfigureUsageCell(tableView, item, maxRef);
}

static void WU_didSelectRowAtIndexPath(
    UIViewController *self,
    SEL _cmd,
    UITableView *tableView,
    NSIndexPath *indexPath
) {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSMutableDictionary *state = WUGetState(self);
    NSArray<WUDataUsageItemDict *> *displayed = state[WUStr("displayedItems")];
    if (indexPath.section != WUTableSectionItems || displayed.count == 0) {
        return;
    }

    WUDataUsageItemDict *item = displayed[indexPath.row];
    WUDataUsageSummaryDict *summary = state[WUStr("summary")];

    WUDataUsageCategory category = (WUDataUsageCategory)[item[WUStr("category")] integerValue];
    BOOL isSystemApp = [item[WUStr("isSystemApp")] boolValue];
    NSString *categoryStr = (category == WUDataUsageCategoryApp)
        ? (isSystemApp ? WUStr("System Application") : WUStr("User Application"))
        : WUStr("System Daemon / Service");

    NSString *displayName = item[WUStr("displayName")] ?: WUStr("Unknown");
    NSString *bundleId = item[WUStr("bundleId")] ?: WUStr("");
    NSString *procName = item[WUStr("procName")] ?: WUStr("");

    uint64_t wifiIn = [item[WUStr("wifiInBytes")] unsignedLongLongValue];
    uint64_t wifiOut = [item[WUStr("wifiOutBytes")] unsignedLongLongValue];
    uint64_t totalWifi = [item[WUStr("totalWifiBytes")] unsignedLongLongValue];

    uint64_t cellIn = [item[WUStr("cellularInBytes")] unsignedLongLongValue];
    uint64_t cellOut = [item[WUStr("cellularOutBytes")] unsignedLongLongValue];
    uint64_t totalCell = [item[WUStr("totalCellularBytes")] unsignedLongLongValue];

    uint64_t totalBytes = [item[WUStr("totalBytes")] unsignedLongLongValue];
    uint64_t grandTotal = summary ? [summary[WUStr("totalCombinedBytes")] unsignedLongLongValue] : totalBytes;
    double shareOfDevice = (grandTotal > 0)
        ? ((double)totalBytes * 100.0 / (double)grandTotal)
        : 0.0;

    NSString *periodTitle = summary[WUStr("periodTitle")] ?: WUStr("All Time");
    NSString *periodSub = summary[WUStr("periodSubtitle")] ?: WUStr("");

    NSMutableString *details = [NSMutableString string];
    if (periodSub.length > 0 && ![periodTitle isEqualToString:WUStr("All Time")]) {
        [details appendFormat:WUStr("Period: %@ (%@)\n"), periodTitle, periodSub];
    } else {
        [details appendFormat:WUStr("Period: %@\n"), periodTitle];
    }
    [details appendFormat:WUStr("Category: %@\n"), categoryStr];
    if (bundleId.length > 0) {
        [details appendFormat:WUStr("Bundle ID: %@\n"), bundleId];
    }
    if (procName.length > 0) {
        [details appendFormat:WUStr("Process: %@\n"), procName];
    }
    [details appendString:WUStr("\n— WI-FI USAGE —\n")];
    [details appendFormat:WUStr("Total Wi-Fi: %@ (%llu B)\n"),
     WUFormatBytes(totalWifi),
     (unsigned long long)totalWifi];
    [details appendFormat:WUStr("Downloaded (↓): %@\n"), WUFormatBytes(wifiIn)];
    [details appendFormat:WUStr("Uploaded (↑): %@\n"), WUFormatBytes(wifiOut)];

    [details appendString:WUStr("\n— CELLULAR USAGE —\n")];
    [details appendFormat:WUStr("Total Cellular: %@ (%llu B)\n"),
     WUFormatBytes(totalCell),
     (unsigned long long)totalCell];
    [details appendFormat:WUStr("Downloaded (↓): %@\n"), WUFormatBytes(cellIn)];
    [details appendFormat:WUStr("Uploaded (↑): %@\n"), WUFormatBytes(cellOut)];

    [details appendString:WUStr("\n— COMBINED TOTAL —\n")];
    [details appendFormat:WUStr("Total: %@ (%.2f%% of period usage)"),
     WUFormatBytes(totalBytes),
     shareOfDevice];

    double lastTs = [item[WUStr("lastTimestamp")] doubleValue];
    if (lastTs > 0) {
        NSDate *lastDate = [NSDate dateWithTimeIntervalSinceReferenceDate:lastTs];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateStyle = NSDateFormatterMediumStyle;
        df.timeStyle = NSDateFormatterShortStyle;
        [details appendFormat:WUStr("\nLast Active: %@"), [df stringFromDate:lastDate]];
    }

    [UIPasteboard generalPasteboard].string =
        [NSString stringWithFormat:WUStr("%@\n%@"), displayName, details];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:displayName
                                            message:details
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:WUStr("Close (Copied to Clipboard)")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

static void WU_searchBarTextDidChange(id self, SEL _cmd, UISearchBar *searchBar, NSString *searchText) {
    NSMutableDictionary *state = WUGetState(self);
    state[WUStr("searchQuery")] = searchText ?: WUStr("");
    WUApplyFiltersAndReload(self);
}

static void WU_searchBarTextDidBeginEditing(id self, SEL _cmd, UISearchBar *searchBar) {
    [searchBar setShowsCancelButton:YES animated:YES];
}

static void WU_searchBarCancelButtonClicked(id self, SEL _cmd, UISearchBar *searchBar) {
    NSMutableDictionary *state = WUGetState(self);
    NSString *empty = WUStr("");
    searchBar.text = empty;
    state[WUStr("searchQuery")] = empty;
    [searchBar setShowsCancelButton:NO animated:YES];
    [searchBar resignFirstResponder];
    WUApplyFiltersAndReload(self);
}

static void WU_searchBarSearchButtonClicked(id self, SEL _cmd, UISearchBar *searchBar) {
    [searchBar resignFirstResponder];
}

#pragma mark - Runtime Class Registration Constructor

__attribute__((constructor))
static void WURegisterPreferenceControllerClass(void) {
    @autoreleasepool {
        if (objc_getClass("WiFiUsageRootListController") != Nil) {
            return;
        }
        Class superCls = objc_getClass("PSViewController") ?: [UIViewController class];
        Class cls = objc_allocateClassPair(superCls, "WiFiUsageRootListController", 0);
        if (!cls) {
            return;
        }

        class_addMethod(cls, sel_registerName("viewDidLoad"), (IMP)WU_viewDidLoad, "v@:");
        class_addMethod(cls, sel_registerName("viewWillDisappear:"), (IMP)WU_viewWillDisappear, "v@:B");
        class_addMethod(cls, sel_registerName("table"), (IMP)WU_table, "@@:");
        class_addMethod(cls, sel_registerName("specifiers"), (IMP)WU_specifiers, "@@:");
        class_addMethod(cls, sel_registerName("reloadSpecifiers"), (IMP)WU_reloadSpecifiers, "v@:");
        class_addMethod(cls, sel_registerName("canBeShownFromSuspendedState"), (IMP)WU_canBeShownFromSuspendedState, "B@:");

        class_addMethod(cls, sel_registerName("handleManualRefresh"), (IMP)WU_handleManualRefresh, "v@:");
        class_addMethod(cls, sel_registerName("periodModeSegmentChanged:"), (IMP)WU_periodModeSegmentChanged, "v@:@");
        class_addMethod(cls, sel_registerName("previousPeriodTapped"), (IMP)WU_previousPeriodTapped, "v@:");
        class_addMethod(cls, sel_registerName("nextPeriodTapped"), (IMP)WU_nextPeriodTapped, "v@:");
        class_addMethod(cls, sel_registerName("resetToCurrentPeriodTapped"), (IMP)WU_resetToCurrentPeriodTapped, "v@:");
        class_addMethod(cls, sel_registerName("categorySegmentChanged:"), (IMP)WU_categorySegmentChanged, "v@:@");
        class_addMethod(cls, sel_registerName("sortSegmentChanged:"), (IMP)WU_sortSegmentChanged, "v@:@");

        class_addMethod(cls, sel_registerName("numberOfSectionsInTableView:"), (IMP)WU_numberOfSectionsInTableView, "q@:@");
        class_addMethod(cls, sel_registerName("tableView:numberOfRowsInSection:"), (IMP)WU_numberOfRowsInSection, "q@:@q");
        class_addMethod(cls, sel_registerName("tableView:titleForHeaderInSection:"), (IMP)WU_titleForHeaderInSection, "@@:@q");
        class_addMethod(cls, sel_registerName("tableView:titleForFooterInSection:"), (IMP)WU_titleForFooterInSection, "@@:@q");
        class_addMethod(cls, sel_registerName("tableView:cellForRowAtIndexPath:"), (IMP)WU_cellForRowAtIndexPath, "@@:@@");
        class_addMethod(cls, sel_registerName("tableView:didSelectRowAtIndexPath:"), (IMP)WU_didSelectRowAtIndexPath, "v@:@@");

        class_addMethod(cls, sel_registerName("searchBar:textDidChange:"), (IMP)WU_searchBarTextDidChange, "v@:@@");
        class_addMethod(cls, sel_registerName("searchBarTextDidBeginEditing:"), (IMP)WU_searchBarTextDidBeginEditing, "v@:@");
        class_addMethod(cls, sel_registerName("searchBarCancelButtonClicked:"), (IMP)WU_searchBarCancelButtonClicked, "v@:@");
        class_addMethod(cls, sel_registerName("searchBarSearchButtonClicked:"), (IMP)WU_searchBarSearchButtonClicked, "v@:@");

        objc_registerClassPair(cls);
    }
}
