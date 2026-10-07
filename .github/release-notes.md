Unofficial build of **KDE Connect iOS** (based on upstream `master`, just past v0.5.6) with a
share sheet extension upstream does not have. Source and full history:
https://github.com/minortex/kdeconnect-ios

## What's in it

- **Share sheet extension** — KDE Connect now shows up in the iOS share sheet. Share **files,
  photos, text and URLs**. Original file names are preserved.
- **"Open in KDE Connect"** — it also shows up in *Open in / Open with* menus (Filza, Files, …),
  so files can be handed over without a share sheet.
- **Device picking happens in the app**, where the live connection state is known: with one
  connected device it sends straight away, with several it shows an in-app picker.
- **Clipboard, phone → desktop**: not included (kept manual, as upstream).

## Requirements

- iOS 15.0+ (built with the iOS 26 SDK, minimum OS is 15.0; tested on iOS 17.0)
- **TrollStore** — the IPA is unsigned. You can also re-sign it with your own certificate.

## Install

1. **Uninstall the App Store build of KDE Connect first** — this uses the same bundle id
   (`org.kde.kdeconnect`), so they cannot coexist.
2. Install `kdeconnect-ios-unsigned.ipa` with TrollStore.
3. **Reboot the device after installing.** iOS caches app-extension processes and LaunchServices
   registrations; without a reboot the share sheet or *Open in* entry may not show up.
4. Open KDE Connect once.

## Known limitations

- **This cannot go on the App Store in this form.** When the app is not running, the share
  extension uses a private-API fallback (walking the `UIResponder` chain to call `openURL:`) to
  launch it. That is a deliberate grey area; it works up to iOS 17 and is blocked from iOS 18.
  The normal path (a Darwin notification to the already-running app) does not need it.
- Like any normal app it is suspended in the background, so it only receives while it is in the
  foreground or freshly backgrounded. There is **no** background keep-alive: an earlier build
  used a silent audio session for that and was measured at ~76% of the whole device's power
  draw, so it was removed.
- Force-quitting the app stops receiving entirely.

## License

Based on [KDE Connect iOS](https://invent.kde.org/network/kdeconnect-ios),
GPL-2.0-or-later / LicenseRef-KDE-Accepted-GPL. This is an unofficial build and is not affiliated
with or endorsed by KDE.
