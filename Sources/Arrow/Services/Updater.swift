import AppKit
import ArrowKit
import CEF
import Observation

/// Versions of the embedded Chromium.
enum CEFVersion {
    static var chromium: String {
        "\(cef_version_info(4)).\(cef_version_info(5)).\(cef_version_info(6)).\(cef_version_info(7))"
    }

    static var cef: String {
        "\(cef_version_info(0)).\(cef_version_info(1)).\(cef_version_info(2))"
    }
}

/// Automatic updates from Arrow Cloud's Sparkle appcast.
///
/// Archives are only installed when their Ed25519 signature matches the
/// public key in Info.plist (`SUPublicEDKey`, as with Sparkle). Without a key
/// Arrow only offers to download the new version.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        /// Verified update unpacked and waiting for a relaunch.
        case ready(version: String)
        case failed(String)
    }

    static let shared = Updater()

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored weak var store: BrowserStore?

    private var currentShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Ed25519 public key used to trust update archives.
    private var publicKey: String? {
        #if DEBUG
        // Lets tests sign their own archives without re-signing the app.
        if let override = UserDefaults.standard.string(forKey: "ArrowUpdatePublicKeyOverride") { return override }
        #endif
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        return key?.isEmpty == false ? key : nil
    }

    /// Checks at launch and then every day.
    func start(store: BrowserStore) {
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Task { await Updater.shared.check(interactive: false) } }
        }
        Task { await check(interactive: false) }
    }

    func check(interactive: Bool) async {
        guard let store, !store.settings.cloudServerURL.isEmpty,
              let feed = URL(string: store.settings.cloudServerURL)?.appendingPathComponent("v1/updates/appcast.xml") else {
            if interactive { alert("Updates are not configured", "Set an Arrow Cloud server in Settings ▸ Arrow Cloud.") }
            return
        }
        if case .ready = phase { return }
        phase = .checking
        guard let (data, _) = try? await URLSession.shared.data(from: feed) else {
            phase = .idle
            if interactive { alert("Couldn’t check for updates", "The update server could not be reached.") }
            return
        }
        guard let item = Appcast.latest(in: Appcast.parse(data), currentShortVersion: currentShortVersion,
                                        currentVersion: currentVersion) else {
            phase = .idle
            if interactive { alert("Arrow is up to date", "You’re running version \(currentShortVersion).") }
            return
        }
        guard store.settings.automaticallyInstallUpdates || interactive, let publicKey else {
            phase = .idle
            offerDownload(item)
            return
        }
        await download(item, publicKey: publicKey, interactive: interactive)
    }

    private func download(_ item: AppcastItem, publicKey: String, interactive: Bool) async {
        guard let url = URL(string: item.url) else { return }
        phase = .downloading
        do {
            let (file, _) = try await URLSession.shared.download(from: url)
            let archive = try Data(contentsOf: file)
            guard Appcast.verify(archive: archive, item: item, publicKey: publicKey) else {
                phase = .failed("The update’s signature is invalid.")
                if interactive { alert("Update rejected", "The downloaded update is not signed with Arrow’s key.") }
                return
            }
            stagedApp = try await stage(archive, version: item.shortVersion)
            phase = .ready(version: item.shortVersion)
            if interactive { promptRelaunch(version: item.shortVersion) }
        } catch {
            phase = .failed(error.localizedDescription)
            if interactive { alert("Update failed", error.localizedDescription) }
        }
    }

    /// Unzips the archive and checks it contains Arrow.
    private func stage(_ archive: Data, version: String) async throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arrow/Updates/\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("update.zip")
        try archive.write(to: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, root.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: zip)
        let apps = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard unzip.terminationStatus == 0, let app = apps.first,
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw CocoaError(.fileReadCorruptFile)
        }
        releaseFromQuarantine(app)
        return app
    }

    /// Arrow quarantines the files it writes (`LSFileQuarantineEnabled`), so
    /// Gatekeeper would translocate or block the relaunch. The archive's
    /// signature is verified at this point, so release it like Sparkle does.
    private func releaseFromQuarantine(_ app: URL) {
        let contents = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for url in [app] + contents {
            removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// Replaces the running app with the staged update and relaunches.
    func installAndRelaunch() {
        guard let stagedApp else { return }
        let current = Bundle.main.bundleURL.path
        let backup = current + ".previous"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup)"
        if mv "\(current)" "\(backup)" && mv "\(stagedApp.path)" "\(current)"; then
          rm -rf "\(backup)" "\(stagedApp.deletingLastPathComponent().path)"
        else
          [ -d "\(backup)" ] && [ ! -d "\(current)" ] && mv "\(backup)" "\(current)"
        fi
        /usr/bin/open "\(current)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func promptRelaunch(version: String) {
        let prompt = NSAlert()
        prompt.messageText = "Arrow \(version) is ready to install"
        prompt.informativeText = "Arrow will relaunch to finish updating."
        prompt.addButton(withTitle: "Relaunch Now")
        prompt.addButton(withTitle: "Later")
        if prompt.runModal() == .alertFirstButtonReturn { installAndRelaunch() }
    }

    private func offerDownload(_ item: AppcastItem) {
        let prompt = NSAlert()
        prompt.messageText = "Arrow \(item.shortVersion) is available"
        prompt.informativeText = "You’re running version \(currentShortVersion)."
        prompt.addButton(withTitle: "Download")
        prompt.addButton(withTitle: "Later")
        if prompt.runModal() == .alertFirstButtonReturn, let url = URL(string: item.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
