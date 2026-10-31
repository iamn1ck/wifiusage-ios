#import "WUDataUsageManager.h"
#import <sqlite3.h>
#import <notify.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

static const char *const kSnapshotPathPrimaryCStr = "/var/jb/var/mobile/Library/Preferences/com.n1ck.wifiusage.snapshot.plist";
static const char *const kSnapshotPathFallbackCStr = "/tmp/com.n1ck.wifiusage.snapshot.plist";
static const char *const kLiveLedgerPathPrimaryCStr = "/var/jb/var/mobile/Library/Preferences/com.n1ck.wifiusage.liveledger.plist";
static const char *const kLiveLedgerPathFallbackCStr = "/tmp/com.n1ck.wifiusage.liveledger.plist";
static const char *const kNotifyRefresh = "com.n1ck.wifiusage.refresh";

static pthread_mutex_t gProcMapLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSString *> *gProcToBundleMap = nil;
static BOOL gInstalledAppsIndexed = NO;
static double gLastAutoRefreshTs = 0.0;

static pthread_mutex_t gAllTimeCacheLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gLastKnownAllTimeRecords = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gLastKnownAllTimeBuckets = nil;

void WURequestDaemonRefresh(void) {
    notify_post(kNotifyRefresh);
}

static void WURequestDaemonRefreshThrottled(void) {
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastAutoRefreshTs >= 4.0) {
        gLastAutoRefreshTs = now;
        notify_post(kNotifyRefresh);
    }
}

static void WURegisterProcBundleMapping(NSString *procName, NSString *bundleId) {
    if (![procName isKindOfClass:[NSString class]] || procName.length == 0) {
        return;
    }
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return;
    }
    pthread_mutex_lock(&gProcMapLock);
    if (!gProcToBundleMap) {
        gProcToBundleMap = [NSMutableDictionary dictionary];
    }
    gProcToBundleMap[procName] = bundleId;
    gProcToBundleMap[[procName lowercaseString]] = bundleId;
    if (procName.length > 15) {
        NSString *p15 = [procName substringToIndex:15];
        NSString *p16 = (procName.length > 16) ? [procName substringToIndex:16] : procName;
        if (!gProcToBundleMap[p15]) {
            gProcToBundleMap[p15] = bundleId;
        }
        if (!gProcToBundleMap[[p15 lowercaseString]]) {
            gProcToBundleMap[[p15 lowercaseString]] = bundleId;
        }
        if (!gProcToBundleMap[p16]) {
            gProcToBundleMap[p16] = bundleId;
        }
        if (!gProcToBundleMap[[p16 lowercaseString]]) {
            gProcToBundleMap[[p16 lowercaseString]] = bundleId;
        }
    }
    pthread_mutex_unlock(&gProcMapLock);
}

static void WUEnsureInstalledAppMappingsIndexed(id _Nullable lsWorkspace) {
    pthread_mutex_lock(&gProcMapLock);
    if (gInstalledAppsIndexed) {
        pthread_mutex_unlock(&gProcMapLock);
        return;
    }
    gInstalledAppsIndexed = YES;
    if (!gProcToBundleMap) {
        gProcToBundleMap = [NSMutableDictionary dictionary];
    }
    pthread_mutex_unlock(&gProcMapLock);

    id ws = lsWorkspace;
    if (!ws) {
        Class lsCls = objc_getClass("LSApplicationWorkspace");
        SEL defaultWsSel = sel_registerName("defaultWorkspace");
        if (lsCls && [lsCls respondsToSelector:defaultWsSel]) {
            id (*msgSendWs)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            ws = msgSendWs(lsCls, defaultWsSel);
        }
    }
    if (!ws) {
        return;
    }

    SEL allAppsSel = sel_registerName("allApplications");
    SEL appIdSel = sel_registerName("applicationIdentifier");
    SEL bundleIdSel = sel_registerName("bundleIdentifier");
    SEL bundleExecSel = sel_registerName("bundleExecutable");
    SEL bundleUrlSel = sel_registerName("bundleURL");

    if ([ws respondsToSelector:allAppsSel]) {
        id (*msgSendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        NSArray *apps = msgSendId(ws, allAppsSel);
        if ([apps isKindOfClass:[NSArray class]]) {
            for (id proxy in apps) {
                NSString *bId = nil;
                if ([proxy respondsToSelector:appIdSel]) {
                    bId = msgSendId(proxy, appIdSel);
                }
                if ((![bId isKindOfClass:[NSString class]] || bId.length == 0) &&
                    [proxy respondsToSelector:bundleIdSel]) {
                    bId = msgSendId(proxy, bundleIdSel);
                }
                if (![bId isKindOfClass:[NSString class]] || bId.length == 0) {
                    continue;
                }
                if ([proxy respondsToSelector:bundleExecSel]) {
                    NSString *exec = msgSendId(proxy, bundleExecSel);
                    if ([exec isKindOfClass:[NSString class]] && exec.length > 0) {
                        WURegisterProcBundleMapping(exec, bId);
                    }
                }
                if ([proxy respondsToSelector:bundleUrlSel]) {
                    NSURL *url = msgSendId(proxy, bundleUrlSel);
                    if ([url isKindOfClass:[NSURL class]]) {
                        NSString *last = [[url lastPathComponent] stringByDeletingPathExtension];
                        if (last.length > 0) {
                            WURegisterProcBundleMapping(last, bId);
                        }
                    }
                }
            }
        }
    }
}

static NSString *WUResolveBundleForProc(NSString *procName, NSString *bundleId) {
    if ([bundleId isKindOfClass:[NSString class]] && bundleId.length > 0) {
        if ([procName isKindOfClass:[NSString class]] && procName.length > 0) {
            WURegisterProcBundleMapping(procName, bundleId);
        }
        return bundleId;
    }
    if (![procName isKindOfClass:[NSString class]] || procName.length == 0) {
        return WUStr("");
    }
    pthread_mutex_lock(&gProcMapLock);
    NSString *found = nil;
    if (gProcToBundleMap) {
        found = gProcToBundleMap[procName];
        if (!found) {
            found = gProcToBundleMap[[procName lowercaseString]];
        }
        if (!found && procName.length >= 15) {
            NSString *p15 = [procName substringToIndex:15];
            found = gProcToBundleMap[p15] ?: gProcToBundleMap[[p15 lowercaseString]];
        }
    }
    pthread_mutex_unlock(&gProcMapLock);
    return found ?: WUStr("");
}

static NSDictionary<NSString *, NSString *> *WUKnownDaemonDescriptions(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static pthread_mutex_t mapLock = PTHREAD_MUTEX_INITIALIZER;

    pthread_mutex_lock(&mapLock);
    if (!map) {
        NSMutableDictionary<NSString *, NSString *> *m = [NSMutableDictionary dictionary];
        struct { const char *k; const char *v; } pairs[] = {
            {"mDNSResponder", "DNS & Bonjour (mDNSResponder)"},
            {"apsd", "Apple Push Notifications (apsd)"},
            {"cloudd", "iCloud Sync Daemon (cloudd)"},
            {"nsurlsessiond", "Background Transfers (nsurlsessiond)"},
            {"configd", "Network Configuration (configd)"},
            {"trustd", "Certificate Trust Evaluation (trustd)"},
            {"identityservicesd", "iMessage & FaceTime IDS (identityservicesd)"},
            {"SpringBoard", "Home Screen & System UI (SpringBoard)"},
            {"com.apple.springboard", "Home Screen & System UI (SpringBoard)"},
            {"parsecd", "Siri & Spotlight Suggestions (parsecd)"},
            {"itunesstored", "App Store & Media Services (itunesstored)"},
            {"appstored", "App Store Background Daemon (appstored)"},
            {"locationd", "Location Services (locationd)"},
            {"symptomsd", "Network Quality & Diagnostics (symptomsd)"},
            {"CommCenter", "Cellular Baseband Service (CommCenter)"},
            {"wifid", "Wi-Fi System Service (wifid)"},
            {"networkserviceproxy", "iCloud Private Relay / Proxy (networkserviceproxy)"},
            {"nesessionmanager", "VPN & Network Extensions (nesessionmanager)"},
            {"nehelper", "Network Extension Helper (nehelper)"},
            {"akd", "Apple ID AuthKit (akd)"},
            {"accountsd", "System Accounts Daemon (accountsd)"},
            {"bird", "iCloud Drive Daemon (bird)"},
            {"dasd", "Duet Activity Scheduler (dasd)"},
            {"avenir", "System Service"},
            {"rapportd", "Continuity & Handoff (rapportd)"},
            {"sharingd", "AirDrop & Nearby Sharing (sharingd)"},
            {"mediaremoted", "Media Remote Control (mediaremoted)"},
            {"bluetoothd", "Bluetooth System Service (bluetoothd)"},
            {"assistantd", "Siri Voice Assistant (assistantd)"},
            {"siriknowledged", "Siri Knowledge Service (siriknowledged)"},
            {"searchd", "Spotlight Search Service (searchd)"},
            {"weatherd", "Weather Background Service (weatherd)"},
            {"timed", "Network Time Synchronization (timed)"},
            {"geod", "Apple Maps Geo Services (geod)"},
            {"passd", "Apple Wallet & Pay (passd)"},
            {"fmfd", "Find My Friends / Devices (fmfd)"},
            {"findmydeviced", "Find My Service (findmydeviced)"},
            {"imagent", "iMessage Agent (imagent)"},
            {"IMTransferAgent", "iMessage Attachments (IMTransferAgent)"},
            {"assetsd", "Photo & Media Assets (assetsd)"},
            {"cloudphotod", "iCloud Photos Sync (cloudphotod)"},
            {"familycircled", "Family Sharing (familycircled)"},
            {"routined", "Significant Locations & Routine (routined)"},
            {"analyticsd", "System Diagnostics & Analytics (analyticsd)"},
            {"softwareupdateservicesd", "iOS Software Update (softwareupdateservicesd)"},
            {"mobileassetd", "System Mobile Assets (mobileassetd)"},
            {"adprivacyd", "Privacy-Preserving Attribution (adprivacyd)"},
            {"terminusd", "Continuity Link (terminusd)"},
            {"WiFiVelocity", "Wi-Fi Diagnostics (WiFiVelocity)"}
        };
        size_t count = sizeof(pairs) / sizeof(pairs[0]);
        for (size_t i = 0; i < count; i++) {
            m[WUStr(pairs[i].k)] = WUStr(pairs[i].v);
        }
        map = [m copy];
    }
    pthread_mutex_unlock(&mapLock);
    return map;
}

static void WUReadLiveInterfaceCounters(
    uint64_t *outWifiIn,
    uint64_t *outWifiOut,
    uint64_t *outCellIn,
    uint64_t *outCellOut
) {
    uint64_t wifiIn = 0;
    uint64_t wifiOut = 0;
    uint64_t cellIn = 0;
    uint64_t cellOut = 0;

    struct ifaddrs *addrs = NULL;
    if (getifaddrs(&addrs) == 0 && addrs != NULL) {
        for (struct ifaddrs *cursor = addrs; cursor != NULL; cursor = cursor->ifa_next) {
            if (cursor->ifa_addr == NULL || cursor->ifa_addr->sa_family != AF_LINK) {
                continue;
            }
            if (cursor->ifa_data == NULL || cursor->ifa_name == NULL) {
                continue;
            }
            struct if_data *ifd = (struct if_data *)cursor->ifa_data;
            const char *ifName = cursor->ifa_name;
            if (strcmp(ifName, "en0") == 0 || strcmp(ifName, "en1") == 0) {
                wifiIn += ifd->ifi_ibytes;
                wifiOut += ifd->ifi_obytes;
            } else if (strncmp(ifName, "pdp_ip", 6) == 0) {
                cellIn += ifd->ifi_ibytes;
                cellOut += ifd->ifi_obytes;
            }
        }
        freeifaddrs(addrs);
    }

    if (outWifiIn) *outWifiIn = wifiIn;
    if (outWifiOut) *outWifiOut = wifiOut;
    if (outCellIn) *outCellIn = cellIn;
    if (outCellOut) *outCellOut = cellOut;
}

static inline double WUToReferenceTimestamp(double rawTs) {
    if (rawTs <= 0.0) {
        return 0.0;
    }
    if (rawTs > 1200000000.0) {
        return rawTs - kCFAbsoluteTimeIntervalSince1970;
    }
    return rawTs;
}

static void WUMergeRecord(
    NSString *key,
    NSString *procName,
    NSString *bundleId,
    uint64_t wifiIn,
    uint64_t wifiOut,
    uint64_t wwanIn,
    uint64_t wwanOut,
    double firstTs,
    double lastTs,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *recordsMap
) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *safeProc = [procName isKindOfClass:[NSString class]] ? procName : WUStr("");
    NSString *safeBundle = [bundleId isKindOfClass:[NSString class]] ? bundleId : WUStr("");

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    NSMutableDictionary *existing = recordsMap[key];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = safeProc;
        existing[kBundle] = safeBundle;
        existing[kWifiIn] = WUU64(wifiIn);
        existing[kWifiOut] = WUU64(wifiOut);
        existing[kWwanIn] = WUU64(wwanIn);
        existing[kWwanOut] = WUU64(wwanOut);
        existing[kFirstTs] = WUDouble(firstTs);
        existing[kLastTs] = WUDouble(lastTs);
        recordsMap[key] = existing;
    } else {
        NSString *exProc = existing[kProc];
        if ((![exProc isKindOfClass:[NSString class]] || exProc.length == 0) && safeProc.length > 0) {
            existing[kProc] = safeProc;
        }
        NSString *exBundle = existing[kBundle];
        if ((![exBundle isKindOfClass:[NSString class]] || exBundle.length == 0) && safeBundle.length > 0) {
            existing[kBundle] = safeBundle;
        }

        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        existing[kWifiIn] = WUU64(MAX(prevWifiIn, wifiIn));
        existing[kWifiOut] = WUU64(MAX(prevWifiOut, wifiOut));
        existing[kWwanIn] = WUU64(MAX(prevWwanIn, wwanIn));
        existing[kWwanOut] = WUU64(MAX(prevWwanOut, wwanOut));

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDouble(lastTs);
        }
    }
}

