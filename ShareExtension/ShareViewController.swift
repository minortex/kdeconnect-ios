import UIKit
import UniformTypeIdentifiers

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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        collectItems()
    }

    // MARK: - Collecting

    private func collectItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return finish()
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { return finish() }

        for provider in providers {
            load(provider)
        }

        group.notify(queue: .main) { [weak self] in
            self?.handOff()
        }
    }

    private func load(_ provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                defer { self?.group.leave() }
                if let url = item as? URL, !url.isFileURL {
                    self?.append { $0.urls.append(url.absoluteString) }
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
                    self?.append { $0.urls.append(string) }
                }
            }
            return
        }

        for type in [UTType.image, UTType.movie, UTType.fileURL, UTType.data] {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
                    defer { self?.group.leave() }
                    guard let url, let copied = self?.copyIntoGroup(url) else { return }
                    self?.append { $0.files.append(copied) }
                }
                return
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                defer { self?.group.leave() }
                if let text = item as? String {
                    self?.append { $0.texts.append(text) }
                }
            }
            return
        }
    }

    private func append(_ body: (ShareViewController) -> Void) {
        lock.lock()
        body(self)
        lock.unlock()
    }

    // MARK: - Handing off

    private func copyIntoGroup(_ source: URL) -> String? {
        guard let container = groupContainerURL() else { return nil }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        let name = "\(UUID().uuidString).\(source.pathExtension)"
        let destination = incoming.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        return name
    }

    private func handOff() {
        writeManifest()
        postDarwinNotification()
        openContainingApp()
        finish()
    }

    private func writeManifest() {
        guard let container = groupContainerURL() else { return }
        let manifest: [String: Any] = ["files": files, "texts": texts, "urls": urls]
        let destination = container.appendingPathComponent(Self.manifestName)
        if let data = try? JSONSerialization.data(withJSONObject: manifest) {
            try? data.write(to: destination, options: .atomic)
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
