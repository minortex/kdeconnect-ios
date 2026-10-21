# KDE Connect Legacy

Minimal Objective-C client for iOS 9, based on the 2014 KDE Connect iOS
implementation. It implements the protocol v8 LAN flow used by current KDE
Connect desktop clients.

## Scope

- UDP discovery on port 1716
- TCP + TLS connection using the device certificate
- pairing with the v8 timestamp-based flow
- file sending and receiving
- clipboard sending and receiving

Not included: mDNS, Share Extension, notifications, Ping, remote input,
presenter, run command, and background execution.

## Build

Use Xcode 12.4 or older when you need an armv7/iOS 9 build. Newer Xcode
releases no longer ship the 32-bit iOS toolchain.

```sh
cd Legacy
brew install xcodegen
xcodegen generate
pod install
open KDEConnectLegacy.xcworkspace
```

`OpenSSL-Universal-1.0.2` is used only to create the self-signed client certificate
on iOS 9. It is an unmaintained dependency and should stay isolated to this
legacy target.

The legacy target must be built and tested on a Mac with the iOS 9 SDK or a
modern Xcode that still accepts the armv7 target. The current workspace is
Linux, so syntax/plist/YAML checks pass here but an iOS build cannot be run
locally.
