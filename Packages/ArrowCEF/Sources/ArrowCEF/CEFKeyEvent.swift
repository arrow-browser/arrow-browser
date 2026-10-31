import CEF

/// A key pressed in a page, as CEF reports it before the page gets it.
public struct CEFKeyEvent: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: UInt32(EVENTFLAG_SHIFT_DOWN.rawValue))
        public static let control = Modifiers(rawValue: UInt32(EVENTFLAG_CONTROL_DOWN.rawValue))
        public static let alt = Modifiers(rawValue: UInt32(EVENTFLAG_ALT_DOWN.rawValue))
    }

    /// The key's Windows virtual-key code, on every platform.
    public var keyCode: Int32
    public var modifiers: Modifiers

    public init(keyCode: Int32, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ event: cef_key_event_t) {
        keyCode = Int32(event.windows_key_code)
        var modifiers = Modifiers(rawValue: event.modifiers).intersection([.shift, .control, .alt])
        // AltGr, reported as Ctrl+Alt, types characters (@, €…).
        if event.modifiers & UInt32(EVENTFLAG_ALTGR_DOWN.rawValue) != 0 {
            modifiers.subtract([.control, .alt])
        }
        self.modifiers = modifiers
    }
}
