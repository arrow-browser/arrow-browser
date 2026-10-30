import Foundation

/// Routes links opened from other apps to a space (Air Traffic Control).
public struct AirTrafficRule: Codable, Identifiable, Hashable, Sendable {
    public enum Condition: String, Codable, CaseIterable, Sendable {
        case hostIs
        case urlContains
        case urlStartsWith
    }

    public var id: UUID
    public var condition: Condition
    public var value: String
    public var spaceID: UUID

    public init(id: UUID = UUID(), condition: Condition, value: String, spaceID: UUID) {
        self.id = id
        self.condition = condition
        self.value = value
        self.spaceID = spaceID
    }

    public func matches(_ url: String) -> Bool {
        let pattern = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return false }
        let lowered = url.lowercased()
        switch condition {
        case .hostIs:
            guard let host = URLDisplay.host(of: url)?.lowercased() else { return false }
            let target = pattern.hasPrefix("www.") ? String(pattern.dropFirst(4)) : pattern
            return host == target || host.hasSuffix("." + target)
        case .urlContains:
            return lowered.contains(pattern)
        case .urlStartsWith:
            return URLDisplay.full(lowered).hasPrefix(URLDisplay.full(pattern))
        }
    }
}

/// Where links opened from other applications go.
/// Preferences ▸ Profiles ▸ New documents: the app "New Document" opens.
public enum DocumentApp: String, Codable, CaseIterable, Sendable {
    case none, googleDocs, notion, microsoftWord

    public var title: String {
        switch self {
        case .none: "——"
        case .googleDocs: "Google Docs"
        case .notion: "Notion"
        case .microsoftWord: "Microsoft Word"
        }
    }

    public var newDocumentURL: String? {
        switch self {
        case .none: nil
        case .googleDocs: "https://docs.new"
        case .notion: "https://notion.new"
        case .microsoftWord: "https://word.new"
        }
    }
}

/// Preferences ▸ Profiles ▸ Download location.
public enum DownloadLocation: String, Codable, CaseIterable, Sendable {
    /// Ask where to save each file.
    case ask
    case downloads
    /// `ArrowSettings.downloadFolder`.
    case folder
}

/// Preferences ▸ Links ▸ Archive Little Arcs after.
public enum LittleArrowArchive: String, Codable, CaseIterable, Sendable {
    case oneHour, sixHours, twelveHours, oneDay, never

    public var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .sixHours: "6 hours (default)"
        case .twelveHours: "12 hours"
        case .oneDay: "24 hours"
        case .never: "Never"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .oneDay: 24 * 3600
        case .never: nil
        }
    }
}

/// View ▸ Appearance: the color scheme of websites, easels and notes.
public enum ContentAppearance: String, Codable, CaseIterable, Sendable {
    case automatic, light, dark
}

public enum ExternalLinkDestination: String, Codable, CaseIterable, Sendable {
    /// Little Arrow mini window (Arc default).
    case littleArrow
    /// A new tab of the frontmost window.
    case activeSpace
}

/// User preferences (Settings window).
public struct ArrowSettings: Codable, Hashable, Sendable {
    public var searchEngine: SearchEngine = .google
    public var archiveInterval: ArchiveInterval = .twelveHours
    public var externalLinks: ExternalLinkDestination = .littleArrow
    public var airTrafficRules: [AirTrafficRule] = []
    /// Links from pinned tabs/favorites to other sites open in Peek.
    public var peekEnabled = true
    /// Picture in Picture when leaving a tab that plays a video.
    public var automaticPictureInPicture = true
    /// Show the full address and developer affordances.
    public var developerMode = false
    public var sidebarOnRight = false
    /// Show the address field at the top of the sidebar.
    public var showURLBar = true
    /// Arc's toolbar mode: navigation and address above the content.
    public var showToolbar = false
    public var showTabPreviewsOnHover = true
    public var adBlockerEnabled = true
    /// Sites (registrable domains) where the ad blocker is turned off.
    public var adBlockerAllowedSites: [String] = []
    public var soundEffects = true
    /// Download and install signed updates from Arrow Cloud.
    public var automaticallyInstallUpdates = true
    public var contentAppearance = ContentAppearance.automatic
    /// View ▸ Developer ▸ Allow JavaScript from Apple Events (off, as in Arc).
    public var allowJavaScriptFromAppleEvents = false
    /// Hold ⌘Q to quit.
    public var warnBeforeQuitting: Bool = false
    /// Search engine suggestions in the command bar.
    public var searchSuggestions: Bool = true
    public var documentApp: DocumentApp = .none
    public var downloadLocation: DownloadLocation = .downloads
    /// Folder used when `downloadLocation` is `.folder`.
    public var downloadFolder: String = ""
    /// ⌥⌘N opens Little Arrow from any app.
    public var littleArrowShortcut: Bool = true
    /// ⌥⌘-clicking a link opens it in Little Arrow.
    public var littleArrowOnOptionCommandClick: Bool = true
    public var littleArrowArchive: LittleArrowArchive = .sixHours
    /// Shift-clicking a link opens it in Peek.
    public var peekOnShiftClick: Bool = true
    public var autoEnableNewMaxFeatures: Bool = false
    /// Max: the sidebar sorts Today tabs by topic.
    public var tidyTabs: Bool = false
    /// Max: Shift-Return opens the top result of a search.
    public var instantLinks: Bool = false
    /// Max: "ChatGPT" then Tab asks ChatGPT.
    public var chatGPTInCommandBar: Bool = false
    /// Haptic feedback when reordering tabs.
    public var hapticFeedback: Bool = true
    /// Restore the windows of the previous session at launch.
    public var restoreWindows: Bool = true
    /// Drag the window from the top edge of web pages.
    public var dragWindowFromPageTop: Bool = false
    public var showFullURLInToolbar: Bool = false
    /// A button to copy a quote appears over highlighted text.
    public var sharedQuotes: Bool = true
    /// Websites can read the space theme (`--arc-palette-*` CSS variables).
    public var shareThemeWithWebsites: Bool = false
    public var boostsEnabled: Bool = true
    /// Preferences ▸ Shortcuts: menu command → key (see `MenuShortcut`).
    public var customShortcuts: [String: String] = [:]
    /// Offer to save passwords and fill them in.
    public var offerToSavePasswords: Bool = true
    /// Sites (registrable domains) where Arrow never offers to save a password.
    public var neverSavePasswordSites: [String] = []
    /// Offer to save payment cards and fill them in.
    public var autofillCards: Bool = true
    /// Languages and sites never offered for translation (Reset Translated-site Prompts).
    public var neverTranslateLanguages: [String] = []
    public var neverTranslateSites: [String] = []
    /// Sidebar width in points (Arc's default).
    public var sidebarWidth: Double = 228

