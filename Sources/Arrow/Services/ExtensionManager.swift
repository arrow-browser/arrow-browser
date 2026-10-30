import AppKit
import ArrowCore
import ArrowKit
import Foundation
import Observation

/// Chrome extensions installed from the Chrome Web Store.
///
/// Embedded (Alloy style) browsers cannot show Chrome's extension UI, but the
/// Chrome runtime runs extensions for every browser of the profile. Arrow
/// downloads and verifies the CRX package, unpacks it, and loads the enabled
/// extensions when Chromium starts (`--load-extension`).
@MainActor
@Observable
final class ExtensionManager {
    struct Extension: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var version: String
        var isEnabled: Bool
        /// Relative path of the action popup (`action.default_popup`).
        var popup: String?
        var options: String?
        var icon: String?
        var directory: String
    }

    enum Failure: LocalizedError {
        case invalidReference
        case download(Int)

        var errorDescription: String? {
            switch self {
            case .invalidReference: "Paste a Chrome Web Store link or a 32-letter extension ID."
            case let .download(status): "The Chrome Web Store returned an error (\(status))."
            }
        }
    }

    static let shared = ExtensionManager()

    private(set) var extensions: [Extension]
    /// Changes apply after relaunching Chromium.
    private(set) var needsRelaunch = false
    private(set) var installing: Set<String> = []

    private let directory: URL

    private init() {
        directory = Self.extensionsDirectory
        extensions = Self.loadList()
    }

    nonisolated private static var extensionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arrow/Extensions", isDirectory: true)
    }

    nonisolated private static var listURL: URL {
        extensionsDirectory.appendingPathComponent("Extensions.json")
    }

    nonisolated private static func loadList() -> [Extension] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? JSONDecoder().decode([Extension].self, from: data)) ?? []
    }

    /// Value of Chromium's `--load-extension` switch (read before startup).
    nonisolated static func loadExtensionArgument() -> String? {
        let paths = loadList()
            .filter(\.isEnabled)
            .map { extensionsDirectory.appendingPathComponent($0.directory).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        return paths.isEmpty ? nil : paths.joined(separator: ",")
    }

    private func saveList() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(extensions) {
            try? data.write(to: Self.listURL, options: .atomic)
        }
        needsRelaunch = true
    }

    // MARK: - Install

    /// Extension ID from a Web Store URL (…/detail/<slug>/<id>) or a bare ID.
    nonisolated static func extensionID(from reference: String) -> String? {
        let candidates = reference.split(whereSeparator: { "/?#&= ".contains($0) }).map(String.init)
        return candidates.last { candidate in
            candidate.count == 32 && candidate.allSatisfy { ("a"..."p").contains($0) }
        }
    }

    /// Installs an extension for `store`'s engine and platform.
    @discardableResult
    func install(_ reference: String, using store: BrowserStore) async throws -> Extension {
        guard let id = Self.extensionID(from: reference) else { throw Failure.invalidReference }
        installing.insert(id)
        defer { installing.remove(id) }

        let version = store.engine.chromiumVersion
        let query = "response=redirect&prodversion=\(version)&acceptformat=crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc"
        let url = URL(string: "https://clients2.google.com/service/update2/crx?\(query)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.download(status) }

        let package = try CRXPackage(data: data, expectedID: id)
        let manifest = try await Self.unpack(package, into: directory, platform: store.platform)
        let installed = Extension(id: id, name: manifest.name, version: manifest.version, isEnabled: true,
                                  popup: manifest.popup, options: manifest.options, icon: manifest.icon, directory: id)
        extensions.removeAll { $0.id == id }
        extensions.append(installed)
        saveList()
        return installed
    }

    private struct ManifestSummary {
        var name: String
        var version: String
        var popup: String?
        var options: String?
        var icon: String?
    }

    /// Unzips the archive and pins the extension ID with the publisher key.
    private nonisolated static func unpack(_ package: CRXPackage, into root: URL,
                                           platform: any Platform) async throws -> ManifestSummary {
        let fileManager = FileManager.default
        let destination = root.appendingPathComponent(package.id, isDirectory: true)
        let staging = root.appendingPathComponent(".\(package.id)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let zip = staging.appendingPathComponent("extension.zip")
        try package.archive.write(to: zip)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)

        try platform.unzip(zip, into: unpacked)

        let manifestURL = unpacked.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw CRXPackage.Failure.malformed
        }
        // Keeps the Web Store ID for the unpacked copy.
        manifest["key"] = package.publicKey.base64EncodedString()
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manifestURL)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: unpacked, to: destination)
        try? fileManager.removeItem(at: staging)

        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let icons = manifest["icons"] as? [String: String] ?? [:]
        let largestIcon = icons.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }?.value
        let optionsUI = manifest["options_ui"] as? [String: Any]
        let options: String? = optionsUI?["page"] as? String ?? manifest["options_page"] as? String
        let rawName: String = manifest["name"] as? String ?? package.id
        return ManifestSummary(name: localized(rawName, manifest: manifest, root: destination),
                               version: manifest["version"] as? String ?? "",
                               popup: action?["default_popup"] as? String,
                               options: options,
                               icon: largestIcon)
    }

    /// Resolves `__MSG_name__` placeholders with the default locale.
    private nonisolated static func localized(_ value: String, manifest: [String: Any], root: URL) -> String {
        guard value.hasPrefix("__MSG_"), value.hasSuffix("__") else { return value }
        let key = String(value.dropFirst(6).dropLast(2)).lowercased()
        let locale = manifest["default_locale"] as? String ?? "en"
        let messagesURL = root.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? Data(contentsOf: messagesURL),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return value }
        return messages.first { $0.key.lowercased() == key }?.value["message"] as? String ?? value
    }

    // MARK: - Management

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = extensions.firstIndex(where: { $0.id == id }) else { return }
        extensions[index].isEnabled = enabled
        saveList()
    }

    func remove(_ id: String) {
        guard let installed = extensions.first(where: { $0.id == id }) else { return }
        extensions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(installed.directory))
        saveList()
    }

    func iconImage(for installed: Extension) -> NSImage? {
        guard let icon = installed.icon else { return nil }
        return NSImage(contentsOf: directory.appendingPathComponent(installed.directory).appendingPathComponent(icon))
    }

    func popupURL(for installed: Extension) -> String? {
        installed.popup.map { "chrome-extension://\(installed.id)/\($0)" }
    }

    func optionsURL(for installed: Extension) -> String? {
        installed.options.map { "chrome-extension://\(installed.id)/\($0)" }
    }

    /// Restarts Arrow so Chromium loads the new extension set.
    func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundle)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}
