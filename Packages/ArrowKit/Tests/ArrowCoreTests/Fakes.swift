import ArrowKit
import Foundation
import Testing
@testable import ArrowCore

// In-memory engine and platform, so the shared core runs without Chromium or
// an operating system UI.

@MainActor
final class FakeBrowser: BrowserEngine {
    weak var delegate: (any BrowserEngineDelegate)?
    let context: any BrowsingContext
    var identifier: Int32?
    var isClosing = false
    var isClosed = false
    var canGoBack = false
    var currentURL: String?
    var zoomLevel = 0.0
    var isAudioMuted = false

    private(set) var loadedURLs: [String] = []
    private(set) var scripts: [String] = []
    private(set) var downloads: [String] = []

    init(context: any BrowsingContext) {
        self.context = context
    }

    func create(url: String) {
        loadedURLs.append(url)
        currentURL = url
        delegate?.browserDidCreate(self)
    }

    func close(force: Bool) {
        isClosing = true
        isClosed = true
        delegate?.browserDidClose(self)
    }

    func load(url: String) {
        loadedURLs.append(url)
        currentURL = url
    }

    func goBack() {}
    func goForward() {}
    func reload() {}
    func reloadIgnoringCache() {}
    func stopLoading() {}
    func executeJavaScript(_ code: String, scriptURL: String) { scripts.append(code) }
    func evaluateJavaScript(_ expression: String) async -> Any? { nil }
    func devToolsMethod(_ method: String, params: [String: Any]) async -> [String: Any]? { nil }
    func find(_ text: String, forward: Bool, findNext: Bool) {}
    func stopFinding() {}
    func setFocus(_ focused: Bool) {}
    func print() {}
    func startDownload(url: String) { downloads.append(url) }
    func showDevTools(inspectAt point: CGPoint?, panel: String?) {}
    func exitFullscreen() {}
    func notifyMoveOrResizeStarted() {}
    func enableAutoResize(min: CGSize, max: CGSize) {}
    func captureScreenshot(clip: CGRect?) async -> Data? { nil }
    func downloadImage(url: String, isFavicon: Bool, maxSize: Int) async -> Data? { nil }
}

@MainActor
final class FakeContext: BrowsingContext {
    let isIncognito: Bool
    /// Where a persistent profile is stored.
    let path: URL?
    private(set) var browsers: [FakeBrowser] = []
    private(set) var deletedCookies: [String?] = []
    private(set) var cacheClears = 0

    init(isIncognito: Bool = false, path: URL? = nil) {
        self.isIncognito = isIncognito
        self.path = path
    }

    func makeBrowser() -> any BrowserEngine {
        let browser = FakeBrowser(context: self)
        browsers.append(browser)
        return browser
    }

    func makeMediaRouter() -> (any MediaRouter)? { nil }
    func clearHTTPCache() { cacheClears += 1 }
    func deleteCookies(url: String?) { deletedCookies.append(url) }
}

@MainActor
final class FakeDownloadCenter: DownloadCenter {
    weak var delegate: (any DownloadCenterDelegate)?
    private(set) var canceled: [UInt32] = []

    func cancel(_ id: UInt32) { canceled.append(id) }
    func pause(_ id: UInt32) {}
    func resume(_ id: UInt32) {}
}

final class FakeResourceFilter: ResourceFilter, @unchecked Sendable {
    private let lock = NSLock()
    private var decision: Decision?

    func setDecision(_ decide: Decision?) {
        lock.withLock { decision = decide }
    }

    var blocked: Int { 0 }

    func blocks(_ url: String, initiator: String?) -> Bool {
        lock.withLock { decision }?(url, initiator, false) ?? false
    }
}

@MainActor
final class FakeRuntime: EngineRuntime {
    let chromiumVersion = "156.0.0.0"
    let rootCachePath: URL
    let downloads: any DownloadCenter = FakeDownloadCenter()
    let resourceFilter: any ResourceFilter = FakeResourceFilter()
    let defaultProfile = FakeContext()
    private(set) var persistentProfiles: [FakeContext] = []

    init(rootCachePath: URL) {
        self.rootCachePath = rootCachePath
    }

    func defaultContext() -> any BrowsingContext { defaultProfile }

    func persistentContext(path: URL) -> any BrowsingContext {
        let context = FakeContext(path: path)
        persistentProfiles.append(context)
        return context
    }

    func incognitoContext() -> any BrowsingContext { FakeContext(isIncognito: true) }
}

