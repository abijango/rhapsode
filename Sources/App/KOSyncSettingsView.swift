import SwiftUI

/// Settings for KOReader Progress Sync (Path 3).
struct KOSyncSettingsView: View {
    @State private var enabled = KOSyncSettings.isEnabled
    @State private var serverURL = KOSyncSettings.serverURL
    @State private var username = KOSyncSettings.username
    @State private var password = ""
    @State private var strategy = KOSyncSettings.strategy
    @State private var deviceName = KOSyncSettings.deviceName
    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var hasUserkey = KOSyncSettings.userkey != nil

    var body: some View {
        Form {
            Section {
                Toggle("Enable KOReader Sync", isOn: $enabled)
                    .onChange(of: enabled) { _, v in KOSyncSettings.isEnabled = v }
            } footer: {
                Text("Sync ebook reading position with KOReader, CrossInk, and other KOSync clients. Audiobook progress still uses your library source.")
            }

            Section {
                TextField("Server URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: serverURL) { _, v in KOSyncSettings.serverURL = v }
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: username) { _, v in KOSyncSettings.username = v }
                SecureField(hasUserkey ? "Password (saved — type to change)" : "Password", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("Default server is https://sync.koreader.rocks (often unreliable). For a local or self-hosted server, use something like http://192.168.1.10:7200. Password is stored as MD5 (KOReader userkey) in the Keychain.")
            }

            Section("Conflict strategy") {
                Picker("When positions differ", selection: $strategy) {
                    ForEach(KOSyncSettings.Strategy.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .onChange(of: strategy) { _, v in KOSyncSettings.strategy = v }
            }

            Section("This device") {
                TextField("Device name", text: $deviceName)
                    .onChange(of: deviceName) { _, v in KOSyncSettings.deviceName = v }
                LabeledContent("Device ID") {
                    Text(KOSyncSettings.deviceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("Sign In / Register")
                    }
                }
                .disabled(isBusy || serverURL.isEmpty || username.isEmpty || (password.isEmpty && !hasUserkey))

                if hasUserkey {
                    Button("Clear saved credentials", role: .destructive) {
                        KOSyncSettings.clearCredentials()
                        hasUserkey = false
                        password = ""
                        statusMessage = "Credentials cleared."
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("KOReader Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testConnection() async {
        isBusy = true
        defer { isBusy = false }
        KOSyncSettings.serverURL = serverURL
        KOSyncSettings.username = username
        KOSyncSettings.deviceName = deviceName

        let pass: String
        if !password.isEmpty {
            pass = password
            KOSyncSettings.setPassword(password)
            hasUserkey = true
        } else if let key = KOSyncSettings.userkey {
            // Re-auth with existing userkey by wrapping a client that already has the key.
            let client = KOSyncClient(
                serverURL: serverURL,
                username: username,
                userkey: key
            )
            // Probe with getProgress on a dummy hash — better: use connect with password.
            // Without password we can only GET with stored key.
            do {
                _ = try await client.getProgress(documentHash: String(repeating: "0", count: 32))
                statusMessage = "Connected with saved credentials."
                KOSyncSettings.isEnabled = true
                enabled = true
            } catch {
                statusMessage = "Saved credentials failed: \(error.localizedDescription). Enter password again."
            }
            return
        } else {
            statusMessage = "Enter a password."
            return
        }

        let client = KOSyncClient(
            serverURL: serverURL,
            username: username,
            userkey: KOSyncSettings.userkey ?? ""
        )
        let result = await client.connect(username: username, password: pass)
        statusMessage = result.message
        if result.success {
            KOSyncSettings.isEnabled = true
            enabled = true
            password = ""
        }
    }
}
