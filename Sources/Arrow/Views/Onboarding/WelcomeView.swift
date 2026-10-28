import AppKit
import ArrowKit
import SwiftUI

/// Default browser state, checked through Launch Services, and Arc's
/// "Try for a week" trial.
@MainActor
enum DefaultBrowser {
    static var isArrow: Bool {
        guard let handler = currentHandler else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private static var currentHandler: URL? {
        URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    private static let dismissedKey = "ArrowDefaultBrowserBannerDismissed"
    private static let trialStartKey = "ArrowDefaultBrowserTrialStart"
    private static let previousBrowserKey = "ArrowDefaultBrowserBeforeTrial"

    static var isBannerDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    static func setDefault(_ application: URL) {
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: "http")
            try? await NSWorkspace.shared.setDefaultApplication(at: application, toOpenURLsWithScheme: "https")
        }
    }

    /// Arrow becomes the default browser; the command bar asks again in a week.
    static func startTrial() {
        if let handler = currentHandler, !isArrow {
            UserDefaults.standard.set(handler.path, forKey: previousBrowserKey)
        }
        UserDefaults.standard.set(Date(), forKey: trialStartKey)
        setDefault(Bundle.main.bundleURL)
    }

    static var isTrialRunning: Bool {
        UserDefaults.standard.object(forKey: trialStartKey) != nil && !isTrialOver
    }

    static var isTrialOver: Bool {
        guard let start = UserDefaults.standard.object(forKey: trialStartKey) as? Date else { return false }
        return Date().timeIntervalSince(start) >= 7 * 24 * 3600
    }

    /// End of the trial: keep Arrow, or give links back to the previous browser.
    static func endTrial(keepArrow: Bool) {
        if !keepArrow, let path = UserDefaults.standard.string(forKey: previousBrowserKey),
           FileManager.default.fileExists(atPath: path) {
            setDefault(URL(fileURLWithPath: path))
        }
        UserDefaults.standard.removeObject(forKey: trialStartKey)
        UserDefaults.standard.removeObject(forKey: previousBrowserKey)
        isBannerDismissed = true
    }
}

/// Footer of the command bar, as in Arc: "Arc works best as your default
/// browser", then "How are you liking Arc?" a week into the trial.
struct DefaultBrowserBanner: View {
    private enum Step { case prompt, trialStarted, afterTrial, hidden }

    @State private var step = DefaultBrowserBanner.initialStep()
    @Environment(\.palette) private var palette

    private static func initialStep() -> Step {
        if DefaultBrowser.isTrialOver { return .afterTrial }
        if DefaultBrowser.isTrialRunning || DefaultBrowser.isBannerDismissed || DefaultBrowser.isArrow { return .hidden }
        return .prompt
    }

    var body: some View {
        if step != .hidden {
            HStack(spacing: 9) {
                Image(nsImage: AppIcons.current)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .frame(width: 24)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.isDark ? Color(white: 0.7) : Color(white: 0.43))
                Spacer(minLength: 8)
                switch step {
                case .prompt:
                    BannerButton(title: "Try for a week", isProminent: false) {
                        DefaultBrowser.startTrial()
                        step = .trialStarted
                    }
                    BannerButton(title: "Set Arrow as default", isProminent: true) {
                        DefaultBrowser.setDefault(Bundle.main.bundleURL)
                        DefaultBrowser.isBannerDismissed = true
                        step = .hidden
                    }
                case .afterTrial:
                    BannerButton(title: "I’m not ready to switch", isProminent: false) {
                        DefaultBrowser.endTrial(keepArrow: false)
                        step = .hidden
                    }
                    BannerButton(title: "Keep Arrow, I like what I see", isProminent: true) {
                        DefaultBrowser.endTrial(keepArrow: true)
                        step = .hidden
                    }
                case .trialStarted, .hidden:
                    EmptyView()
                }
                Button {
                    if step == .prompt { DefaultBrowser.isBannerDismissed = true }
                    step = .hidden
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Maybe Later")
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 59)
            .background(
                Rectangle()
                    .fill(palette.isDark ? Color(white: 0.19) : Color(white: 0.994))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: -2)
            )
        }
    }

    private var message: String {
        switch step {
        case .trialStarted: "Great! We’ll check back in next week."
        case .afterTrial: "How are you liking Arrow?"
        default: "Arrow works best as your default browser"
        }
    }
}

/// Buttons of the banner: white with a border, or filled with the accent.
private struct BannerButton: View {
    let title: String
    let isProminent: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                // Truncated rather than wrapped in narrow bars (Little Arrow).
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isProminent ? palette.accent : (palette.isDark ? Color(white: 0.26) : .white))
                        .shadow(color: .black.opacity(isProminent ? 0.18 : 0.08), radius: 0, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isProminent ? 0 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// First launch: welcome and import from Arc.
struct WelcomeView: View {
    let controller: BrowserWindowController
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?

    private var hasArc: Bool {
        BrowserImporter.availableSources().contains(.arc)
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: AppIcons.current)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Welcome to Arrow")
                .font(.system(size: 26, weight: .bold))
            Text("A browser with spaces, a sidebar of pinned tabs, the command bar, Little Arrow and Boosts — the way Arc did it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack(spacing: 12) {
                if hasArc && result == nil {
                    Button("Import from Arc") {
                        result = BrowserImporter(store: controller.store).importData(from: .arc) ?? "Nothing to import"
                        if let space = controller.store.state.spaces.last { controller.selectSpace(space.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button(result == nil ? "Start Browsing" : "Done") { finish() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 480)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
        controller.showCommandBar(mode: .newTab)
    }

    static let completedKey = "ArrowWelcomeCompleted"
    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: completedKey) }
}
