import AppKit
import ArrowCore
import ArrowKit
import Observation

/// Application-wide model: the persisted sidebar state, settings, history,
/// boosts, notes and the live tabs (Chromium browsers).
@MainActor
@Observable
final class BrowserStore {
    private(set) var state: BrowserState
    var settings: ArrowSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave(.settings)
            if settings.adBlockerEnabled != oldValue.adBlockerEnabled || settings.adBlockerAllowedSites != oldValue.adBlockerAllowedSites {
                adBlocker.apply()
            }
            if settings.syncEnabled != oldValue.syncEnabled || settings.cloudServerURL != oldValue.cloudServerURL {
                settings.syncEnabled ? cloud.startSync() : cloud.stopSync()
            }
            if settings.littleArrowShortcut != oldValue.littleArrowShortcut, !isIncognito {
                GlobalShortcut.littleArrow.setEnabled(settings.littleArrowShortcut)
            }
            if settings.customShortcuts != oldValue.customShortcuts, !isIncognito {
                MainMenu.applyShortcuts(settings.customShortcuts)
            }
            if settings.contentAppearance != oldValue.contentAppearance {
                for tab in tabs.values { tab.applyContentAppearance() }
            }
        }
    }

    private(set) var history: History
    private(set) var boosts: [Boost]
    private(set) var notes: [Note]
    private(set) var easels: [Easel]
    let downloads: DownloadManager
    /// Built-in ad and tracker blocker (normal stores only).
    @ObservationIgnored private(set) lazy var adBlocker = AdBlocker(store: self)
    /// Arrow Cloud client (accounts, sync, AI, sharing).
    @ObservationIgnored private var cloudStorage: ArrowCloud?
    var cloud: ArrowCloud {
        if let cloudStorage { return cloudStorage }
        let cloud = ArrowCloud(store: self)
        cloudStorage = cloud
        return cloud
    }

    /// Live tabs by tab ID.
    @ObservationIgnored private(set) var tabs: [UUID: WebTab] = [:]
    @ObservationIgnored private var requestContexts: [UUID: any BrowsingContext] = [:]
    @ObservationIgnored private var pendingSaves: Set<StoreFile> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTimer: Timer?

    /// The rendering engine (Chromium).
    let engine: any EngineRuntime
    /// Directory of Arrow's own data (Chromium uses the parent directory).
    let dataDirectory: URL
    /// Incognito stores keep everything in memory and use an off-the-record
    /// Chromium context.
    let isIncognito: Bool

    private enum StoreFile: Hashable {
        case sidebar, settings, history, boosts, notes, easels
    }

    init(engine: any EngineRuntime, dataDirectory: URL? = nil) {
        self.engine = engine
        let dataDirectory = dataDirectory ?? engine.rootCachePath.appendingPathComponent("State", isDirectory: true)
        self.dataDirectory = dataDirectory
        isIncognito = false
        let loaded = JSONStore<BrowserState>(url: dataDirectory.appendingPathComponent("Sidebar.json")).load()
        if let loaded, !loaded.spaces.isEmpty, !loaded.profiles.isEmpty {
            state = loaded
        } else {
            state = .initial()
        }
        settings = JSONStore<ArrowSettings>(url: dataDirectory.appendingPathComponent("Settings.json")).load() ?? ArrowSettings()
        history = JSONStore<History>(url: dataDirectory.appendingPathComponent("History.json")).load() ?? History()
        boosts = JSONStore<[Boost]>(url: dataDirectory.appendingPathComponent("Boosts.json")).load() ?? []
        notes = JSONStore<[Note]>(url: dataDirectory.appendingPathComponent("Notes.json")).load() ?? []
        easels = JSONStore<[Easel]>(url: dataDirectory.appendingPathComponent("Easels.json")).load() ?? []
        downloads = DownloadManager(center: engine.downloads)
        downloads.store = self
        downloads.activate()
        startMaintenance()
    }

    /// Ephemeral store of an incognito window.
    init(incognitoWith settings: ArrowSettings, downloads: DownloadManager, engine: any EngineRuntime) {
        self.engine = engine
        dataDirectory = FileManager.default.temporaryDirectory
        isIncognito = true
        let profile = Profile(name: "Incognito", isDefault: true)
        let space = Space(title: "Incognito", icon: .symbol("theatermasks.fill"), theme: .incognito, profileID: profile.id)
        state = BrowserState(profiles: [profile], spaces: [space])
        self.settings = settings
        history = History()
        boosts = []
        notes = []
        easels = []
        self.downloads = downloads
    }

    // MARK: - Persistence

    private func scheduleSave(_ file: StoreFile) {
        guard !isIncognito else { return }
        pendingSaves.insert(file)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes pending changes immediately (also called before quitting).
    func saveNow() {
        let files = pendingSaves
        pendingSaves.removeAll()
        for file in files {
            do {
                switch file {
                case .sidebar:
                    try JSONStore<BrowserState>(url: dataDirectory.appendingPathComponent("Sidebar.json")).save(state, backup: true)
                case .settings:
                    try JSONStore<ArrowSettings>(url: dataDirectory.appendingPathComponent("Settings.json")).save(settings)
                case .history:
                    try JSONStore<History>(url: dataDirectory.appendingPathComponent("History.json")).save(history)
                case .boosts:
                    try JSONStore<[Boost]>(url: dataDirectory.appendingPathComponent("Boosts.json")).save(boosts)
                case .notes:
                    try JSONStore<[Note]>(url: dataDirectory.appendingPathComponent("Notes.json")).save(notes)
                case .easels:
                    try JSONStore<[Easel]>(url: dataDirectory.appendingPathComponent("Easels.json")).save(easels)
                }
            } catch {
                NSLog("Arrow: failed to save \(file): \(error)")
            }
        }
    }

    /// Mutates the sidebar state and persists it.
    func update(_ transform: (inout BrowserState) -> Void) {
        transform(&state)
        scheduleSave(.sidebar)
        if !isIncognito, settings.syncEnabled { cloud.scheduleSync() }
    }

    /// Merges spaces and favorites received from another device.
    func applyRemote(spaces remote: [UUID: Space], deleted: Set<UUID>, favorites: [String: [Tab]]?, order: [UUID]?,
                     profiles: [Profile]?) {
        let before = Set(state.spaces.flatMap(\.allTabs).map(\.id))
        if let profiles {
            for profile in profiles where state.profile(profile.id) == nil {
                state.profiles.append(Profile(id: profile.id, name: profile.name, isDefault: false))
            }
        }
        state.spaces.removeAll { deleted.contains($0.id) }
        for (id, space) in remote {
            if let index = state.spaceIndex(id) {
                state.spaces[index] = space
            } else {
                state.spaces.append(space)
            }
        }
        if let favorites { state.favorites = favorites }
        if let order {
            state.spaces.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        if state.spaces.isEmpty { state = .initial() }
        let after = Set(state.spaces.flatMap(\.allTabs).map(\.id) + state.favorites.values.flatMap { $0.map(\.id) })
        for id in before.subtracting(after) { discardRuntime(id) }
        scheduleSave(.sidebar)
    }

    // MARK: - Profiles

    /// Chromium request context of a profile (cookies, storage…).
    func requestContext(for profileID: UUID) -> any BrowsingContext {
        if let context = requestContexts[profileID] { return context }
        let context = if isIncognito {
            engine.incognitoContext()
        } else if state.profile(profileID)?.isDefault ?? true {
            engine.defaultContext()
        } else {
            engine.persistentContext(path: engine.rootCachePath
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profileID.uuidString, isDirectory: true))
        }
        requestContexts[profileID] = context
        return context
    }

    // MARK: - Clear Browsing Data

    /// Preferences ▸ Profiles ▸ Clear Browsing Data. Chromium removes cookies
    /// and cached files of every profile for all time.
    func clearBrowsingData(since date: Date?, history: Bool, cookies: Bool, cache: Bool) {
        if history { clearHistory(since: date) }
        let contexts = state.profiles.map { requestContext(for: $0.id) }
        for context in contexts {
            if cookies { context.deleteCookies(url: nil) }
            if cache { context.clearHTTPCache() }
        }
    }

    // MARK: - Restore Data

    private var sidebarStore: JSONStore<BrowserState> {
        JSONStore(url: dataDirectory.appendingPathComponent("Sidebar.json"))
    }

    /// Dated copies of the sidebar, newest first (Help ▸ Restore Data).
    func sidebarBackups() -> [URL] {
        sidebarStore.backups().reversed()
    }

    /// Replaces the sidebar with a backup; the current one becomes a backup too.
    func restoreSidebar(from backup: URL) -> Bool {
        guard let restored = sidebarStore.value(inBackup: backup) else { return false }
        try? sidebarStore.save(state, backup: true)
        update { $0 = restored }
        return true
    }

    // MARK: - Live tabs

    /// Live runtime of tab `id`, created on demand from the model.
    func webTab(_ id: UUID) -> WebTab? {
        if let tab = tabs[id] { return tab }
        guard let model = state.tab(id) else { return nil }
        let profileID = state.spaceID(containing: id).flatMap { state.space($0)?.profileID } ?? state.defaultProfile.id
        let tab = WebTab(model: model, profileID: profileID, store: self, isIncognito: isIncognito)
        tabs[id] = tab
        return tab
    }

    /// Registers a tab created by a popup (its engine already exists).
    func register(_ tab: WebTab) {
        tabs[tab.id] = tab
    }

    func discardRuntime(_ id: UUID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        tab.closeEngine()
    }

    /// Updates the persisted model of a tab from its runtime state.
    func syncTabModel(_ tab: WebTab) {
        guard state.tab(tab.id) != nil else { return }
        update { state in
            state.updateTab(tab.id) { model in
                if !tab.url.isEmpty { model.url = tab.url }
                if !tab.title.isEmpty { model.title = tab.title }
                model.faviconURL = tab.faviconURL ?? model.faviconURL
                model.isMuted = tab.isMuted
            }
        }
    }

    func markActive(_ id: UUID) {
        update { $0.updateTab(id) { $0.lastActiveAt = Date() } }
    }

    /// Opens a new today tab in `spaceID` and returns its runtime.
    @discardableResult
    func openTab(url: String, in spaceID: UUID, select: Bool = true) -> WebTab? {
        var created: Tab?
        update { created = $0.openTab(url: url, in: spaceID) }
        guard let created else { return nil }
        return webTab(created.id)
    }

    /// Closes (archives) a today tab or resets a pinned tab/favorite.
    func close(_ id: UUID) {
        guard let location = state.location(of: id) else {
            discardRuntime(id)
            return
        }
        switch location.section {
        case .today:
            let closed = state.space(location.spaceID!)?.today.first(where: { $0.id == id })?.tabs.map(\.id) ?? [id]
            update { $0.close(id) }
            for tabID in closed { discardRuntime(tabID) }
        case .pinned, .favorites:
            // Closing a pinned tab unloads it and returns to its pinned address.
            if let tab = state.tab(id), let pinnedURL = tab.pinnedURL {
                update { $0.updateTab(id) { $0.url = pinnedURL } }
            }
            discardRuntime(id)
        }
    }

    /// Permanently removes a node (pinned tab, folder, favorite).
    func delete(_ id: UUID) {
        let tabIDs = state.tab(id).map { [$0.id] } ?? []
        update { $0.delete(id) }
        for tabID in tabIDs { discardRuntime(tabID) }
    }

    // MARK: - History, boosts, notes

    func recordVisit(url: String, title: String, incognito: Bool) {
        guard !incognito else { return }
        history.recordVisit(url: url, title: title)
        scheduleSave(.history)
    }

    func updateHistoryTitle(url: String, title: String, incognito: Bool) {
        guard !incognito else { return }
        history.updateTitle(url: url, title: title)
        scheduleSave(.history)
    }

    func clearHistoryEntry(_ url: String) {
        history.remove(url: url)
        scheduleSave(.history)
    }

    func clearHistory(since date: Date? = nil) {
        history.clear(since: date)
        scheduleSave(.history)
    }

    func boosts(for url: String) -> [Boost] {
        boosts.filter { $0.applies(to: url) }
    }

    func saveBoost(_ boost: Boost) {
        if let index = boosts.firstIndex(where: { $0.id == boost.id }) {
            boosts[index] = boost
        } else {
            boosts.append(boost)
        }
        scheduleSave(.boosts)
        for tab in tabs.values where boost.applies(to: tab.url) {
            tab.applyBoosts()
        }
    }

    /// Adds a zapped selector to the site's boost (created if needed).
    func zap(_ selector: String, on url: String) {
        guard let host = URLDisplay.host(of: url) else { return }
        var boost = boosts.first { $0.applies(to: url) } ?? Boost(name: "\(host) Boost", domain: host)
        guard !boost.zappedSelectors.contains(selector) else { return }
        boost.zappedSelectors.append(selector)
        if let index = boosts.firstIndex(where: { $0.id == boost.id }) {
            boosts[index] = boost
        } else {
            boosts.append(boost)
        }
        scheduleSave(.boosts)
    }

    func deleteBoost(_ id: UUID) {
        boosts.removeAll { $0.id == id }
        scheduleSave(.boosts)
    }

    /// Sidebar title of a tab that may not be loaded (notes and easels use
    /// their own names).
    func title(of tab: Tab) -> String {
        switch InternalPage(url: tab.url) {
        case let .note(id): note(id)?.title ?? "Untitled"
        case let .easel(id): easel(id)?.title ?? "Untitled Easel"
        case .shortcuts: "Keyboard Shortcuts"
        default: tab.displayTitle
        }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func saveNote(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
        scheduleSave(.notes)
    }

    func deleteNote(_ id: UUID) {
        notes.removeAll { $0.id == id }
        scheduleSave(.notes)
    }

    func easel(_ id: UUID) -> Easel? { easels.first { $0.id == id } }

    func saveEasel(_ easel: Easel) {
        if let index = easels.firstIndex(where: { $0.id == easel.id }) {
            easels[index] = easel
        } else {
            easels.append(easel)
        }
        scheduleSave(.easels)
    }

    func deleteEasel(_ id: UUID) {
        easels.removeAll { $0.id == id }
        scheduleSave(.easels)
    }

    // MARK: - Maintenance

    /// Auto-archive and background tab discarding, checked every minute.
    private func startMaintenance() {
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.performMaintenance() }
        }
        performMaintenance()
    }

    /// IDs of the tabs currently displayed in a window.
    var visibleTabIDs: () -> Set<UUID> = { [] }

    func performMaintenance(now: Date = Date()) {
        let visible = visibleTabIDs()
        var archived: [Tab] = []
        update { archived = $0.archiveStaleTabs(olderThan: settings.archiveInterval.seconds, now: now, excluding: visible) }
        for tab in archived { discardRuntime(tab.id) }

        // Free memory of background tabs unused for an hour.
        for (id, tab) in tabs where !visible.contains(id) && tab.isEngineLoaded && !tab.isPlayingMedia {
            if now.timeIntervalSince(tab.lastVisibleAt) > 3600 {
                tab.closeEngine()
            }
        }
    }

    /// Closes every browser; `completion` runs once all are destroyed.
    func closeAllBrowsers(completion: @escaping @MainActor () -> Void) {
        saveNow()
        let live = tabs.values.filter(\.isEngineLoaded)
        guard !live.isEmpty else {
            completion()
            return
        }
        var remaining = live.count
        for tab in live {
            tab.closeEngine {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }
}