@MainActor
final class FakeCredentials: CredentialStore {
    var passwords: [SavedLogin: String] = [:]
    var savedCards: [PaymentCard] = []

    func logins(for host: String?) -> [SavedLogin] {
        passwords.keys.filter { host == nil || $0.host == host }.sorted { $0.id < $1.id }
    }

    func password(host: String, username: String) -> String? {
        passwords.first { $0.key.host == host && $0.key.username == username }?.value
    }

    func savePassword(_ password: String, host: String, username: String) {
        passwords[SavedLogin(host: host, username: username, modified: nil)] = password
    }

    func deletePassword(host: String, username: String) {
        passwords = passwords.filter { !($0.key.host == host && $0.key.username == username) }
    }

    func cards() -> [PaymentCard] { savedCards }
    func save(_ card: PaymentCard) { savedCards.append(card) }
    func delete(_ card: PaymentCard) { savedCards.removeAll { $0.id == card.id } }
}

@MainActor
final class FakeSecrets: SecretStore {
    var secrets: [String: String] = [:]

    func secret(for account: String) -> String? { secrets[account] }
    func setSecret(_ value: String?, for account: String) { secrets[account] = value }
}

@MainActor
final class FakePlatform: Platform {
    let fakeCredentials = FakeCredentials()
    var credentials: any CredentialStore { fakeCredentials }
    let cloudSecrets: any SecretStore = FakeSecrets()
    let appVersion = "1.0.0"
    var isDarkAppearance = false
    var heldModifiers: KeyModifiers = []

    private(set) var clipboard: [String] = []
    private(set) var sounds: [SoundEffect] = []
    private(set) var revealed: [URL] = []
    private(set) var opened: [URL] = []
    private(set) var changedFiles: [URL] = []
    private(set) var appliedSettings: [ArrowSettings] = []

    func copyToClipboard(_ text: String) { clipboard.append(text) }
    func play(_ sound: SoundEffect) { sounds.append(sound) }
    func reveal(_ file: URL) { revealed.append(file) }
    func open(_ file: URL) { opened.append(file) }
    func fileDidChange(_ file: URL) { changedFiles.append(file) }

    nonisolated func unzip(_ archive: URL, into directory: URL) throws {
        throw CRXPackage.Failure.malformed
    }

    func apply(_ settings: ArrowSettings, previous: ArrowSettings) { appliedSettings.append(settings) }
}

/// Records what a tab asks of its window.
@MainActor
final class FakeTabHost: TabHost {
    private(set) var opened: [(url: String, inBackground: Bool)] = []
    private(set) var littleArrow: [String] = []
    private(set) var peeked: [String] = []
    private(set) var closeRequests = 0

    func tab(_ tab: WebTab, openURL url: String, inBackground: Bool) { opened.append((url, inBackground)) }
    func tab(_ tab: WebTab, createPopupFor url: String, features: PopupFeatures) -> (any BrowserEngine)? { nil }
    func tab(_ tab: WebTab, shouldDivertNavigationTo url: String) -> Bool { false }
    func tab(_ tab: WebTab, openInSplitView url: String) {}
    func tab(_ tab: WebTab, openInLittleArrow url: String) { littleArrow.append(url) }
    func tab(_ tab: WebTab, openInPeek url: String) { peeked.append(url) }
    func tabDidRequestClose(_ tab: WebTab) { closeRequests += 1 }
    func tabDidGainFocus(_ tab: WebTab) {}
    func tab(_ tab: WebTab, didChangeFullscreen fullscreen: Bool) {}
    func tabRequestsBoostEditor(_ tab: WebTab) {}
    func tabRequestsCapture(_ tab: WebTab) {}
    func isDisplaying(_ tab: WebTab) -> Bool { false }
}

/// A store in a temporary directory, with the fake engine and platform.
@MainActor
struct TestBrowser {
    let directory: URL
    let runtime: FakeRuntime
    let platform = FakePlatform()
    let store: BrowserStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrowCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runtime = FakeRuntime(rootCachePath: directory)
        store = BrowserStore(engine: runtime, platform: platform)
        // Settings that would reach the network.
        store.settings.syncEnabled = false
    }

    var spaceID: UUID { store.state.spaces[0].id }

    /// A Today tab with its browser created.
    func openTab(_ url: String) throws -> (WebTab, FakeBrowser) {
        let tab = try #require(store.openTab(url: url, in: spaceID))
        let engine = try #require(tab.ensureEngine(context: store.requestContext(for: tab.profileID)) as? FakeBrowser)
        return (tab, engine)
    }
}
