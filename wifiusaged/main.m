#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sqlite3.h>
#import <notify.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <sys/stat.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static const char *const kSnapshotPathPrimaryCStr = "/var/jb/var/mobile/Library/Preferences/com.n1ck.wifiusage.snapshot.plist";
static const char *const kSnapshotPathFallbackCStr = "/tmp/com.n1ck.wifiusage.snapshot.plist";
static const char *const kLiveLedgerPathPrimaryCStr = "/var/jb/var/mobile/Library/Preferences/com.n1ck.wifiusage.liveledger.plist";
static const char *const kLiveLedgerPathFallbackCStr = "/tmp/com.n1ck.wifiusage.liveledger.plist";

static const char *const kNotifyRefresh = "com.n1ck.wifiusage.refresh";
static const char *const kNotifyUpdated = "com.n1ck.wifiusage.updated";

static pthread_mutex_t gDaemonMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSString *> *gProcToBundleMap = nil;
static NSMutableDictionary<NSNumber *, NSString *> *gPidToBundleMap = nil;
static NSMutableDictionary<NSValue *, NSMutableDictionary *> *gSourceLastCounts = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gLiveLedgerRecords = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gLiveLedgerBuckets = nil;
static id gNWStatsManager = nil;
static id gNWStatsDelegate = nil;
static BOOL gLiveLedgerDirty = NO;

static inline NSString *WUDaemonStr(const char *cstr) {
    if (!cstr) {
        cstr = "";
    }
    CFStringRef ref = CFStringCreateWithCString(kCFAllocatorDefault, cstr, kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)ref;
}

static inline NSNumber *WUDaemonU64(uint64_t val) {
    return [NSNumber numberWithUnsignedLongLong:val];
}

static inline NSNumber *WUDaemonI64(int64_t val) {
    return [NSNumber numberWithLongLong:val];
}

static inline NSNumber *WUDaemonInt(int val) {
    return [NSNumber numberWithInt:val];
}

static inline NSNumber *WUDaemonDouble(double val) {
    return [NSNumber numberWithDouble:val];
}

static void WURegisterProcBundleMappingLocked(NSString *procName, NSString *bundleId) {
    if (![procName isKindOfClass:[NSString class]] || procName.length == 0) {
        return;
    }
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return;
    }
    if (!gProcToBundleMap) {
        gProcToBundleMap = [NSMutableDictionary dictionary];
    }
    gProcToBundleMap[procName] = bundleId;
    gProcToBundleMap[[procName lowercaseString]] = bundleId;
    if (procName.length > 15) {
        NSString *prefix15 = [procName substringToIndex:15];
        NSString *prefix16 = (procName.length > 16) ? [procName substringToIndex:16] : procName;
        if (!gProcToBundleMap[prefix15]) {
            gProcToBundleMap[prefix15] = bundleId;
        }
        if (!gProcToBundleMap[[prefix15 lowercaseString]]) {
            gProcToBundleMap[[prefix15 lowercaseString]] = bundleId;
        }
        if (!gProcToBundleMap[prefix16]) {
            gProcToBundleMap[prefix16] = bundleId;
        }
        if (!gProcToBundleMap[[prefix16 lowercaseString]]) {
            gProcToBundleMap[[prefix16 lowercaseString]] = bundleId;
        }
    }
}

static NSString *WUResolveBundleForProcLocked(NSString *procName, NSString *bundleId) {
    if ([bundleId isKindOfClass:[NSString class]] && bundleId.length > 0) {
        if ([procName isKindOfClass:[NSString class]] && procName.length > 0) {
            WURegisterProcBundleMappingLocked(procName, bundleId);
        }
        return bundleId;
    }
    if (![procName isKindOfClass:[NSString class]] || procName.length == 0 || !gProcToBundleMap) {
        return WUDaemonStr("");
    }
    NSString *found = gProcToBundleMap[procName];
    if (!found) {
        found = gProcToBundleMap[[procName lowercaseString]];
    }
    if (!found && procName.length >= 15) {
        NSString *p15 = [procName substringToIndex:15];
        found = gProcToBundleMap[p15] ?: gProcToBundleMap[[p15 lowercaseString]];
    }
    return found ?: WUDaemonStr("");
}

static NSString *WUResolveBundleForPIDLocked(int pid, NSString *procName) {
    if (pid <= 0) {
        return WUResolveBundleForProcLocked(procName, nil);
    }
    if (!gPidToBundleMap) {
        gPidToBundleMap = [NSMutableDictionary dictionary];
    }
    NSNumber *pidKey = WUDaemonInt(pid);
    NSString *cached = gPidToBundleMap[pidKey];
    if (cached) {
        if (cached.length > 0 && procName.length > 0) {
            WURegisterProcBundleMappingLocked(procName, cached);
        }
        return cached;
    }

    char pathBuf[4096];
    memset(pathBuf, 0, sizeof(pathBuf));
    int ret = proc_pidpath(pid, pathBuf, sizeof(pathBuf) - 1);
    NSString *resolvedBundle = nil;
    if (ret > 0 && pathBuf[0] != '\0') {
        NSString *fullPath = WUDaemonStr(pathBuf);
        NSRange appRange = [fullPath rangeOfString:WUDaemonStr(".app/")];
        if (appRange.location != NSNotFound) {
            NSString *appDir = [fullPath substringToIndex:(appRange.location + 4)];
            NSString *infoPath = [appDir stringByAppendingPathComponent:WUDaemonStr("Info.plist")];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if ([info isKindOfClass:[NSDictionary class]]) {
                NSString *bId = info[WUDaemonStr("CFBundleIdentifier")];
                NSString *execName = info[WUDaemonStr("CFBundleExecutable")];
                if ([bId isKindOfClass:[NSString class]] && bId.length > 0) {
                    resolvedBundle = bId;
                    if ([execName isKindOfClass:[NSString class]] && execName.length > 0) {
                        WURegisterProcBundleMappingLocked(execName, bId);
                    }
                }
            }
        }
    }

    if (!resolvedBundle || resolvedBundle.length == 0) {
        resolvedBundle = WUResolveBundleForProcLocked(procName, nil);
    } else if (procName.length > 0) {
        WURegisterProcBundleMappingLocked(procName, resolvedBundle);
    }

    gPidToBundleMap[pidKey] = resolvedBundle ?: WUDaemonStr("");
    return resolvedBundle ?: WUDaemonStr("");
}

