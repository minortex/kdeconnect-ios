import UIKit
import UniformTypeIdentifiers

// NSLog (unlike os_log) always reaches the device syslog, which is what we can
// read from a Linux host over usbmuxd while debugging.
private func logInfo(_ message: String) { NSLog("KDEConnectShare v3: %@", message) }
private func logError(_ message: String) { NSLog("KDEConnectShare v3 ERROR: %@", message) }

private struct SharedDevice {
    let id: String
    let name: String
}

/// Share sheet entry point. It never talks to the network itself; it just
/// copies whatever was shared into the shared app-group container and then
/// nudges the main app (which keeps a live connection) to send it.
///
/// The main app is woken in two ways:
///  1. a Darwin notification, which works while the app is alive in the
///     background thanks to `BackgroundKeepAlive`;
///  2. a best-effort `openURL:` through the responder chain (the only way an
///     app extension can launch its containing app), as a fallback for when
///     the app is not running at all.
final class ShareViewController: UIViewController {
    private static let appGroupID = "group.5433B4KXM8.org.kde.kdeconnect"
    private static let manifestName = "pending-share.json"
    private static let darwinNotification = "org.kde.kdeconnect.pending-share"

    private let group = DispatchGroup()
    private let lock = NSLock()
    private var files: [String] = []
    private var texts: [String] = []
    private var urls: [String] = []
    /// Mirrored into the manifest so the main app (whose logs we *can* read)
    /// can report what the extension saw.
    private var diagnostics: [String] = []

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        collectItems()
    }

    // MARK: - Collecting

    private func collectItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            diagnostics.append("no inputItems")
            return finish()
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            diagnostics.append("no attachments")
            return finish()
        }

        diagnostics.append("providers=\(providers.count)")
        for (index, provider) in providers.enumerated() {
            diagnostics.append("p\(index) types=[\(provider.registeredTypeIdentifiers.joined(separator: ","))]")
            load(provider)
        }

        group.notify(queue: .main) { [weak self] in
            self?.chooseDeviceAndHandOff()
        }
    }

    private func load(_ provider: NSItemProvider) {
        // Photos / videos: ask for a real file on disk.
        for type in [UTType.image, UTType.movie] {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                diagnostics.append("p: image/movie \(type.identifier)")
                loadAsFile(provider, type: type)
                return
            }
        }

        // Files from the Files app. This must come before the plain `public.url`
        // check: a file URL also conforms to `public.url`, and treating it as a
        // link drops the file entirely.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            diagnostics.append("p: file-url")
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                defer { self?.group.leave() }
                guard let self else { return }
                var source: URL?
                if let url = item as? URL {
                    source = url
                } else if let data = item as? Data {
                    source = URL(dataRepresentation: data, relativeTo: nil)
                }
                guard let source, let copied = self.copyIntoGroup(source, suggestedName: source.lastPathComponent) else { return }
                self.append { $0.files.append(copied) }
            }
            return
        }

        // Web links (Safari tabs and friends).
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            diagnostics.append("p: url")
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                defer { self?.group.leave() }
                guard let self else { return }
                if let url = item as? URL {
                    if url.isFileURL, let copied = self.copyIntoGroup(url, suggestedName: url.lastPathComponent) {
                        self.append { $0.files.append(copied) }
                    } else if !url.isFileURL {
                        self.append { $0.urls.append(url.absoluteString) }
                    }
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    self.append { $0.urls.append(string) }
                }
            }
            return
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            diagnostics.append("p: text")
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                defer { self?.group.leave() }
                if let text = item as? String {
                    self?.append { $0.texts.append(text) }
                }
            }
            return
        }

        // Anything else we can still pull a file out of.
        diagnostics.append("p: fallback data")
        loadAsFile(provider, type: .data)
    }

    private func loadAsFile(_ provider: NSItemProvider, type: UTType) {
        guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return }
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            defer { self?.group.leave() }
            guard let url, let copied = self?.copyIntoGroup(url, suggestedName: provider.suggestedName) else { return }
            self?.append { $0.files.append(copied) }
        }
    }

    private func append(_ body: (ShareViewController) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }

    // MARK: - Handing off

    private func copyIntoGroup(_ source: URL, suggestedName: String?) -> String? {
        // Files shared from the Files app / other providers are security scoped
        // and cannot be read without asking for access first.
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        guard let container = groupContainerURL() else {
            logError("no app group container available")
            append { $0.diagnostics.append("no app group container") }
            return nil
        }
        // Every share gets its own folder so identical names cannot collide,
        // while the file itself keeps its original (meaningful) name.
        let folderName = UUID().uuidString
        let folder = container.appendingPathComponent("Incoming/\(folderName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var name = (suggestedName?.isEmpty == false ? suggestedName! : source.lastPathComponent)
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty {
            name += ".\(source.pathExtension)"
        }
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            logError("copy failed for \(source.lastPathComponent): \(error.localizedDescription)")
            append { $0.diagnostics.append("copyFailed \(source.lastPathComponent): \(error.localizedDescription)") }
            return nil
        }
        let relative = "\(folderName)/\(name)"
        logInfo("copied \(relative)")
        append { $0.diagnostics.append("copied \(relative)") }
        return relative
    }

    /// Ask which device to send to when more than one is connected. The device
    /// list is mirrored into the app group by the main app.
    private func chooseDeviceAndHandOff() {
        let devices = loadSharedDevices()
        logInfo("collected \(self.files.count) file(s), \(self.texts.count) text(s), \(self.urls.count) url(s); \(devices.count) connected device(s)")
        if files.isEmpty && texts.isEmpty && urls.isEmpty {
            presentDiagnostics("KDE Connect: nothing to send")
            return
        }
        guard devices.count > 1 else {
            handOff(deviceID: devices.first?.id)
            return
        }

        let alert = UIAlertController(title: "Send with KDE Connect",
                                      message: "Choose a device",
                                      preferredStyle: .alert)
        for device in devices {
            alert.addAction(UIAlertAction(title: device.name, style: .default) { [weak self] _ in
                self?.handOff(deviceID: device.id)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finish()
        })
        present(alert, animated: true)
    }

    private func handOff(deviceID: String?) {
        logInfo("handing off to \(deviceID ?? "any")")
        guard writeManifest(deviceID: deviceID) else {
            presentDiagnostics("KDE Connect could not prepare the share")
            return
        }
        postDarwinNotification()

        // Give the (backgrounded) main app a moment to pick this up. Only force
        // launching the app when nothing consumed the manifest, so a live app
        // does not yank the user into the foreground for nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if self.manifestStillPending() {
                logInfo("manifest still pending after 1.5s, launching app")
                self.openContainingApp()
            } else {
                logInfo("main app consumed the manifest")
            }
            self.finish()
        }
    }

    @discardableResult
    private func writeManifest(deviceID: String?) -> Bool {
        guard let container = groupContainerURL() else {
            diagnostics.append("writeManifest: no app group container")
            return false
        }
        var manifest: [String: Any] = ["files": files, "texts": texts, "urls": urls]
        manifest["diag"] = diagnostics
        if let deviceID { manifest["device"] = deviceID }
        let destination = container.appendingPathComponent(Self.manifestName)
        guard let data = try? JSONSerialization.data(withJSONObject: manifest) else {
            diagnostics.append("writeManifest: could not serialize")
            return false
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            diagnostics.append("writeManifest failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private func presentDiagnostics(_ title: String) {
        let alert = UIAlertController(title: title,
                                      message: diagnostics.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.finish()
        })
        present(alert, animated: true)
    }

    private func manifestStillPending() -> Bool {
        guard let container = groupContainerURL() else { return true }
        return FileManager.default.fileExists(
            atPath: container.appendingPathComponent(Self.manifestName).path)
    }

    private func loadSharedDevices() -> [SharedDevice] {
        guard let container = groupContainerURL(),
              let data = try? Data(contentsOf: container.appendingPathComponent("devices.json")),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"], let name = entry["name"] else { return nil }
            return SharedDevice(id: id, name: name)
        }
    }

    private func postDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(Self.darwinNotification as CFString),
            nil, nil, true
        )
    }

    /// An app extension may not use `extensionContext.open(_:)` (that is a
    /// Today-widget-only API), so walk the responder chain and call the private
    /// `openURL:` selector instead. This is the same trick third-party share
    /// extensions use to launch their host app.
    private func openContainingApp() {
        guard let url = URL(string: "kdeconnect://share") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    private func groupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