    // Arrow Cloud (sync, sharing, AI) — see server/.
    public var cloudServerURL: String = ""
    public var syncEnabled = false

    // AI features ("Max").
    public var aiEnabled = false
    public var tidyTabTitles = false
    public var tidyDownloads = false
    public var linkPreviews = false

    public init() {}

    public func route(_ url: String) -> UUID? {
        airTrafficRules.first { $0.matches(url) }?.spaceID
    }

    enum CodingKeys: String, CodingKey {
        case searchEngine, archiveInterval, externalLinks, airTrafficRules, peekEnabled, automaticPictureInPicture
        case developerMode, sidebarOnRight, showURLBar, showToolbar, showTabPreviewsOnHover, adBlockerEnabled, adBlockerAllowedSites, soundEffects, automaticallyInstallUpdates
        case contentAppearance, allowJavaScriptFromAppleEvents
        case offerToSavePasswords, neverSavePasswordSites, autofillCards, neverTranslateLanguages, neverTranslateSites
        case warnBeforeQuitting, searchSuggestions, documentApp, downloadLocation, downloadFolder
        case littleArrowShortcut, littleArrowOnOptionCommandClick, littleArrowArchive, peekOnShiftClick, autoEnableNewMaxFeatures
        case tidyTabs, instantLinks, chatGPTInCommandBar, hapticFeedback, restoreWindows, dragWindowFromPageTop, showFullURLInToolbar
        case sharedQuotes, shareThemeWithWebsites, boostsEnabled, customShortcuts
        case sidebarWidth, cloudServerURL, syncEnabled, aiEnabled, tidyTabTitles, tidyDownloads, linkPreviews
    }

