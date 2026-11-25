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
        }
        .confirmationDialog("Remove \(dest.name)?", isPresented: $confirmRemove) {
            Button("Remove Destination", role: .destructive) { syncer.removeDestination(dest.id) }
        } message: {
            Text("Photos already copied there are not deleted. PhotoSyncer simply stops using this destination.")
        }
    }
}

private struct SFTPForm: View {
    @ObservedObject var syncer: SyncEngine
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var host = ""
    @State private var port = 22
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = "/photos"
    @State private var testing = false
    @State private var testedKey: String?
    @State private var message: String?
    @State private var messageIsError = false

    private var valid: Bool { !host.isEmpty && !username.isEmpty && !password.isEmpty && port > 0 }

    private func draft() -> Destination {
        Destination(name: name.isEmpty ? host : name, kind: .sftp, host: host.trimmingCharacters(in: .whitespaces),
                    port: port, username: username, remotePath: remotePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add SFTP Server").font(.headline)
            Form {
                TextField("Name (optional)", text: $name)
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                TextField("Remote folder", text: $remotePath, prompt: Text("/photos"))
            }
            .formStyle(.grouped)

            if let message {
                Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .green)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button(testing ? "Testing…" : "Test Connection") { Task { await test() } }
                    .disabled(!valid || testing)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(testedKey == nil || testing)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: host) { testedKey = nil }
        .onChange(of: port) { testedKey = nil }
        .onChange(of: username) { testedKey = nil }
        .onChange(of: password) { testedKey = nil }
        .onChange(of: remotePath) { testedKey = nil }
    }

    private func test() async {
        testing = true; message = nil
        let result = await syncer.testSFTP(draft(), password: password)
        testing = false
        switch result {
        case .success(let r):
            testedKey = r.key
            messageIsError = false
            message = "Connected – \(r.files) file(s) in the folder.\nServer key \(HostKey.fingerprint(r.key)). Adding trusts this key; a different key later will be refused."
        case .failure(let e):
            testedKey = nil
            messageIsError = true
            message = e.localizedDescription
        }
    }

    private func add() {
        var d = draft()
        d.trustedHostKey = testedKey
        syncer.addSFTPDestination(d, password: password)
        isPresented = false
    }
}

private struct SMBForm: View {
    @ObservedObject var syncer: SyncEngine
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var host = ""
    @State private var share = ""
    @State private var folder = "photos"
    @State private var port = Destination.defaultSMBPort
    @State private var guest = false
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var tested = false
    @State private var message: String?
    @State private var messageIsError = false

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ ")).isEmpty
            && port > 0
            && (guest || (!username.isEmpty && !password.isEmpty))
    }

    private func draft() -> Destination {
        let h = host.trimmingCharacters(in: .whitespaces)
        let s = share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
        return Destination(name: name.isEmpty ? "\(h)/\(s)" : name, kind: .smb, host: h, port: port,
                           username: guest ? "" : username, remotePath: folder, share: s, guest: guest ? true : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add SMB Share").font(.headline)
            Form {
                TextField("Name (optional)", text: $name)
                TextField("Server", text: $host, prompt: Text("nas.local or 192.168.1.20"))
                TextField("Share", text: $share, prompt: Text("Photos"))
                TextField("Folder in share", text: $folder, prompt: Text("photos (blank = share root)"))
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Connect as guest", isOn: $guest)
                if !guest {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }
            }
            .formStyle(.grouped)

            if let message {
                Text(message).font(.caption).foregroundStyle(messageIsError ? .red : .green)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button(testing ? "Testing…" : "Test Connection") { Task { await test() } }
                    .disabled(!valid || testing)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!tested || testing)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: host) { tested = false }
        .onChange(of: share) { tested = false }
        .onChange(of: folder) { tested = false }
        .onChange(of: port) { tested = false }
        .onChange(of: guest) { tested = false }
        .onChange(of: username) { tested = false }
        .onChange(of: password) { tested = false }
    }

    private func test() async {
        testing = true; message = nil
        let result = await syncer.testSMB(draft(), password: password)
        testing = false
        switch result {
        case .success(let files):
            tested = true
            messageIsError = false
            message = "Connected – \(files) file(s) in the folder."
        case .failure(let e):
            tested = false
            messageIsError = true
            message = e.localizedDescription
        }
    }

    private func add() {
        syncer.addSMBDestination(draft(), password: password)
        isPresented = false
    }
}
