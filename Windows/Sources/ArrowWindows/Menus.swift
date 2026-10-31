import ArrowCEF
import Foundation
import UWP
import WindowsFoundation
import WinUI

/// Arc's menus: WinUI menu flyouts, with Segoe Fluent icons and the
/// shortcuts' text in the app menus, and a gray title first in the context
/// menus. They open in windows of their own, over the page's browser.
@MainActor
enum Menu {
    /// A menu entry: nil entries are left out, so menus can list optional
    /// ones inline.
    typealias Entry = MenuFlyoutItemBase?

    static func flyout(_ entries: [Entry]) -> MenuFlyout {
        let menu = MenuFlyout()
        menu.shouldConstrainToRootBounds = false
        for entry in entries.compactMap({ $0 }) {
            menu.items.append(entry)
        }
        return menu
    }

    static func item(_ title: String, glyph: String? = nil, shortcut: CEFKeyEvent? = nil, isEnabled: Bool = true,
                     action: @escaping () -> Void) -> MenuFlyoutItem {
        let item = MenuFlyoutItem()
        item.text = title
        if let glyph { item.icon = icon(glyph) }
        if let shortcut { item.keyboardAcceleratorTextOverride = shortcut.label }
        item.isEnabled = isEnabled
        item.click.addHandler { _, _ in action() }
        return item
    }

    static func submenu(_ title: String, glyph: String? = nil, _ entries: [Entry]) -> MenuFlyoutSubItem {
        let submenu = MenuFlyoutSubItem()
        submenu.text = title
        if let glyph { submenu.icon = icon(glyph) }
        for entry in entries.compactMap({ $0 }) {
            submenu.items.append(entry)
        }
        submenu.isEnabled = submenu.items.size > 0
        return submenu
    }

    static func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> ToggleMenuFlyoutItem {
        let item = ToggleMenuFlyoutItem()
        item.text = title
        item.isChecked = isOn
        item.click.addHandler { _, _ in action() }
        return item
    }

    static func separator() -> MenuFlyoutSeparator {
        MenuFlyoutSeparator()
    }

    /// The gray title of Arc's context menus ("Tab Context Menu").
    static func title(_ title: String) -> MenuFlyoutItem {
        let item = MenuFlyoutItem()
        item.text = title
        item.isEnabled = false
        return item
    }

    static func icon(_ glyph: String) -> FontIcon {
        let icon = FontIcon()
        icon.glyph = glyph
        icon.fontFamily = Glyph.font
        return icon
    }

    /// Opens `menu` under `button`, aligned to its left edge.
    static func show(_ menu: FlyoutBase, under button: FrameworkElement) {
        menu.placement = .bottomEdgeAlignedLeft
        try? menu.showAt(button)
    }

    /// Opens `menu` above `button`, centered (Translate's Options).
    static func show(_ menu: FlyoutBase, above button: FrameworkElement) {
        menu.placement = .top
        try? menu.showAt(button)
    }

    /// Opens `menu` at the pointer's position in `element` (a right click).
    static func show(_ menu: MenuFlyout, at point: Point, in element: UIElement) {
        try? menu.showAt(element, point)
    }
}

extension UIElement {
    /// Opens the menu `build` makes on a right click, the menu key or
    /// Shift+F10, at the pointer: the innermost element's menu.
    ///
    /// The element is the event's sender: its Swift object can be gone while
    /// WinUI keeps the element.
    @MainActor
    func setContextMenu(_ build: @escaping @MainActor () -> MenuFlyout?) {
        contextRequested.addHandler { sender, event in
            guard let element = sender, let event, let menu = build() else { return }
            event.handled = true
            var point = Point(x: 0, y: 0)
            if (try? event.tryGetPosition(element, &point)) != true {
                point = Point(x: 12, y: 12)
            }
            Menu.show(menu, at: point, in: element)
        }
    }
}
