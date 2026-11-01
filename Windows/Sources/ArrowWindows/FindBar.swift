import ArrowCore
import ArrowKit
import Foundation
import UWP
import WinSDK
import WindowsFoundation
import WinUI

/// Arc's find in page (Ctrl+F): a field at the top right of the page with
/// the matches' count, previous, next and close. A windowed popup, over the
/// page's browser.
@MainActor
final class FindBar {
    /// Called once the bar has closed.
    var onClose: (() -> Void)?
    private unowned let window: BrowserWindow
    private(set) weak var tab: WebTab?
    private let popup = Popup()
    private let panel = Border()
    private let field = TextBox()
    private let count = TextBlock()

    init(window: BrowserWindow, tab: WebTab) {
        self.window = window
        self.tab = tab
        let palette = window.brushes.palette
        panel.requestedTheme = palette.isDark ? .dark : .light
        panel.width = 360
        panel.height = 40
        panel.cornerRadius = CornerRadius(8)
        panel.borderThickness = Thickness(left: 1, top: 1, right: 1, bottom: 1)
        panel.borderBrush = SolidColorBrush(Color(palette.accent))
        panel.background = SolidColorBrush(Color(palette.contentBackground.mixed(with: palette.accent, amount: 0.08)))
        panel.padding = Thickness(left: 4, top: 0, right: 6, bottom: 0)

        let row = Grid()
        row.columnSpacing = 4
        for width in [GridLength.star, .auto, .auto, .auto, .auto] {
            let column = ColumnDefinition()
            column.width = width
            row.columnDefinitions.append(column)
        }
        field.placeholderText = "Find in page…"
        field.minHeight = 0
        field.verticalAlignment = .center
        field.isSpellCheckEnabled = false
        let clear = SolidColorBrush(Color(a: 0, r: 0, g: 0, b: 0))
        for key in ["Background", "BorderBrush"] {
            for state in ["", "PointerOver", "Focused"] {
                _ = field.resources.insert("TextControl\(key)\(state)", clear)
            }
        }
        row.children.append(field)
        count.fontSize = 11
        count.verticalAlignment = .center
        count.opacity = 0.7
        try? Grid.setColumn(count, 1)
        row.children.append(count)
        for (index, (glyph, name, action)) in [
            (Glyph.chevronUp, "Previous Match", { [weak self] in self?.find(forward: false) }),
            (Glyph.chevronDown, "Next Match", { [weak self] in self?.find(forward: true) }),
            (Glyph.close, "Close Find", { [weak self] in self?.close() }),
        ].enumerated() {
            let button = Button()
            button.content = Glyph.view(glyph, size: 11)
            button.width = 26
            button.height = 26
            button.padding = Thickness()
            button.background = clear
            button.borderThickness = Thickness()
            button.verticalAlignment = .center
            try? AutomationProperties.setName(button, name)
            try? ToolTipService.setToolTip(button, name)
            try? Grid.setColumn(button, Int32(index + 2))
            row.children.append(button)
            button.click.addHandler { _, _ in action() }
        }
        panel.child = row
        popup.child = panel
        popup.shouldConstrainToRootBounds = false

        field.textChanged.addHandler { [weak self] _, _ in self?.find(forward: true) }
        field.previewKeyDown.addHandler { [weak self] _, event in
            guard let self, let event else { return }
            switch event.key {
            case .enter:
                event.handled = true
                find(forward: GetKeyState(VK_SHIFT) >= 0)
            case .escape:
                event.handled = true
                close()
            default:
                break
            }
        }
        popup.closed.addHandler { [weak self] _, _ in
            self?.tab?.endFind()
            self?.onClose?()
        }
        observe { [weak self] in self?.updateCount() }
    }

    /// Opens the bar at the top right of `frame` (the page, in the window's
    /// coordinates), with the keyboard.
    func show(in frame: Rect) {
        guard let root = window.content.xamlRoot else { return }
        popup.xamlRoot = root
        place(in: frame)
        popup.isOpen = true
        _ = try? field.focus(.programmatic)
        try? field.selectAll()
    }

    func place(in frame: Rect) {
        popup.horizontalOffset = Double(frame.x + frame.width) - panel.width - 8
        popup.verticalOffset = Double(frame.y) + 8
    }

    func focus() {
        _ = try? field.focus(.programmatic)
        try? field.selectAll()
    }

    func close() {
        popup.isOpen = false
    }

    private func find(forward: Bool) {
        let text = field.text
        guard let tab else { return }
        if text.isEmpty {
            tab.endFind()
        } else {
            tab.find(text, forward: forward)
        }
    }

    private func updateCount() {
        guard let find = tab?.find, !find.text.isEmpty else {
            count.text = ""
            return
        }
        count.text = "\(find.matchCount == 0 ? 0 : find.activeMatch)/\(find.matchCount)"
    }
}
