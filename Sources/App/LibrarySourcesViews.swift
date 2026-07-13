import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Add/Edit File Source (VidHub)

/// List of configured storages + toolbar **+** to add (matches VidHub Add/Edit File Source).
struct LibrarySourceSettingsView: View {
    @Environment(SyncManager.self) private var sync
    @State private var profiles: [SmbStorageProfile] = SmbConfig.profiles
    @State private var showAddStorage = false
    @State private var showRestartHint = false
    @State private var dropboxConnected = false

    var body: some View {
        List {
            if showRestartHint {
                Section {
                    Label("Quit and reopen Rhapsode to switch the active library source.",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if profiles.isEmpty {
                    Text("No SMB storage yet. Tap + to add.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        NavigationLink {
                            SmbStorageEditorView(profile: profile) {
                                reload()
                                showRestartHint = true
                            }
                        } label: {
                            storageRow(
                                title: profile.name,
                                subtitle: profile.listSubtitle,
                                isActive: SmbConfig.shouldUseSmb && SmbConfig.activeProfileId == profile.id
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                SmbConfig.deleteProfile(id: profile.id)
                                reload()
                                showRestartHint = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Use as active source") {
                                SmbConfig.setActive(id: profile.id)
                                reload()
                                showRestartHint = true
                            }
                            Button("Delete", role: .destructive) {
                                SmbConfig.deleteProfile(id: profile.id)
                                reload()
                                showRestartHint = true
                            }
                        }
                    }
                }
            } header: {
                Text("Added Storage")
            }

            Section {
                NavigationLink {
                    DropboxSourceEditView(onChanged: { showRestartHint = true })
                } label: {
                    storageRow(
                        title: "Dropbox",
                        subtitle: dropboxConnected ? "Connected" : "Not connected",
                        isActive: dropboxConnected
                            && !SmbConfig.shouldUseSmb
                            && !RhapsodeServerConfig.shouldUseServer,
                        systemImage: "shippingbox"
                    )
                }

                NavigationLink {
                    ServerSourceEditView(onChanged: { showRestartHint = true })
                } label: {
                    storageRow(
                        title: "Rhapsode Server",
                        subtitle: RhapsodeServerConfig.isConfigured ? "Configured · parked" : "Optional",
                        isActive: RhapsodeServerConfig.shouldUseServer,
                        systemImage: "server.rack"
                    )
                }
            } header: {
                Text("Other")
            }
        }
        .navigationTitle("Library Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddStorage = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showAddStorage) {
            AddStorageTypeView {
                showAddStorage = false
                reload()
                showRestartHint = true
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        profiles = SmbConfig.profiles
        dropboxConnected = ((try? KeychainTokenStore().load()) ?? nil) != nil
    }

    private func storageRow(
        title: String,
        subtitle: String,
        isActive: Bool,
        systemImage: String = "externaldrive.fill"
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Storage type picker

struct AddStorageTypeView: View {
    var onAdded: () -> Void

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SmbStorageEditorView(profile: SmbStorageProfile(name: "My SMB"), isNew: true) {
                        onAdded()
                    }
                } label: {
                    Label("Add SMB", systemImage: "externaldrive.connected.to.line.below")
                }
            } header: {
                Text("Network Storage")
            }

            Section {
                NavigationLink {
                    DropboxSourceEditView(onChanged: onAdded)
                } label: {
                    Label("Add Dropbox", systemImage: "shippingbox")
                }
            } header: {
                Text("Cloud")
            } footer: {
                Text("SMB is recommended for your Synology. Dropbox remains until SMB is solid.")
            }
        }
        .navigationTitle("Add Storage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Add / Edit SMB (VidHub Add Storage fields)

struct SmbStorageEditorView: View {
    @State var profile: SmbStorageProfile
    var isNew: Bool = false
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SyncManager.self) private var sync

    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    @State private var ok = false
    @State private var shareNames: [String] = []
    @StateObject private var browser = SmbNetworkBrowser()

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name, prompt: Text("My SMB"))
                TextField("Server", text: $profile.host, prompt: Text("192.168.8.200 or nas.local"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #if targetEnvironment(macCatalyst)
                    .textFieldStyle(.roundedBorder)
                    #endif
                TextField("Username", text: $profile.username, prompt: Text("Optional, leave empty for guest"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                SecureField("Password", text: $password, prompt: Text(passwordPrompt))
                    .textContentType(.password)
                TextField("Domain", text: $profile.domain, prompt: Text("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("SMB")
            } footer: {
                Text("Same fields as VidHub. Domain is usually empty on Synology. After saving, pick library folders.")
            }

            // Available shares on the entered server (after credentials)
            if !shareNames.isEmpty {
                Section {
                    ForEach(shareNames, id: \.self) { name in
                        Button {
                            profile.share = name
                        } label: {
                            HStack {
                                Image(systemName: profile.share == name
                                      ? "checkmark.circle.fill" : "externaldrive")
                                VStack(alignment: .leading) {
                                    Text(name)
                                    Text("Share on \(profile.host)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Shares on server")
                } footer: {
                    Text("Tap a share to select it (e.g. Storage).")
                }
            }

            // LAN discovery (VidHub “Available Shares”)
            Section {
                if browser.isBrowsing && browser.hosts.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Searching local network…")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(browser.hosts) { host in
                    Button {
                        profile.host = SmbConfig.sanitizeHost(host.host)
                        if profile.name == "My SMB" || profile.name.isEmpty {
                            profile.name = host.name
                        }
                        Task { await loadSharesOnServer() }
                    } label: {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                            VStack(alignment: .leading) {
                                Text(host.name)
                                Text(host.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if SmbConfig.sanitizeHost(profile.host)
                                .caseInsensitiveCompare(SmbConfig.sanitizeHost(host.host)) == .orderedSame {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                if !browser.isBrowsing {
                    Button("Search local network") {
                        browser.start()
                    }
                }
            } header: {
                Text("Available Shares")
            } footer: {
                Text("Devices advertising SMB on your LAN (Bonjour). Tap one to fill Server, then enter login to list shares.")
            }

            Section {
                NavigationLink {
                    SmbFolderPickerView(
                        title: "Audiobooks folder",
                        profile: profile,
                        password: password,
                        initialPath: profile.audiobooksPath
                    ) { path in
                        profile.audiobooksPath = path
                    }
                } label: {
                    LabeledContent("Audiobooks folder") {
                        Text(profile.audiobooksPath.isEmpty ? "Share root" : profile.audiobooksPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(profile.share.isEmpty)

                NavigationLink {
                    SmbFolderPickerView(
                        title: "Books folder",
                        profile: profile,
                        password: password,
                        initialPath: profile.booksPath
                    ) { path in
                        profile.booksPath = path
                    }
                } label: {
                    LabeledContent("Books folder") {
                        Text(profile.booksPath.isEmpty ? "Share root" : profile.booksPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(profile.share.isEmpty)
            } header: {
                Text("Library folders")
            } footer: {
                Text(profile.share.isEmpty
                     ? "Select a share above first."
                     : "Browse and tap “Use This Folder”.")
            }

            Section {
                Button {
                    Task { await saveAndTest(activate: false) }
                } label: {
                    HStack {
                        Text("Save & Test")
                        if busy { ProgressView() }
                        Spacer()
                        if ok {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .disabled(busy || profile.host.isEmpty)

                Button {
                    Task { await saveAndTest(activate: true) }
                } label: {
                    Text("Save & Use as Active Source")
                }
                .disabled(busy || profile.host.isEmpty || profile.share.isEmpty)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ok ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
            }

            if !isNew {
                Section {
                    Button("Delete Storage", role: .destructive) {
                        SmbConfig.deleteProfile(id: profile.id)
                        onSaved()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Add Storage" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") {
                    Task { await saveAndTest(activate: isNew || SmbConfig.profiles.isEmpty) }
                }
                .fontWeight(.semibold)
                .disabled(busy || profile.host.isEmpty)
            }
        }
        .onAppear {
            browser.start()
        }
        .onDisappear {
            browser.stop()
        }
        .onChange(of: profile.host) { _, _ in
            shareNames = []
        }
    }

    private var passwordPrompt: String {
        (try? SmbKeychain(profileId: profile.id).loadPassword()) != nil
            ? "•••••••• (saved)"
            : "Optional"
    }

    @MainActor
    private func loadSharesOnServer() async {
        guard !profile.host.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let names = try await SmbLibrarySource().listShareNames(
                profile: profile, password: password.isEmpty ? nil : password)
            shareNames = names
            if profile.share.isEmpty, names.contains("Storage") {
                profile.share = "Storage"
            }
            message = names.isEmpty ? "No shares returned." : "Select a share below."
            ok = !names.isEmpty
        } catch {
            message = error.localizedDescription
            ok = false
        }
    }

    @MainActor
    private func saveAndTest(activate: Bool) async {
        message = nil
        ok = false
        busy = true
        defer { busy = false }

        profile.host = SmbConfig.sanitizeHost(profile.host)
        profile.share = SmbConfig.sanitizeShare(profile.share)
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.name = profile.share.isEmpty ? "My SMB" : profile.share
        }

        if !password.isEmpty {
            do {
                try SmbKeychain(profileId: profile.id).savePassword(password)
            } catch {
                message = "Could not save password: \(error.localizedDescription)"
                return
            }
        }

        // Load shares if we have credentials but no share yet
        if profile.share.isEmpty {
            await loadSharesOnServer()
            if profile.share.isEmpty {
                message = (message ?? "") + "\nPick a share under “Shares on server”, then Save again."
                return
            }
        }

        do {
            let result = try await SmbLibrarySource().testConnection(
                profile: profile, password: password.isEmpty ? nil : password)
            SmbConfig.upsert(profile)
            if activate {
                SmbConfig.setActive(id: profile.id)
            } else if SmbConfig.activeProfileId == nil {
                SmbConfig.activeProfileId = profile.id
            }
            ok = true
            message = result
            onSaved()
            if activate || sync.source is SmbLibrarySource {
                // Only bootstrap if this launch is already on SMB
                if sync.source is SmbLibrarySource {
                    try? await sync.bootstrap()
                    await sync.ensureWatching()
                }
            }
            if isNew {
                dismiss()
            }
        } catch {
            ok = false
            message = error.localizedDescription
            // Still list shares for picking
            if let names = try? await SmbLibrarySource().listShareNames(
                profile: profile, password: password.isEmpty ? nil : password) {
                shareNames = names
            }
        }
    }
}

// MARK: - Folder browser

struct SmbFolderPickerView: View {
    let title: String
    var profile: SmbStorageProfile
    var password: String
    let initialPath: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pathComponents: [String] = []
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var errorText: String?

    private var currentPath: String {
        pathComponents.joined(separator: "/")
    }

    var body: some View {
        List {
            Section {
                Button {
                    onPick(currentPath)
                    dismiss()
                } label: {
                    Label(
                        currentPath.isEmpty ? "Use share root" : "Use “\(currentPath)”",
                        systemImage: "checkmark.circle.fill"
                    )
                }
            } footer: {
                Text("Relative to share “\(profile.share)”.")
            }

            if let errorText {
                Section {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                if loading {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                    }
                } else if folders.isEmpty {
                    Text("No subfolders here").foregroundStyle(.secondary)
                } else {
                    ForEach(folders, id: \.self) { name in
                        Button {
                            pathComponents.append(name)
                            Task { await load() }
                        } label: {
                            Label(name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            } header: {
                Text(currentPath.isEmpty ? "Folders" : currentPath)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !pathComponents.isEmpty {
                    Button("Up") {
                        _ = pathComponents.popLast()
                        Task { await load() }
                    }
                }
            }
        }
        .task {
            if pathComponents.isEmpty, !initialPath.isEmpty {
                pathComponents = initialPath.split(separator: "/").map(String.init)
            }
            await load()
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            folders = try await SmbLibrarySource().listSubdirectories(
                profile: profile,
                password: password.isEmpty ? nil : password,
                at: currentPath)
        } catch {
            folders = []
            errorText = error.localizedDescription
            if !pathComponents.isEmpty {
                pathComponents = []
                do {
                    folders = try await SmbLibrarySource().listSubdirectories(
                        profile: profile,
                        password: password.isEmpty ? nil : password,
                        at: "")
                    errorText = "Previous path not found — showing share root."
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Dropbox

struct DropboxSourceEditView: View {
    var onChanged: () -> Void
    @Environment(SyncManager.self) private var sync
    @State private var connected = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    private let keychain = KeychainTokenStore()

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: connected ? "Connected" : "Not connected")
                if !DropboxConfig.isConfigured {
                    Label("App key not set in DropboxConfig", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if SmbConfig.shouldUseSmb || RhapsodeServerConfig.shouldUseServer {
                    Text("Another source is active. Turn it off (or choose Use as Active on Dropbox after connect) and relaunch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if connected {
                    Button("Disconnect", role: .destructive) {
                        try? keychain.clear()
                        connected = false
                        onChanged()
                    }
                    Button("Use as active source") {
                        SmbConfig.preferSmb = false
                        RhapsodeServerConfig.preferServer = false
                        onChanged()
                    }
                } else {
                    Button {
                        connect()
                    } label: {
                        if isConnecting { ProgressView() } else { Text("Connect Dropbox") }
                    }
                    .disabled(isConnecting || !DropboxConfig.isConfigured)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Dropbox")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            connected = ((try? keychain.load()) ?? nil) != nil
        }
    }

    private func connect() {
        errorMessage = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let tokens = try await DropboxOAuth().connect()
                try keychain.save(tokens)
                connected = true
                SmbConfig.preferSmb = false
                RhapsodeServerConfig.preferServer = false
                onChanged()
                try await sync.bootstrap()
                await sync.requestNotificationPermission()
                await sync.ensureWatching()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Server (parked)

struct ServerSourceEditView: View {
    var onChanged: () -> Void
    @Environment(SyncManager.self) private var sync

    @State private var preferServer = RhapsodeServerConfig.preferServer
    @State private var serverURL = RhapsodeServerConfig.baseURLString
    @State private var homeURL = RhapsodeServerConfig.homeURLString
    @State private var serverToken = ""
    @State private var bootstrapSecret = ""
    @State private var showBootstrap = false
    @State private var busy = false
    @State private var message: String?
    @State private var ok = false
    private let serverKeychain = RhapsodeServerKeychain()

    var body: some View {
        Form {
            Section {
                Toggle("Use as active source", isOn: $preferServer)
                    .onChange(of: preferServer) { _, v in
                        RhapsodeServerConfig.preferServer = v
                        if v { SmbConfig.preferSmb = false }
                        onChanged()
                    }
            } footer: {
                Text("Optional / parked. Prefer SMB for day-to-day NAS access.")
            }

            Section {
                TextField("Remote URL", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Home URL", text: $homeURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Device API token", text: $serverToken)
                Button("Save & Test") { Task { await saveAndTest() } }
                    .disabled(busy)
                if let message {
                    Text(message).font(.footnote)
                        .foregroundStyle(ok ? Color.secondary : Color.red)
                }
            }

            Section {
                DisclosureGroup("First-time bootstrap", isExpanded: $showBootstrap) {
                    SecureField("Bootstrap secret", text: $bootstrapSecret)
                    Button("Bootstrap first device") { Task { await bootstrap() } }
                        .disabled(busy || bootstrapSecret.isEmpty)
                }
            }

            if sync.source is RhapsodeServerSource {
                Section("Index") {
                    Button("Reindex (incremental)") {
                        Task { await sync.reindexLibrary(full: false) }
                    }
                    .disabled(sync.isScanning)
                }
            }
        }
        .navigationTitle("Rhapsode Server")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func saveAndTest() async {
        busy = true
        defer { busy = false }
        message = nil
        ok = false
        RhapsodeServerConfig.baseURLString = serverURL
        RhapsodeServerConfig.homeURLString = homeURL
        RhapsodeServerConfig.preferServer = preferServer
        RhapsodeServerConfig.clearActiveBaseURL()
        if preferServer { SmbConfig.preferSmb = false }
        let pasted = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty {
            try? serverKeychain.saveToken(pasted)
            serverToken = ""
        }
        guard RhapsodeServerConfig.hasToken, !RhapsodeServerConfig.candidateURLs.isEmpty else {
            message = "Need URL + token."
            return
        }
        do {
            let client = RhapsodeServerClient()
            _ = try await client.resolveBaseURL(forceProbe: true)
            let me = try await client.me()
            ok = true
            message = "OK — \(me.deviceName)"
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func bootstrap() async {
        busy = true
        defer { busy = false }
        RhapsodeServerConfig.baseURLString = serverURL
        RhapsodeServerConfig.homeURLString = homeURL
        RhapsodeServerConfig.clearActiveBaseURL()
        do {
            #if canImport(UIKit)
            let name = UIDevice.current.name
            #else
            let name = "Rhapsode"
            #endif
            let client = RhapsodeServerClient()
            _ = try await client.bootstrap(
                deviceName: name,
                bootstrapToken: bootstrapSecret.trimmingCharacters(in: .whitespacesAndNewlines))
            bootstrapSecret = ""
            preferServer = true
            RhapsodeServerConfig.preferServer = true
            SmbConfig.preferSmb = false
            ok = true
            message = "Device created. Token saved."
            onChanged()
        } catch {
            message = error.localizedDescription
        }
    }
}
