import AppKit
import ArrowCore
import ArrowKit
import SwiftUI

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