static void WUMergeBucketRecord(
    NSString *key,
    NSString *procName,
    NSString *bundleId,
    int64_t bucketHr,
    uint64_t wifiIn,
    uint64_t wifiOut,
    uint64_t wwanIn,
    uint64_t wwanOut,
    double firstTs,
    double lastTs,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap
) {
    if (!bucketsMap || ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *safeProc = [procName isKindOfClass:[NSString class]] ? procName : WUStr("");
    NSString *safeBundle = [bundleId isKindOfClass:[NSString class]] ? bundleId : WUStr("");
    NSString *bucketKey = [NSString stringWithFormat:WUStr("%@#%lld"), key, (long long)bucketHr];

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kBucketHr = WUStr("bucketHour");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    NSMutableDictionary *existing = bucketsMap[bucketKey];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = safeProc;
        existing[kBundle] = safeBundle;
        existing[kBucketHr] = [NSNumber numberWithLongLong:bucketHr];
        existing[kWifiIn] = WUU64(wifiIn);
        existing[kWifiOut] = WUU64(wifiOut);
        existing[kWwanIn] = WUU64(wwanIn);
        existing[kWwanOut] = WUU64(wwanOut);
        existing[kFirstTs] = WUDouble(firstTs);
        existing[kLastTs] = WUDouble(lastTs);
        bucketsMap[bucketKey] = existing;
    } else {
        NSString *exProc = existing[kProc];
        if ((![exProc isKindOfClass:[NSString class]] || exProc.length == 0) && safeProc.length > 0) {
            existing[kProc] = safeProc;
        }
        NSString *exBundle = existing[kBundle];
        if ((![exBundle isKindOfClass:[NSString class]] || exBundle.length == 0) && safeBundle.length > 0) {
            existing[kBundle] = safeBundle;
        }

        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        existing[kWifiIn] = WUU64(MAX(prevWifiIn, wifiIn));
        existing[kWifiOut] = WUU64(MAX(prevWifiOut, wifiOut));
        existing[kWwanIn] = WUU64(MAX(prevWwanIn, wwanIn));
        existing[kWwanOut] = WUU64(MAX(prevWwanOut, wwanOut));

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDouble(lastTs);
        }
    }
}

static void WUAccumulatePeriodRecord(
    NSString *key,
    NSString *procName,
    NSString *bundleId,
    uint64_t wifiIn,
    uint64_t wifiOut,
    uint64_t wwanIn,
    uint64_t wwanOut,
    double firstTs,
    double lastTs,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *periodRecordsMap
) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *safeProc = [procName isKindOfClass:[NSString class]] ? procName : WUStr("");
    NSString *safeBundle = [bundleId isKindOfClass:[NSString class]] ? bundleId : WUStr("");

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    NSMutableDictionary *existing = periodRecordsMap[key];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = safeProc;
        existing[kBundle] = safeBundle;
        existing[kWifiIn] = WUU64(wifiIn);
        existing[kWifiOut] = WUU64(wifiOut);
        existing[kWwanIn] = WUU64(wwanIn);
        existing[kWwanOut] = WUU64(wwanOut);
        existing[kFirstTs] = WUDouble(firstTs);
        existing[kLastTs] = WUDouble(lastTs);
        periodRecordsMap[key] = existing;
    } else {
        NSString *exProc = existing[kProc];
        if ((![exProc isKindOfClass:[NSString class]] || exProc.length == 0) && safeProc.length > 0) {
            existing[kProc] = safeProc;
        }
        NSString *exBundle = existing[kBundle];
        if ((![exBundle isKindOfClass:[NSString class]] || exBundle.length == 0) && safeBundle.length > 0) {
            existing[kBundle] = safeBundle;
        }

        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        existing[kWifiIn] = WUU64(prevWifiIn + wifiIn);
        existing[kWifiOut] = WUU64(prevWifiOut + wifiOut);
        existing[kWwanIn] = WUU64(prevWwanIn + wwanIn);
        existing[kWwanOut] = WUU64(prevWwanOut + wwanOut);

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDouble(lastTs);
        }
    }
}

static void WUAccumulateBucketRecord(
    NSString *key,
    NSString *procName,
    NSString *bundleId,
    int64_t bucketHr,
    uint64_t wifiIn,
    uint64_t wifiOut,
    uint64_t wwanIn,
    uint64_t wwanOut,
    double firstTs,
    double lastTs,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap
) {
    if (!bucketsMap || ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *safeProc = [procName isKindOfClass:[NSString class]] ? procName : WUStr("");
    NSString *safeBundle = [bundleId isKindOfClass:[NSString class]] ? bundleId : WUStr("");
    NSString *bucketKey = [NSString stringWithFormat:WUStr("%@#%lld"), key, (long long)bucketHr];

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kBucketHr = WUStr("bucketHour");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    NSMutableDictionary *existing = bucketsMap[bucketKey];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = safeProc;
        existing[kBundle] = safeBundle;
        existing[kBucketHr] = [NSNumber numberWithLongLong:bucketHr];
        existing[kWifiIn] = WUU64(wifiIn);
        existing[kWifiOut] = WUU64(wifiOut);
        existing[kWwanIn] = WUU64(wwanIn);
        existing[kWwanOut] = WUU64(wwanOut);
        existing[kFirstTs] = WUDouble(firstTs);
        existing[kLastTs] = WUDouble(lastTs);
        bucketsMap[bucketKey] = existing;
    } else {
        NSString *exProc = existing[kProc];
        if ((![exProc isKindOfClass:[NSString class]] || exProc.length == 0) && safeProc.length > 0) {
            existing[kProc] = safeProc;
        }
        NSString *exBundle = existing[kBundle];
        if ((![exBundle isKindOfClass:[NSString class]] || exBundle.length == 0) && safeBundle.length > 0) {
            existing[kBundle] = safeBundle;
        }

        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        existing[kWifiIn] = WUU64(prevWifiIn + wifiIn);
        existing[kWifiOut] = WUU64(prevWifiOut + wifiOut);
        existing[kWwanIn] = WUU64(prevWwanIn + wwanIn);
        existing[kWwanOut] = WUU64(prevWwanOut + wwanOut);

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDouble(lastTs);
        }
    }
}

