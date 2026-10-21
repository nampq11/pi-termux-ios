import SwiftUI

// Native port of spaces.html: device pairing (prepare form, enroll with QR
// content or token), the key action buttons, and space connection. The web
// page's labels are German; the native app uses English throughout.

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
            Section("Pair device") {
                TextField("Own NetBird peer ID", text: $peerId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Trusted control host ID", text: $controlHostId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Control endpoint", text: $controlEndpoint, prompt: Text("tcp://100.x.x.x:PORT"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Create device key") {
                    Task {
                        _ = await spaces.call("prepare", body: [
                            "peerId": peerId,
                            "controlHostId": controlHostId,
                            "endpoint": controlEndpoint
                        ])
                    }
                }
                .disabled(spaces.running || peerId.isEmpty || controlHostId.isEmpty || controlEndpoint.isEmpty)
                TextField("Enrollment QR content or token", text: $enrollToken, axis: .vertical)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Pair") {
                    // The input is cleared on submit like the web page.
                    let value = enrollToken
                    enrollToken = ""
                    Task { await spaces.enroll(value) }
                }
                .disabled(spaces.running || enrollToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                actionButton("Check pairing status", "enrollStatus", spaces)
                actionButton("Prove key possession", "authenticate", spaces)
                actionButton("Rotate key", "rotate", spaces)
                actionButton("Check rotation", "rotationStatus", spaces)
            }
            Section("Connect space") {
                TextField("Trusted data host ID", text: $dataHostId)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Data endpoint", text: $dataEndpoint, prompt: Text("tcp://100.x.x.x:PORT"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Space ID or alias", text: $dataSpace)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save host and space") {
                    Task {
                        _ = await spaces.call("dataHost", body: [
                            "hostId": dataHostId,
                            "endpoint": dataEndpoint,
                            "space": dataSpace
                        ])
                    }
                }
                .disabled(spaces.running || dataHostId.isEmpty || dataEndpoint.isEmpty || dataSpace.isEmpty)
                actionButton("Show space and objects", "objects", spaces)
                NavigationLink {
                    SpaceCtlView()
                } label: {
                    Label("Control runs, workers and operations", systemImage: "switch.2")
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
