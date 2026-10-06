/*
 * SPDX-FileCopyrightText: 2021 Lucas Wang <lucas.wang@tuta.io>
 *
 * SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
 */

// Original header below:
//
//  KDE_Connect_App.swift
//  KDE Connect
//
//  Created by Lucas Wang on 2021-06-17.
//

#if !os(macOS)
import UIKit
import AVFoundation
#else
import UserNotifications
#endif
import SwiftUI

// Intentional naming
// swiftlint:disable:next type_name
@main struct KDE_Connect_App: App {
    @ObservedObject var kdeConnectSettingsForTopLevel: KdeConnectSettings = .shared
#if !os(macOS)
    @StateObject var alertManager: AlertManager = AlertManager()
#else
    @StateObject var inAppNotificationManager: InAppNotificationManager
    @StateObject var notificationManager: NotificationManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State var grantedNotificationPermission: Bool = false
    @State var showingHelpWindow: Bool = false
    
    init() {
        let inAppNotificationManager = InAppNotificationManager()
        let notificationManager = NotificationManager(inAppNotificationManager)
        _inAppNotificationManager = StateObject(wrappedValue: inAppNotificationManager)
        _notificationManager = StateObject(wrappedValue: notificationManager)
    }
    
    func requestNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if error == nil {
                self.grantedNotificationPermission = true
            } else {
                self.grantedNotificationPermission = false
            }
        }
    }
#endif
    
    var body: some Scene {
#if !os(macOS)
        WindowGroup {
            MainTabView()
                .preferredColorScheme(kdeConnectSettingsForTopLevel.chosenTheme)
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("setupScreenshotDevices") {
                        UIPreview.setupFakeDevices()
                    }
#endif
                    backgroundService.startDiscovery()
                    motionManager.gyroUpdateInterval = 0.025
                    
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // Back in the foreground we no longer need to stay alive, so
                    // release the silent audio session again.
                    BackgroundKeepAlive.shared.stop()

                    // In case the app's been chilling suspended for a long time,
                    // upon returning ask for updates to all devices's battery statuses
                    // broadcastBatteryStatusAllDevices()
                    // requestBatteryStatusAllDevices()

                    backgroundService.refreshDiscovery()
                }
                .onReceive(NotificationCenter.default
                    .publisher(for: UIApplication
                        .didEnterBackgroundNotification)
                ) { _ in
                    // Keep the sockets alive so we can still receive clipboard and
                    // file packets while backgrounded. Playing silence with an
                    // active `.playback` audio session (see UIBackgroundModes)
                    // stops iOS from suspending the process.
                    BackgroundKeepAlive.shared.start()
                }
                .environmentObject(KdeConnectSettings.shared)
                .environmentObject(connectedDevicesViewModel)
                .environmentObject(alertManager)
                .alert(
                    alertManager.currentAlert.title,
                    isPresented: $alertManager.alertPresent,
                    actions: alertManager.currentAlert.buttons,
                    message: alertManager.currentAlert.content
                )
        }
#else
        WindowGroup("Connect", id: "connect") {
            MainView(grantedNotificationPermission: self.$grantedNotificationPermission, showingHelpWindow: self.$showingHelpWindow)
                .preferredColorScheme(kdeConnectSettingsForTopLevel.chosenTheme)
                .onAppear {
                    NSApplication.shared.applicationIconImage = NSImage(named: (kdeConnectSettingsForTopLevel.appIcon.rawValue ?? "AppIcon"))
                    requestNotification()
                    backgroundService.startDiscovery()
                    requestBatteryStatusAllDevices()
                }
                .environmentObject(notificationManager)
                .environmentObject(inAppNotificationManager)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willUpdateNotification)) { _ in
                    requestNotification()
                }
        }
        .commands {
            CommandMenu("Devices") {
                Button("Refresh Discovery") {
                    MainView.mainViewSingleton?.refreshDiscoveryAndList()
                }
                Button("Show Received Files in Finder") {
                    let fileManager = FileManager.default
                    do {
                        // see Share plugin
                        let documentDirectory = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                        NSWorkspace.shared.open(documentDirectory)
                    } catch {
                        print("Error showing received files in Finder \(error)")
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
    
        WindowGroup("Help", id: "help") {
            HelpView(showingHelpWindow: self.$showingHelpWindow)
                .preferredColorScheme(kdeConnectSettingsForTopLevel.chosenTheme)
        }
        .windowStyle(.hiddenTitleBar)
        
        Settings {
            SettingsView(grantedNotificationPermission: self.$grantedNotificationPermission)
                .preferredColorScheme(kdeConnectSettingsForTopLevel.chosenTheme)
                .environmentObject(kdeConnectSettingsForTopLevel)
        }
#endif
    }
}

#if !os(macOS)
/// Keeps the process alive while it is in the background by looping silence
/// through an active `.playback` audio session.
///
/// This is paired with `UIBackgroundModes = audio` in Info.plist. We never
/// publish anything to `MPNowPlayingInfoCenter` and never register remote
/// commands, so the system "Now Playing" UI should normally stay empty.
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var engine: AVAudioEngine?
    private let logger = Logger()

    private init() {}

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` so we don't stop whatever the user is listening to.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100,
                                             channels: 2) else { return }
            let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }

            let engine = AVAudioEngine()
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: format)
            try engine.start()

            self.engine = engine
            logger.info("Background keep-alive audio session started")
        } catch {
            logger.fault("Failed to start background keep-alive: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        guard engine != nil else { return }
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        logger.info("Background keep-alive audio session stopped")
    }
}
#endif