static void WUPopulateInstalledAppMappings(void) {
    @autoreleasepool {
        pthread_mutex_lock(&gDaemonMutex);
        if (!gProcToBundleMap) {
            gProcToBundleMap = [NSMutableDictionary dictionary];
        }
        pthread_mutex_unlock(&gDaemonMutex);

        Class lsCls = objc_getClass("LSApplicationWorkspace");
        SEL defaultWsSel = sel_registerName("defaultWorkspace");
        SEL allAppsSel = sel_registerName("allApplications");
        SEL appIdSel = sel_registerName("applicationIdentifier");
        SEL bundleIdSel = sel_registerName("bundleIdentifier");
        SEL bundleExecSel = sel_registerName("bundleExecutable");
        SEL bundleUrlSel = sel_registerName("bundleURL");

        if (lsCls && [lsCls respondsToSelector:defaultWsSel]) {
            id (*msgSendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            id ws = msgSendId(lsCls, defaultWsSel);
            if (ws && [ws respondsToSelector:allAppsSel]) {
                NSArray *apps = msgSendId(ws, allAppsSel);
                if ([apps isKindOfClass:[NSArray class]]) {
                    pthread_mutex_lock(&gDaemonMutex);
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
                                WURegisterProcBundleMappingLocked(exec, bId);
                            }
                        }
                        if ([proxy respondsToSelector:bundleUrlSel]) {
                            NSURL *url = msgSendId(proxy, bundleUrlSel);
                            if ([url isKindOfClass:[NSURL class]]) {
                                NSString *last = [[url lastPathComponent] stringByDeletingPathExtension];
                                if (last.length > 0) {
                                    WURegisterProcBundleMappingLocked(last, bId);
                                }
                            }
                        }
                    }
                    pthread_mutex_unlock(&gDaemonMutex);
                }
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        const char *appDirs[] = {
            "/Applications",
            "/var/jb/Applications"
        };
        for (size_t i = 0; i < sizeof(appDirs) / sizeof(appDirs[0]); i++) {
            NSString *dirPath = WUDaemonStr(appDirs[i]);
            NSArray *items = [fm contentsOfDirectoryAtPath:dirPath error:nil];
            for (NSString *item in items) {
                if (![item hasSuffix:WUDaemonStr(".app")]) {
                    continue;
                }
                NSString *infoPath = [[dirPath stringByAppendingPathComponent:item]
                                      stringByAppendingPathComponent:WUDaemonStr("Info.plist")];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSString *bId = info[WUDaemonStr("CFBundleIdentifier")];
                    NSString *exec = info[WUDaemonStr("CFBundleExecutable")];
                    pthread_mutex_lock(&gDaemonMutex);
                    if ([bId isKindOfClass:[NSString class]] && bId.length > 0) {
                        if ([exec isKindOfClass:[NSString class]] && exec.length > 0) {
                            WURegisterProcBundleMappingLocked(exec, bId);
                        }
                        NSString *appBase = [item stringByDeletingPathExtension];
                        if (appBase.length > 0) {
                            WURegisterProcBundleMappingLocked(appBase, bId);
                        }
                    }
                    pthread_mutex_unlock(&gDaemonMutex);
                }
            }
        }

        NSString *containersDir = WUDaemonStr("/var/containers/Bundle/Application");
        NSArray *uuids = [fm contentsOfDirectoryAtPath:containersDir error:nil];
        for (NSString *uuid in uuids) {
            NSString *uuidPath = [containersDir stringByAppendingPathComponent:uuid];
            NSArray *subItems = [fm contentsOfDirectoryAtPath:uuidPath error:nil];
            for (NSString *sub in subItems) {
                if (![sub hasSuffix:WUDaemonStr(".app")]) {
                    continue;
                }
                NSString *infoPath = [[uuidPath stringByAppendingPathComponent:sub]
                                      stringByAppendingPathComponent:WUDaemonStr("Info.plist")];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSString *bId = info[WUDaemonStr("CFBundleIdentifier")];
                    NSString *exec = info[WUDaemonStr("CFBundleExecutable")];
                    pthread_mutex_lock(&gDaemonMutex);
                    if ([bId isKindOfClass:[NSString class]] && bId.length > 0) {
                        if ([exec isKindOfClass:[NSString class]] && exec.length > 0) {
                            WURegisterProcBundleMappingLocked(exec, bId);
                        }
                        NSString *appBase = [sub stringByDeletingPathExtension];
                        if (appBase.length > 0) {
                            WURegisterProcBundleMappingLocked(appBase, bId);
                        }
                    }
                    pthread_mutex_unlock(&gDaemonMutex);
                }
            }
        }
    }
}

static NSDictionary<NSString *, NSNumber *> *readInterfaceCounters(void) {
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

    NSMutableDictionary<NSString *, NSNumber *> *dict = [NSMutableDictionary dictionary];
    dict[WUDaemonStr("ifWifiIn")] = WUDaemonU64(wifiIn);
    dict[WUDaemonStr("ifWifiOut")] = WUDaemonU64(wifiOut);
    dict[WUDaemonStr("ifCellIn")] = WUDaemonU64(cellIn);
    dict[WUDaemonStr("ifCellOut")] = WUDaemonU64(cellOut);
    return dict;
}

static void WUAddRecordToMap(
    NSMutableDictionary<NSString *, NSMutableDictionary *> *targetMap,
    NSString *key,
    NSString *procName,
    NSString *bundleId,
    uint64_t wifiIn,
    uint64_t wifiOut,
    uint64_t wwanIn,
    uint64_t wwanOut,
    double firstTs,
    double lastTs,
    BOOL sumValues
) {
    if (!targetMap || ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *kKey = WUDaemonStr("key");
    NSString *kProc = WUDaemonStr("procName");
    NSString *kBundle = WUDaemonStr("bundleId");
    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");
    NSString *kFirstTs = WUDaemonStr("firstTimestamp");
    NSString *kLastTs = WUDaemonStr("lastTimestamp");

    NSMutableDictionary *existing = targetMap[key];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = procName ?: WUDaemonStr("");
        existing[kBundle] = bundleId ?: WUDaemonStr("");
        existing[kWifiIn] = WUDaemonU64(wifiIn);
        existing[kWifiOut] = WUDaemonU64(wifiOut);
        existing[kWwanIn] = WUDaemonU64(wwanIn);
        existing[kWwanOut] = WUDaemonU64(wwanOut);
        existing[kFirstTs] = WUDaemonDouble(firstTs);
        existing[kLastTs] = WUDaemonDouble(lastTs);
        targetMap[key] = existing;
    } else {
        if ([existing[kProc] length] == 0 && procName.length > 0) {
            existing[kProc] = procName;
        }
        if ([existing[kBundle] length] == 0 && bundleId.length > 0) {
            existing[kBundle] = bundleId;
        }
        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        if (sumValues) {
            existing[kWifiIn] = WUDaemonU64(prevWifiIn + wifiIn);
            existing[kWifiOut] = WUDaemonU64(prevWifiOut + wifiOut);
            existing[kWwanIn] = WUDaemonU64(prevWwanIn + wwanIn);
            existing[kWwanOut] = WUDaemonU64(prevWwanOut + wwanOut);
        } else {
            existing[kWifiIn] = WUDaemonU64(MAX(prevWifiIn, wifiIn));
            existing[kWifiOut] = WUDaemonU64(MAX(prevWifiOut, wifiOut));
            existing[kWwanIn] = WUDaemonU64(MAX(prevWwanIn, wwanIn));
            existing[kWwanOut] = WUDaemonU64(MAX(prevWwanOut, wwanOut));
        }

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDaemonDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDaemonDouble(lastTs);
        }
    }
}

