import ArrowKit
import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI

/// Client of Arrow's self-hosted server (see server/README.md): accounts,
/// end-to-end encrypted sync, sharing, AI and feedback.
@MainActor
@Observable
final class ArrowCloud {
    struct User: Codable, Equatable {
        var id: String
        var email: String
        var displayName: String
    }

    struct APIError: LocalizedError {
        var status: Int
        var code: String
        var message: String
        var errorDescription: String? { message }
    }

    private(set) var user: User?
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    @ObservationIgnored private weak var store: BrowserStore?
    @ObservationIgnored private var token: String? {
        didSet { Keychain.set(token, account: "token") }
    }

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var syncState: SyncState
    @ObservationIgnored private let syncStateURL: URL
    @ObservationIgnored private let deviceID: String

    /// Last pushed payload hash and server revision of each document.
    private struct SyncState: Codable {
        var revision: Int64 = 0
        var documents: [String: DocumentState] = [:]

        struct DocumentState: Codable {
            var revision: Int64
            var hash: String
        }
    }

    init(store: BrowserStore) {
        self.store = store
        syncStateURL = store.dataDirectory.appendingPathComponent("SyncState.json")
        syncState = JSONStore<SyncState>(url: syncStateURL).load() ?? SyncState()
        if let existing = UserDefaults.standard.string(forKey: "ArrowDeviceID") {
            deviceID = existing
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "ArrowDeviceID")
        }
        token = Keychain.get(account: "token")
        if token != nil {
            Task { await refreshUser() }
        }
    }

    private var baseURL: URL? {
        guard let value = store?.settings.cloudServerURL, !value.isEmpty else { return nil }
        return URL(string: value.hasSuffix("/") ? String(value.dropLast()) : value)
    }

    var isSignedIn: Bool { token != nil && user != nil }

    // MARK: - HTTP

    private func request(_ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none,
                         authenticated: Bool = true) async throws -> Data {
        guard let baseURL, let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError(status: 0, code: "not_configured", message: "Set the Arrow Cloud server URL in Settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONEncoder.arrow.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            if status == 401, authenticated {
                token = nil
                user = nil
            }
            throw APIError(status: status, code: envelope?.error.code ?? "http_\(status)",
                           message: envelope?.error.message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var code: String
            var message: String
        }

        var error: Body
    }

    // MARK: - Account

    private struct Credentials: Encodable {
        var email: String
        var password: String
        var displayName: String?
    }

    private struct Session: Decodable {
        var token: String
        var user: User
    }

    func register(email: String, password: String, displayName: String) async throws {
        let data = try await request("POST", "/v1/auth/register",
                                     body: Credentials(email: email, password: password, displayName: displayName.isEmpty ? nil : displayName),
                                     authenticated: false)
        try adopt(data)
    }

    func signIn(email: String, password: String) async throws {
        let data = try await request("POST", "/v1/auth/login", body: Credentials(email: email, password: password),
                                     authenticated: false)
        try adopt(data)
    }

    private func adopt(_ data: Data) throws {
        let session = try JSONDecoder().decode(Session.self, from: data)
        token = session.token
        user = session.user
        startSync()
    }

    func signOut() async {
        _ = try? await request("POST", "/v1/auth/logout")
        stopSync()
        token = nil
        user = nil
    }

    func refreshUser() async {
        struct Me: Decodable { var user: User }
        guard let data = try? await request("GET", "/v1/me"), let me = try? JSONDecoder().decode(Me.self, from: data) else { return }
        user = me.user
        startSync()
    }

    // MARK: - Encryption

    /// Base64 recovery key: the only way to decrypt synced data on a new Mac.
    var recoveryKey: String {
        SyncKey.current().withUnsafeBytes { Data($0).base64EncodedString() }
    }

    func restore(recoveryKey: String) -> Bool {
        guard let data = Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32 else { return false }
        SyncKey.store(SymmetricKey(data: data))
        syncState = SyncState()
        Task { await syncNow() }
        return true
    }

    private func seal<T: Encodable>(_ value: T) throws -> String {
        let plaintext = try JSONEncoder.arrow.encode(value)
        let box = try AES.GCM.seal(plaintext, using: SyncKey.current())
        return box.combined!.base64EncodedString()
    }

    private func open<T: Decodable>(_ payload: String, as type: T.Type) throws -> T {
        guard let data = Data(base64Encoded: payload) else { throw CocoaError(.coderReadCorrupt) }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: SyncKey.current())
        return try JSONDecoder.arrow.decode(T.self, from: plaintext)
    }

    // MARK: - Sync

    private struct Change: Codable {
        var id: String
        var kind: String
        var payload: String?
        var deleted: Bool
        var baseRevision: Int64?
        var revision: Int64?
    }

    private struct ChangesResponse: Decodable {
        var revision: Int64
        var changes: [Change]
    }

    private struct PushRequest: Encodable {
        var deviceId: String
        var changes: [Change]
    }

    private struct PushResponse: Decodable {
        struct Conflict: Decodable {
            var id: String
            var serverRevision: Int64
        }

        var revision: Int64
        var accepted: [String]
        var conflicts: [Conflict]
    }

    /// Shared metadata document (space order, profiles).
    private struct Layout: Codable {
        var spaceOrder: [UUID]
        var profiles: [Profile]
    }

    func startSync() {
        guard store?.settings.syncEnabled == true, token != nil, eventsTask == nil else { return }
        eventsTask = Task { [weak self] in await self?.listenForEvents() }
        Task { await syncNow() }
    }

    func stopSync() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Debounced push after a local change.
    func scheduleSync() {
        guard store?.settings.syncEnabled == true, token != nil else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard !isSyncing, let store, store.settings.syncEnabled, token != nil else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await pull(into: store)
            try await push(from: store)
            lastSyncError = nil
            lastSyncDate = Date()
            try? JSONStore<SyncState>(url: syncStateURL).save(syncState)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func localDocuments(_ state: BrowserState) throws -> [(id: String, kind: String, payload: String, hash: String)] {
        var documents: [(String, String, Encodable)] = state.spaces.map { ($0.id.uuidString, "space", $0) }
        documents.append(("favorites", "favorites", state.favorites))
        documents.append(("layout", "settings", Layout(spaceOrder: state.spaces.map(\.id), profiles: state.profiles)))
        return try documents.map { id, kind, value in
            let plaintext = try JSONEncoder.arrow.encode(value)
            let hash = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
            return (id, kind, try seal(AnyEncodable(value)), hash)
        }
    }

    private func push(from store: BrowserStore) async throws {
        let documents = try localDocuments(store.state)
        var changes: [Change] = documents.compactMap { document in
            let known = syncState.documents[document.id]
            guard known?.hash != document.hash else { return nil }
            return Change(id: document.id, kind: document.kind, payload: document.payload, deleted: false,
                          baseRevision: known?.revision ?? 0)
        }
        let localSpaceIDs = Set(store.state.spaces.map(\.id.uuidString))
        for (id, known) in syncState.documents where UUID(uuidString: id) != nil && !localSpaceIDs.contains(id) {
            changes.append(Change(id: id, kind: "space", payload: nil, deleted: true, baseRevision: known.revision))
        }
        guard !changes.isEmpty else { return }
        let data = try await request("POST", "/v1/sync/push", body: PushRequest(deviceId: deviceID, changes: changes))
        let response = try JSONDecoder().decode(PushResponse.self, from: data)
        let hashes = Dictionary(documents.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        for id in response.accepted {
            if let hash = hashes[id] {
                syncState.documents[id] = .init(revision: response.revision, hash: hash)
            } else {
                syncState.documents[id] = nil
            }
        }
        if !response.conflicts.isEmpty {
            // Another device changed these documents: take theirs, then retry.
            try await pull(into: store, force: true)
        }
    }

    private func pull(into store: BrowserStore, force: Bool = false) async throws {
        let since = force ? 0 : syncState.revision
        let data = try await request("GET", "/v1/sync/changes?since=\(since)")
        let response = try JSONDecoder().decode(ChangesResponse.self, from: data)
        var remoteSpaces: [UUID: Space] = [:]
        var deletedSpaces: Set<UUID> = []
        var favorites: [String: [Tab]]?
        var layout: Layout?
        for change in response.changes {
            let revision = change.revision ?? response.revision
            if change.deleted {
                if let id = UUID(uuidString: change.id) { deletedSpaces.insert(id) }
                syncState.documents[change.id] = nil
                continue
            }
            guard let payload = change.payload else { continue }
            do {
                let plaintextHash = try hashOfDecrypted(payload)
                // Our own pushes come back from the server. They are already
                // applied here, and applying them again would undo the local
                // changes made since.
                if syncState.documents[change.id]?.hash == plaintextHash {
                    syncState.documents[change.id]?.revision = revision
                    continue
                }
                switch change.kind {
                case "space":
                    let space = try open(payload, as: Space.self)
                    remoteSpaces[space.id] = space
                case "favorites":
                    favorites = try open(payload, as: [String: [Tab]].self)
                case "settings":
                    layout = try open(payload, as: Layout.self)
                default:
                    continue
                }
                syncState.documents[change.id] = .init(revision: revision, hash: plaintextHash)
            } catch {
                lastSyncError = "Some synced data could not be decrypted. Check your recovery key."
            }
        }
        syncState.revision = response.revision
        guard !remoteSpaces.isEmpty || !deletedSpaces.isEmpty || favorites != nil || layout != nil else { return }
        store.applyRemote(spaces: remoteSpaces, deleted: deletedSpaces, favorites: favorites,
                          order: layout?.spaceOrder, profiles: layout?.profiles)
    }

    private func hashOfDecrypted(_ payload: String) throws -> String {
        guard let data = Data(base64Encoded: payload) else { return "" }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SyncKey.current())
        return SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
    }

    /// Listens to the server's revision events (SSE) and pulls on change.
    private func listenForEvents() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            guard let baseURL, let token, let url = URL(string: baseURL.absoluteString + "/v1/sync/events") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 3600
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                delay = .seconds(1)
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let json = Data(line.dropFirst(5).utf8)
                    if let event = try? JSONDecoder().decode([String: Int64].self, from: json),
                       let revision = event["revision"], revision > syncState.revision {
                        await syncNow()
                    }
                }
            } catch {
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    // MARK: - AI

    enum AITask: String {
        case tidyTabTitle = "tidy-tab-title"
        case tidyDownloadName = "tidy-download-name"
        case previewSummary = "preview-summary"
        case askPage = "ask-page"
        case tidyTabs = "tidy-tabs"
        case chat
    }

    private struct AIRequest: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var task: String
        var messages: [Message]
        var stream = false
    }

    private struct AIResponse: Decodable {
        var text: String
        var stopReason: String
    }

    /// Runs an AI task. Returns nil when the model declined (refusal).
    func ai(_ task: AITask, prompt: String) async throws -> String? {
        let data = try await request("POST", "/v1/ai/messages",
                                     body: AIRequest(task: task.rawValue, messages: [.init(role: "user", content: prompt)]))
        let response = try JSONDecoder().decode(AIResponse.self, from: data)
        guard response.stopReason != "refusal" else { return nil }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sharing & feedback

    private struct ShareRequest: Encodable {
        struct Link: Encodable {
            var title: String
            var url: String
        }

        struct Payload: Encodable {
            var items: [Link]
        }

        var kind: String
        var title: String
        var payload: Payload
    }

    private struct ShareResponse: Decodable {
        var url: String
    }

    /// Publishes a public page listing `tabs`; returns its URL.
    func share(kind: String, title: String, tabs: [Tab]) async throws -> String {
        let body = ShareRequest(kind: kind, title: title,
                                payload: .init(items: tabs.map { .init(title: $0.displayTitle, url: $0.pinnedURL ?? $0.url) }))
        let data = try await request("POST", "/v1/shares", body: body)
        return try JSONDecoder().decode(ShareResponse.self, from: data).url
    }

    /// A published share, read without authentication.
    struct SharedCollection: Decodable {
        struct Payload: Decodable {
            struct Link: Decodable {
                var title: String
                var url: String
            }

            var items: [Link]?
        }

        var id: String
        var kind: String
        var title: String
        var payload: Payload?
    }

    func fetchShare(_ id: String) async throws -> SharedCollection {
        let safeID = id.filter { $0.isLetter || $0.isNumber }
        let data = try await request("GET", "/v1/shares/\(safeID)", authenticated: false)
        return try JSONDecoder().decode(SharedCollection.self, from: data)
    }

    private struct FeedbackRequest: Encodable {
        var message: String
        var email: String?
        var appVersion: String
        var osVersion: String
    }

    func sendFeedback(_ message: String, email: String?) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        _ = try await request("POST", "/v1/feedback", body: FeedbackRequest(
            message: message, email: email?.isEmpty == true ? nil : email, appVersion: version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString))
    }
}

