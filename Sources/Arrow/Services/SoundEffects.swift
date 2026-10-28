import AppKit

/// Preferences ▸ Advanced ▸ Play Arrow sound effects. Like Arc, two sounds:
/// a chime for events (copy, pin, archive) and a shutter for captures. They
/// are synthesized by `scripts/make-sounds.swift`; Arc's files are not reused.
@MainActor
enum SoundEffects {
    enum Effect: String {
        case event
        case capture
    }

    private static var sounds: [Effect: NSSound] = [:]

    static func play(_ effect: Effect, store: BrowserStore?) {
        guard store?.settings.soundEffects ?? false else { return }
        #if DEBUG
        let started = sound(effect)?.play() ?? false
        NSLog("Arrow sound \(effect.rawValue) started=\(started)")
        #else
        sound(effect)?.play()
        #endif
    }

    #if DEBUG
    /// Source and duration of a sound, without playing it.
    static func info(_ effect: Effect) -> String {
        guard let sound = sound(effect) else { return "missing" }
        return "\(sound.name ?? "bundled") \(String(format: "%.2f", sound.duration))s"
    }
    #endif

    private static func sound(_ effect: Effect) -> NSSound? {
        if let sound = sounds[effect] { return sound }
        let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "caf", subdirectory: "Sounds")
        let sound = url.flatMap { NSSound(contentsOf: $0, byReference: true) }
            ?? NSSound(named: NSSound.Name(effect == .event ? "Pop" : "Tink"))
        sounds[effect] = sound
        return sound
    }
}