static void WUAddBucketToMap(
    NSMutableDictionary<NSString *, NSMutableDictionary *> *targetBuckets,
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
    BOOL sumValues
) {
    if (!targetBuckets || ![key isKindOfClass:[NSString class]] || key.length == 0) {
        return;
    }
    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
        return;
    }

    NSString *kKey = WUDaemonStr("key");
    NSString *kProc = WUDaemonStr("procName");
    NSString *kBundle = WUDaemonStr("bundleId");
    NSString *kBucketHr = WUDaemonStr("bucketHour");
    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");
    NSString *kFirstTs = WUDaemonStr("firstTimestamp");
    NSString *kLastTs = WUDaemonStr("lastTimestamp");

    NSString *bucketKey = [NSString stringWithFormat:WUDaemonStr("%@#%lld"), key, (long long)bucketHr];
    NSMutableDictionary *existing = targetBuckets[bucketKey];
    if (!existing) {
        existing = [NSMutableDictionary dictionary];
        existing[kKey] = key;
        existing[kProc] = procName ?: WUDaemonStr("");
        existing[kBundle] = bundleId ?: WUDaemonStr("");
        existing[kBucketHr] = WUDaemonI64(bucketHr);
        existing[kWifiIn] = WUDaemonU64(wifiIn);
        existing[kWifiOut] = WUDaemonU64(wifiOut);
        existing[kWwanIn] = WUDaemonU64(wwanIn);
        existing[kWwanOut] = WUDaemonU64(wwanOut);
        existing[kFirstTs] = WUDaemonDouble(firstTs);
        existing[kLastTs] = WUDaemonDouble(lastTs);
        targetBuckets[bucketKey] = existing;
    } else {
        if ([existing[kProc] length] == 0 && procName.length > 0) {
            existing[kProc] = procName;
        }
        if ([existing[kBundle] length] == 0 && bundleId.length > 0) {
            existing[kBundle] = bundleId;
        }
        uint64_t prevWifiIn = [existing[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [existing[kWifiOut] unsignedLongLongValue];
        uint64_t prevWwanIn = [existing[kWwanIn] unsignedLongLongValue];
        uint64_t prevWwanOut = [existing[kWwanOut] unsignedLongLongValue];

        if (sumValues) {
            existing[kWifiIn] = WUDaemonU64(prevWifiIn + wifiIn);
            existing[kWifiOut] = WUDaemonU64(prevWifiOut + wifiOut);
            existing[kWwanIn] = WUDaemonU64(prevWwanIn + wwanIn);
            existing[kWwanOut] = WUDaemonU64(prevWwanOut + wwanOut);
        } else {
            existing[kWifiIn] = WUDaemonU64(MAX(prevWifiIn, wifiIn));
            existing[kWifiOut] = WUDaemonU64(MAX(prevWifiOut, wifiOut));
            existing[kWwanIn] = WUDaemonU64(MAX(prevWwanIn, wwanIn));
            existing[kWwanOut] = WUDaemonU64(MAX(prevWwanOut, wwanOut));
        }

        double prevFirst = [existing[kFirstTs] doubleValue];
        double prevLast = [existing[kLastTs] doubleValue];
        if (firstTs > 0 && (prevFirst <= 0 || firstTs < prevFirst)) {
            existing[kFirstTs] = WUDaemonDouble(firstTs);
        }
        if (lastTs > prevLast) {
            existing[kLastTs] = WUDaemonDouble(lastTs);
        }
    }
}

static void WULoadLiveLedgerLocked(void) {
    if (gLiveLedgerRecords && gLiveLedgerBuckets) {
        return;
    }
    gLiveLedgerRecords = [NSMutableDictionary dictionary];
    gLiveLedgerBuckets = [NSMutableDictionary dictionary];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *primary = WUDaemonStr(kLiveLedgerPathPrimaryCStr);
    NSString *fallback = WUDaemonStr(kLiveLedgerPathFallbackCStr);
    NSString *chosen = nil;
    if ([fm fileExistsAtPath:primary]) {
        chosen = primary;
    } else if ([fm fileExistsAtPath:fallback]) {
        chosen = fallback;
    }
    if (!chosen) {
        return;
    }

    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:chosen];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *kKey = WUDaemonStr("key");
    NSString *kProc = WUDaemonStr("procName");
    NSString *kBundle = WUDaemonStr("bundleId");
    NSString *kBucketHr = WUDaemonStr("bucketHour");
    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");
    NSString *kFirstTs = WUDaemonStr("firstTimestamp");
    NSString *kLastTs = WUDaemonStr("lastTimestamp");

    NSArray *items = plist[WUDaemonStr("items")];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *entry in items) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *proc = entry[kProc] ?: WUDaemonStr("");
            NSString *bundle = WUResolveBundleForProcLocked(proc, entry[kBundle]);
            NSString *key = (bundle.length > 0) ? bundle : (entry[kKey] ?: proc);
            WUAddRecordToMap(
                gLiveLedgerRecords,
                key,
                proc,
                bundle,
                [entry[kWifiIn] unsignedLongLongValue],
                [entry[kWifiOut] unsignedLongLongValue],
                [entry[kWwanIn] unsignedLongLongValue],
                [entry[kWwanOut] unsignedLongLongValue],
                [entry[kFirstTs] doubleValue],
                [entry[kLastTs] doubleValue],
                YES
            );
        }
    }

    NSArray *buckets = plist[WUDaemonStr("buckets")];
    if ([buckets isKindOfClass:[NSArray class]]) {
        for (NSDictionary *entry in buckets) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *proc = entry[kProc] ?: WUDaemonStr("");
            NSString *bundle = WUResolveBundleForProcLocked(proc, entry[kBundle]);
            NSString *key = (bundle.length > 0) ? bundle : (entry[kKey] ?: proc);
            WUAddBucketToMap(
                gLiveLedgerBuckets,
                key,
                proc,
                bundle,
                [entry[kBucketHr] longLongValue],
                [entry[kWifiIn] unsignedLongLongValue],
                [entry[kWifiOut] unsignedLongLongValue],
                [entry[kWwanIn] unsignedLongLongValue],
                [entry[kWwanOut] unsignedLongLongValue],
                [entry[kFirstTs] doubleValue],
                [entry[kLastTs] doubleValue],
                YES
            );
        }
    }
}

