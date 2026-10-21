import SwiftUI

// Native port of spaces.html: device pairing (prepare form, enroll with QR
// content or token), the key action buttons, and space connection. Labels
// stay German like the web page; only "Android Keystore" is dropped from the
// prepare button since this is the iOS app.

struct SpacesView: View {
    @Environment(AppModel.self) private var model
    @State private var peerId = ""
    @State private var controlHostId = ""
    @State private var controlEndpoint = ""
    @State private var enrollToken = ""
    @State private var dataHostId = ""
    @State private var dataEndpoint = ""
    @State private var dataSpace = ""

    var body: some View {
        let spaces = model.spaces
        Form {
            Section("Gerät koppeln") {
                TextField("Eigene NetBird Peer-ID", text: $peerId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Vertrauenswürdige Control Host-ID", text: $controlHostId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Control-Endpunkt", text: $controlEndpoint, prompt: Text("tcp://100.x.x.x:PORT"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Geräteschlüssel anlegen") {
                    Task {
                        _ = await spaces.call("prepare", body: [
                            "peerId": peerId,
                            "controlHostId": controlHostId,
                            "endpoint": controlEndpoint
                        ])
                    }
                }
                .disabled(spaces.running || peerId.isEmpty || controlHostId.isEmpty || controlEndpoint.isEmpty)
                TextField("Enrollment-QR-Inhalt oder Token", text: $enrollToken, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Koppeln") {
                    // The input is cleared on submit like the web page.
                    let value = enrollToken
                    enrollToken = ""
                    Task { await spaces.enroll(value) }
                }
                .disabled(spaces.running || enrollToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                actionButton("Kopplungsstatus prüfen", "enrollStatus", spaces)
                actionButton("Schlüsselbeweis prüfen", "authenticate", spaces)
                actionButton("Schlüssel rotieren", "rotate", spaces)
                actionButton("Rotation auswerten", "rotationStatus", spaces)
            }
            Section("Space verbinden") {
                TextField("Vertrauenswürdige Data Host-ID", text: $dataHostId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Data-Endpunkt", text: $dataEndpoint, prompt: Text("tcp://100.x.x.x:PORT"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Space-ID oder Alias", text: $dataSpace)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Host und Space speichern") {
                    Task {
                        _ = await spaces.call("dataHost", body: [
                            "hostId": dataHostId,
                            "endpoint": dataEndpoint,
                            "space": dataSpace
                        ])
                    }
                }
                .disabled(spaces.running || dataHostId.isEmpty || dataEndpoint.isEmpty || dataSpace.isEmpty)
                actionButton("Space und Objekte anzeigen", "objects", spaces)
                NavigationLink {
                    SpaceCtlView()
                } label: {
                    Label("Läufe, Worker und Vorgänge steuern", systemImage: "switch.2")
                }
            }
            if !spaces.message.isEmpty || spaces.result != nil {
                Section {
                    if !spaces.message.isEmpty {
                        Text(spaces.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let result = spaces.result {
                        Text(result)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Spaces")
        .navigationBarTitleDisplayMode(.inline)
        .task { await spaces.call("status") }
    }

    private func actionButton(_ title: String, _ action: String, _ spaces: SpacesModel) -> some View {
        Button(title) {
            Task { _ = await spaces.call(action) }
        }
        .disabled(spaces.running)
    }
}
