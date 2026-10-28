import AppKit
import SwiftUI

/// Borderless-looking browser window: transparent full-size title bar with
/// the traffic lights moved into the sidebar header, like Arc.
final class ArrowWindow: NSWindow {
    /// Vertical center of the traffic lights from the top of the window.
    static let trafficLightCenterY: CGFloat = 23.5
    /// Arc spaces its traffic lights 23 pt apart, wider than AppKit's 20 pt.
    static let trafficLightSpacing: CGFloat = 23

    var trafficLightsHidden = false {
        didSet { layoutTrafficLights() }
    }

    /// Center of the close button from the top-left corner (measured on Arc;
    /// its Library and Little Arc place them differently).
    var trafficLightCenter = CGPoint(x: 20, y: ArrowWindow.trafficLightCenterY) {
        didSet { layoutTrafficLights() }
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior.insert(.fullScreenPrimary)
        minSize = NSSize(width: 520, height: 360)
        animationBehavior = .documentWindow
        tabbingMode = .disallowed
        // Arrow restores its windows itself (window snapshot), so macOS does
        // not, and the Quit menu has no "Quit and Keep Windows", as in Arc.
        isRestorable = false

        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            center.addObserver(self, selector: #selector(relayout), name: name, object: self)
        }
    }

    @objc private func relayout() {
        layoutTrafficLights()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }

    func layoutTrafficLights() {
        let buttons: [NSButton] = [.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        guard let first = buttons.first, let titlebar = first.superview, let container = titlebar.superview else { return }
        let inFullScreen = styleMask.contains(.fullScreen)
        for button in buttons {
            button.isHidden = trafficLightsHidden && !inFullScreen
        }
        guard !inFullScreen else { return }
        let height = trafficLightCenter.y * 2
        let containerFrame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != containerFrame {
            container.frame = containerFrame
        }
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: (trafficLightCenter.x + CGFloat(index) * Self.trafficLightSpacing - button.frame.width / 2).rounded(),
                                 y: (titlebar.frame.height - button.frame.height) / 2)
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }
}

/// Lets the user drag the window from an otherwise empty SwiftUI area.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Behind-window blur under the space gradient (Arc's vibrant themes).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
