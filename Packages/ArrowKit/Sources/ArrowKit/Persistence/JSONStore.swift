import Foundation

/// Atomic JSON persistence with rotating backups (Arc keeps dated copies of
/// its storable files the same way).
public struct JSONStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public let backupCount: Int

    public init(url: URL, backupCount: Int = 5) {
        self.url = url
        self.backupCount = backupCount
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Dates are stored as their exact reference-date Double so values
        // round-trip bit for bit (secondsSince1970 adds an offset that can
        // drop the last bits).
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    /// Value stored in one of the `backups()`.
    public func value(inBackup backup: URL) -> Value? {
        Self.read(backup)
    }

    /// Loads the value, falling back to the newest readable backup.
    public func load() -> Value? {
        if let value = Self.read(url) { return value }
        for backup in backups().reversed() {
            if let value = Self.read(backup) { return value }
        }
        return nil
    }

    private static func read(_ url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Value.self, from: data)
    }

    /// Writes atomically. When `backup` is true the previous file is kept
    /// as a dated copy.
    public func save(_ value: Value, backup: Bool = false) throws {
        let data = try Self.encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup, FileManager.default.fileExists(atPath: url.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"
            let name = url.deletingPathExtension().lastPathComponent + "." + formatter.string(from: Date()) + ".json"
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            try? FileManager.default.copyItem(at: url, to: destination)
            pruneBackups()
        }
        try data.write(to: url, options: [.atomic])
    }

    /// Dated copies, oldest first.
    public func backups() -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + "."
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" && $0 != url }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneBackups() {
        let existing = backups()
        guard existing.count > backupCount else { return }
        for file in existing.prefix(existing.count - backupCount) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
