#import "WUDataUsageItem.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

NSString *WUFormatBytes(uint64_t bytes) {
    if (bytes == 0) {
        return WUStr("0 B");
    }
    const double kb = 1024.0;
    const double mb = kb * 1024.0;
    const double gb = mb * 1024.0;
    const double tb = gb * 1024.0;

    char buf[64];
    if (bytes >= (uint64_t)tb) {
        snprintf(buf, sizeof(buf), "%.2f TB", (double)bytes / tb);
    } else if (bytes >= (uint64_t)gb) {
        snprintf(buf, sizeof(buf), "%.2f GB", (double)bytes / gb);
    } else if (bytes >= (uint64_t)mb) {
        snprintf(buf, sizeof(buf), "%.2f MB", (double)bytes / mb);
    } else if (bytes >= (uint64_t)kb) {
        snprintf(buf, sizeof(buf), "%.1f KB", (double)bytes / kb);
    } else {
        snprintf(buf, sizeof(buf), "%llu B", (unsigned long long)bytes);
    }
    return WUStr(buf);
}

UIImage *WUResolvedIconForItem(WUDataUsageItemDict *item) {
    static NSCache<NSString *, UIImage *> *iconCache = nil;
    static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;

    pthread_mutex_lock(&cacheLock);
    if (!iconCache) {
        iconCache = [[NSCache alloc] init];
        iconCache.countLimit = 256;
    }
    pthread_mutex_unlock(&cacheLock);

    NSString *key = item[WUStr("key")] ?: WUStr("unknown");
    UIImage *cached = [iconCache objectForKey:key];
    if (cached) {
        return cached;
    }

    WUDataUsageCategory category = (WUDataUsageCategory)[item[WUStr("category")] integerValue];
    NSString *bundleId = item[WUStr("bundleId")] ?: WUStr("");

    SEL iconSel = sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:");
    if (category == WUDataUsageCategoryApp && bundleId.length > 0 &&
        [UIImage respondsToSelector:iconSel]) {
        CGFloat scale = [UIScreen mainScreen].scale;
        UIImage * (*func)(id, SEL, NSString *, int, CGFloat) =
            (UIImage * (*)(id, SEL, NSString *, int, CGFloat))objc_msgSend;
        UIImage *appIcon = func([UIImage class], iconSel, bundleId, 0, scale);
        if ([appIcon isKindOfClass:[UIImage class]]) {
            [iconCache setObject:appIcon forKey:key];
            return appIcon;
        }
    }

    NSString *symbolName = (category == WUDataUsageCategoryApp)
        ? WUStr("app.fill")
        : WUStr("gearshape.2.fill");
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *fallback = [UIImage systemImageNamed:symbolName withConfiguration:config];
    if (!fallback) {
        fallback = [[UIImage alloc] init];
    }
    [iconCache setObject:fallback forKey:key];
    return fallback;
}
