/*
 * SPDX-FileCopyrightText: 2021 Lucas Wang <lucas.wang@tuta.io>
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

// Original header below:
//
//  Clipboard.swift
//  KDE Connect Test
//
//  Created by Lucas Wang on 2021-09-05.
//

#if !os(macOS)
import UIKit
#else
import AppKit
#endif

@objc class Clipboard: NSObject, Plugin {
    static var lastLocalClipboardUpdateTimestamp: Int = Int(Date().millisecondsSince1970)
    @objc weak var controlDevice: Device!
    private let logger = Logger()
    
    @objc init(controlDevice: Device) {
        self.controlDevice = controlDevice
    }
    
    @objc func onDevicePacketReceived(np: NetworkPacket) {
        if (np.type == .clipboard || np.type == .clipboardConnect) {
            if (np.object(forKey: "content") != nil) {
                if (np.type == .clipboard) {
#if !os(macOS)
                    UIPasteboard.general.string = np.object(forKey: "content") as? String
                    ClipboardSync.shared.noteRemoteWrite()
#else
                    NSPasteboard.general.setString(np.object(forKey: "content") as? String ?? "", forType: .string)
#endif
                    Self.lastLocalClipboardUpdateTimestamp = Int(Date().millisecondsSince1970)
                    logger.debug("Local clipboard synced with remote packet, timestamp updated")
                } else if (np.type == .clipboardConnect) {
                    let packetTimeStamp: Int = np.integer(forKey: "timestamp")
                    if (packetTimeStamp == 0 || packetTimeStamp < Self.lastLocalClipboardUpdateTimestamp) {
                        logger.info("Invalid timestamp from \(np.type.rawValue, privacy: .public), doing nothing")
                    } else {
#if !os(macOS)
                        UIPasteboard.general.string = np.object(forKey: "content") as? String
                        ClipboardSync.shared.noteRemoteWrite()
#else
                        NSPasteboard.general.setString(np.object(forKey: "content") as? String ?? "", forType: .string)
#endif
                        Self.lastLocalClipboardUpdateTimestamp = Int(Date().millisecondsSince1970)
                        logger.debug("Local clipboard synced with remote packet, timestamp updated")
                    }
                }
            } else {
                logger.debug("Received nil for the content of the remote device's \(np.type.rawValue, privacy: .public), doing nothing")
            }
        }
    }
    
    // FIXME: unused function
    func connectClipboardContent() {
#if !os(macOS)
        if let clipboardContent = UIPasteboard.general.string {
            let np = NetworkPacket(type: .clipboardConnect)
            np.setObject(clipboardContent, forKey: "content")
            np.setInteger(Self.lastLocalClipboardUpdateTimestamp, forKey: "timestamp")
            controlDevice.send(np, tag: Int(PACKET_TAG_CLIPBOARD))
        } else {
            logger.info("Attempt to connect local clipboard content with remote device returned nil")
        }
#else
        if let clipboardContent = NSPasteboard.general.string(forType: .string) {
            let np = NetworkPacket(type: .clipboardConnect)
            np.setObject(clipboardContent, forKey: "content")
            np.setInteger(Self.lastLocalClipboardUpdateTimestamp, forKey: "timestamp")
            controlDevice.send(np, tag: Int(PACKET_TAG_CLIPBOARD))
        } else {
            print("Attempt to connect local clipboard content with remote device returned nil")
        }
#endif
    }
    
    func sendClipboardContentOut() {
#if !os(macOS)
        if let clipboardContent = UIPasteboard.general.string {
            let np = NetworkPacket(type: .clipboard)
            np.setObject(clipboardContent, forKey: "content")
            controlDevice.send(np, tag: Int(PACKET_TAG_CLIPBOARD))
        } else {
            logger.info("Attempt to grab and update local clipboard content returned nil")
        }
#else
        if let clipboardContent = NSPasteboard.general.string(forType: .string) {
            let np = NetworkPacket(type: .clipboard)
            np.setObject(clipboardContent, forKey: "content")
            controlDevice.send(np, tag: Int(PACKET_TAG_CLIPBOARD))
        } else {
            print("Attempt to grab and update local clipboard content returned nil")
        }
#endif
    }

    @objc func sendText(_ content: String) {
        let np = NetworkPacket(type: .clipboard)
        np.setObject(content, forKey: "content")
        controlDevice.send(np, tag: Int(PACKET_TAG_CLIPBOARD))
    }
}

#if !os(macOS)
/// Watches the system pasteboard and pushes every change to all connected
/// devices, so the phone's clipboard reaches the desktop automatically.
///
/// This keeps working while the app is in the background because
/// `BackgroundKeepAlive` keeps the process running.
///
/// iOS 16+ shows a "... would like to paste from ..." alert whenever we read a
/// pasteboard that another app wrote. Users can silence it once via
/// Settings -> KDE Connect -> Paste from Other Apps -> Allow.
@objc final class ClipboardSync: NSObject {
    @objc static let shared = ClipboardSync()

    private var started = false
    private var timer: Timer?
    private var lastChangeCount = 0
    private let logger = Logger()

    private override init() {
        super.init()
    }

    @objc func start() {
        guard !started else { return }
        started = true
        lastChangeCount = UIPasteboard.general.changeCount

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardMayHaveChanged),
            name: UIPasteboard.changedNotification,
            object: nil
        )

        // `changedNotification` is not reliably delivered while we are in the
        // background, so also poll the change counter on the main run loop.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pasteboardMayHaveChanged()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        logger.info("Clipboard auto-sync started")
    }

    /// Call right after writing a clipboard that came from a remote device so
    /// we don't immediately echo it back.
    @objc func noteRemoteWrite() {
        lastChangeCount = UIPasteboard.general.changeCount
    }

    @objc private func pasteboardMayHaveChanged() {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let targets: [Clipboard] = backgroundService.devices.values.compactMap { device in
            guard device._pluginsEnableStatus[.clipboard]?.boolValue == true else { return nil }
            return device._plugins[.clipboard] as? Clipboard
        }
        guard !targets.isEmpty else { return }

        // Reading the content is what may trigger the "Paste from Other Apps" alert.
        guard let text = pasteboard.string, !text.isEmpty else { return }

        for clipboard in targets {
            clipboard.sendText(text)
        }
        logger.debug("Pushed local clipboard to \(targets.count) device(s)")
    }
}
#endif
