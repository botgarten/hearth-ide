import SwiftUI
import AppKit

/// Approving a GitLab/GitHub server and storing its read or write token, shared by the
/// CI/CD pane and the merge/pull requests in the Git pane.
struct CITokenSetupView: View {
    enum Purpose { case pipelines, changeRequests }

    @Environment(AppModel.self) private var model
    let remote: CIRemote?
    var purpose: Purpose = .pipelines
    var backTitle: String?
    var onBack: () -> Void = {}
    var onSaved: () -> Void = {}
    var onRevoke: () -> Void = {}

    @State private var writing: Bool
    @State private var tokenInput = ""
    @State private var error: String?

    init(remote: CIRemote?, purpose: Purpose = .pipelines, writing: Bool = false, backTitle: String? = nil,
         onBack: @escaping () -> Void = {}, onSaved: @escaping () -> Void = {}, onRevoke: @escaping () -> Void = {}) {
        self.remote = remote
        self.purpose = purpose
        self.backTitle = backTitle
        self.onBack = onBack
        self.onSaved = onSaved
        self.onRevoke = onRevoke
        _writing = State(initialValue: writing)
    }

    private var provider: CIProvider { remote?.provider ?? .gitLab }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up \(provider.name) access", systemImage: "key.fill").scaledFont(.headline)
            Text("Tokens are only sent to the HTTPS origin you approve below and are stored in the keychain per server and access level. Please check the server address first.")
                .scaledFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let r = remote {
                Text(r.origin.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if r.provider == .gitHub {
                    Text("API: \(r.apiBase.host ?? r.host)").scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                }
                Toggle(writeToggleTitle(r.provider), isOn: $writing)
                Text(hint(r.provider))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: r.tokenPage(writing: writing)) {
                    Label("Create a token in \(r.provider.name)", systemImage: "arrow.up.forward.square")
                }
            }
            HStack {
                SecureField("Paste token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Approve server & save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let backTitle {
                Button(backTitle, action: onBack)
                if let r = remote {
                    Button("Revoke server approval", role: .destructive) {
                        model.ci.revoke(r.origin)
                        tokenInput = ""
                        onRevoke()
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func writeToggleTitle(_ p: CIProvider) -> String {
        switch (p, purpose) {
        case (.gitLab, _): String(localized: "Set up separate write access (api)")
        case (.gitHub, .pipelines): String(localized: "Set up separate write access (Actions: Read and write)")
        case (.gitHub, .changeRequests): String(localized: "Set up separate write access (Pull requests: Read and write)")
        }
    }

    private func hint(_ p: CIProvider) -> String {
        if writing {
            switch (p, purpose) {
            case (.gitHub, .changeRequests):
                return String(localized: "For comments, reviews and merging: “Pull requests: Read and write”, to merge also “Contents: Read and write”. A read token is needed as well.")
            default:
                return String(localized: "Only for write actions you trigger yourself; a read token is needed as well.")
            }
        }
        switch (p, purpose) {
        case (.gitLab, _): return String(localized: "For automatic loading the read_api scope is enough.")
        case (.gitHub, .pipelines):
            return String(localized: "Fine-grained token, only this repository, permission “Actions: Read-only” (plus “Metadata: Read-only”, added automatically).")
        case (.gitHub, .changeRequests):
            return String(localized: "Fine-grained token, only this repository, permission “Pull requests: Read-only”. The same token serves the CI/CD pane – add “Actions: Read-only” there if you use it.")
        }
    }

    private func save() {
        let t = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let r = remote else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Approve this \(r.provider.name) server?")
        let access: String = switch (r.provider, purpose) {
        case (.gitLab, _): writing ? String(localized: "Write (api)") : String(localized: "Read (read_api)")
        case (.gitHub, .pipelines): writing ? String(localized: "Write (Actions)") : String(localized: "Read (Actions)")
        case (.gitHub, .changeRequests): writing ? String(localized: "Write (Pull requests)") : String(localized: "Read (Pull requests)")
        }
        let apiNote = r.provider == .gitHub ? " (API: \(r.apiBase.host ?? r.host))" : ""
        alert.informativeText = String(localized: "\(r.origin.value)\(apiNote)\n\nOnly this HTTPS origin receives the token. Access: \(access). Nothing is approved for other hosts or ports.")
        alert.addButton(withTitle: String(localized: "Approve"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if model.ci.save(t, for: r.origin, writing: writing) {
            tokenInput = ""
            model.toast(String(localized: "\(r.provider.name) token saved"))
            onSaved()
        } else {
            error = String(localized: "The token could not be saved in the keychain.")
        }
    }
}