static BOOL WULoadFromSnapshotPlist(
    NSMutableDictionary<NSString *, NSMutableDictionary *> *recordsMap,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap,
    NSMutableArray<NSString *> *sourcesList,
    NSDate * __strong *outDate
) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *primaryPath = WUStr(kSnapshotPathPrimaryCStr);
    NSString *fallbackPath = WUStr(kSnapshotPathFallbackCStr);
    NSString *chosenPath = nil;

    if ([fm fileExistsAtPath:primaryPath]) {
        chosenPath = primaryPath;
    } else if ([fm fileExistsAtPath:fallbackPath]) {
        chosenPath = fallbackPath;
    }
    if (!chosenPath) {
        return NO;
    }

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:chosenPath];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSArray *items = plist[WUStr("items")];
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) {
        return NO;
    }

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kBucketHr = WUStr("bucketHour");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    for (NSDictionary *entry in items) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *procName = entry[kProc] ?: WUStr("");
        NSString *bundleId = entry[kBundle] ?: WUStr("");
        if (procName.length > 0 && bundleId.length > 0) {
            WURegisterProcBundleMapping(procName, bundleId);
        }
    }

    NSMutableDictionary<NSString *, NSMutableDictionary *> *snapRecords = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *snapBuckets = [NSMutableDictionary dictionary];

    for (NSDictionary *entry in items) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *procName = entry[kProc] ?: WUStr("");
        NSString *bundleId = WUResolveBundleForProc(procName, entry[kBundle] ?: WUStr(""));
        NSString *key = (bundleId.length > 0) ? bundleId : (entry[kKey] ?: procName);
        if (![key isKindOfClass:[NSString class]] || key.length == 0) {
            key = (bundleId.length > 0) ? bundleId : procName;
        }
        uint64_t wifiIn = [entry[kWifiIn] unsignedLongLongValue];
        uint64_t wifiOut = [entry[kWifiOut] unsignedLongLongValue];
        uint64_t wwanIn = [entry[kWwanIn] unsignedLongLongValue];
        uint64_t wwanOut = [entry[kWwanOut] unsignedLongLongValue];
        double firstTs = [entry[kFirstTs] doubleValue];
        double lastTs = [entry[kLastTs] doubleValue];

        WUAccumulatePeriodRecord(
            key,
            procName,
            bundleId,
            wifiIn,
            wifiOut,
            wwanIn,
            wwanOut,
            firstTs,
            lastTs,
            snapRecords
        );
    }

    for (NSDictionary *rec in [snapRecords allValues]) {
        WUMergeRecord(
            rec[kKey],
            rec[kProc],
            rec[kBundle],
            [rec[kWifiIn] unsignedLongLongValue],
            [rec[kWifiOut] unsignedLongLongValue],
            [rec[kWwanIn] unsignedLongLongValue],
            [rec[kWwanOut] unsignedLongLongValue],
            [rec[kFirstTs] doubleValue],
            [rec[kLastTs] doubleValue],
            recordsMap
        );
    }

    NSArray *buckets = plist[WUStr("buckets")];
    if ([buckets isKindOfClass:[NSArray class]] && bucketsMap) {
        for (NSDictionary *entry in buckets) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *procName = entry[kProc] ?: WUStr("");
            NSString *bundleId = WUResolveBundleForProc(procName, entry[kBundle] ?: WUStr(""));
            NSString *key = (bundleId.length > 0) ? bundleId : (entry[kKey] ?: procName);
            if (![key isKindOfClass:[NSString class]] || key.length == 0) {
                key = (bundleId.length > 0) ? bundleId : procName;
            }
            int64_t bucketHr = [entry[kBucketHr] longLongValue];
            uint64_t wifiIn = [entry[kWifiIn] unsignedLongLongValue];
            uint64_t wifiOut = [entry[kWifiOut] unsignedLongLongValue];
            uint64_t wwanIn = [entry[kWwanIn] unsignedLongLongValue];
            uint64_t wwanOut = [entry[kWwanOut] unsignedLongLongValue];
            double firstTs = [entry[kFirstTs] doubleValue];
            double lastTs = [entry[kLastTs] doubleValue];

            WUAccumulateBucketRecord(
                key,
                procName,
                bundleId,
                bucketHr,
                wifiIn,
                wifiOut,
                wwanIn,
                wwanOut,
                firstTs,
                lastTs,
                snapBuckets
            );
        }

        for (NSDictionary *bRec in [snapBuckets allValues]) {
            WUMergeBucketRecord(
                bRec[kKey],
                bRec[kProc],
                bRec[kBundle],
                [bRec[kBucketHr] longLongValue],
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                [bRec[kFirstTs] doubleValue],
                [bRec[kLastTs] doubleValue],
                bucketsMap
            );
        }
    }

    NSArray *src = plist[WUStr("sources")];
    if ([src isKindOfClass:[NSArray class]]) {
        for (id s in src) {
            if ([s isKindOfClass:[NSString class]] && ![sourcesList containsObject:s]) {
                [sourcesList addObject:s];
            }
        }
    }

    NSNumber *genAt = plist[WUStr("generatedAt")];
    if ([genAt isKindOfClass:[NSNumber class]] && [genAt doubleValue] > 0 && outDate) {
        *outDate = [NSDate dateWithTimeIntervalSince1970:[genAt doubleValue]];
    }

    return (recordsMap.count > 0);
}

static BOOL WULoadFromLiveLedgerPlist(
    NSMutableDictionary<NSString *, NSMutableDictionary *> *recordsMap,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap,
    NSMutableArray<NSString *> *sourcesList
) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *primaryPath = WUStr(kLiveLedgerPathPrimaryCStr);
    NSString *fallbackPath = WUStr(kLiveLedgerPathFallbackCStr);
    NSString *chosenPath = nil;

    if ([fm fileExistsAtPath:primaryPath]) {
        chosenPath = primaryPath;
    } else if ([fm fileExistsAtPath:fallbackPath]) {
        chosenPath = fallbackPath;
    }
    if (!chosenPath) {
        return NO;
    }

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:chosenPath];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kBucketHr = WUStr("bucketHour");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    BOOL loadedAny = NO;
    NSArray *items = plist[WUStr("items")];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *entry in items) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *procName = entry[kProc] ?: WUStr("");
            NSString *bundleId = WUResolveBundleForProc(procName, entry[kBundle] ?: WUStr(""));
            NSString *key = (bundleId.length > 0) ? bundleId : (entry[kKey] ?: procName);
            WUMergeRecord(
                key,
                procName,
                bundleId,
                [entry[kWifiIn] unsignedLongLongValue],
                [entry[kWifiOut] unsignedLongLongValue],
                [entry[kWwanIn] unsignedLongLongValue],
                [entry[kWwanOut] unsignedLongLongValue],
                [entry[kFirstTs] doubleValue],
                [entry[kLastTs] doubleValue],
                recordsMap
            );
            loadedAny = YES;
        }
    }

    NSArray *buckets = plist[WUStr("buckets")];
    if ([buckets isKindOfClass:[NSArray class]] && bucketsMap) {
        for (NSDictionary *entry in buckets) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *procName = entry[kProc] ?: WUStr("");
            NSString *bundleId = WUResolveBundleForProc(procName, entry[kBundle] ?: WUStr(""));
            NSString *key = (bundleId.length > 0) ? bundleId : (entry[kKey] ?: procName);
            WUMergeBucketRecord(
                key,
                procName,
                bundleId,
                [entry[kBucketHr] longLongValue],
                [entry[kWifiIn] unsignedLongLongValue],
                [entry[kWifiOut] unsignedLongLongValue],
                [entry[kWwanIn] unsignedLongLongValue],
                [entry[kWwanOut] unsignedLongLongValue],
                [entry[kFirstTs] doubleValue],
                [entry[kLastTs] doubleValue],
                bucketsMap
            );
        }
    }

    if (loadedAny && sourcesList && ![sourcesList containsObject:WUStr("NetworkStatistics")]) {
        [sourcesList addObject:WUStr("NetworkStatistics")];
    }
    return loadedAny;
}

static NSSet<NSString *> *WUGetSQLiteTableColumns(sqlite3 *db, const char *tableName) {
    NSMutableSet<NSString *> *cols = [NSMutableSet set];
    char pragmaSql[256];
    snprintf(pragmaSql, sizeof(pragmaSql), "PRAGMA table_info(%s);", tableName);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, pragmaSql, -1, &stmt, NULL) == SQLITE_OK && stmt != NULL) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *colName = (const char *)sqlite3_column_text(stmt, 1);
            if (colName && colName[0] != '\0') {
                [cols addObject:[WUStr(colName) uppercaseString]];
            }
        }
        sqlite3_finalize(stmt);
    }
    return cols;
}