static void WUSaveLiveLedgerLocked(void) {
    if (!gLiveLedgerDirty || !gLiveLedgerRecords) {
        return;
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[WUDaemonStr("updatedAt")] = WUDaemonDouble([[NSDate date] timeIntervalSince1970]);
    payload[WUDaemonStr("items")] = [gLiveLedgerRecords allValues] ?: [NSArray array];
    payload[WUDaemonStr("buckets")] = [gLiveLedgerBuckets allValues] ?: [NSArray array];

    NSString *primary = WUDaemonStr(kLiveLedgerPathPrimaryCStr);
    NSString *fallback = WUDaemonStr(kLiveLedgerPathFallbackCStr);
    if ([payload writeToFile:primary atomically:YES]) {
        chmod(kLiveLedgerPathPrimaryCStr, 0644);
    }
    if ([payload writeToFile:fallback atomically:YES]) {
        chmod(kLiveLedgerPathFallbackCStr, 0644);
    }
    gLiveLedgerDirty = NO;
}

static void WUProcessNWStatisticsSource(id source) {
    if (!source) {
        return;
    }
    SEL currentSnapSel = sel_registerName("currentSnapshot");
    if (![source respondsToSelector:currentSnapSel]) {
        return;
    }
    id (*msgSendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id snap = msgSendId(source, currentSnapSel);
    if (!snap) {
        return;
    }

    SEL pidSel = sel_registerName("processID");
    SEL procNameSel = sel_registerName("processName");
    SEL rxWifiSel = sel_registerName("rxWiFiBytes");
    SEL txWifiSel = sel_registerName("txWiFiBytes");
    SEL rxWiredSel = sel_registerName("rxWiredBytes");
    SEL txWiredSel = sel_registerName("txWiredBytes");
    SEL rxCellSel = sel_registerName("rxCellularBytes");
    SEL txCellSel = sel_registerName("txCellularBytes");

    int pid = 0;
    if ([snap respondsToSelector:pidSel]) {
        int (*msgSendInt)(id, SEL) = (int (*)(id, SEL))objc_msgSend;
        pid = msgSendInt(snap, pidSel);
    }

    NSString *procName = nil;
    if ([snap respondsToSelector:procNameSel]) {
        procName = msgSendId(snap, procNameSel);
    }
    if (![procName isKindOfClass:[NSString class]]) {
        procName = WUDaemonStr("");
    }

    uint64_t (*msgSendU64)(id, SEL) = (uint64_t (*)(id, SEL))objc_msgSend;
    uint64_t rxWifi = [snap respondsToSelector:rxWifiSel] ? msgSendU64(snap, rxWifiSel) : 0;
    uint64_t txWifi = [snap respondsToSelector:txWifiSel] ? msgSendU64(snap, txWifiSel) : 0;
    uint64_t rxWired = [snap respondsToSelector:rxWiredSel] ? msgSendU64(snap, rxWiredSel) : 0;
    uint64_t txWired = [snap respondsToSelector:txWiredSel] ? msgSendU64(snap, txWiredSel) : 0;
    uint64_t rxCell = [snap respondsToSelector:rxCellSel] ? msgSendU64(snap, rxCellSel) : 0;
    uint64_t txCell = [snap respondsToSelector:txCellSel] ? msgSendU64(snap, txCellSel) : 0;

    uint64_t totalWifiIn = rxWifi + rxWired;
    uint64_t totalWifiOut = txWifi + txWired;

    if (totalWifiIn == 0 && totalWifiOut == 0 && rxCell == 0 && txCell == 0) {
        return;
    }

    pthread_mutex_lock(&gDaemonMutex);
    WULoadLiveLedgerLocked();
    if (!gSourceLastCounts) {
        gSourceLastCounts = [NSMutableDictionary dictionary];
    }

    NSValue *srcKey = [NSValue valueWithPointer:(__bridge const void *)source];
    NSMutableDictionary *prev = gSourceLastCounts[srcKey];

    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");

    uint64_t deltaWifiIn = totalWifiIn;
    uint64_t deltaWifiOut = totalWifiOut;
    uint64_t deltaCellIn = rxCell;
    uint64_t deltaCellOut = txCell;

    if (prev) {
        uint64_t prevWifiIn = [prev[kWifiIn] unsignedLongLongValue];
        uint64_t prevWifiOut = [prev[kWifiOut] unsignedLongLongValue];
        uint64_t prevCellIn = [prev[kWwanIn] unsignedLongLongValue];
        uint64_t prevCellOut = [prev[kWwanOut] unsignedLongLongValue];

        deltaWifiIn = (totalWifiIn >= prevWifiIn) ? (totalWifiIn - prevWifiIn) : totalWifiIn;
        deltaWifiOut = (totalWifiOut >= prevWifiOut) ? (totalWifiOut - prevWifiOut) : totalWifiOut;
        deltaCellIn = (rxCell >= prevCellIn) ? (rxCell - prevCellIn) : rxCell;
        deltaCellOut = (txCell >= prevCellOut) ? (txCell - prevCellOut) : txCell;
    } else {
        prev = [NSMutableDictionary dictionary];
        gSourceLastCounts[srcKey] = prev;
    }

    prev[kWifiIn] = WUDaemonU64(totalWifiIn);
    prev[kWifiOut] = WUDaemonU64(totalWifiOut);
    prev[kWwanIn] = WUDaemonU64(rxCell);
    prev[kWwanOut] = WUDaemonU64(txCell);

    if (deltaWifiIn > 0 || deltaWifiOut > 0 || deltaCellIn > 0 || deltaCellOut > 0) {
        NSString *bundleId = WUResolveBundleForPIDLocked(pid, procName);
        NSString *key = (bundleId.length > 0) ? bundleId : procName;
        if (key.length > 0) {
            double nowRef = [NSDate timeIntervalSinceReferenceDate];
            int64_t bucketHr = (int64_t)(nowRef / 3600.0);
            WUAddRecordToMap(
                gLiveLedgerRecords,
                key,
                procName,
                bundleId,
                deltaWifiIn,
                deltaWifiOut,
                deltaCellIn,
                deltaCellOut,
                nowRef,
                nowRef,
                YES
            );
            WUAddBucketToMap(
                gLiveLedgerBuckets,
                key,
                procName,
                bundleId,
                bucketHr,
                deltaWifiIn,
                deltaWifiOut,
                deltaCellIn,
                deltaCellOut,
                nowRef,
                nowRef,
                YES
            );
            gLiveLedgerDirty = YES;
        }
    }
    pthread_mutex_unlock(&gDaemonMutex);
}

static void WUNWStatsDidAddSourceIMP(id self, SEL _cmd, id mgr, id source) {
    if (!source) {
        return;
    }
    SEL setDelSel = sel_registerName("setDelegate:");
    if ([source respondsToSelector:setDelSel]) {
        void (*msgSendSetDel)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        msgSendSetDel(source, setDelSel, self);
    }
    WUProcessNWStatisticsSource(source);
}

static void WUNWStatsDidRemoveSourceIMP(id self, SEL _cmd, id mgr, id source) {
    if (!source) {
        return;
    }
    WUProcessNWStatisticsSource(source);
    pthread_mutex_lock(&gDaemonMutex);
    if (gSourceLastCounts) {
        NSValue *srcKey = [NSValue valueWithPointer:(__bridge const void *)source];
        [gSourceLastCounts removeObjectForKey:srcKey];
    }
    pthread_mutex_unlock(&gDaemonMutex);
}

static void WUNWStatsSourceDidUpdateIMP(id self, SEL _cmd, id source) {
    WUProcessNWStatisticsSource(source);
}

static void WUInitNWStatisticsManager(void) {
    if (gNWStatsManager) {
        return;
    }
    dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
    Class mgrCls = objc_getClass("NWStatisticsManager");
    if (!mgrCls) {
        return;
    }

    Class delCls = objc_getClass("WUNWStatsDelegate");
    if (!delCls) {
        delCls = objc_allocateClassPair([NSObject class], "WUNWStatsDelegate", 0);
        if (delCls) {
            class_addMethod(
                delCls,
                sel_registerName("statisticsManager:didAddSource:"),
                (IMP)WUNWStatsDidAddSourceIMP,
                "v@:@@"
            );
            class_addMethod(
                delCls,
                sel_registerName("statisticsManager:didReceiveSource:"),
                (IMP)WUNWStatsDidAddSourceIMP,
                "v@:@@"
            );
            class_addMethod(
                delCls,
                sel_registerName("statisticsManager:didRemoveSource:"),
                (IMP)WUNWStatsDidRemoveSourceIMP,
                "v@:@@"
            );
            class_addMethod(
                delCls,
                sel_registerName("sourceDidReceiveDescription:"),
                (IMP)WUNWStatsSourceDidUpdateIMP,
                "v@:@"
            );
            class_addMethod(
                delCls,
                sel_registerName("sourceDidReceiveCounts:"),
                (IMP)WUNWStatsSourceDidUpdateIMP,
                "v@:@"
            );
            objc_registerClassPair(delCls);
        }
    }

    if (!delCls) {
        return;
    }

    gNWStatsDelegate = [[delCls alloc] init];
    gNWStatsManager = [[mgrCls alloc] init];
    if (!gNWStatsManager) {
        return;
    }

    SEL setDelSel = sel_registerName("setDelegate:");
    if ([gNWStatsManager respondsToSelector:setDelSel]) {
        void (*msgSendSetDel)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        msgSendSetDel(gNWStatsManager, setDelSel, gNWStatsDelegate);
    }

    SEL addTcpSel = sel_registerName("addAllTCP:");
    if ([gNWStatsManager respondsToSelector:addTcpSel]) {
        BOOL (*msgSendAdd)(id, SEL, unsigned long long) = (BOOL (*)(id, SEL, unsigned long long))objc_msgSend;
        msgSendAdd(gNWStatsManager, addTcpSel, 0ULL);
    }

    SEL addUdpSel = sel_registerName("addAllUDP:");
    if ([gNWStatsManager respondsToSelector:addUdpSel]) {
        BOOL (*msgSendAdd)(id, SEL, unsigned long long) = (BOOL (*)(id, SEL, unsigned long long))objc_msgSend;
        msgSendAdd(gNWStatsManager, addUdpSel, 0ULL);
    }
}

static void WUPollNWStatisticsSources(void) {
    if (!gNWStatsManager) {
        return;
    }
    SEL sourcesSel = sel_registerName("sources");
    if ([gNWStatsManager respondsToSelector:sourcesSel]) {
        id (*msgSendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        NSSet *sources = msgSendId(gNWStatsManager, sourcesSel);
        if ([sources isKindOfClass:[NSSet class]] || [sources isKindOfClass:[NSArray class]]) {
            NSArray *snapshotList = [sources allObjects];
            for (id src in snapshotList) {
                WUProcessNWStatisticsSource(src);
            }
        }
    }
    pthread_mutex_lock(&gDaemonMutex);
    WUSaveLiveLedgerLocked();
    pthread_mutex_unlock(&gDaemonMutex);
}

static sqlite3 *WUOpenDatabaseCopyOrImmutable(NSString *dbPath, NSString * __strong *outTempBase) {
    if (outTempBase) {
        *outTempBase = nil;
    }
    if (!dbPath || dbPath.length == 0) {
        return NULL;
    }

    struct stat st;
    if (stat(dbPath.UTF8String, &st) != 0) {
        return NULL;
    }

    NSString *walPath = [dbPath stringByAppendingString:WUDaemonStr("-wal")];
    struct stat walSt;
    BOOL hasWal = (stat(walPath.UTF8String, &walSt) == 0 && walSt.st_size > 0);
    if (st.st_size == 0 && !hasWal) {
        return NULL;
    }

    static unsigned int sCopySeq = 0;
    unsigned int seq = ++sCopySeq;
    NSString *tempBase = [NSString stringWithFormat:WUDaemonStr("/tmp/wu_tmp_%d_%u.sqlite"), (int)getpid(), seq];
    NSString *tempWal = [tempBase stringByAppendingString:WUDaemonStr("-wal")];
    NSString *tempShm = [tempBase stringByAppendingString:WUDaemonStr("-shm")];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:tempBase error:nil];
    [fm removeItemAtPath:tempWal error:nil];
    [fm removeItemAtPath:tempShm error:nil];

    sqlite3 *db = NULL;
    if ([fm copyItemAtPath:dbPath toPath:tempBase error:nil]) {
        chmod(tempBase.UTF8String, 0600);
        if ([fm fileExistsAtPath:walPath]) {
            if ([fm copyItemAtPath:walPath toPath:tempWal error:nil]) {
                chmod(tempWal.UTF8String, 0600);
            }
        }
        // Do NOT copy the live .sqlite-shm file! When SQLite opens tempBase in read-write mode
        // without an existing -shm, it cleanly rebuilds a private -shm from tempWal in /tmp
        // without any lock contention from symptomsd/networkd.

        if (sqlite3_open_v2(tempBase.UTF8String, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK && db != NULL) {
            sqlite3_busy_timeout(db, 3000);
            sqlite3_exec(db, "PRAGMA wal_checkpoint(PASSIVE);", NULL, NULL, NULL);
            sqlite3_stmt *testStmt = NULL;
            if (sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &testStmt, NULL) == SQLITE_OK && testStmt != NULL) {
                sqlite3_step(testStmt);
                sqlite3_finalize(testStmt);
                if (outTempBase) {
                    *outTempBase = tempBase;
                }
                return db;
            }
            sqlite3_close(db);
            db = NULL;
        }
        [fm removeItemAtPath:tempBase error:nil];
        [fm removeItemAtPath:tempWal error:nil];
        [fm removeItemAtPath:tempShm error:nil];
    }

    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && db != NULL) {
        sqlite3_busy_timeout(db, 3000);
        sqlite3_stmt *testStmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master;", -1, &testStmt, NULL) == SQLITE_OK && testStmt != NULL) {
            sqlite3_step(testStmt);
            sqlite3_finalize(testStmt);
            return db;
        }
        sqlite3_close(db);
        db = NULL;
    }

    NSString *uri = [NSString stringWithFormat:WUDaemonStr("file:%@?immutable=1"), dbPath];
    if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) == SQLITE_OK && db != NULL) {
        sqlite3_busy_timeout(db, 3000);
        return db;
    }
    if (db != NULL) {
        sqlite3_close(db);
    }
    return NULL;
}