    /// Decodes leniently so settings files from older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ArrowSettings()
        searchEngine = (try? c.decode(SearchEngine.self, forKey: .searchEngine)) ?? d.searchEngine
        archiveInterval = (try? c.decode(ArchiveInterval.self, forKey: .archiveInterval)) ?? d.archiveInterval
        externalLinks = (try? c.decode(ExternalLinkDestination.self, forKey: .externalLinks)) ?? d.externalLinks
        airTrafficRules = (try? c.decode([AirTrafficRule].self, forKey: .airTrafficRules)) ?? d.airTrafficRules
        peekEnabled = (try? c.decode(Bool.self, forKey: .peekEnabled)) ?? d.peekEnabled
        automaticPictureInPicture = (try? c.decode(Bool.self, forKey: .automaticPictureInPicture)) ?? d.automaticPictureInPicture
        developerMode = (try? c.decode(Bool.self, forKey: .developerMode)) ?? d.developerMode
        sidebarOnRight = (try? c.decode(Bool.self, forKey: .sidebarOnRight)) ?? d.sidebarOnRight
        showURLBar = (try? c.decode(Bool.self, forKey: .showURLBar)) ?? d.showURLBar
        showToolbar = (try? c.decode(Bool.self, forKey: .showToolbar)) ?? d.showToolbar
        showTabPreviewsOnHover = (try? c.decode(Bool.self, forKey: .showTabPreviewsOnHover)) ?? d.showTabPreviewsOnHover
        adBlockerEnabled = (try? c.decode(Bool.self, forKey: .adBlockerEnabled)) ?? d.adBlockerEnabled
        adBlockerAllowedSites = (try? c.decode([String].self, forKey: .adBlockerAllowedSites)) ?? d.adBlockerAllowedSites
        soundEffects = (try? c.decode(Bool.self, forKey: .soundEffects)) ?? d.soundEffects
        automaticallyInstallUpdates = (try? c.decode(Bool.self, forKey: .automaticallyInstallUpdates)) ?? d.automaticallyInstallUpdates
        contentAppearance = (try? c.decode(ContentAppearance.self, forKey: .contentAppearance)) ?? d.contentAppearance
        allowJavaScriptFromAppleEvents = (try? c.decode(Bool.self, forKey: .allowJavaScriptFromAppleEvents))
            ?? d.allowJavaScriptFromAppleEvents
        offerToSavePasswords = (try? c.decode(Bool.self, forKey: .offerToSavePasswords)) ?? d.offerToSavePasswords
        neverSavePasswordSites = (try? c.decode([String].self, forKey: .neverSavePasswordSites)) ?? d.neverSavePasswordSites
        autofillCards = (try? c.decode(Bool.self, forKey: .autofillCards)) ?? d.autofillCards
        neverTranslateLanguages = (try? c.decode([String].self, forKey: .neverTranslateLanguages)) ?? d.neverTranslateLanguages
        neverTranslateSites = (try? c.decode([String].self, forKey: .neverTranslateSites)) ?? d.neverTranslateSites
        warnBeforeQuitting = (try? c.decode(Bool.self, forKey: .warnBeforeQuitting)) ?? d.warnBeforeQuitting
        searchSuggestions = (try? c.decode(Bool.self, forKey: .searchSuggestions)) ?? d.searchSuggestions
        documentApp = (try? c.decode(DocumentApp.self, forKey: .documentApp)) ?? d.documentApp
        downloadLocation = (try? c.decode(DownloadLocation.self, forKey: .downloadLocation)) ?? d.downloadLocation
        downloadFolder = (try? c.decode(String.self, forKey: .downloadFolder)) ?? d.downloadFolder
        littleArrowShortcut = (try? c.decode(Bool.self, forKey: .littleArrowShortcut)) ?? d.littleArrowShortcut
        littleArrowOnOptionCommandClick = (try? c.decode(Bool.self, forKey: .littleArrowOnOptionCommandClick)) ?? d.littleArrowOnOptionCommandClick
        littleArrowArchive = (try? c.decode(LittleArrowArchive.self, forKey: .littleArrowArchive)) ?? d.littleArrowArchive
        peekOnShiftClick = (try? c.decode(Bool.self, forKey: .peekOnShiftClick)) ?? d.peekOnShiftClick
        autoEnableNewMaxFeatures = (try? c.decode(Bool.self, forKey: .autoEnableNewMaxFeatures)) ?? d.autoEnableNewMaxFeatures
        tidyTabs = (try? c.decode(Bool.self, forKey: .tidyTabs)) ?? d.tidyTabs
        instantLinks = (try? c.decode(Bool.self, forKey: .instantLinks)) ?? d.instantLinks
        chatGPTInCommandBar = (try? c.decode(Bool.self, forKey: .chatGPTInCommandBar)) ?? d.chatGPTInCommandBar
        hapticFeedback = (try? c.decode(Bool.self, forKey: .hapticFeedback)) ?? d.hapticFeedback
        restoreWindows = (try? c.decode(Bool.self, forKey: .restoreWindows)) ?? d.restoreWindows
        dragWindowFromPageTop = (try? c.decode(Bool.self, forKey: .dragWindowFromPageTop)) ?? d.dragWindowFromPageTop
        showFullURLInToolbar = (try? c.decode(Bool.self, forKey: .showFullURLInToolbar)) ?? d.showFullURLInToolbar
        sharedQuotes = (try? c.decode(Bool.self, forKey: .sharedQuotes)) ?? d.sharedQuotes
        shareThemeWithWebsites = (try? c.decode(Bool.self, forKey: .shareThemeWithWebsites)) ?? d.shareThemeWithWebsites
        boostsEnabled = (try? c.decode(Bool.self, forKey: .boostsEnabled)) ?? d.boostsEnabled
        customShortcuts = (try? c.decode([String: String].self, forKey: .customShortcuts)) ?? d.customShortcuts
        sidebarWidth = (try? c.decode(Double.self, forKey: .sidebarWidth)) ?? d.sidebarWidth
        cloudServerURL = (try? c.decode(String.self, forKey: .cloudServerURL)) ?? d.cloudServerURL
        syncEnabled = (try? c.decode(Bool.self, forKey: .syncEnabled)) ?? d.syncEnabled
        aiEnabled = (try? c.decode(Bool.self, forKey: .aiEnabled)) ?? d.aiEnabled
        tidyTabTitles = (try? c.decode(Bool.self, forKey: .tidyTabTitles)) ?? d.tidyTabTitles
        tidyDownloads = (try? c.decode(Bool.self, forKey: .tidyDownloads)) ?? d.tidyDownloads
        linkPreviews = (try? c.decode(Bool.self, forKey: .linkPreviews)) ?? d.linkPreviews
    }
}
