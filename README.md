# WiFiUsage (`com.n1ck.wifiusage`)

A rootless iOS 16.4 Dopamine jailbreak tweak (`PreferenceBundle` + root helper daemon) that adds a **Wi-Fi & Cellular Usage** section directly inside the native **iOS Settings** app.

> [!NOTE]
> Historic data usage calculations and metrics may not be completely accurate due to how iOS aggregates and flushes network database records.

> [!WARNING]
> **Disclaimer**: This project was developed with the assistance of AI. Use at your own risk. The authors and contributors assume no liability for any issues, data loss, or device instability that may arise from using this software.

## Features

- **Native iOS Settings Integration**: Appears in the main iOS Settings list (`Wi-Fi & Cellular Usage`) via `PreferenceLoader`.
- **All-Time, Weekly, and Monthly Views with Browsable History**:
  - Switch between **All Time**, **Weekly**, and **Monthly** usage at the top of the page.
  - Step backward and forward (`◀` / `▶`) through previous calendar weeks and months, or tap the center date range to jump back to the current week/month.
  - Automatically calculates daily average data consumption (`Wi-Fi` & `Cellular`) for the selected week or month.
- **Top Summary Card**:
  - Combined total data consumption (`Wi-Fi + Cellular`) with a visual Wi-Fi vs. Cellular proportional bar.
  - Side-by-side **Wi-Fi** and **Cellular** cards showing total data, downloaded (`↓`) and uploaded (`↑`) traffic, and the **Apps vs. System** split for each interface.
  - **Apps vs. System** summary lines with process counts.
  - **Boot Session Live Counters**: Hardware network interface totals (`en0` for Wi-Fi, `pdp_ip*` for Cellular) since last reboot via `getifaddrs()`.
- **Split Per App or System**:
  - Filter between **Apps** (installed user & system applications), **System** (daemons, background services, and system processes), or **All**.
  - Sort by **Total Usage**, **Wi-Fi Only**, or **Cellular Only**.
  - Live search bar to filter by app name, bundle identifier (`ZBUNDLENAME`), or process executable (`ZPROCNAME`).
- **Detailed Per-Item View**:
  - Every row displays the app or service icon, name, category badge (`[App]`, `[System App]`, `[System]`), **Wi-Fi amount**, **Cellular amount**, **Total amount**, and a relative usage bar.
  - Tap any row to view exact byte counts, download/upload (`↓`/`↑`) split for both Wi-Fi and Cellular, percentage of total device usage, last active timestamp, and a one-tap **Copy Details** button.

## Architecture (iOS 16.4 Dopamine Rootless)

1. **`wifiusaged` (`/var/jb/usr/libexec/wifiusaged`)**:
   - Lightweight on-demand root daemon triggered via Darwin notification (`com.n1ck.wifiusage.refresh`).
   - Queries `/private/var/networkd/db/netusage.sqlite` and `/private/var/wireless/Library/Databases/DataUsage.sqlite` (`ZLIVEUSAGE` + `ZPROCESS` tables for `ZWIFIIN`, `ZWIFIOUT`, `ZWWANIN`, `ZWWANOUT`) as `root` and writes a snapshot to `/var/jb/var/mobile/Library/Preferences/com.n1ck.wifiusage.snapshot.plist`.
2. **`WiFiUsagePrefs.bundle` (`/var/jb/Library/PreferenceBundles/WiFiUsagePrefs.bundle`)**:
   - Loaded by `Preferences.app` via `/var/jb/Library/PreferenceLoader/Preferences/WiFiUsagePrefs.plist`.
   - Merges data from the `wifiusaged` snapshot, direct in-process SQLite reads, `CoreTelephonyClient` (`CTDeviceDataUsage`), and `getifaddrs()`, resolving application names and icons via `LSApplicationProxy`.

## Building the Rootless `.deb`

Requires [Theos](https://theos.dev/) configured with an iOS 15.0+ SDK:

```bash
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

The resulting Dopamine-compatible `iphoneos-arm64` `.deb` package will be generated in `./packages/` and can be installed via **Sileo**, **Zebra**, or `dpkg -i`.