static sqlite3 *WUOpenSQLiteWithImmutableFallback(NSString *dbPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dbPath]) {
        return NULL;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && db != NULL) {
        sqlite3_busy_timeout(db, 1200);
        sqlite3_stmt *testStmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &testStmt, NULL) == SQLITE_OK && testStmt != NULL) {
            sqlite3_step(testStmt);
            sqlite3_finalize(testStmt);
            return db;
        }
        sqlite3_close(db);
        db = NULL;
    }

    NSString *uri = [NSString stringWithFormat:WUStr("file:%@?immutable=1"), dbPath];
    if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) == SQLITE_OK && db != NULL) {
        sqlite3_busy_timeout(db, 1200);
        return db;
    }
    if (db != NULL) {
        sqlite3_close(db);
    }
    return NULL;
}

static BOOL WUQuerySQLiteAtPath(
    NSString *dbPath,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *recordsMap,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap
) {
    sqlite3 *db = WUOpenSQLiteWithImmutableFallback(dbPath);
    if (!db) {
        return NO;
    }

    NSSet<NSString *> *procCols = WUGetSQLiteTableColumns(db, "ZPROCESS");
    NSSet<NSString *> *liveCols = WUGetSQLiteTableColumns(db, "ZLIVEUSAGE");

    if ([procCols containsObject:WUStr("ZPROCNAME")] &&
        [procCols containsObject:WUStr("ZBUNDLENAME")]) {
        const char *mapSql =
            "SELECT ZPROCNAME, ZBUNDLENAME FROM ZPROCESS "
            "WHERE ZPROCNAME IS NOT NULL AND ZPROCNAME != '' "
            "  AND ZBUNDLENAME IS NOT NULL AND ZBUNDLENAME != '';";
        sqlite3_stmt *mapStmt = NULL;
        if (sqlite3_prepare_v2(db, mapSql, -1, &mapStmt, NULL) == SQLITE_OK && mapStmt != NULL) {
            while (sqlite3_step(mapStmt) == SQLITE_ROW) {
                const char *cProc = (const char *)sqlite3_column_text(mapStmt, 0);
                const char *cBundle = (const char *)sqlite3_column_text(mapStmt, 1);
                if (cProc && cBundle) {
                    WURegisterProcBundleMapping(WUStr(cProc), WUStr(cBundle));
                }
            }
            sqlite3_finalize(mapStmt);
        }
    }

    if (liveCols.count == 0 || ![liveCols containsObject:WUStr("ZHASPROCESS")]) {
        sqlite3_close(db);
        return NO;
    }

    BOOL hasWifiIn = [liveCols containsObject:WUStr("ZWIFIIN")];
    BOOL hasWifiOut = [liveCols containsObject:WUStr("ZWIFIOUT")];
    BOOL hasWiredIn = [liveCols containsObject:WUStr("ZWIREDIN")];
    BOOL hasWiredOut = [liveCols containsObject:WUStr("ZWIREDOUT")];
    BOOL hasWwanIn = [liveCols containsObject:WUStr("ZWWANIN")];
    BOOL hasWwanOut = [liveCols containsObject:WUStr("ZWWANOUT")];
    BOOL hasTs = [liveCols containsObject:WUStr("ZTIMESTAMP")];
    BOOL hasFirstTs = [procCols containsObject:WUStr("ZFIRSTTIMESTAMP")];

    const char *wifiInExpr = "0";
    if (hasWifiIn && hasWiredIn) {
        wifiInExpr = "COALESCE(u.ZWIFIIN, 0) + COALESCE(u.ZWIREDIN, 0)";
    } else if (hasWifiIn) {
        wifiInExpr = "COALESCE(u.ZWIFIIN, 0)";
    } else if (hasWiredIn) {
        wifiInExpr = "COALESCE(u.ZWIREDIN, 0)";
    }

    const char *wifiOutExpr = "0";
    if (hasWifiOut && hasWiredOut) {
        wifiOutExpr = "COALESCE(u.ZWIFIOUT, 0) + COALESCE(u.ZWIREDOUT, 0)";
    } else if (hasWifiOut) {
        wifiOutExpr = "COALESCE(u.ZWIFIOUT, 0)";
    } else if (hasWiredOut) {
        wifiOutExpr = "COALESCE(u.ZWIREDOUT, 0)";
    }

    const char *wwanInExpr = hasWwanIn ? "COALESCE(u.ZWWANIN, 0)" : "0";
    const char *wwanOutExpr = hasWwanOut ? "COALESCE(u.ZWWANOUT, 0)" : "0";
    const char *firstTsExpr = hasFirstTs ? "COALESCE(p.ZFIRSTTIMESTAMP, 0)" : "0";
    const char *lastTsExpr = hasTs ? "COALESCE(u.ZTIMESTAMP, 0)" : firstTsExpr;

    char sql[2048];
    snprintf(
        sql,
        sizeof(sql),
        "SELECT "
        "  COALESCE(p.ZPROCNAME, ''), "
        "  COALESCE(p.ZBUNDLENAME, ''), "
        "  SUM(%s), "
        "  SUM(%s), "
        "  SUM(%s), "
        "  SUM(%s), "
        "  MIN(%s), "
        "  MAX(%s) "
        "FROM ZLIVEUSAGE u "
        "LEFT JOIN ZPROCESS p ON u.ZHASPROCESS = p.Z_PK "
        "GROUP BY COALESCE(p.ZPROCNAME, ''), COALESCE(p.ZBUNDLENAME, '');",
        wifiInExpr,
        wifiOutExpr,
        wwanInExpr,
        wwanOutExpr,
        firstTsExpr,
        lastTsExpr
    );

    NSMutableDictionary<NSString *, NSMutableDictionary *> *dbRecords = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *dbBuckets = [NSMutableDictionary dictionary];

    sqlite3_stmt *stmt = NULL;
    BOOL ok = NO;

    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt != NULL) {
        ok = YES;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *cProc = (const char *)sqlite3_column_text(stmt, 0);
            const char *cBundle = (const char *)sqlite3_column_text(stmt, 1);

            NSString *procName = WUStr(cProc);
            NSString *bundleId = WUResolveBundleForProc(procName, WUStr(cBundle));
            NSString *key = (bundleId.length > 0) ? bundleId : procName;
            if (key.length == 0) {
                continue;
            }

            uint64_t wifiIn = (uint64_t)MAX(0.0, sqlite3_column_double(stmt, 2));
            uint64_t wifiOut = (uint64_t)MAX(0.0, sqlite3_column_double(stmt, 3));
            uint64_t wwanIn = (uint64_t)MAX(0.0, sqlite3_column_double(stmt, 4));
            uint64_t wwanOut = (uint64_t)MAX(0.0, sqlite3_column_double(stmt, 5));
            double firstTs = sqlite3_column_double(stmt, 6);
            double lastTs = sqlite3_column_double(stmt, 7);

            WUAccumulatePeriodRecord(
                key,
                procName,
                bundleId,
                wifiIn,
                wifiOut,
                wwanIn,
                wwanOut,
                firstTs,
                lastTs,
                dbRecords
            );
        }
        sqlite3_finalize(stmt);
    }

    if (bucketsMap) {
        char bucketSql[2048];
        snprintf(
            bucketSql,
            sizeof(bucketSql),
            "SELECT "
            "  COALESCE(p.ZPROCNAME, ''), "
            "  COALESCE(p.ZBUNDLENAME, ''), "
            "  CAST(COALESCE(NULLIF(%s, 0), NULLIF(%s, 0), 0) / 3600 AS INTEGER), "
            "  SUM(%s), "
            "  SUM(%s), "
            "  SUM(%s), "
            "  SUM(%s), "
            "  MIN(%s), "
            "  MAX(COALESCE(NULLIF(%s, 0), %s)) "
            "FROM ZLIVEUSAGE u "
            "LEFT JOIN ZPROCESS p ON u.ZHASPROCESS = p.Z_PK "
            "GROUP BY COALESCE(p.ZPROCNAME, ''), COALESCE(p.ZBUNDLENAME, ''), "
            "         CAST(COALESCE(NULLIF(%s, 0), NULLIF(%s, 0), 0) / 3600 AS INTEGER);",
            lastTsExpr,
            firstTsExpr,
            wifiInExpr,
            wifiOutExpr,
            wwanInExpr,
            wwanOutExpr,
            firstTsExpr,
            lastTsExpr,
            firstTsExpr,
            lastTsExpr,
            firstTsExpr
        );

        sqlite3_stmt *bucketStmt = NULL;
        if (sqlite3_prepare_v2(db, bucketSql, -1, &bucketStmt, NULL) == SQLITE_OK && bucketStmt != NULL) {
            while (sqlite3_step(bucketStmt) == SQLITE_ROW) {
                const char *cProc = (const char *)sqlite3_column_text(bucketStmt, 0);
                const char *cBundle = (const char *)sqlite3_column_text(bucketStmt, 1);

                NSString *procName = WUStr(cProc);
                NSString *bundleId = WUResolveBundleForProc(procName, WUStr(cBundle));
                NSString *key = (bundleId.length > 0) ? bundleId : procName;
                if (key.length == 0) {
                    continue;
                }

                int64_t bucketHr = sqlite3_column_int64(bucketStmt, 2);
                uint64_t wifiIn = (uint64_t)MAX(0.0, sqlite3_column_double(bucketStmt, 3));
                uint64_t wifiOut = (uint64_t)MAX(0.0, sqlite3_column_double(bucketStmt, 4));
                uint64_t wwanIn = (uint64_t)MAX(0.0, sqlite3_column_double(bucketStmt, 5));
                uint64_t wwanOut = (uint64_t)MAX(0.0, sqlite3_column_double(bucketStmt, 6));
                double firstTs = sqlite3_column_double(bucketStmt, 7);
                double lastTs = sqlite3_column_double(bucketStmt, 8);

                WUAccumulateBucketRecord(
                    key,
                    procName,
                    bundleId,
                    bucketHr,
                    wifiIn,
                    wifiOut,
                    wwanIn,
                    wwanOut,
                    firstTs,
                    lastTs,
                    dbBuckets
                );
            }
            sqlite3_finalize(bucketStmt);
        }
    }

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kBucketHr = WUStr("bucketHour");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");

    for (NSDictionary *rec in [dbRecords allValues]) {
        WUMergeRecord(
            rec[kKey],
            rec[kProc],
            rec[kBundle],
            [rec[kWifiIn] unsignedLongLongValue],
            [rec[kWifiOut] unsignedLongLongValue],
            [rec[kWwanIn] unsignedLongLongValue],
            [rec[kWwanOut] unsignedLongLongValue],
            [rec[kFirstTs] doubleValue],
            [rec[kLastTs] doubleValue],
            recordsMap
        );
    }

    if (bucketsMap) {
        for (NSDictionary *bRec in [dbBuckets allValues]) {
            WUMergeBucketRecord(
                bRec[kKey],
                bRec[kProc],
                bRec[kBundle],
                [bRec[kBucketHr] longLongValue],
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                [bRec[kFirstTs] doubleValue],
                [bRec[kLastTs] doubleValue],
                bucketsMap
            );
        }
    }

    sqlite3_close(db);
    return ok;
}

