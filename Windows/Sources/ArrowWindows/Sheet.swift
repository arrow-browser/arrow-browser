import ArrowCEF
import ArrowKit
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// A dialog over the window, drawn as WinUI's ContentDialog, in a window of
/// its own (a windowed popup): a ContentDialog would show under the page's
/// browser.
@MainActor
final class Sheet {
    struct Action {
        var title: String
        var isPrimary = false
        /// Returns whether the sheet closes.
        var perform: () -> Bool = { true }
    }

    /// Called once the sheet has closed.
    var onClose: (() -> Void)?
    /// The open sheets: WinUI keeps their elements, not this object.
    private static var open: [Sheet] = []
    private unowned let window: BrowserWindow
    private let popup = Popup()
    private let panel = Border()
    private var primary: Action?
    /// Escape's action: Cancel's, when there is one.
    private var cancel: Action?

    init(window: BrowserWindow, title: String, content: UIElement, width: Double = 440, actions: [Action]) {
        self.window = window
        let isDark = window.brushes.palette.isDark
        panel.requestedTheme = isDark ? .dark : .light
        panel.width = width
        panel.cornerRadius = CornerRadius(8)
        panel.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        panel.borderBrush = SolidColorBrush(Color((isDark ? RGBColor.white : .black).withAlpha(0.1)))
        panel.background = SolidColorBrush(Color(isDark ? RGBColor(hex: 0x2B2B2B) : RGBColor(hex: 0xFFFFFF)))

        let body = StackPanel()
        body.spacing = 12
        body.padding = Thickness(left: 24, top: 24, right: 24, bottom: 24)
        let heading = TextBlock()
        heading.text = title
        heading.fontSize = 20
        heading.fontWeight = FontWeight(weight: 600)
        heading.textWrapping = .wrap
        body.children.append(heading)
        body.children.append(content)

        let footer = Grid()
        footer.padding = Thickness(left: 24, top: 24, right: 24, bottom: 24)
        footer.columnSpacing = 8
        footer.background = SolidColorBrush(Color(isDark ? RGBColor(hex: 0x202020) : RGBColor(hex: 0xF3F3F3)))
        for (index, action) in actions.enumerated() {
            let column = ColumnDefinition()
            column.width = .star
            footer.columnDefinitions.append(column)
            let button = Button()
            button.content = action.title
            button.horizontalAlignment = .stretch
            if action.title == "Cancel" { cancel = action }
            if action.isPrimary {
                primary = action
                if let style = try? Application.current.resources.lookup("AccentButtonStyle") as? Style {
                    button.style = style
                }
            }
            try? Grid.setColumn(button, Int32(index))
            footer.children.append(button)
            button.click.addHandler { [weak self] _, _ in
                if action.perform() { self?.close() }
            }
        }

        let layout = StackPanel()
        layout.children.append(body)
        if !actions.isEmpty { layout.children.append(footer) }
        panel.child = layout
        popup.child = panel
        popup.shouldConstrainToRootBounds = false
        panel.previewKeyDown.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            switch event.key {
            case .escape:
                event.handled = true
                _ = cancel?.perform()
                close()
            case .enter:
                // Enter makes a new line in a multi-line field (a boost's CSS).
                guard let primary, (event.originalSource as? TextBox)?.acceptsReturn != true else { return }
                event.handled = true
                if primary.perform() { close() }
            default:
                break
            }
        }
        popup.closed.addHandler { [weak self] _, _ in
            guard let self else { return }
            Sheet.open.removeAll { $0 === self }
            onClose?()
        }
    }

    /// Shows the sheet in the middle of the window, its first control with
    /// the keyboard.
    func show(focusing control: Control? = nil) {
        guard let root = window.content.xamlRoot else { return }
        popup.xamlRoot = root
        try? panel.measure(Size(width: Float(panel.width), height: .infinity))
        let height = Double(panel.desiredSize.height)
        popup.horizontalOffset = (window.content.actualWidth - panel.width) / 2
        popup.verticalOffset = max((window.content.actualHeight - height) / 2, 24)
        popup.isOpen = true
        Sheet.open.append(self)
        guard let control else { return }
        _ = try? control.focus(.programmatic)
        // A menu that opened the sheet gives the keyboard back as it closes,
        // after this: take it again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, popup.isOpen else { return }
            _ = try? control.focus(.programmatic)
        }
    }

    func close() {
        popup.isOpen = false
    }
}

extension BrowserWindow {
    /// A sheet with a message and a Close button.
    func showMessage(_ title: String, _ message: String) {
        let text = TextBlock()
        text.text = message
        text.textWrapping = .wrap
        text.isTextSelectionEnabled = true
        Sheet(window: self, title: title, content: text, actions: [Sheet.Action(title: "Close", isPrimary: true)]).show()
    }

    func showAbout() {
        showMessage("About Arrow", "Arrow \(ArrowApp.version) for Windows\nChromium \(CEFVersion.chromium) (CEF \(CEFVersion.cef))\n\n"
            + "A browser in the spirit of Arc, on WinUI 3 and Chromium.")
    }
}