// MARK: - Helpers

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension JSONEncoder {
    static var arrow: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Exact round trip: a pulled document re-encodes to the same bytes,
        // so its hash does not change and it is not pushed back.
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}

extension JSONDecoder {
    static var arrow: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}

/// The 256-bit sync key, kept in the Keychain.
private enum SyncKey {
    static func current() -> SymmetricKey {
        if let stored = Keychain.get(account: "syncKey"), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        store(key)
        return key
    }

    static func store(_ key: SymmetricKey) {
        Keychain.set(key.withUnsafeBytes { Data($0).base64EncodedString() }, account: "syncKey")
    }
}

/// Generic passwords of the "Arrow Cloud" Keychain service.
enum Keychain {
    private static let service = "Arrow Cloud"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

// MARK: - Settings UI

/// Sign in / account status in Settings ▸ Arrow Cloud.
struct AccountView: View {
    @Environment(BrowserStore.self) private var store
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var error: String?
    @State private var recovery = ""
    @State private var isWorking = false

    var body: some View {
        let cloud = store.cloud
        if let user = cloud.user {
            LabeledContent("Signed in as", value: "\(user.displayName) (\(user.email))")
            HStack {
                Button("Sync Now") { Task { await cloud.syncNow() } }
                    .disabled(!store.settings.syncEnabled || cloud.isSyncing)
                if cloud.isSyncing { ProgressView().controlSize(.small) }
                if let date = cloud.lastSyncDate {
                    Text("Last sync \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") { Task { await cloud.signOut() } }
            }
            if let message = cloud.lastSyncError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            DisclosureGroup("Recovery key") {
                Text("Your synced data is end-to-end encrypted. Keep this key to restore it on another Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(cloud.recoveryKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cloud.recoveryKey, forType: .string)
                    }
                }
                HStack {
                    TextField("Paste a recovery key from another Mac", text: $recovery)
                    Button("Use Key") {
                        error = cloud.restore(recoveryKey: recovery) ? nil : "Invalid recovery key"
                    }
                }
            }
        } else {
            TextField("Email", text: $email)
            SecureField("Password", text: $password)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Toggle("Create a new account", isOn: $isRegistering)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(isRegistering ? "Create Account" : "Sign In") { submit(cloud) }
                    .disabled(email.isEmpty || password.count < 8 || store.settings.cloudServerURL.isEmpty || isWorking)
            }
        }
    }

    private func submit(_ cloud: ArrowCloud) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                if isRegistering {
                    try await cloud.register(email: email, password: password, displayName: "")
                } else {
                    try await cloud.signIn(email: email, password: password)
                }
                error = nil
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
