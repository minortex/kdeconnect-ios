Unofficial build of **KDE Connect iOS** (based on upstream `master`, just past v0.5.6) with two
things upstream does not have. Source and full history: https://github.com/minortex/kdeconnect-ios

## What's in it

- **Background keep-alive (experimental)** — the app no longer tears down its connection when it
  goes to the background, so it can keep receiving files while backgrounded.
  Uses the private `UIBackgroundModes = continuous` mode, with no silent audio.
  **Do not use releases older than `v0.5.6-bg-share.2`**: those kept the audio codec powered 24/7
  through a silent audio session and were measured at ~76% of the entire device's power draw.
- **Share sheet extension** — KDE Connect now shows up in the iOS share sheet and can send
  **files, photos, text and URLs**. When more than one device is connected you get a picker with
  just the reachable ones. Original file names are preserved.
- **Clipboard, phone → desktop**: not included (kept manual, as upstream).

## Requirements

- iOS 15.0+ (built with the iOS 26 SDK, minimum OS is 15.0; tested on iOS 17.0)
- **TrollStore** — the IPA is unsigned. You can also re-sign it with your own certificate.

## Install

1. **Uninstall the App Store build of KDE Connect first** — this uses the same bundle id
   (`org.kde.kdeconnect`), so they cannot coexist.
2. Install `kdeconnect-ios-unsigned.ipa` with TrollStore.
3. **Reboot the device after installing.** iOS caches app-extension processes; without a reboot the
   share extension may keep running the previously installed build.
4. Open KDE Connect once so it can publish its device list to the share extension.

## Known limitations

- **This cannot go on the App Store in this form.** The share extension uses a private-API
  fallback (walking the `UIResponder` chain to call `openURL:`) to launch the app when it is not
  running. That is a deliberate grey area; it works up to iOS 17 and is blocked from iOS 18.
  The normal path (a Darwin notification to the already-running background app) does not need it.
- The background keep-alive is experimental and its cost has not been measured yet; if you see
  unusual battery drain, please report it.
- The app must not be force-quit or background receiving stops.
- If iOS kills the app in the background, shares are only delivered once the app is opened again.

## License

Based on [KDE Connect iOS](https://invent.kde.org/network/kdeconnect-ios),
GPL-2.0-or-later / LicenseRef-KDE-Accepted-GPL. This is an unofficial build and is not affiliated
with or endorsed by KDE.
