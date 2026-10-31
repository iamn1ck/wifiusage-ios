#import "WUSummaryHeaderView.h"
#import <objc/runtime.h>

static const void *kSummaryCellRefsKey = &kSummaryCellRefsKey;

static UIView *WUCreateMetricBox(
    NSString *title,
    NSString *symbolName,
    UIColor *tintColor,
    UILabel * __strong *outTotalLabel,
    UILabel * __strong *outRxTxLabel,
    UILabel * __strong *outSplitLabel
) {
    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [tintColor colorWithAlphaComponent:0.10];
    box.layer.cornerRadius = 10.0;
    box.layer.borderWidth = 1.0;
    box.layer.borderColor = [tintColor colorWithAlphaComponent:0.25].CGColor;

    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.tintColor = tintColor;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *symCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    iconView.image = [UIImage systemImageNamed:symbolName withConfiguration:symCfg];
    [box addSubview:iconView];

    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    headerLabel.text = title;
    headerLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    headerLabel.textColor = tintColor;
    [box addSubview:headerLabel];

    UILabel *totalLabel = [[UILabel alloc] init];
    totalLabel.translatesAutoresizingMaskIntoConstraints = NO;
    totalLabel.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
    totalLabel.textColor = [UIColor labelColor];
    totalLabel.text = WUStr("0 B");
    totalLabel.adjustsFontSizeToFitWidth = YES;
    [box addSubview:totalLabel];

    UILabel *rxTxLabel = [[UILabel alloc] init];
    rxTxLabel.translatesAutoresizingMaskIntoConstraints = NO;
    rxTxLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    rxTxLabel.textColor = [UIColor secondaryLabelColor];
    rxTxLabel.text = WUStr("↓ 0 B  ↑ 0 B");
    rxTxLabel.adjustsFontSizeToFitWidth = YES;
    [box addSubview:rxTxLabel];

    UILabel *splitLabel = [[UILabel alloc] init];
    splitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    splitLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    splitLabel.textColor = [UIColor secondaryLabelColor];
    splitLabel.numberOfLines = 2;
    splitLabel.text = WUStr("Apps: 0 B\nSystem: 0 B");
    [box addSubview:splitLabel];

    if (outTotalLabel) *outTotalLabel = totalLabel;
    if (outRxTxLabel) *outRxTxLabel = rxTxLabel;
    if (outSplitLabel) *outSplitLabel = splitLabel;

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [iconView.topAnchor constraintEqualToAnchor:box.topAnchor constant:10.0],
        [iconView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [iconView.widthAnchor constraintEqualToConstant:16.0],
        [iconView.heightAnchor constraintEqualToConstant:16.0],

        [headerLabel.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],
        [headerLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:5.0],
        [headerLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],

        [totalLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:6.0],
        [totalLabel.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [totalLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],

        [rxTxLabel.topAnchor constraintEqualToAnchor:totalLabel.bottomAnchor constant:3.0],
        [rxTxLabel.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [rxTxLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],

        [splitLabel.topAnchor constraintEqualToAnchor:rxTxLabel.bottomAnchor constant:4.0],
        [splitLabel.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [splitLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],
        [splitLabel.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10.0],
        nil
    ]];

    return box;
}

static NSMutableDictionary *WUSetupSummaryCellViews(UITableViewCell *cell) {
    UIView *content = cell.contentView;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = WUStr("COMBINED DATA USAGE (WI-FI + CELLULAR)");
    titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor secondaryLabelColor];
    [content addSubview:titleLabel];

    UILabel *grandTotalValueLabel = [[UILabel alloc] init];
    grandTotalValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    grandTotalValueLabel.font = [UIFont systemFontOfSize:28.0 weight:UIFontWeightBold];
    grandTotalValueLabel.textColor = [UIColor labelColor];
    grandTotalValueLabel.text = WUStr("0 B");
    [content addSubview:grandTotalValueLabel];

    UIView *barContainer = [[UIView alloc] init];
    barContainer.translatesAutoresizingMaskIntoConstraints = NO;
    barContainer.backgroundColor = [UIColor systemGreenColor];
    barContainer.layer.cornerRadius = 5.0;
    barContainer.clipsToBounds = YES;
    [content addSubview:barContainer];

    UIView *wifiBarFill = [[UIView alloc] init];
    wifiBarFill.translatesAutoresizingMaskIntoConstraints = NO;
    wifiBarFill.backgroundColor = [UIColor systemBlueColor];
    [barContainer addSubview:wifiBarFill];

    NSLayoutConstraint *wifiWidthConstraint =
        [wifiBarFill.widthAnchor constraintEqualToAnchor:barContainer.widthAnchor multiplier:0.5];

    UILabel *ratioLegendLabel = [[UILabel alloc] init];
    ratioLegendLabel.translatesAutoresizingMaskIntoConstraints = NO;
    ratioLegendLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    ratioLegendLabel.textColor = [UIColor secondaryLabelColor];
    ratioLegendLabel.text = WUStr("Wi-Fi: 0%  •  Cellular: 0%");
    ratioLegendLabel.numberOfLines = 1;
    ratioLegendLabel.adjustsFontSizeToFitWidth = YES;
    [content addSubview:ratioLegendLabel];

    UILabel *wifiTotalLabel = nil;
    UILabel *wifiRxTxLabel = nil;
    UILabel *wifiSplitLabel = nil;
    UIView *wifiBox = WUCreateMetricBox(
        WUStr("Wi-Fi"),
        WUStr("wifi"),
        [UIColor systemBlueColor],
        &wifiTotalLabel,
        &wifiRxTxLabel,
        &wifiSplitLabel
    );

    UILabel *cellTotalLabel = nil;
    UILabel *cellRxTxLabel = nil;
    UILabel *cellSplitLabel = nil;
    UIView *cellBox = WUCreateMetricBox(
        WUStr("Cellular"),
        WUStr("antenna.radiowaves.left.and.right"),
        [UIColor systemGreenColor],
        &cellTotalLabel,
        &cellRxTxLabel,
        &cellSplitLabel
    );

    UIStackView *boxesStack = [[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:wifiBox, cellBox, nil]];
    boxesStack.translatesAutoresizingMaskIntoConstraints = NO;
    boxesStack.axis = UILayoutConstraintAxisHorizontal;
    boxesStack.distribution = UIStackViewDistributionFillEqually;
    boxesStack.spacing = 10.0;
    [content addSubview:boxesStack];

    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor separatorColor];
    [content addSubview:divider];

    UILabel *appsSummaryLabel = [[UILabel alloc] init];
    appsSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    appsSummaryLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    appsSummaryLabel.textColor = [UIColor labelColor];
    appsSummaryLabel.numberOfLines = 1;
    appsSummaryLabel.adjustsFontSizeToFitWidth = YES;
    appsSummaryLabel.text = WUStr("Apps (0): 0 B");
    [content addSubview:appsSummaryLabel];

    UILabel *systemSummaryLabel = [[UILabel alloc] init];
    systemSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    systemSummaryLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    systemSummaryLabel.textColor = [UIColor labelColor];
    systemSummaryLabel.numberOfLines = 1;
    systemSummaryLabel.adjustsFontSizeToFitWidth = YES;
    systemSummaryLabel.text = WUStr("System (0): 0 B");
    [content addSubview:systemSummaryLabel];

    UILabel *sessionSummaryLabel = [[UILabel alloc] init];
    sessionSummaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    sessionSummaryLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    sessionSummaryLabel.textColor = [UIColor secondaryLabelColor];
    sessionSummaryLabel.numberOfLines = 1;
    sessionSummaryLabel.adjustsFontSizeToFitWidth = YES;
    sessionSummaryLabel.text = WUStr("Boot Session (Live HW): Wi-Fi 0 B • Cellular 0 B");
    [content addSubview:sessionSummaryLabel];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [titleLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [grandTotalValueLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
        [grandTotalValueLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [grandTotalValueLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [barContainer.topAnchor constraintEqualToAnchor:grandTotalValueLabel.bottomAnchor constant:10.0],
        [barContainer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [barContainer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [barContainer.heightAnchor constraintEqualToConstant:10.0],

        [wifiBarFill.leadingAnchor constraintEqualToAnchor:barContainer.leadingAnchor],
        [wifiBarFill.topAnchor constraintEqualToAnchor:barContainer.topAnchor],
        [wifiBarFill.bottomAnchor constraintEqualToAnchor:barContainer.bottomAnchor],
        wifiWidthConstraint,

        [ratioLegendLabel.topAnchor constraintEqualToAnchor:barContainer.bottomAnchor constant:6.0],
        [ratioLegendLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [ratioLegendLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [boxesStack.topAnchor constraintEqualToAnchor:ratioLegendLabel.bottomAnchor constant:12.0],
        [boxesStack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [boxesStack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [divider.topAnchor constraintEqualToAnchor:boxesStack.bottomAnchor constant:12.0],
        [divider.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [divider.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [divider.heightAnchor constraintEqualToConstant:0.5],

        [appsSummaryLabel.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:10.0],
        [appsSummaryLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [appsSummaryLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [systemSummaryLabel.topAnchor constraintEqualToAnchor:appsSummaryLabel.bottomAnchor constant:5.0],
        [systemSummaryLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [systemSummaryLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],

        [sessionSummaryLabel.topAnchor constraintEqualToAnchor:systemSummaryLabel.bottomAnchor constant:6.0],
        [sessionSummaryLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16.0],
        [sessionSummaryLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16.0],
        [sessionSummaryLabel.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14.0],
        nil
    ]];

    NSMutableDictionary *refs = [NSMutableDictionary dictionary];
    refs[WUStr("titleLabel")] = titleLabel;
    refs[WUStr("grandTotalValueLabel")] = grandTotalValueLabel;
    refs[WUStr("barContainer")] = barContainer;
    refs[WUStr("wifiBarFill")] = wifiBarFill;
    refs[WUStr("wifiWidthConstraint")] = wifiWidthConstraint;
    refs[WUStr("ratioLegendLabel")] = ratioLegendLabel;
    refs[WUStr("wifiTotalLabel")] = wifiTotalLabel;
    refs[WUStr("wifiRxTxLabel")] = wifiRxTxLabel;
    refs[WUStr("wifiSplitLabel")] = wifiSplitLabel;
    refs[WUStr("cellTotalLabel")] = cellTotalLabel;
    refs[WUStr("cellRxTxLabel")] = cellRxTxLabel;
    refs[WUStr("cellSplitLabel")] = cellSplitLabel;
    refs[WUStr("appsSummaryLabel")] = appsSummaryLabel;
    refs[WUStr("systemSummaryLabel")] = systemSummaryLabel;
    refs[WUStr("sessionSummaryLabel")] = sessionSummaryLabel;

    objc_setAssociatedObject(cell, kSummaryCellRefsKey, refs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return refs;
}

UITableViewCell *WUDequeueAndConfigureSummaryCell(
    UITableView *tableView,
    WUDataUsageSummaryDict * _Nullable summary
) {
    NSString *cellId = WUStr("WUSummaryCardCell");
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    NSMutableDictionary *refs = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        refs = WUSetupSummaryCellViews(cell);
    } else {
        refs = objc_getAssociatedObject(cell, kSummaryCellRefsKey);
        if (!refs) {
            refs = WUSetupSummaryCellViews(cell);
        }
    }

    if (!summary) {
        return cell;
    }

    uint64_t totalWifiIn = [summary[WUStr("totalWifiInBytes")] unsignedLongLongValue];
    uint64_t totalWifiOut = [summary[WUStr("totalWifiOutBytes")] unsignedLongLongValue];
    uint64_t totalWifi = [summary[WUStr("totalWifiBytes")] unsignedLongLongValue];

    uint64_t totalCellIn = [summary[WUStr("totalCellularInBytes")] unsignedLongLongValue];
    uint64_t totalCellOut = [summary[WUStr("totalCellularOutBytes")] unsignedLongLongValue];
    uint64_t totalCell = [summary[WUStr("totalCellularBytes")] unsignedLongLongValue];

    uint64_t combined = [summary[WUStr("totalCombinedBytes")] unsignedLongLongValue];

    uint64_t appWifi = [summary[WUStr("appWifiBytes")] unsignedLongLongValue];
    uint64_t appCell = [summary[WUStr("appCellularBytes")] unsignedLongLongValue];
    uint64_t appTotal = [summary[WUStr("appTotalBytes")] unsignedLongLongValue];
    NSUInteger appCount = [summary[WUStr("appCount")] unsignedIntegerValue];

    uint64_t sysWifi = [summary[WUStr("systemWifiBytes")] unsignedLongLongValue];
    uint64_t sysCell = [summary[WUStr("systemCellularBytes")] unsignedLongLongValue];
    uint64_t sysTotal = [summary[WUStr("systemTotalBytes")] unsignedLongLongValue];
    NSUInteger sysCount = [summary[WUStr("systemCount")] unsignedIntegerValue];

    uint64_t ifWifi = [summary[WUStr("interfaceWifiBytes")] unsignedLongLongValue];
    uint64_t ifCell = [summary[WUStr("interfaceCellularBytes")] unsignedLongLongValue];

    NSInteger periodMode = [summary[WUStr("periodMode")] integerValue];
    uint64_t dailyAvgTotal = [summary[WUStr("dailyAverageBytes")] unsignedLongLongValue];
    uint64_t dailyAvgWifi = [summary[WUStr("dailyAverageWifiBytes")] unsignedLongLongValue];
    uint64_t dailyAvgCell = [summary[WUStr("dailyAverageCellularBytes")] unsignedLongLongValue];
    NSString *headerBanner = summary[WUStr("periodHeaderBanner")];

    double wifiPct = (combined > 0) ? ((double)totalWifi * 100.0 / (double)combined) : 0.0;
    double cellPct = (combined > 0) ? ((double)totalCell * 100.0 / (double)combined) : 0.0;
    CGFloat wifiRatio = (combined > 0) ? (CGFloat)((double)totalWifi / (double)combined) : 0.5f;
    wifiRatio = MAX(0.001f, MIN(0.999f, wifiRatio));

    UILabel *titleLabel = refs[WUStr("titleLabel")];
    UILabel *grandTotalValueLabel = refs[WUStr("grandTotalValueLabel")];
    UILabel *ratioLegendLabel = refs[WUStr("ratioLegendLabel")];
    UILabel *wifiTotalLabel = refs[WUStr("wifiTotalLabel")];
    UILabel *wifiRxTxLabel = refs[WUStr("wifiRxTxLabel")];
    UILabel *wifiSplitLabel = refs[WUStr("wifiSplitLabel")];
    UILabel *cellTotalLabel = refs[WUStr("cellTotalLabel")];
    UILabel *cellRxTxLabel = refs[WUStr("cellRxTxLabel")];
    UILabel *cellSplitLabel = refs[WUStr("cellSplitLabel")];
    UILabel *appsSummaryLabel = refs[WUStr("appsSummaryLabel")];
    UILabel *systemSummaryLabel = refs[WUStr("systemSummaryLabel")];
    UILabel *sessionSummaryLabel = refs[WUStr("sessionSummaryLabel")];
    UIView *barContainer = refs[WUStr("barContainer")];
    UIView *wifiBarFill = refs[WUStr("wifiBarFill")];
    NSLayoutConstraint *oldWidthConstraint = refs[WUStr("wifiWidthConstraint")];

    if (oldWidthConstraint) {
        oldWidthConstraint.active = NO;
    }
    NSLayoutConstraint *newWidthConstraint =
        [wifiBarFill.widthAnchor constraintEqualToAnchor:barContainer.widthAnchor multiplier:wifiRatio];
    newWidthConstraint.active = YES;
    refs[WUStr("wifiWidthConstraint")] = newWidthConstraint;

    titleLabel.text = ([headerBanner isKindOfClass:[NSString class]] && headerBanner.length > 0)
        ? headerBanner
        : WUStr("COMBINED DATA USAGE (WI-FI + CELLULAR)");

    grandTotalValueLabel.text = WUFormatBytes(combined);
    ratioLegendLabel.text = [NSString stringWithFormat:WUStr("● Wi-Fi: %.1f%% (%@)   ● Cellular: %.1f%% (%@)"),
                             wifiPct,
                             WUFormatBytes(totalWifi),
                             cellPct,
                             WUFormatBytes(totalCell)];

    wifiTotalLabel.text = WUFormatBytes(totalWifi);
    wifiRxTxLabel.text = [NSString stringWithFormat:WUStr("↓ %@   ↑ %@"),
                          WUFormatBytes(totalWifiIn),
                          WUFormatBytes(totalWifiOut)];
    wifiSplitLabel.text = [NSString stringWithFormat:WUStr("Apps: %@\nSystem: %@"),
                           WUFormatBytes(appWifi),
                           WUFormatBytes(sysWifi)];

    cellTotalLabel.text = WUFormatBytes(totalCell);
    cellRxTxLabel.text = [NSString stringWithFormat:WUStr("↓ %@   ↑ %@"),
                          WUFormatBytes(totalCellIn),
                          WUFormatBytes(totalCellOut)];
    cellSplitLabel.text = [NSString stringWithFormat:WUStr("Apps: %@\nSystem: %@"),
                           WUFormatBytes(appCell),
                           WUFormatBytes(sysCell)];

    appsSummaryLabel.text = [NSString stringWithFormat:WUStr("Apps (%lu): %@  (Wi-Fi: %@ • Cellular: %@)"),
                             (unsigned long)appCount,
                             WUFormatBytes(appTotal),
                             WUFormatBytes(appWifi),
                             WUFormatBytes(appCell)];

    systemSummaryLabel.text = [NSString stringWithFormat:WUStr("System (%lu): %@  (Wi-Fi: %@ • Cellular: %@)"),
                               (unsigned long)sysCount,
                               WUFormatBytes(sysTotal),
                               WUFormatBytes(sysWifi),
                               WUFormatBytes(sysCell)];

    if (periodMode != 0) {
        sessionSummaryLabel.text = [NSString stringWithFormat:WUStr("Daily Avg: %@/day  (Wi-Fi: %@ • Cellular: %@)"),
                                    WUFormatBytes(dailyAvgTotal),
                                    WUFormatBytes(dailyAvgWifi),
                                    WUFormatBytes(dailyAvgCell)];
    } else {
        sessionSummaryLabel.text = [NSString stringWithFormat:WUStr("Boot Session (Live HW): Wi-Fi %@  •  Cellular %@"),
                                    WUFormatBytes(ifWifi),
                                    WUFormatBytes(ifCell)];
    }

    return cell;
}