static void WUCloseDatabaseAndCleanTemp(sqlite3 *db, NSString *tempBase) {
    if (db != NULL) {
        sqlite3_close(db);
    }
    if (tempBase && tempBase.length > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:tempBase error:nil];
        [fm removeItemAtPath:[tempBase stringByAppendingString:WUDaemonStr("-wal")] error:nil];
        [fm removeItemAtPath:[tempBase stringByAppendingString:WUDaemonStr("-shm")] error:nil];
    }
}

static NSSet<NSString *> *WUGetTableColumns(sqlite3 *db, const char *tableName) {
    NSMutableSet<NSString *> *cols = [NSMutableSet set];
    char pragmaSql[256];
    snprintf(pragmaSql, sizeof(pragmaSql), "PRAGMA table_info(%s);", tableName);
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, pragmaSql, -1, &stmt, NULL) == SQLITE_OK && stmt != NULL) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *colName = (const char *)sqlite3_column_text(stmt, 1);
            if (colName && colName[0] != '\0') {
                [cols addObject:[WUDaemonStr(colName) uppercaseString]];
            }
        }
        sqlite3_finalize(stmt);
    }
    return cols;
}

static void WULoadProcessMappingsFromDB(sqlite3 *db) {
    NSSet<NSString *> *procCols = WUGetTableColumns(db, "ZPROCESS");
    if (![procCols containsObject:WUDaemonStr("ZPROCNAME")] ||
        ![procCols containsObject:WUDaemonStr("ZBUNDLENAME")]) {
        return;
    }

    const char *sql =
        "SELECT ZPROCNAME, ZBUNDLENAME FROM ZPROCESS "
        "WHERE ZPROCNAME IS NOT NULL AND ZPROCNAME != '' "
        "  AND ZBUNDLENAME IS NOT NULL AND ZBUNDLENAME != '';";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt != NULL) {
        pthread_mutex_lock(&gDaemonMutex);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *cProc = (const char *)sqlite3_column_text(stmt, 0);
            const char *cBundle = (const char *)sqlite3_column_text(stmt, 1);
            if (cProc && cBundle) {
                WURegisterProcBundleMappingLocked(WUDaemonStr(cProc), WUDaemonStr(cBundle));
            }
        }
        pthread_mutex_unlock(&gDaemonMutex);
        sqlite3_finalize(stmt);
    }
}