static WUDataUsageItemDict *WUBuildItemFromRawRecord(
    NSDictionary *raw,
    id _Nullable lsWorkspace
) {
    static NSMutableDictionary<NSString *, NSDictionary *> *metaCache = nil;
    static pthread_mutex_t metaLock = PTHREAD_MUTEX_INITIALIZER;

    NSString *key = raw[WUStr("key")] ?: WUStr("");
    NSString *procName = raw[WUStr("procName")] ?: WUStr("");
    NSString *bundleId = raw[WUStr("bundleId")] ?: WUStr("");

    uint64_t wifiIn = [raw[WUStr("wifiIn")] unsignedLongLongValue];
    uint64_t wifiOut = [raw[WUStr("wifiOut")] unsignedLongLongValue];
    uint64_t cellIn = [raw[WUStr("wwanIn")] unsignedLongLongValue];
    uint64_t cellOut = [raw[WUStr("wwanOut")] unsignedLongLongValue];
    double firstTs = [raw[WUStr("firstTimestamp")] doubleValue];
    double lastTs = [raw[WUStr("lastTimestamp")] doubleValue];

    NSDictionary *cachedMeta = nil;
    if (key.length > 0) {
        pthread_mutex_lock(&metaLock);
        if (!metaCache) {
            metaCache = [NSMutableDictionary dictionary];
        }
        cachedMeta = metaCache[key];
        pthread_mutex_unlock(&metaLock);
    }

    NSString *displayName = nil;
    NSString *subtitle = nil;
    WUDataUsageCategory category = WUDataUsageCategorySystem;
    BOOL isSystemApp = NO;

    if (cachedMeta) {
        displayName = cachedMeta[WUStr("displayName")];
        subtitle = cachedMeta[WUStr("subtitle")];
        category = (WUDataUsageCategory)[cachedMeta[WUStr("category")] integerValue];
        isSystemApp = [cachedMeta[WUStr("isSystemApp")] boolValue];
    } else {
        BOOL isApp = NO;
        NSString *resolvedName = nil;

        SEL appProxySel = sel_registerName("applicationProxyForIdentifier:");
        SEL appTypeSel = sel_registerName("applicationType");
        SEL locNameSel = sel_registerName("localizedName");
        SEL itemNameSel = sel_registerName("itemName");

        if (bundleId.length > 0 && lsWorkspace && [lsWorkspace respondsToSelector:appProxySel]) {
            id (*msgSendId)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
            id proxy = msgSendId(lsWorkspace, appProxySel, bundleId);
            if (proxy) {
                NSString * (*msgSendStr)(id, SEL) = (NSString * (*)(id, SEL))objc_msgSend;
                NSString *appType = [proxy respondsToSelector:appTypeSel] ? msgSendStr(proxy, appTypeSel) : nil;
                NSString *locName = [proxy respondsToSelector:locNameSel] ? msgSendStr(proxy, locNameSel) : nil;
                if (![locName isKindOfClass:[NSString class]] || locName.length == 0) {
                    locName = [proxy respondsToSelector:itemNameSel] ? msgSendStr(proxy, itemNameSel) : nil;
                }
                if ([locName isKindOfClass:[NSString class]] && locName.length > 0 &&
                    ![locName isEqualToString:bundleId]) {
                    resolvedName = locName;
                    isApp = YES;
                    if ([appType isKindOfClass:[NSString class]] &&
                        [appType isEqualToString:WUStr("System")]) {
                        isSystemApp = YES;
                    }
                } else if ([appType isKindOfClass:[NSString class]] &&
                           ([appType isEqualToString:WUStr("User")] ||
                            [appType isEqualToString:WUStr("System")])) {
                    if (![bundleId hasPrefix:WUStr("com.apple.")] ||
                        (locName && locName.length > 0)) {
                        isApp = YES;
                        isSystemApp = [appType isEqualToString:WUStr("System")];
                        resolvedName = (locName.length > 0) ? locName : bundleId;
                    }
                }
            }
        }

        NSDictionary<NSString *, NSString *> *daemonMap = WUKnownDaemonDescriptions();
        NSString *daemonFriendly = nil;
        if (procName.length > 0) {
            daemonFriendly = daemonMap[procName];
        }
        if (!daemonFriendly && bundleId.length > 0) {
            daemonFriendly = daemonMap[bundleId];
        }

        if (daemonFriendly) {
            if ([bundleId isEqualToString:WUStr("com.apple.springboard")] ||
                [procName isEqualToString:WUStr("SpringBoard")]) {
                isApp = NO;
                resolvedName = daemonFriendly;
            } else if (!isApp) {
                resolvedName = daemonFriendly;
            }
        }

        if (!isApp && bundleId.length > 0 && ![bundleId hasPrefix:WUStr("com.apple.")]) {
            if ([bundleId containsString:WUStr(".")]) {
                isApp = YES;
                isSystemApp = NO;
                if (!resolvedName || resolvedName.length == 0) {
                    NSString *lastComp = [[bundleId componentsSeparatedByString:WUStr(".")] lastObject];
                    resolvedName = (lastComp.length > 0) ? [lastComp capitalizedString] : bundleId;
                }
            }
        }

        category = isApp ? WUDataUsageCategoryApp : WUDataUsageCategorySystem;

        if (isApp) {
            displayName = (resolvedName.length > 0) ? resolvedName : (bundleId.length > 0 ? bundleId : procName);
            if (bundleId.length > 0 && procName.length > 0 && ![bundleId isEqualToString:procName]) {
                subtitle = [NSString stringWithFormat:WUStr("%@ (%@)"), bundleId, procName];
            } else {
                subtitle = (bundleId.length > 0) ? bundleId : procName;
            }
        } else {
            if (resolvedName.length > 0) {
                displayName = resolvedName;
            } else if (procName.length > 0) {
                displayName = procName;
            } else {
                displayName = bundleId;
            }

            if (bundleId.length > 0 && procName.length > 0 && ![bundleId isEqualToString:procName]) {
                subtitle = [NSString stringWithFormat:WUStr("%@ • %@"), procName, bundleId];
            } else if (bundleId.length > 0) {
                subtitle = bundleId;
            } else {
                subtitle = WUStr("iOS System Process / Daemon");
            }
        }

        if (key.length > 0) {
            NSMutableDictionary *meta = [NSMutableDictionary dictionary];
            meta[WUStr("displayName")] = displayName ?: WUStr("Unknown");
            meta[WUStr("subtitle")] = subtitle ?: WUStr("");
            meta[WUStr("category")] = WUInt(category);
            meta[WUStr("isSystemApp")] = WUBool(isSystemApp);
            pthread_mutex_lock(&metaLock);
            metaCache[key] = meta;
            pthread_mutex_unlock(&metaLock);
        }
    }

    uint64_t totalWifi = wifiIn + wifiOut;
    uint64_t totalCell = cellIn + cellOut;
    uint64_t totalBytes = totalWifi + totalCell;

    NSMutableDictionary<NSString *, id> *item = [NSMutableDictionary dictionary];
    item[WUStr("key")] = key;
    item[WUStr("displayName")] = displayName ?: WUStr("Unknown");
    item[WUStr("subtitle")] = subtitle ?: WUStr("");
    item[WUStr("bundleId")] = bundleId ?: WUStr("");
    item[WUStr("procName")] = procName ?: WUStr("");
    item[WUStr("category")] = WUInt(category);
    item[WUStr("isSystemApp")] = WUBool(isSystemApp);
    item[WUStr("wifiInBytes")] = WUU64(wifiIn);
    item[WUStr("wifiOutBytes")] = WUU64(wifiOut);
    item[WUStr("cellularInBytes")] = WUU64(cellIn);
    item[WUStr("cellularOutBytes")] = WUU64(cellOut);
    item[WUStr("totalWifiBytes")] = WUU64(totalWifi);
    item[WUStr("totalCellularBytes")] = WUU64(totalCell);
    item[WUStr("totalBytes")] = WUU64(totalBytes);
    item[WUStr("firstTimestamp")] = WUDouble(firstTs);
    item[WUStr("lastTimestamp")] = WUDouble(lastTs);
    return item;
}

