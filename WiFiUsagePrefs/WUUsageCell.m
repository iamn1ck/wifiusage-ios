#import "WUUsageCell.h"
#import <objc/runtime.h>

static const void *kUsageCellRefsKey = &kUsageCellRefsKey;

static NSMutableDictionary *WUSetupUsageCellViews(UITableViewCell *cell) {
    UIView *content = cell.contentView;

    UIImageView *iconImageView = [[UIImageView alloc] init];
    iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    iconImageView.layer.cornerRadius = 7.0;
    iconImageView.clipsToBounds = YES;
    iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    iconImageView.tintColor = [UIColor systemBlueColor];
    [content addSubview:iconImageView];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:nameLabel];

    UILabel *totalLabel = [[UILabel alloc] init];
    totalLabel.translatesAutoresizingMaskIntoConstraints = NO;
    totalLabel.font = [UIFont monospacedDigitSystemFontOfSize:14.5 weight:UIFontWeightBold];
    totalLabel.textColor = [UIColor labelColor];
    totalLabel.textAlignment = NSTextAlignmentRight;
    [totalLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
    [totalLabel setContentHuggingPriority:UILayoutPriorityRequired
                                  forAxis:UILayoutConstraintAxisHorizontal];
    [content addSubview:totalLabel];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [content addSubview:subtitleLabel];

    UILabel *wifiValueLabel = [[UILabel alloc] init];
    wifiValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    wifiValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
    wifiValueLabel.textColor = [UIColor systemBlueColor];

    UILabel *cellularValueLabel = [[UILabel alloc] init];
    cellularValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    cellularValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
    cellularValueLabel.textColor = [UIColor systemGreenColor];
    cellularValueLabel.textAlignment = NSTextAlignmentRight;

    UIStackView *metricsRow = [[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:wifiValueLabel, cellularValueLabel, nil]];
    metricsRow.translatesAutoresizingMaskIntoConstraints = NO;
    metricsRow.axis = UILayoutConstraintAxisHorizontal;
    metricsRow.distribution = UIStackViewDistributionFillProportionally;
    metricsRow.spacing = 8.0;
    [content addSubview:metricsRow];

    UIView *barTrackView = [[UIView alloc] init];
    barTrackView.translatesAutoresizingMaskIntoConstraints = NO;
    barTrackView.backgroundColor = [UIColor systemFillColor];
    barTrackView.layer.cornerRadius = 2.5;
    barTrackView.clipsToBounds = YES;
    [content addSubview:barTrackView];

    UIView *wifiBarView = [[UIView alloc] init];
    wifiBarView.translatesAutoresizingMaskIntoConstraints = NO;
    wifiBarView.backgroundColor = [UIColor systemBlueColor];
    [barTrackView addSubview:wifiBarView];

    UIView *cellBarView = [[UIView alloc] init];
    cellBarView.translatesAutoresizingMaskIntoConstraints = NO;
    cellBarView.backgroundColor = [UIColor systemGreenColor];
    [barTrackView addSubview:cellBarView];

    NSLayoutConstraint *wifiWidthConstraint =
        [wifiBarView.widthAnchor constraintEqualToAnchor:barTrackView.widthAnchor multiplier:0.001];
    NSLayoutConstraint *cellWidthConstraint =
        [cellBarView.widthAnchor constraintEqualToAnchor:barTrackView.widthAnchor multiplier:0.001];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [iconImageView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14.0],
        [iconImageView.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [iconImageView.widthAnchor constraintEqualToConstant:32.0],
        [iconImageView.heightAnchor constraintEqualToConstant:32.0],

        [nameLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:10.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:iconImageView.trailingAnchor constant:12.0],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:totalLabel.leadingAnchor constant:-8.0],

        [totalLabel.centerYAnchor constraintEqualToAnchor:nameLabel.centerYAnchor],
        [totalLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8.0],

        [subtitleLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8.0],

        [metricsRow.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:5.0],
        [metricsRow.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [metricsRow.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8.0],

        [barTrackView.topAnchor constraintEqualToAnchor:metricsRow.bottomAnchor constant:5.0],
        [barTrackView.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [barTrackView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8.0],
        [barTrackView.heightAnchor constraintEqualToConstant:5.0],
        [barTrackView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-10.0],

        [wifiBarView.leadingAnchor constraintEqualToAnchor:barTrackView.leadingAnchor],
        [wifiBarView.topAnchor constraintEqualToAnchor:barTrackView.topAnchor],
        [wifiBarView.bottomAnchor constraintEqualToAnchor:barTrackView.bottomAnchor],
        wifiWidthConstraint,

        [cellBarView.leadingAnchor constraintEqualToAnchor:wifiBarView.trailingAnchor],
        [cellBarView.topAnchor constraintEqualToAnchor:barTrackView.topAnchor],
        [cellBarView.bottomAnchor constraintEqualToAnchor:barTrackView.bottomAnchor],
        cellWidthConstraint,
        nil
    ]];

    NSMutableDictionary *refs = [NSMutableDictionary dictionary];
    refs[WUStr("iconImageView")] = iconImageView;
    refs[WUStr("nameLabel")] = nameLabel;
    refs[WUStr("totalLabel")] = totalLabel;
    refs[WUStr("subtitleLabel")] = subtitleLabel;
    refs[WUStr("wifiValueLabel")] = wifiValueLabel;
    refs[WUStr("cellularValueLabel")] = cellularValueLabel;
    refs[WUStr("barTrackView")] = barTrackView;
    refs[WUStr("wifiBarView")] = wifiBarView;
    refs[WUStr("cellBarView")] = cellBarView;
    refs[WUStr("wifiWidthConstraint")] = wifiWidthConstraint;
    refs[WUStr("cellWidthConstraint")] = cellWidthConstraint;

    objc_setAssociatedObject(cell, kUsageCellRefsKey, refs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return refs;
}

UITableViewCell *WUDequeueAndConfigureUsageCell(
    UITableView *tableView,
    WUDataUsageItemDict *item,
    uint64_t maxReferenceBytes
) {
    NSString *cellId = WUStr("WUUsageCell");
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    NSMutableDictionary *refs = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:cellId];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        refs = WUSetupUsageCellViews(cell);
    } else {
        refs = objc_getAssociatedObject(cell, kUsageCellRefsKey);
        if (!refs) {
            refs = WUSetupUsageCellViews(cell);
        }
    }

    UIImageView *iconImageView = refs[WUStr("iconImageView")];
    UILabel *nameLabel = refs[WUStr("nameLabel")];
    UILabel *totalLabel = refs[WUStr("totalLabel")];
    UILabel *subtitleLabel = refs[WUStr("subtitleLabel")];
    UILabel *wifiValueLabel = refs[WUStr("wifiValueLabel")];
    UILabel *cellularValueLabel = refs[WUStr("cellularValueLabel")];
    UIView *barTrackView = refs[WUStr("barTrackView")];
    UIView *wifiBarView = refs[WUStr("wifiBarView")];
    UIView *cellBarView = refs[WUStr("cellBarView")];

    NSString *displayName = item[WUStr("displayName")] ?: WUStr("Unknown");
    NSString *subtitle = item[WUStr("subtitle")] ?: WUStr("");
    WUDataUsageCategory category = (WUDataUsageCategory)[item[WUStr("category")] integerValue];
    BOOL isSystemApp = [item[WUStr("isSystemApp")] boolValue];

    uint64_t totalWifi = [item[WUStr("totalWifiBytes")] unsignedLongLongValue];
    uint64_t totalCell = [item[WUStr("totalCellularBytes")] unsignedLongLongValue];
    uint64_t totalBytes = [item[WUStr("totalBytes")] unsignedLongLongValue];

    nameLabel.text = displayName;
    totalLabel.text = WUFormatBytes(totalBytes);

    NSString *badge = (category == WUDataUsageCategoryApp)
        ? (isSystemApp ? WUStr("[System App]") : WUStr("[App]"))
        : WUStr("[System]");
    subtitleLabel.text = [NSString stringWithFormat:WUStr("%@ %@"), badge, subtitle];

    wifiValueLabel.text = [NSString stringWithFormat:WUStr("Wi-Fi: %@"), WUFormatBytes(totalWifi)];
    cellularValueLabel.text = [NSString stringWithFormat:WUStr("Cellular: %@"), WUFormatBytes(totalCell)];

    iconImageView.image = WUResolvedIconForItem(item);
    iconImageView.tintColor = (category == WUDataUsageCategoryApp)
        ? [UIColor systemBlueColor]
        : [UIColor systemIndigoColor];

    uint64_t denom = (maxReferenceBytes > 0) ? maxReferenceBytes : totalBytes;
    CGFloat wShare = 0.001f;
    CGFloat cShare = 0.001f;
    if (denom > 0) {
        wShare = (CGFloat)((double)totalWifi / (double)denom);
        cShare = (CGFloat)((double)totalCell / (double)denom);
    }
    wShare = MAX(0.0001f, MIN(0.9998f, wShare));
    cShare = MAX(0.0001f, MIN(1.0f - wShare, cShare));

    NSLayoutConstraint *oldW = refs[WUStr("wifiWidthConstraint")];
    NSLayoutConstraint *oldC = refs[WUStr("cellWidthConstraint")];
    if (oldW) oldW.active = NO;
    if (oldC) oldC.active = NO;

    NSLayoutConstraint *newW =
        [wifiBarView.widthAnchor constraintEqualToAnchor:barTrackView.widthAnchor multiplier:wShare];
    NSLayoutConstraint *newC =
        [cellBarView.widthAnchor constraintEqualToAnchor:barTrackView.widthAnchor multiplier:cShare];
    newW.active = YES;
    newC.active = YES;
    refs[WUStr("wifiWidthConstraint")] = newW;
    refs[WUStr("cellWidthConstraint")] = newC;

    return cell;
}
