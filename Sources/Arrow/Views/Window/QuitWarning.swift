import AppKit
import SwiftUI

/// Preferences ▸ General ▸ Warn before quitting: Arc's "Quit Arc?" dialog.
@MainActor
enum QuitWarning {
    enum Choice {
        case quit, quitAndStopAsking, cancel
    }

    static func confirm() -> Choice {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        var choice = Choice.cancel
        panel.contentView = NSHostingView(rootView: QuitDialog { result in
            choice = result
            NSApp.stopModal()
        })
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return choice
    }
}

private struct QuitDialog: View {
    let done: (QuitWarning.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: AppIcons.current).resizable().frame(width: 36, height: 36)
            Text("Quit Arrow?").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 8) {
                Button("Quit, and don’t ask again") { done(.quitAndStopAsking) }
                    .fixedSize()
                Button { done(.cancel) } label: {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        KeyHint(text: "esc")
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button { done(.quit) } label: {
                    HStack(spacing: 6) {
                        Text("Quit")
                        KeyHint(text: "↩")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
    }
}

private struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.12)))
    }
}