static NSInteger WUCompareItemsFunction(
    id aObj,
    id bObj,
    void *context
) {
    WUDataUsageItemDict *a = (WUDataUsageItemDict *)aObj;
    WUDataUsageItemDict *b = (WUDataUsageItemDict *)bObj;
    WUDataUsageSortOrder sortOrder = (WUDataUsageSortOrder)(intptr_t)context;

    uint64_t valA = 0;
    uint64_t valB = 0;

    switch (sortOrder) {
        case WUDataUsageSortOrderWiFi:
            valA = [a[WUStr("totalWifiBytes")] unsignedLongLongValue];
            valB = [b[WUStr("totalWifiBytes")] unsignedLongLongValue];
            break;
        case WUDataUsageSortOrderCellular:
            valA = [a[WUStr("totalCellularBytes")] unsignedLongLongValue];
            valB = [b[WUStr("totalCellularBytes")] unsignedLongLongValue];
            break;
        case WUDataUsageSortOrderTotal:
        default:
            valA = [a[WUStr("totalBytes")] unsignedLongLongValue];
            valB = [b[WUStr("totalBytes")] unsignedLongLongValue];
            break;
    }

    if (valA > valB) return NSOrderedAscending;
    if (valA < valB) return NSOrderedDescending;

    uint64_t totA = [a[WUStr("totalBytes")] unsignedLongLongValue];
    uint64_t totB = [b[WUStr("totalBytes")] unsignedLongLongValue];
    if (totA > totB) return NSOrderedAscending;
    if (totA < totB) return NSOrderedDescending;

    NSString *nameA = a[WUStr("displayName")] ?: WUStr("");
    NSString *nameB = b[WUStr("displayName")] ?: WUStr("");
    return [nameA localizedCaseInsensitiveCompare:nameB];
}

NSArray<WUDataUsageItemDict *> *WUSortItems(
    NSArray<WUDataUsageItemDict *> *items,
    WUDataUsageSortOrder sortOrder
) {
    if (!items || items.count == 0) {
        return [NSArray array];
    }
    return [items sortedArrayUsingFunction:WUCompareItemsFunction
                                   context:(void *)(intptr_t)sortOrder];
}

static void WUComputePeriodDetails(
    WUDataUsagePeriodMode periodMode,
    NSInteger periodOffset,
    double earliestRefTs,
    NSDate * __strong *outStartDate,
    NSDate * __strong *outEndDate,
    NSString * __strong *outTitle,
    NSString * __strong *outSubtitle,
    NSString * __strong *outHeaderBanner,
    double *outActiveDays
) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];

    NSDateFormatter *shortRangeDf = [[NSDateFormatter alloc] init];
    shortRangeDf.dateFormat = WUStr("MMM d");

    NSDateFormatter *fullDateDf = [[NSDateFormatter alloc] init];
    fullDateDf.dateFormat = WUStr("MMM d, yyyy");

    NSDateFormatter *monthYearDf = [[NSDateFormatter alloc] init];
    monthYearDf.dateFormat = WUStr("MMMM yyyy");

    if (periodMode == WUDataUsagePeriodModeWeekly) {
        NSDate *startOfCurrentWeek = nil;
        NSTimeInterval weekInterval = 0;
        if (![cal rangeOfUnit:NSCalendarUnitWeekOfYear
                    startDate:&startOfCurrentWeek
                     interval:&weekInterval
                      forDate:now] || !startOfCurrentWeek) {
            startOfCurrentWeek = [cal startOfDayForDate:now];
        }

        NSDateComponents *offsetComps = [[NSDateComponents alloc] init];
        offsetComps.weekOfYear = periodOffset;
        NSDate *periodStart = [cal dateByAddingComponents:offsetComps toDate:startOfCurrentWeek options:0] ?: startOfCurrentWeek;

        NSDateComponents *oneWeekComps = [[NSDateComponents alloc] init];
        oneWeekComps.weekOfYear = 1;
        NSDate *periodEnd = [cal dateByAddingComponents:oneWeekComps toDate:periodStart options:0] ?: [periodStart dateByAddingTimeInterval:7.0 * 86400.0];

        NSDate *inclusiveEnd = [periodEnd dateByAddingTimeInterval:-1.0];
        NSString *rangeStr = [NSString stringWithFormat:WUStr("%@ – %@"),
                              [shortRangeDf stringFromDate:periodStart],
                              [fullDateDf stringFromDate:inclusiveEnd]];

        NSString *title = nil;
        if (periodOffset == 0) {
            title = WUStr("This Week");
        } else if (periodOffset == -1) {
            title = WUStr("Last Week");
        } else {
            title = [NSString stringWithFormat:WUStr("%ld Weeks Ago"), (long)(-periodOffset)];
        }

        NSString *banner = [NSString stringWithFormat:WUStr("WEEKLY DATA USAGE • %@"), [rangeStr uppercaseString]];
        double days = 7.0;
        if (periodOffset == 0) {
            double elapsed = [now timeIntervalSinceDate:periodStart] / 86400.0;
            days = MAX(1.0, MIN(7.0, ceil(elapsed)));
        }

        if (outStartDate) *outStartDate = periodStart;
        if (outEndDate) *outEndDate = periodEnd;
        if (outTitle) *outTitle = title;
        if (outSubtitle) *outSubtitle = rangeStr;
        if (outHeaderBanner) *outHeaderBanner = banner;
        if (outActiveDays) *outActiveDays = days;
        return;
    }

    if (periodMode == WUDataUsagePeriodModeMonthly) {
        NSDate *startOfCurrentMonth = nil;
        NSTimeInterval monthInterval = 0;
        if (![cal rangeOfUnit:NSCalendarUnitMonth
                    startDate:&startOfCurrentMonth
                     interval:&monthInterval
                      forDate:now] || !startOfCurrentMonth) {
            startOfCurrentMonth = [cal startOfDayForDate:now];
        }

        NSDateComponents *offsetComps = [[NSDateComponents alloc] init];
        offsetComps.month = periodOffset;
        NSDate *periodStart = [cal dateByAddingComponents:offsetComps toDate:startOfCurrentMonth options:0] ?: startOfCurrentMonth;

        NSDateComponents *oneMonthComps = [[NSDateComponents alloc] init];
        oneMonthComps.month = 1;
        NSDate *periodEnd = [cal dateByAddingComponents:oneMonthComps toDate:periodStart options:0] ?: [periodStart dateByAddingTimeInterval:30.0 * 86400.0];

        NSDate *inclusiveEnd = [periodEnd dateByAddingTimeInterval:-1.0];
        NSString *monthYearStr = [monthYearDf stringFromDate:periodStart];
        NSString *rangeStr = [NSString stringWithFormat:WUStr("%@ – %@"),
                              [shortRangeDf stringFromDate:periodStart],
                              [fullDateDf stringFromDate:inclusiveEnd]];

        NSString *title = nil;
        NSString *subtitle = nil;
        if (periodOffset == 0) {
            title = [NSString stringWithFormat:WUStr("This Month — %@"), monthYearStr];
            subtitle = rangeStr;
        } else if (periodOffset == -1) {
            title = [NSString stringWithFormat:WUStr("Last Month — %@"), monthYearStr];
            subtitle = rangeStr;
        } else {
            title = monthYearStr;
            subtitle = [NSString stringWithFormat:WUStr("%ld Months Ago • %@"), (long)(-periodOffset), rangeStr];
        }

        NSString *banner = [NSString stringWithFormat:WUStr("MONTHLY DATA USAGE • %@"), [monthYearStr uppercaseString]];
        double totalDaysInMonth = MAX(1.0, round([periodEnd timeIntervalSinceDate:periodStart] / 86400.0));
        double days = totalDaysInMonth;
        if (periodOffset == 0) {
            double elapsed = [now timeIntervalSinceDate:periodStart] / 86400.0;
            days = MAX(1.0, MIN(totalDaysInMonth, ceil(elapsed)));
        }

        if (outStartDate) *outStartDate = periodStart;
        if (outEndDate) *outEndDate = periodEnd;
        if (outTitle) *outTitle = title;
        if (outSubtitle) *outSubtitle = subtitle;
        if (outHeaderBanner) *outHeaderBanner = banner;
        if (outActiveDays) *outActiveDays = days;
        return;
    }

    NSString *allSubtitle = WUStr("Cumulative usage across all recorded periods");
    double days = 1.0;
    if (earliestRefTs > 0.0) {
        NSDate *earliestDate = [NSDate dateWithTimeIntervalSinceReferenceDate:earliestRefTs];
        allSubtitle = [NSString stringWithFormat:WUStr("Recorded since %@"), [fullDateDf stringFromDate:earliestDate]];
        double elapsed = [now timeIntervalSinceDate:earliestDate] / 86400.0;
        days = MAX(1.0, ceil(elapsed));
    }

    if (outStartDate) *outStartDate = nil;
    if (outEndDate) *outEndDate = nil;
    if (outTitle) *outTitle = WUStr("All Time");
    if (outSubtitle) *outSubtitle = allSubtitle;
    if (outHeaderBanner) *outHeaderBanner = WUStr("ALL-TIME DATA USAGE (WI-FI + CELLULAR)");
    if (outActiveDays) *outActiveDays = days;
}

NSDictionary<NSString *, id> *WUFetchDataUsage(
    WUDataUsageSortOrder sortOrder
) {
    return WUFetchDataUsageForPeriod(sortOrder, WUDataUsagePeriodModeAllTime, 0);
}