static BOOL querySQLiteDatabase(
    NSString *dbPath,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedRecords,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedBuckets
) {
    NSString *tempBase = nil;
    sqlite3 *db = WUOpenDatabaseCopyOrImmutable(dbPath, &tempBase);
    if (!db) {
        return NO;
    }

    WULoadProcessMappingsFromDB(db);

    NSSet<NSString *> *liveCols = WUGetTableColumns(db, "ZLIVEUSAGE");
    NSSet<NSString *> *procCols = WUGetTableColumns(db, "ZPROCESS");
    BOOL hasProcessTable = ([procCols containsObject:WUDaemonStr("Z_PK")] &&
                            [procCols containsObject:WUDaemonStr("ZPROCNAME")]);

    NSMutableDictionary<NSString *, NSMutableDictionary *> *dbRecords = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *dbBuckets = [NSMutableDictionary dictionary];
    BOOL success = NO;

    if (liveCols.count > 0 && hasProcessTable && [liveCols containsObject:WUDaemonStr("ZHASPROCESS")]) {
        BOOL hasWifiIn = [liveCols containsObject:WUDaemonStr("ZWIFIIN")];
        BOOL hasWifiOut = [liveCols containsObject:WUDaemonStr("ZWIFIOUT")];
        BOOL hasWiredIn = [liveCols containsObject:WUDaemonStr("ZWIREDIN")];
        BOOL hasWiredOut = [liveCols containsObject:WUDaemonStr("ZWIREDOUT")];
        BOOL hasWwanIn = [liveCols containsObject:WUDaemonStr("ZWWANIN")];
        BOOL hasWwanOut = [liveCols containsObject:WUDaemonStr("ZWWANOUT")];
        BOOL hasTs = [liveCols containsObject:WUDaemonStr("ZTIMESTAMP")];
        BOOL hasFirstTs = [procCols containsObject:WUDaemonStr("ZFIRSTTIMESTAMP")];

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

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && stmt != NULL) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *cProc = (const char *)sqlite3_column_text(stmt, 0);
                const char *cBundle = (const char *)sqlite3_column_text(stmt, 1);

                NSString *procName = WUDaemonStr(cProc);
                NSString *rawBundle = WUDaemonStr(cBundle);
                pthread_mutex_lock(&gDaemonMutex);
                NSString *bundleId = WUResolveBundleForProcLocked(procName, rawBundle);
                pthread_mutex_unlock(&gDaemonMutex);

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

                if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
                    continue;
                }
                success = YES;
                WUAddRecordToMap(dbRecords, key, procName, bundleId, wifiIn, wifiOut, wwanIn, wwanOut, firstTs, lastTs, YES);
            }
            sqlite3_finalize(stmt);
        }

        if (mergedBuckets) {
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

                    NSString *procName = WUDaemonStr(cProc);
                    NSString *rawBundle = WUDaemonStr(cBundle);
                    pthread_mutex_lock(&gDaemonMutex);
                    NSString *bundleId = WUResolveBundleForProcLocked(procName, rawBundle);
                    pthread_mutex_unlock(&gDaemonMutex);

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

                    if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
                        continue;
                    }
                    WUAddBucketToMap(dbBuckets, key, procName, bundleId, bucketHr, wifiIn, wifiOut, wwanIn, wwanOut, firstTs, lastTs, YES);
                }
                sqlite3_finalize(bucketStmt);
            }
        }
    }

    NSSet<NSString *> *routeCols = WUGetTableColumns(db, "ZLIVEROUTEPERF");
    if (routeCols.count > 0 && hasProcessTable &&
        [routeCols containsObject:WUDaemonStr("ZHASPROCESS")] &&
        [routeCols containsObject:WUDaemonStr("ZKIND")] &&
        [routeCols containsObject:WUDaemonStr("ZBYTESIN")] &&
        [routeCols containsObject:WUDaemonStr("ZBYTESOUT")]) {
        const char *routeSql =
            "SELECT "
            "  COALESCE(p.ZPROCNAME, ''), "
            "  COALESCE(p.ZBUNDLENAME, ''), "
            "  SUM(CASE WHEN r.ZKIND = 1 OR r.ZKIND = 3 THEN COALESCE(r.ZBYTESIN, 0) ELSE 0 END), "
            "  SUM(CASE WHEN r.ZKIND = 1 OR r.ZKIND = 3 THEN COALESCE(r.ZBYTESOUT, 0) ELSE 0 END), "
            "  SUM(CASE WHEN r.ZKIND = 2 THEN COALESCE(r.ZBYTESIN, 0) ELSE 0 END), "
            "  SUM(CASE WHEN r.ZKIND = 2 THEN COALESCE(r.ZBYTESOUT, 0) ELSE 0 END), "
            "  MIN(COALESCE(p.ZFIRSTTIMESTAMP, 0)), "
            "  MAX(COALESCE(r.ZTIMESTAMP, 0)) "
            "FROM ZLIVEROUTEPERF r "
            "LEFT JOIN ZPROCESS p ON r.ZHASPROCESS = p.Z_PK "
            "GROUP BY COALESCE(p.ZPROCNAME, ''), COALESCE(p.ZBUNDLENAME, '');";

        sqlite3_stmt *rStmt = NULL;
        NSMutableDictionary<NSString *, NSMutableDictionary *> *routeRecords = [NSMutableDictionary dictionary];
        if (sqlite3_prepare_v2(db, routeSql, -1, &rStmt, NULL) == SQLITE_OK && rStmt != NULL) {
            while (sqlite3_step(rStmt) == SQLITE_ROW) {
                const char *cProc = (const char *)sqlite3_column_text(rStmt, 0);
                const char *cBundle = (const char *)sqlite3_column_text(rStmt, 1);

                NSString *procName = WUDaemonStr(cProc);
                NSString *rawBundle = WUDaemonStr(cBundle);
                pthread_mutex_lock(&gDaemonMutex);
                NSString *bundleId = WUResolveBundleForProcLocked(procName, rawBundle);
                pthread_mutex_unlock(&gDaemonMutex);

                NSString *key = (bundleId.length > 0) ? bundleId : procName;
                if (key.length == 0) {
                    continue;
                }

                uint64_t wifiIn = (uint64_t)MAX(0.0, sqlite3_column_double(rStmt, 2));
                uint64_t wifiOut = (uint64_t)MAX(0.0, sqlite3_column_double(rStmt, 3));
                uint64_t wwanIn = (uint64_t)MAX(0.0, sqlite3_column_double(rStmt, 4));
                uint64_t wwanOut = (uint64_t)MAX(0.0, sqlite3_column_double(rStmt, 5));
                double firstTs = sqlite3_column_double(rStmt, 6);
                double lastTs = sqlite3_column_double(rStmt, 7);

                if (wifiIn == 0 && wifiOut == 0 && wwanIn == 0 && wwanOut == 0) {
                    continue;
                }
                success = YES;
                WUAddRecordToMap(routeRecords, key, procName, bundleId, wifiIn, wifiOut, wwanIn, wwanOut, firstTs, lastTs, YES);
            }
            sqlite3_finalize(rStmt);
        }

        NSString *kKey = WUDaemonStr("key");
        NSString *kProc = WUDaemonStr("procName");
        NSString *kBundle = WUDaemonStr("bundleId");
        NSString *kWifiIn = WUDaemonStr("wifiIn");
        NSString *kWifiOut = WUDaemonStr("wifiOut");
        NSString *kWwanIn = WUDaemonStr("wwanIn");
        NSString *kWwanOut = WUDaemonStr("wwanOut");
        NSString *kFirstTs = WUDaemonStr("firstTimestamp");
        NSString *kLastTs = WUDaemonStr("lastTimestamp");

        for (NSDictionary *rec in [routeRecords allValues]) {
            WUAddRecordToMap(
                dbRecords,
                rec[kKey],
                rec[kProc],
                rec[kBundle],
                [rec[kWifiIn] unsignedLongLongValue],
                [rec[kWifiOut] unsignedLongLongValue],
                [rec[kWwanIn] unsignedLongLongValue],
                [rec[kWwanOut] unsignedLongLongValue],
                [rec[kFirstTs] doubleValue],
                [rec[kLastTs] doubleValue],
                NO
            );
        }
    }

    NSString *kKey = WUDaemonStr("key");
    NSString *kProc = WUDaemonStr("procName");
    NSString *kBundle = WUDaemonStr("bundleId");
    NSString *kBucketHr = WUDaemonStr("bucketHour");
    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");
    NSString *kFirstTs = WUDaemonStr("firstTimestamp");
    NSString *kLastTs = WUDaemonStr("lastTimestamp");

    for (NSDictionary *rec in [dbRecords allValues]) {
        WUAddRecordToMap(
            mergedRecords,
            rec[kKey],
            rec[kProc],
            rec[kBundle],
            [rec[kWifiIn] unsignedLongLongValue],
            [rec[kWifiOut] unsignedLongLongValue],
            [rec[kWwanIn] unsignedLongLongValue],
            [rec[kWwanOut] unsignedLongLongValue],
            [rec[kFirstTs] doubleValue],
            [rec[kLastTs] doubleValue],
            NO
        );
    }

    if (mergedBuckets) {
        for (NSDictionary *bRec in [dbBuckets allValues]) {
            WUAddBucketToMap(
                mergedBuckets,
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
                NO
            );
        }
    }

    WUCloseDatabaseAndCleanTemp(db, tempBase);
    return success;
}

