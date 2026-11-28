import SwiftUI

struct DestinationsView: View {
    @ObservedObject var syncer: SyncEngine
    @State private var showSFTP = false
    @State private var showSMB = false

    var body: some View {
        Form {
            Section("Destinations") {
                if syncer.destinations.isEmpty {
                    Text("No destination yet. Add a folder (local disk, USB drive, mounted NAS share), an SMB share, or an SFTP server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(syncer.destinations) { d in
                    DestinationRow(syncer: syncer, dest: d)
                }
                HStack {
                    Button("Add Folder…") { syncer.addFolderDestination() }
                    Button("Add SMB Share…") { showSMB = true }
                    Button("Add SFTP Server…") { showSFTP = true }
                }
                .disabled(syncer.isSyncing)
                if syncer.isVerifying {
                    Text("Destination changes are locked while file verification is running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keep destinations in sync") {
                Toggle("Keep destinations in sync with each other", isOn: $syncer.mirrorEnabled)
                Text("Files missing from one destination are copied from another, so all destinations converge to the same set of photos, even after one was offline. Copies are checked against their checksums, matched by content (not name), and never delete anything. A file you delete from one destination will be restored from another.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Label {
                    Text("With several destinations, “Delete from iCloud” waits until a photo is copied and verified on every enabled destination, and all of them are online.")
                        .font(.caption)
                } icon: { Image(systemName: "info.circle") }
                Label {
                    Text("SMB shares are connected with macOS's built-in SMB client (the same one Finder uses), and the password is stored in your Keychain.")
                        .font(.caption)
                } icon: { Image(systemName: "network") }
                Label {
                    Text("SFTP is encrypted. The server's host key is pinned the first time you connect, and the password is stored in your Keychain.")
                        .font(.caption)
                } icon: { Image(systemName: "lock.shield") }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSFTP) { SFTPForm(syncer: syncer, isPresented: $showSFTP) }
        .sheet(isPresented: $showSMB) { SMBForm(syncer: syncer, isPresented: $showSMB) }
    }
}

private struct DestinationRow: View {
    @ObservedObject var syncer: SyncEngine
    let dest: Destination
    @State private var confirmRemove = false

    private var status: String { dest.enabled ? (syncer.destStatus[dest.key] ?? "Not checked yet") : "Disabled" }
    private var statusColor: Color {
        if status.hasPrefix("Error") { return .red }
        if status.hasPrefix("Waiting") { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { dest.enabled }, set: { syncer.setEnabled(dest.id, $0) }))
                .labelsHidden()
                .disabled(syncer.isSyncing)
            VStack(alignment: .leading, spacing: 2) {
                Text(dest.name).fontWeight(.semibold)
                Text(dest.summary).font(.caption).foregroundStyle(.secondary)
                Text(status).font(.caption).foregroundStyle(statusColor)
                if dest.kind == .sftp, let key = dest.trustedHostKey {
                    Text("Host key \(HostKey.fingerprint(key))")
                        .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
            Spacer()
            Menu {
                if dest.kind == .sftp && dest.trustedHostKey != nil {
                    Button("Forget Host Key") { syncer.forgetHostKey(dest.id) }
                }
                Button("Remove…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(syncer.isSyncing)
        }
        .confirmationDialog("Remove \(dest.name)?", isPresented: $confirmRemove) {
            Button("Remove Destination", role: .destructive) { syncer.removeDestination(dest.id) }
        } message: {
            Text("Photos already copied there are not deleted. PhotoSyncer simply stops using this destination.")
        }
    }
}

private struct SFTPForm: View {
    private enum Step {
        case connect
        case browse
    }

    @ObservedObject var syncer: SyncEngine
    @Binding var isPresented: Bool

    @StateObject private var browser = SFTPBrowseSession()
    @State private var step: Step = .connect
    @State private var serverInput = ""
    @State private var port = Destination.defaultSFTPPort
    @State private var showAdvancedPort = false
    @State private var username = ""
    @State private var password = ""
    @State private var customName = ""

    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showGoToPathSheet = false
    @State private var goToPathInput = ""
    @State private var recordEnteredPathInSidebar = false
    @State private var isAdding = false

    private var canConnect: Bool {
        let ep = SFTPServerEndpoint.parse(serverInput, defaultPort: port)
        let resolvedUser = username.trimmingCharacters(in: .whitespaces).isEmpty
            ? (ep?.usernameHint ?? "")
            : username.trimmingCharacters(in: .whitespaces)
        return ep != nil && port > 0 && !resolvedUser.isEmpty && !password.isEmpty && !browser.isConnecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .connect:
                connectStepView
            case .browse:
                browseStepView
            }
        }
        .padding(20)
        .frame(width: step == .connect ? 460 : 620)
        .onDisappear {
            let session = browser
            Task { await session.cleanup() }
        }
        .alert("New Folder", isPresented: $showNewFolderSheet) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let target = newFolderName
                newFolderName = ""
                Task { _ = await browser.createSubfolder(named: target) }
            }
        } message: {
            Text("Create a new folder inside “\(browser.currentPath)”.")
        }
        .alert("Go to Remote Folder", isPresented: $showGoToPathSheet) {
            TextField("Path (e.g. /volume1/Photos or ~/Photos)", text: $goToPathInput)
            Button("Cancel", role: .cancel) { goToPathInput = "" }
            Button("Open") {
                let target = goToPathInput
                let pin = recordEnteredPathInSidebar
                goToPathInput = ""
                Task {
                    _ = await browser.selectPath(target, scanSubfolders: false, recordLocation: pin)
                }
            }
        } message: {
            Text("Enter an absolute path (starting with “/”), “~/” home-relative path, or subfolder name on \(browser.connectedHost).")
        }
    }

    // MARK: Step 1 – Connect to SFTP Server
    private var connectStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to SFTP Server").font(.headline)
                    Text("Enter your server's IP address or hostname and SSH login to browse its folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Form {
                    TextField("Server Address", text: $serverInput, prompt: Text("nas.local or 192.168.1.20"))
                        .onChange(of: serverInput) {
                            if let ep = SFTPServerEndpoint.parse(serverInput, defaultPort: port) {
                                if username.isEmpty, let hintedUser = ep.usernameHint {
                                    username = hintedUser
                                }
                            }
                        }

                    TextField("Name", text: $username, prompt: Text("SSH Username"))
                    SecureField("Password", text: $password)

                    if showAdvancedPort {
                        TextField("Port", value: $port, format: .number.grouping(.never))
                    }
                }
                .formStyle(.columns)

                Button {
                    showAdvancedPort.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvancedPort ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                        Text("Advanced")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )

            if let err = browser.errorMessage {
                Label {
                    Text(err)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    browser.cancelConnect()
                    isPresented = false
                }
                Spacer()
                if browser.isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Connect") {
                    submitConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submitConnect() {
        guard canConnect else { return }
        Task {
            if await browser.connect(
                serverInput: serverInput,
                port: port,
                username: username,
                password: password
            ) {
                step = .browse
            }
        }
    }

    // MARK: Step 2 – Browse Remote Folders
    private var browseStepView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Select a Folder on \(browser.connectedHost)")
                        .font(.headline)
                    Text("Connected as \(browser.connectedUsername) · Host key \(browser.hostKeyFingerprint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("Adding this destination pins SSH host key \(browser.hostKeyFingerprint); a different key later will be refused.")
                }
                Spacer()
                Button {
                    browser.loadSubfolders()
                } label: {
                    Label("Refresh Subfolders", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Load or refresh subfolders")
                .disabled(!browser.isReady || browser.isLoadingFolder || browser.isScanningSubfolders)
            }

            HStack(spacing: 0) {
                // Left column: Quick-jump Locations (Home, Root, and custom paths)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Locations")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            goToPathInput = ""
                            recordEnteredPathInSidebar = true
                            showGoToPathSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Jump to a remote folder path and add it to Locations")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(browser.sidebarLocations) { loc in
                                let isSelected = browser.currentPath == loc.path
                                Button {
                                    guard browser.currentPath != loc.path else { return }
                                    Task { _ = await browser.selectPath(loc.path, scanSubfolders: false) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: loc.systemImage)
                                            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                            .frame(width: 15)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(loc.title)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                            if loc.title != loc.path {
                                                Text(loc.path)
                                                    .font(.caption2)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.accentColor : Color.clear)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                    }

                    if browser.hasHiddenSubfolders || browser.showHiddenFolders {
                        Divider()
                        Toggle("Show hidden (.)", isOn: $browser.showHiddenFolders)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .frame(width: 195)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Right column: Breadcrumb path + remote subfolders
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(Array(browser.breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                                    if idx > 0 {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    let isLast = idx == browser.breadcrumbs.count - 1
                                    Button {
                                        Task { _ = await browser.selectPath(crumb.fullPath, scanSubfolders: false) }
                                    } label: {
                                        if idx == 0 {
                                            HStack(spacing: 2) {
                                                Image(systemName: "internaldrive")
                                                Text("/")
                                                    .fontWeight(isLast ? .semibold : .regular)
                                            }
                                            .font(.caption)
                                        } else {
                                            Text(crumb.label)
                                                .font(.caption)
                                                .fontWeight(isLast ? .semibold : .regular)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isLast || browser.isLoadingFolder)
                                }
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 6)

                        Button {
                            goToPathInput = ""
                            recordEnteredPathInSidebar = false
                            showGoToPathSheet = true
                        } label: {
                            Label("Go to Path…", systemImage: "arrow.right.doc.on.clipboard")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .disabled(!browser.isReady || browser.isLoadingFolder)

                        Button {
                            newFolderName = ""
                            showNewFolderSheet = true
                        } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .disabled(!browser.isReady || !browser.isWritable || browser.isLoadingFolder)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    Divider()

                    if browser.isLoadingFolder {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Opening folder…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !browser.isReady {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("Could not open “\(browser.currentPath)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if let parent = browser.parentPath {
                                    let parentLabel = parent == "/" ? "/" : URL(fileURLWithPath: parent).lastPathComponent
                                    Button {
                                        Task { await browser.navigateUp() }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "arrow.turn.left.up")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 16)
                                            Text("Back to “\(parentLabel)”")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .font(.callout)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.vertical, 2)
                                }

                                if browser.subfolders.isEmpty {
                                    if browser.isScanningSubfolders {
                                        VStack(spacing: 8) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Looking for subfolders…")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Text("You can click Add now to sync into “\(browser.currentPath)”.")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 40)
                                        .padding(.horizontal, 16)
                                    } else if !browser.hasScannedCurrentFolder {
                                        VStack(spacing: 10) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.green)
                                            Text("“\(browser.currentPath)” is ready")
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text("Click Add below to sync photos directly here, create a New Folder…, or load existing subfolders.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.center)
                                            Button("Browse Subfolders") {
                                                browser.loadSubfolders()
                                            }
                                            .controlSize(.small)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 34)
                                        .padding(.horizontal, 16)
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "folder")
                                                .font(.title2)
                                                .foregroundStyle(.tertiary)
                                            Text("No subfolders inside “\(browser.currentFolderDisplayName)”.")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Text("Click Add to sync photos here, or New Folder… to create a subfolder.")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 44)
                                        .padding(.horizontal, 16)
                                    }
                                } else {
                                    ForEach(browser.subfolders, id: \.self) { folder in
                                        Button {
                                            Task { await browser.openSubfolder(folder) }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: "folder.fill")
                                                    .foregroundStyle(Color.accentColor)
                                                    .frame(width: 16)
                                                Text(folder)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .contentShape(Rectangle())
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(Color.primary.opacity(0.03))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )

            // Selected destination summary + optional custom label
            VStack(alignment: .leading, spacing: 8) {
                if let err = browser.errorMessage {
                    Label {
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                } else if browser.isReady && browser.isWritable {
                    Label {
                        Text("Sync into \(browser.targetPreviewURLString) · Host key pinned on Add")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 8) {
                    Text("Display name:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(browser.defaultDestinationName, text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isAdding)

                Button("Back") {
                    Task {
                        await browser.resetToServerStep()
                        step = .connect
                    }
                }
                .disabled(isAdding)

                Spacer()

                Button(isAdding ? "Adding…" : "Add") {
                    addSelectedDestination()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!browser.isReady || !browser.isWritable || browser.isLoadingFolder || isAdding)
            }
        }
    }

    private func addSelectedDestination() {
        guard let built = browser.buildDestination(customName: customName) else { return }
        let cand = built.destination
        let alreadyExists = syncer.destinations.contains { existing in
            existing.kind == .sftp
                && existing.host.caseInsensitiveCompare(cand.host) == .orderedSame
                && existing.port == cand.port
                && SFTPPath.normalize(existing.remotePath) == SFTPPath.normalize(cand.remotePath)
        }
        if alreadyExists {
            browser.errorMessage = "That SFTP folder is already added as a destination."
            return
        }
        isAdding = true
        Task {
            await browser.cleanup()
            syncer.addSFTPDestination(cand, password: built.password)
            isAdding = false
            isPresented = false
        }
    }
}

private struct SMBForm: View {
    private enum Step {
        case connect
        case browse
    }

    @ObservedObject var syncer: SyncEngine
    @Binding var isPresented: Bool

    @StateObject private var browser = SMBBrowseSession()
    @State private var step: Step = .connect
    @State private var serverInput = ""
    @State private var port = Destination.defaultSMBPort
    @State private var showAdvancedPort = false
    @State private var guest = false
    @State private var username = ""
    @State private var password = ""
    @State private var customName = ""

    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showGoToFolderSheet = false
    @State private var goToFolderPath = ""
    @State private var showManualShareSheet = false
    @State private var manualShareName = ""
    @State private var isAdding = false

    private var canConnect: Bool {
        let hasServer = SMBServerEndpoint.parse(serverInput, defaultPort: port) != nil
        let hasAuth = guest || (!username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty)
        return hasServer && port > 0 && hasAuth && !browser.isConnecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .connect:
                connectStepView
            case .browse:
                browseStepView
            }
        }
        .padding(20)
        .frame(width: step == .connect ? 460 : 620)
        .onDisappear {
            let session = browser
            Task { await session.cleanup() }
        }
        .alert("New Folder", isPresented: $showNewFolderSheet) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let target = newFolderName
                newFolderName = ""
                Task { _ = await browser.createSubfolder(named: target) }
            }
        } message: {
            Text("Create a new folder inside “\(browser.pathComponents.last ?? browser.selectedShare ?? "share")”.")
        }
        .alert("Go to Subfolder", isPresented: $showGoToFolderSheet) {
            TextField("Subfolder path (e.g. Photos/2026)", text: $goToFolderPath)
            Button("Cancel", role: .cancel) { goToFolderPath = "" }
            Button("Open") {
                let target = goToFolderPath
                goToFolderPath = ""
                Task { _ = await browser.openSubfolderPath(target) }
            }
        } message: {
            Text("Open an existing subfolder inside “\(browser.pathComponents.last ?? browser.selectedShare ?? "share")” directly without scanning sibling files.")
        }
        .alert("Enter Share Name", isPresented: $showManualShareSheet) {
            TextField("Share name", text: $manualShareName)
            Button("Cancel", role: .cancel) { manualShareName = "" }
            Button("Open Share") {
                let target = manualShareName
                manualShareName = ""
                Task { await browser.addManualShare(target) }
            }
        } message: {
            Text("If a shared folder on \(browser.connectedHost) is hidden from browsing (browseable = no), enter its name directly.")
        }
    }

    // MARK: Step 1 – Connect to Server
    private var connectStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to SMB Server").font(.headline)
                    Text("Enter your server's IP address or hostname to browse its shared folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Form {
                    TextField("Server Address", text: $serverInput, prompt: Text("nas.local or 192.168.1.20"))
                        .onChange(of: serverInput) {
                            if let ep = SMBServerEndpoint.parse(serverInput, defaultPort: port) {
                                if username.isEmpty, let hintedUser = ep.usernameHint {
                                    username = hintedUser
                                }
                            }
                        }

                    Picker("Connect As", selection: $guest) {
                        Text("Registered User").tag(false)
                        Text("Guest").tag(true)
                    }
                    .pickerStyle(.radioGroup)

                    if !guest {
                        TextField("Name", text: $username, prompt: Text("Username"))
                        SecureField("Password", text: $password)
                    }

                    if showAdvancedPort {
                        TextField("Port", value: $port, format: .number.grouping(.never))
                    }
                }
                .formStyle(.columns)

                Button {
                    showAdvancedPort.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAdvancedPort ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                        Text("Advanced")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )

            if let err = browser.errorMessage {
                Label {
                    Text(err)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    browser.cancelConnect()
                    isPresented = false
                }
                Spacer()
                if browser.isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Connect") {
                    submitConnect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submitConnect() {
        guard canConnect else { return }
        Task {
            if await browser.connect(
                serverInput: serverInput,
                port: port,
                guest: guest,
                username: username,
                password: password
            ) {
                step = .browse
                if browser.visibleShares.isEmpty && browser.enumerationUnsupported {
                    DispatchQueue.main.async {
                        manualShareName = ""
                        showManualShareSheet = true
                    }
                }
            }
        }
    }

    // MARK: Step 2 – Browse Shares & Subfolders
    private var browseStepView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Select a Folder on \(browser.connectedHost)")
                        .font(.headline)
                    Text(browser.connectedGuest ? "Connected as Guest" : "Connected as \(browser.connectedUsername)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    browser.loadSubfolders(exhaustive: false)
                } label: {
                    Label("Refresh Subfolders", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Load or refresh subfolders")
                .disabled(!browser.isMountedReady || browser.isLoadingShare || browser.isScanningSubfolders)
            }

            HStack(spacing: 0) {
                // Left column: Shared volumes on the server
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Shared Volumes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            manualShareName = ""
                            showManualShareSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Enter an unbrowsable share name manually")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider()

                    if browser.visibleShares.isEmpty {
                        VStack(spacing: 8) {
                            Text(
                                browser.enumerationUnsupported
                                ? "Connected to \(browser.connectedHost), but this server doesn’t list shares automatically."
                                : (browser.hasHiddenShares
                                    ? "Only hidden ($) shares were returned. Show hidden shares below or enter a share name."
                                    : "No browsable shares returned by server.")
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            Button("Enter Share Name…") {
                                manualShareName = ""
                                showManualShareSheet = true
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(browser.visibleShares) { share in
                                    let isSelected = browser.selectedShare == share.name
                                    Button {
                                        guard browser.selectedShare != share.name else { return }
                                        Task { await browser.selectShare(share.name) }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "externaldrive.connected.to.line.below")
                                                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                            Text(share.displayName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? Color.accentColor : Color.clear)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(6)
                        }
                    }

                    if browser.hasHiddenShares {
                        Divider()
                        Toggle("Show hidden ($)", isOn: $browser.showHiddenShares)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .frame(width: 195)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Right column: Breadcrumb path + subfolders inside selected share
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if let share = browser.selectedShare {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 4) {
                                    Button {
                                        Task { await browser.navigateToDepth(0) }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "externaldrive")
                                            Text(share)
                                                .fontWeight(browser.pathComponents.isEmpty ? .semibold : .regular)
                                        }
                                        .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(browser.pathComponents.isEmpty || browser.isLoadingShare)

                                    ForEach(Array(browser.pathComponents.enumerated()), id: \.offset) { idx, part in
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        let isLast = idx == browser.pathComponents.count - 1
                                        Button(part) {
                                            Task { await browser.navigateToDepth(idx + 1) }
                                        }
                                        .font(.caption)
                                        .fontWeight(isLast ? .semibold : .regular)
                                        .buttonStyle(.borderless)
                                        .disabled(isLast || browser.isLoadingShare)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No share selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 6)

                        if browser.isScanningSubfolders && !browser.subfolders.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .help("Scanning remaining subfolders…")
                        }

                        Button {
                            goToFolderPath = ""
                            showGoToFolderSheet = true
                        } label: {
                            Label("Go to Folder…", systemImage: "arrow.right.doc.on.clipboard")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .disabled(!browser.isMountedReady || browser.isLoadingShare)

                        Button {
                            newFolderName = ""
                            showNewFolderSheet = true
                        } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .disabled(!browser.isMountedReady || !browser.isWritable || browser.isLoadingShare)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)

                    Divider()

                    if browser.isLoadingShare {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Opening folder…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if browser.selectedShare == nil {
                        Text("Choose a shared volume on the left.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !browser.isMountedReady {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            Text("Could not open “\(browser.selectedShare ?? "")”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                if !browser.pathComponents.isEmpty {
                                    let parentName = browser.pathComponents.dropLast().last ?? (browser.selectedShare ?? "Share")
                                    Button {
                                        Task { await browser.navigateToDepth(browser.pathComponents.count - 1) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "arrow.turn.left.up")
                                                .foregroundStyle(.secondary)
                                                .frame(width: 16)
                                            Text("Back to “\(parentName)”")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .font(.callout)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.vertical, 2)
                                }

                                if browser.subfolders.isEmpty {
                                    if browser.isScanningSubfolders {
                                        VStack(spacing: 8) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Looking for subfolders…")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Text("You can click Add now to sync into “\(browser.pathComponents.last ?? browser.selectedShare ?? "")”.")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 40)
                                        .padding(.horizontal, 16)
                                    } else if !browser.hasScannedCurrentFolder {
                                        VStack(spacing: 10) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.green)
                                            Text("“\(browser.pathComponents.last ?? browser.selectedShare ?? "")” is ready")
                                                .font(.callout.weight(.medium))
                                            Text("Click Add below to sync photos directly here, create a New Folder…, or load existing subfolders.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.center)
                                            Button("Browse Subfolders") {
                                                browser.loadSubfolders(exhaustive: false)
                                            }
                                            .controlSize(.small)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 34)
                                        .padding(.horizontal, 16)
                                    } else if browser.scanStoppedDueToManyFiles {
                                        VStack(spacing: 8) {
                                            Image(systemName: "folder.badge.questionmark")
                                                .font(.title2)
                                                .foregroundStyle(.secondary)
                                            Text("Skipped thousands of files in “\(browser.pathComponents.last ?? browser.selectedShare ?? "")”")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Text("Click Add to sync here, Go to Folder… if you know the subfolder name, or scan all remaining entries.")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .multilineTextAlignment(.center)
                                            Button("Scan All Entries for Subfolders") {
                                                browser.loadSubfolders(exhaustive: true)
                                            }
                                            .controlSize(.small)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 30)
                                        .padding(.horizontal, 16)
                                    } else {
                                        VStack(spacing: 6) {
                                            Image(systemName: "folder")
                                                .font(.title2)
                                                .foregroundStyle(.tertiary)
                                            Text("No subfolders inside “\(browser.pathComponents.last ?? browser.selectedShare ?? "")”.")
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                            Text("Click Add to sync photos here, or New Folder… to create a subfolder.")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 44)
                                        .padding(.horizontal, 16)
                                    }
                                } else {
                                    ForEach(browser.subfolders, id: \.self) { folder in
                                        Button {
                                            Task { await browser.openSubfolder(folder) }
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: "folder.fill")
                                                    .foregroundStyle(Color.accentColor)
                                                    .frame(width: 16)
                                                Text(folder)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .contentShape(Rectangle())
                                            .background(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .fill(Color.primary.opacity(0.03))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    if browser.scanStoppedDueToManyFiles && !browser.isScanningSubfolders {
                                        Divider().padding(.vertical, 4)
                                        HStack {
                                            Text("Stopped early after skipping hundreds of files.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button("Scan Remaining") {
                                                browser.loadSubfolders(exhaustive: true)
                                            }
                                            .controlSize(.mini)
                                        }
                                        .padding(.horizontal, 8)
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )

            // Selected destination summary + optional custom label
            VStack(alignment: .leading, spacing: 8) {
                if let err = browser.errorMessage {
                    Label {
                        Text(err)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                } else if browser.isMountedReady && browser.isWritable {
                    Label {
                        Text("Sync into \(browser.targetPreviewURLString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 8) {
                    Text("Display name:")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(browser.defaultDestinationName, text: $customName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isAdding)

                Button("Back") {
                    Task {
                        await browser.resetToServerStep()
                        step = .connect
                    }
                }
                .disabled(isAdding)

                Spacer()

                Button(isAdding ? "Adding…" : "Add") {
                    addSelectedDestination()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!browser.isMountedReady || !browser.isWritable || browser.isLoadingShare || isAdding)
            }
        }
    }

    private func addSelectedDestination() {
        guard let built = browser.buildDestination(customName: customName) else { return }
        let cand = built.destination
        let alreadyExists = syncer.destinations.contains { existing in
            existing.kind == .smb
                && existing.host.caseInsensitiveCompare(cand.host) == .orderedSame
                && existing.port == cand.port
                && (existing.share ?? "").caseInsensitiveCompare(cand.share ?? "") == .orderedSame
                && existing.remotePath.caseInsensitiveCompare(cand.remotePath) == .orderedSame
        }
        if alreadyExists {
            browser.errorMessage = "That SMB folder is already added as a destination."
            return
        }
        isAdding = true
        Task {
            await browser.cleanup()
            syncer.addSMBDestination(cand, password: built.password)
            isAdding = false
            isPresented = false
        }
    }
}