NSDictionary<NSString *, id> *WUFetchDataUsageForPeriod(
    WUDataUsageSortOrder sortOrder,
    WUDataUsagePeriodMode periodMode,
    NSInteger periodOffset
) {
    if (periodOffset > 0) {
        periodOffset = 0;
    }

    id lsWorkspace = nil;
    Class lsCls = objc_getClass("LSApplicationWorkspace");
    SEL defaultWsSel = sel_registerName("defaultWorkspace");
    if (lsCls && [lsCls respondsToSelector:defaultWsSel]) {
        id (*msgSendWs)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        lsWorkspace = msgSendWs(lsCls, defaultWsSel);
    }
    WUEnsureInstalledAppMappingsIndexed(lsWorkspace);

    NSMutableDictionary<NSString *, NSMutableDictionary *> *recordsMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketsMap = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    NSDate *snapshotDate = nil;

    BOOL loadedSnapshot = WULoadFromSnapshotPlist(recordsMap, bucketsMap, sources, &snapshotDate);

    const char *directDBCStrs[] = {
        "/private/var/networkd/db/netusage.sqlite",
        "/private/var/networkd/netusage.sqlite",
        "/private/var/wireless/Library/Databases/DataUsage.sqlite"
    };
    for (size_t i = 0; i < sizeof(directDBCStrs) / sizeof(directDBCStrs[0]); i++) {
        NSString *dbPath = WUStr(directDBCStrs[i]);
        if (WUQuerySQLiteAtPath(dbPath, recordsMap, bucketsMap)) {
            NSString *name = [dbPath lastPathComponent];
            if (![sources containsObject:name]) {
                [sources addObject:name];
            }
        }
    }

    WULoadFromLiveLedgerPlist(recordsMap, bucketsMap, sources);

    NSString *kKey = WUStr("key");
    NSString *kProc = WUStr("procName");
    NSString *kBundle = WUStr("bundleId");
    NSString *kWifiIn = WUStr("wifiIn");
    NSString *kWifiOut = WUStr("wifiOut");
    NSString *kWwanIn = WUStr("wwanIn");
    NSString *kWwanOut = WUStr("wwanOut");
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");
    NSString *kBucketHr = WUStr("bucketHour");

    // Pre-merge in-memory historical maximum records to guarantee monotonic non-decreasing totals
    pthread_mutex_lock(&gAllTimeCacheLock);
    if (gLastKnownAllTimeRecords.count > 0) {
        for (NSDictionary *rec in [gLastKnownAllTimeRecords allValues]) {
            WUMergeRecord(
                rec[kKey] ?: WUStr(""),
                rec[kProc] ?: WUStr(""),
                rec[kBundle] ?: WUStr(""),
                [rec[kWifiIn] unsignedLongLongValue],
                [rec[kWifiOut] unsignedLongLongValue],
                [rec[kWwanIn] unsignedLongLongValue],
                [rec[kWwanOut] unsignedLongLongValue],
                [rec[kFirstTs] doubleValue],
                [rec[kLastTs] doubleValue],
                recordsMap
            );
        }
    }
    if (gLastKnownAllTimeBuckets.count > 0) {
        for (NSDictionary *bRec in [gLastKnownAllTimeBuckets allValues]) {
            WUMergeBucketRecord(
                bRec[kKey] ?: WUStr(""),
                bRec[kProc] ?: WUStr(""),
                bRec[kBundle] ?: WUStr(""),
                [bRec[kBucketHr] longLongValue],
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                [bRec[kFirstTs] doubleValue],
                [bRec[kLastTs] doubleValue],
                bucketsMap
            );
        }
    }
    pthread_mutex_unlock(&gAllTimeCacheLock);

    BOOL snapshotStale = (!snapshotDate || [[NSDate date] timeIntervalSinceDate:snapshotDate] > 15.0);
    if (!loadedSnapshot || snapshotStale || bucketsMap.count == 0) {
        WURequestDaemonRefreshThrottled();
    }

    if (bucketsMap.count == 0 && recordsMap.count > 0) {
        // Synthesize buckets from recordsMap if an older snapshot plist lacked "buckets"
        NSString *kKey = WUStr("key");
        NSString *kProc = WUStr("procName");
        NSString *kBundle = WUStr("bundleId");
        NSString *kWifiIn = WUStr("wifiIn");
        NSString *kWifiOut = WUStr("wifiOut");
        NSString *kWwanIn = WUStr("wwanIn");
        NSString *kWwanOut = WUStr("wwanOut");
        NSString *kFirstTs = WUStr("firstTimestamp");
        NSString *kLastTs = WUStr("lastTimestamp");

        for (NSDictionary *rec in [recordsMap allValues]) {
            double lastTs = WUToReferenceTimestamp([rec[kLastTs] doubleValue]);
            double firstTs = WUToReferenceTimestamp([rec[kFirstTs] doubleValue]);
            double effectiveTs = (lastTs > 0.0) ? lastTs : firstTs;
            int64_t bucketHr = (effectiveTs > 0.0) ? (int64_t)(effectiveTs / 3600.0) : 0;
            WUMergeBucketRecord(
                rec[kKey] ?: WUStr(""),
                rec[kProc] ?: WUStr(""),
                rec[kBundle] ?: WUStr(""),
                bucketHr,
                [rec[kWifiIn] unsignedLongLongValue],
                [rec[kWifiOut] unsignedLongLongValue],
                [rec[kWwanIn] unsignedLongLongValue],
                [rec[kWwanOut] unsignedLongLongValue],
                firstTs,
                lastTs,
                bucketsMap
            );
        }
    } else if (bucketsMap.count > 0) {
        // Ensure cumulative recordsMap is at least the sum of its hourly buckets
        NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketTotals = [NSMutableDictionary dictionary];
        NSString *kKey = WUStr("key");
        NSString *kProc = WUStr("procName");
        NSString *kBundle = WUStr("bundleId");
        NSString *kWifiIn = WUStr("wifiIn");
        NSString *kWifiOut = WUStr("wifiOut");
        NSString *kWwanIn = WUStr("wwanIn");
        NSString *kWwanOut = WUStr("wwanOut");
        NSString *kFirstTs = WUStr("firstTimestamp");
        NSString *kLastTs = WUStr("lastTimestamp");
        NSString *kBucketHr = WUStr("bucketHour");

        for (NSDictionary *bRec in [bucketsMap allValues]) {
            double rawLastTs = [bRec[kLastTs] doubleValue];
            double rawFirstTs = [bRec[kFirstTs] doubleValue];
            int64_t bHr = [bRec[kBucketHr] longLongValue];
            double bRefTs = WUToReferenceTimestamp(rawLastTs);
            if (bRefTs <= 0.0 && bHr > 0) {
                bRefTs = WUToReferenceTimestamp((double)bHr * 3600.0);
            }
            WUAccumulatePeriodRecord(
                bRec[kKey] ?: WUStr(""),
                bRec[kProc] ?: WUStr(""),
                bRec[kBundle] ?: WUStr(""),
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                WUToReferenceTimestamp(rawFirstTs),
                bRefTs,
                bucketTotals
            );
        }

        for (NSDictionary *tot in [bucketTotals allValues]) {
            WUMergeRecord(
                tot[kKey] ?: WUStr(""),
                tot[kProc] ?: WUStr(""),
                tot[kBundle] ?: WUStr(""),
                [tot[kWifiIn] unsignedLongLongValue],
                [tot[kWifiOut] unsignedLongLongValue],
                [tot[kWwanIn] unsignedLongLongValue],
                [tot[kWwanOut] unsignedLongLongValue],
                [tot[kFirstTs] doubleValue],
                [tot[kLastTs] doubleValue],
                recordsMap
            );
        }
    }

    // Persist latest maximums to in-memory cache
    pthread_mutex_lock(&gAllTimeCacheLock);
    if (!gLastKnownAllTimeRecords) {
        gLastKnownAllTimeRecords = [NSMutableDictionary dictionary];
    }
    for (NSDictionary *rec in [recordsMap allValues]) {
        WUMergeRecord(
            rec[kKey] ?: WUStr(""),
            rec[kProc] ?: WUStr(""),
            rec[kBundle] ?: WUStr(""),
            [rec[kWifiIn] unsignedLongLongValue],
            [rec[kWifiOut] unsignedLongLongValue],
            [rec[kWwanIn] unsignedLongLongValue],
            [rec[kWwanOut] unsignedLongLongValue],
            [rec[kFirstTs] doubleValue],
            [rec[kLastTs] doubleValue],
            gLastKnownAllTimeRecords
        );
    }
    if (!gLastKnownAllTimeBuckets) {
        gLastKnownAllTimeBuckets = [NSMutableDictionary dictionary];
    }
    for (NSDictionary *bRec in [bucketsMap allValues]) {
        WUMergeBucketRecord(
            bRec[kKey] ?: WUStr(""),
            bRec[kProc] ?: WUStr(""),
            bRec[kBundle] ?: WUStr(""),
            [bRec[kBucketHr] longLongValue],
            [bRec[kWifiIn] unsignedLongLongValue],
            [bRec[kWifiOut] unsignedLongLongValue],
            [bRec[kWwanIn] unsignedLongLongValue],
            [bRec[kWwanOut] unsignedLongLongValue],
            [bRec[kFirstTs] doubleValue],
            [bRec[kLastTs] doubleValue],
            gLastKnownAllTimeBuckets
        );
    }
    pthread_mutex_unlock(&gAllTimeCacheLock);

    double earliestRefTs = 0.0;
    NSString *kFirstTs = WUStr("firstTimestamp");
    NSString *kLastTs = WUStr("lastTimestamp");
    NSString *kBucketHr = WUStr("bucketHour");

    for (NSDictionary *rec in [recordsMap allValues]) {
        double fTs = WUToReferenceTimestamp([rec[kFirstTs] doubleValue]);
        double lTs = WUToReferenceTimestamp([rec[kLastTs] doubleValue]);
        if (fTs > 0.0 && (earliestRefTs <= 0.0 || fTs < earliestRefTs)) {
            earliestRefTs = fTs;
        }
        if (lTs > 0.0 && (earliestRefTs <= 0.0 || lTs < earliestRefTs)) {
            earliestRefTs = lTs;
        }
    }
    for (NSDictionary *bRec in [bucketsMap allValues]) {
        int64_t bHr = [bRec[kBucketHr] longLongValue];
        double bTs = WUToReferenceTimestamp((double)bHr * 3600.0);
        if (bTs > 0.0 && (earliestRefTs <= 0.0 || bTs < earliestRefTs)) {
            earliestRefTs = bTs;
        }
    }

    NSDate *periodStartDate = nil;
    NSDate *periodEndDate = nil;
    NSString *periodTitle = nil;
    NSString *periodSubtitle = nil;
    NSString *periodHeaderBanner = nil;
    double activeDays = 1.0;

    WUComputePeriodDetails(
        periodMode,
        periodOffset,
        earliestRefTs,
        &periodStartDate,
        &periodEndDate,
        &periodTitle,
        &periodSubtitle,
        &periodHeaderBanner,
        &activeDays
    );

    NSDictionary<NSString *, NSMutableDictionary *> *activeRecordsMap = recordsMap;
    if (periodMode != WUDataUsagePeriodModeAllTime && periodStartDate && periodEndDate) {
        double startRefTs = [periodStartDate timeIntervalSinceReferenceDate];
        double endRefTs = [periodEndDate timeIntervalSinceReferenceDate];

        NSMutableDictionary<NSString *, NSMutableDictionary *> *filteredMap = [NSMutableDictionary dictionary];
        NSString *kKey = WUStr("key");
        NSString *kProc = WUStr("procName");
        NSString *kBundle = WUStr("bundleId");
        NSString *kWifiIn = WUStr("wifiIn");
        NSString *kWifiOut = WUStr("wifiOut");
        NSString *kWwanIn = WUStr("wwanIn");
        NSString *kWwanOut = WUStr("wwanOut");

        for (NSDictionary *bRec in [bucketsMap allValues]) {
            double rawLastTs = [bRec[kLastTs] doubleValue];
            double rawFirstTs = [bRec[kFirstTs] doubleValue];
            int64_t bHr = [bRec[kBucketHr] longLongValue];

            double bucketRefTs = WUToReferenceTimestamp(rawLastTs);
            if (bucketRefTs <= 0.0 && bHr > 0) {
                bucketRefTs = WUToReferenceTimestamp((double)bHr * 3600.0);
            }
            if (bucketRefTs <= 0.0) {
                bucketRefTs = WUToReferenceTimestamp(rawFirstTs);
            }

            if (bucketRefTs >= startRefTs && bucketRefTs < endRefTs) {
                WUAccumulatePeriodRecord(
                    bRec[kKey] ?: WUStr(""),
                    bRec[kProc] ?: WUStr(""),
                    bRec[kBundle] ?: WUStr(""),
                    [bRec[kWifiIn] unsignedLongLongValue],
                    [bRec[kWifiOut] unsignedLongLongValue],
                    [bRec[kWwanIn] unsignedLongLongValue],
                    [bRec[kWwanOut] unsignedLongLongValue],
                    WUToReferenceTimestamp(rawFirstTs),
                    bucketRefTs,
                    filteredMap
                );
            }
        }
        activeRecordsMap = filteredMap;
    }

    NSMutableArray<WUDataUsageItemDict *> *apps = [NSMutableArray array];
    NSMutableArray<WUDataUsageItemDict *> *systems = [NSMutableArray array];
    NSMutableArray<WUDataUsageItemDict *> *all = [NSMutableArray array];

    uint64_t totalWifiIn = 0;
    uint64_t totalWifiOut = 0;
    uint64_t totalCellIn = 0;
    uint64_t totalCellOut = 0;

    uint64_t appWifi = 0;
    uint64_t appCell = 0;
    uint64_t sysWifi = 0;
    uint64_t sysCell = 0;

    NSArray *rawValues = [activeRecordsMap allValues];
    for (NSDictionary *raw in rawValues) {
        WUDataUsageItemDict *item = WUBuildItemFromRawRecord(raw, lsWorkspace);
        uint64_t totalBytes = [item[WUStr("totalBytes")] unsignedLongLongValue];
        if (totalBytes == 0) {
            continue;
        }

        uint64_t wIn = [item[WUStr("wifiInBytes")] unsignedLongLongValue];
        uint64_t wOut = [item[WUStr("wifiOutBytes")] unsignedLongLongValue];
        uint64_t cIn = [item[WUStr("cellularInBytes")] unsignedLongLongValue];
        uint64_t cOut = [item[WUStr("cellularOutBytes")] unsignedLongLongValue];
        uint64_t tWifi = [item[WUStr("totalWifiBytes")] unsignedLongLongValue];
        uint64_t tCell = [item[WUStr("totalCellularBytes")] unsignedLongLongValue];
        WUDataUsageCategory cat = (WUDataUsageCategory)[item[WUStr("category")] integerValue];

        totalWifiIn += wIn;
        totalWifiOut += wOut;
        totalCellIn += cIn;
        totalCellOut += cOut;

        if (cat == WUDataUsageCategoryApp) {
            appWifi += tWifi;
            appCell += tCell;
            [apps addObject:item];
        } else {
            sysWifi += tWifi;
            sysCell += tCell;
            [systems addObject:item];
        }
        [all addObject:item];
    }

    uint64_t ifWifiIn = 0, ifWifiOut = 0, ifCellIn = 0, ifCellOut = 0;
    WUReadLiveInterfaceCounters(&ifWifiIn, &ifWifiOut, &ifCellIn, &ifCellOut);

    uint64_t totalWifi = totalWifiIn + totalWifiOut;
    uint64_t totalCell = totalCellIn + totalCellOut;
    if (totalWifi == 0) {
        WURequestDaemonRefreshThrottled();
    }
    uint64_t combined = totalWifi + totalCell;
    uint64_t appTotal = appWifi + appCell;
    uint64_t sysTotal = sysWifi + sysCell;
    uint64_t ifWifi = ifWifiIn + ifWifiOut;
    uint64_t ifCell = ifCellIn + ifCellOut;

    double safeDays = MAX(1.0, activeDays);
    uint64_t dailyAvgTotal = (uint64_t)((double)combined / safeDays);
    uint64_t dailyAvgWifi = (uint64_t)((double)totalWifi / safeDays);
    uint64_t dailyAvgCell = (uint64_t)((double)totalCell / safeDays);

    NSString *sourcesDesc = (sources.count > 0)
        ? [sources componentsJoinedByString:WUStr(" + ")]
        : WUStr("Live Interface Counters (ifaddrs)");

    NSMutableDictionary<NSString *, id> *summary = [NSMutableDictionary dictionary];
    summary[WUStr("periodMode")] = WUInt(periodMode);
    summary[WUStr("periodOffset")] = WUInt(periodOffset);
    summary[WUStr("periodTitle")] = periodTitle ?: WUStr("All Time");
    summary[WUStr("periodSubtitle")] = periodSubtitle ?: WUStr("");
    summary[WUStr("periodHeaderBanner")] = periodHeaderBanner ?: WUStr("COMBINED DATA USAGE (WI-FI + CELLULAR)");
    summary[WUStr("dailyAverageBytes")] = WUU64(dailyAvgTotal);
    summary[WUStr("dailyAverageWifiBytes")] = WUU64(dailyAvgWifi);
    summary[WUStr("dailyAverageCellularBytes")] = WUU64(dailyAvgCell);
    summary[WUStr("canGoNextPeriod")] = WUBool(periodOffset < 0);
    summary[WUStr("canGoPreviousPeriod")] = WUBool(YES);
    if (periodStartDate) {
        summary[WUStr("periodStartDate")] = periodStartDate;
    }
    if (periodEndDate) {
        summary[WUStr("periodEndDate")] = periodEndDate;
    }
    if (earliestRefTs > 0.0) {
        summary[WUStr("earliestDate")] = [NSDate dateWithTimeIntervalSinceReferenceDate:earliestRefTs];
    }

    summary[WUStr("totalWifiInBytes")] = WUU64(totalWifiIn);
    summary[WUStr("totalWifiOutBytes")] = WUU64(totalWifiOut);
    summary[WUStr("totalWifiBytes")] = WUU64(totalWifi);
    summary[WUStr("totalCellularInBytes")] = WUU64(totalCellIn);
    summary[WUStr("totalCellularOutBytes")] = WUU64(totalCellOut);
    summary[WUStr("totalCellularBytes")] = WUU64(totalCell);
    summary[WUStr("totalCombinedBytes")] = WUU64(combined);
    summary[WUStr("appWifiBytes")] = WUU64(appWifi);
    summary[WUStr("appCellularBytes")] = WUU64(appCell);
    summary[WUStr("appTotalBytes")] = WUU64(appTotal);
    summary[WUStr("appCount")] = WUUInt(apps.count);
    summary[WUStr("systemWifiBytes")] = WUU64(sysWifi);
    summary[WUStr("systemCellularBytes")] = WUU64(sysCell);
    summary[WUStr("systemTotalBytes")] = WUU64(sysTotal);
    summary[WUStr("systemCount")] = WUUInt(systems.count);
    summary[WUStr("interfaceWifiInBytes")] = WUU64(ifWifiIn);
    summary[WUStr("interfaceWifiOutBytes")] = WUU64(ifWifiOut);
    summary[WUStr("interfaceWifiBytes")] = WUU64(ifWifi);
    summary[WUStr("interfaceCellularInBytes")] = WUU64(ifCellIn);
    summary[WUStr("interfaceCellularOutBytes")] = WUU64(ifCellOut);
    summary[WUStr("interfaceCellularBytes")] = WUU64(ifCell);
    summary[WUStr("lastUpdatedDate")] = snapshotDate ?: [NSDate date];
    summary[WUStr("activeSourcesDescription")] = sourcesDesc;

    NSArray<WUDataUsageItemDict *> *sortedApps = WUSortItems(apps, sortOrder);
    NSArray<WUDataUsageItemDict *> *sortedSystems = WUSortItems(systems, sortOrder);
    NSArray<WUDataUsageItemDict *> *sortedAll = WUSortItems(all, sortOrder);

    NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
    result[WUStr("summary")] = summary;
    result[WUStr("appItems")] = sortedApps;
    result[WUStr("systemItems")] = sortedSystems;
    result[WUStr("allItems")] = sortedAll;
    return result;
}