static NSArray<NSString *> *WUDiscoverDatabasePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *priorityCStrs[] = {
        "/private/var/networkd/db/netusage.sqlite",
        "/private/var/networkd/netusage.sqlite",
        "/private/var/wireless/Library/Databases/DataUsage.sqlite"
    };
    for (size_t i = 0; i < sizeof(priorityCStrs) / sizeof(priorityCStrs[0]); i++) {
        NSString *p = WUDaemonStr(priorityCStrs[i]);
        if ([fm fileExistsAtPath:p]) {
            NSString *resolved = [p stringByResolvingSymlinksInPath];
            if (![paths containsObject:resolved]) {
                [paths addObject:resolved];
            }
        }
    }

    const char *scanRoots[] = {
        "/private/var/networkd",
        "/private/var/wireless/Library/Databases"
    };
    for (size_t i = 0; i < sizeof(scanRoots) / sizeof(scanRoots[0]); i++) {
        NSString *root = WUDaemonStr(scanRoots[i]);
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
        NSString *rel = nil;
        while ((rel = [enumerator nextObject]) != nil) {
            if ([rel hasSuffix:WUDaemonStr(".sqlite")] || [rel hasSuffix:WUDaemonStr(".db")]) {
                if ([rel containsString:WUDaemonStr("watch")] || [rel containsString:WUDaemonStr("tmp")]) {
                    continue;
                }
                NSString *full = [root stringByAppendingPathComponent:rel];
                NSString *resolved = [full stringByResolvingSymlinksInPath];
                if (![paths containsObject:resolved]) {
                    [paths addObject:resolved];
                }
            }
        }
    }
    return paths;
}

static void WULoadExistingSnapshotLocked(
    NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedRecords,
    NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedBuckets,
    NSMutableArray<NSString *> *activeSources
) {
    NSString *primaryPath = WUDaemonStr(kSnapshotPathPrimaryCStr);
    NSString *fallbackPath = WUDaemonStr(kSnapshotPathFallbackCStr);
    NSDictionary *snapshot = [NSDictionary dictionaryWithContentsOfFile:primaryPath];
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        snapshot = [NSDictionary dictionaryWithContentsOfFile:fallbackPath];
    }
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSString *kKey = WUDaemonStr("key");
    NSString *kProc = WUDaemonStr("procName");
    NSString *kBundle = WUDaemonStr("bundleId");
    NSString *kBucketHr = WUDaemonStr("bucketHour");
    NSString *kWifiIn = WUDaemonStr("wifiIn");
    NSString *kWifiOut = WUDaemonStr("wifiOut");
    NSString *kWwanIn = WUDaemonStr("wwanIn");
    NSString *kWwanOut = WUDaemonStr("wwanOut");
    NSString *kFirstTs = WUDaemonStr("firstTimestamp");
    NSString *kLastTs = WUDaemonStr("lastTimestamp");

    NSArray *items = snapshot[WUDaemonStr("items")];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *rec in items) {
            if (![rec isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *key = rec[kKey];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) {
                continue;
            }
            WUAddRecordToMap(
                mergedRecords,
                key,
                rec[kProc],
                rec[kBundle],
                [rec[kWifiIn] unsignedLongLongValue],
                [rec[kWifiOut] unsignedLongLongValue],
                [rec[kWwanIn] unsignedLongLongValue],
                [rec[kWwanOut] unsignedLongLongValue],
                [rec[kFirstTs] doubleValue],
                [rec[kLastTs] doubleValue],
                NO
            );
        }
    }

    NSArray *buckets = snapshot[WUDaemonStr("buckets")];
    if ([buckets isKindOfClass:[NSArray class]]) {
        for (NSDictionary *bRec in buckets) {
            if (![bRec isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *key = bRec[kKey];
            if (![key isKindOfClass:[NSString class]] || key.length == 0) {
                continue;
            }
            WUAddBucketToMap(
                mergedBuckets,
                key,
                bRec[kProc],
                bRec[kBundle],
                [bRec[kBucketHr] longLongValue],
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                [bRec[kFirstTs] doubleValue],
                [bRec[kLastTs] doubleValue],
                NO
            );
        }
    }

    NSArray *sources = snapshot[WUDaemonStr("sources")];
    if ([sources isKindOfClass:[NSArray class]]) {
        for (NSString *s in sources) {
            if ([s isKindOfClass:[NSString class]] && ![activeSources containsObject:s]) {
                [activeSources addObject:s];
            }
        }
    }
}

static void exportDataUsageSnapshot(void) {
    @autoreleasepool {
        WUPollNWStatisticsSources();

        NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedRecords = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableDictionary *> *mergedBuckets = [NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *activeSources = [NSMutableArray array];

        // Pre-populate with previous snapshot data to guarantee monotonic non-decreasing totals
        WULoadExistingSnapshotLocked(mergedRecords, mergedBuckets, activeSources);

        NSArray<NSString *> *candidatePaths = WUDiscoverDatabasePaths();

        // Query and merge usage records and hourly buckets from reachable databases
        for (NSString *path in candidatePaths) {
            if (querySQLiteDatabase(path, mergedRecords, mergedBuckets)) {
                NSString *name = [path lastPathComponent];
                if (![activeSources containsObject:name]) {
                    [activeSources addObject:name];
                }
            }
        }

        // Merge persistent live kernel socket ledger (NetworkStatistics)
        pthread_mutex_lock(&gDaemonMutex);
        WULoadLiveLedgerLocked();
        NSString *kKey = WUDaemonStr("key");
        NSString *kProc = WUDaemonStr("procName");
        NSString *kBundle = WUDaemonStr("bundleId");
        NSString *kBucketHr = WUDaemonStr("bucketHour");
        NSString *kWifiIn = WUDaemonStr("wifiIn");
        NSString *kWifiOut = WUDaemonStr("wifiOut");
        NSString *kWwanIn = WUDaemonStr("wwanIn");
        NSString *kWwanOut = WUDaemonStr("wwanOut");
        NSString *kFirstTs = WUDaemonStr("firstTimestamp");
        NSString *kLastTs = WUDaemonStr("lastTimestamp");

        if (gLiveLedgerBuckets.count > 0) {
            for (NSDictionary *bRec in [gLiveLedgerBuckets allValues]) {
                NSString *proc = bRec[kProc] ?: WUDaemonStr("");
                NSString *bundle = WUResolveBundleForProcLocked(proc, bRec[kBundle]);
                NSString *key = (bundle.length > 0) ? bundle : (bRec[kKey] ?: proc);
                WUAddBucketToMap(
                    mergedBuckets,
                    key,
                    proc,
                    bundle,
                    [bRec[kBucketHr] longLongValue],
                    [bRec[kWifiIn] unsignedLongLongValue],
                    [bRec[kWifiOut] unsignedLongLongValue],
                    [bRec[kWwanIn] unsignedLongLongValue],
                    [bRec[kWwanOut] unsignedLongLongValue],
                    [bRec[kFirstTs] doubleValue],
                    [bRec[kLastTs] doubleValue],
                    NO
                );
            }
        }

        if (gLiveLedgerRecords.count > 0) {
            BOOL addedLive = NO;
            for (NSDictionary *rec in [gLiveLedgerRecords allValues]) {
                NSString *proc = rec[kProc] ?: WUDaemonStr("");
                NSString *bundle = WUResolveBundleForProcLocked(proc, rec[kBundle]);
                NSString *key = (bundle.length > 0) ? bundle : (rec[kKey] ?: proc);
                WUAddRecordToMap(
                    mergedRecords,
                    key,
                    proc,
                    bundle,
                    [rec[kWifiIn] unsignedLongLongValue],
                    [rec[kWifiOut] unsignedLongLongValue],
                    [rec[kWwanIn] unsignedLongLongValue],
                    [rec[kWwanOut] unsignedLongLongValue],
                    [rec[kFirstTs] doubleValue],
                    [rec[kLastTs] doubleValue],
                    NO
                );
                addedLive = YES;
            }
            if (addedLive && ![activeSources containsObject:WUDaemonStr("NetworkStatistics")]) {
                [activeSources addObject:WUDaemonStr("NetworkStatistics")];
            }
        }
        pthread_mutex_unlock(&gDaemonMutex);

        // Ensure every record's cumulative totals are at least the sum of its hourly buckets
        NSMutableDictionary<NSString *, NSMutableDictionary *> *bucketSums = [NSMutableDictionary dictionary];
        for (NSDictionary *bRec in [mergedBuckets allValues]) {
            WUAddRecordToMap(
                bucketSums,
                bRec[kKey],
                bRec[kProc],
                bRec[kBundle],
                [bRec[kWifiIn] unsignedLongLongValue],
                [bRec[kWifiOut] unsignedLongLongValue],
                [bRec[kWwanIn] unsignedLongLongValue],
                [bRec[kWwanOut] unsignedLongLongValue],
                [bRec[kFirstTs] doubleValue],
                [bRec[kLastTs] doubleValue],
                YES
            );
        }
        for (NSDictionary *sumRec in [bucketSums allValues]) {
            WUAddRecordToMap(
                mergedRecords,
                sumRec[kKey],
                sumRec[kProc],
                sumRec[kBundle],
                [sumRec[kWifiIn] unsignedLongLongValue],
                [sumRec[kWifiOut] unsignedLongLongValue],
                [sumRec[kWwanIn] unsignedLongLongValue],
                [sumRec[kWwanOut] unsignedLongLongValue],
                [sumRec[kFirstTs] doubleValue],
                [sumRec[kLastTs] doubleValue],
                NO
            );
        }

        NSDictionary *ifCounters = readInterfaceCounters();
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[WUDaemonStr("generatedAt")] = WUDaemonDouble([[NSDate date] timeIntervalSince1970]);
        payload[WUDaemonStr("sources")] = activeSources;
        payload[WUDaemonStr("interfaceCounters")] = ifCounters ?: [NSDictionary dictionary];
        payload[WUDaemonStr("items")] = [mergedRecords allValues] ?: [NSArray array];
        payload[WUDaemonStr("buckets")] = [mergedBuckets allValues] ?: [NSArray array];

        NSString *primaryPath = WUDaemonStr(kSnapshotPathPrimaryCStr);
        NSString *fallbackPath = WUDaemonStr(kSnapshotPathFallbackCStr);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *primaryDir = [primaryPath stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:primaryDir]) {
            [fm createDirectoryAtPath:primaryDir withIntermediateDirectories:YES attributes:nil error:nil];
        }

        if ([payload writeToFile:primaryPath atomically:YES]) {
            chmod(kSnapshotPathPrimaryCStr, 0644);
        }
        if ([payload writeToFile:fallbackPath atomically:YES]) {
            chmod(kSnapshotPathFallbackCStr, 0644);
        }
    }
}

static void WUDaemonRefreshCallback(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
) {
    exportDataUsageSnapshot();
    notify_post(kNotifyUpdated);
}

static void WUDaemonTimerCallback(CFRunLoopTimerRef timer, void *info) {
    exportDataUsageSnapshot();
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        WUPopulateInstalledAppMappings();
        WUInitNWStatisticsManager();

        BOOL runOnce = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--once") == 0) {
                runOnce = YES;
                break;
            }
        }

        if (runOnce) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
            exportDataUsageSnapshot();
            notify_post(kNotifyUpdated);
            return 0;
        }

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        exportDataUsageSnapshot();
        notify_post(kNotifyUpdated);

        CFNotificationCenterRef darwinCenter = CFNotificationCenterGetDarwinNotifyCenter();
        CFStringRef refreshName = (__bridge CFStringRef)WUDaemonStr(kNotifyRefresh);
        CFNotificationCenterAddObserver(
            darwinCenter,
            NULL,
            WUDaemonRefreshCallback,
            refreshName,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 15.0,
            15.0,
            0,
            0,
            WUDaemonTimerCallback,
            NULL
        );
        if (timer != NULL) {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
            CFRelease(timer);
        }

        CFRunLoopRun();
    }
    return 0;
}
