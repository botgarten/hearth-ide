import SwiftUI
import AppKit

/// Shown on launch when no agent was running: continue in a recent folder or start a new one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    private let showOnLaunch = State(initialValue: AppModel.welcomeEnabled)

    /// Newest session per folder, so a click starts the same agent there again.
    private var recentAgentFolders: [AgentRun] {
        var seen = Set<String>()
        return model.agents.runs.sorted { $0.updated > $1.updated }
            .filter { $0.purpose == .session && seen.insert($0.directory).inserted }
            .prefix(8).map { $0 }
    }

    private func resumable(_ run: AgentRun) -> Bool { run.isRunning || run.canResume }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Hearth IDE").font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("All your agents in safe sandboxes – where do you want to start?")
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)

            Divider()

            UpdateNoticeBar(checker: model.updates, compact: true)

            VStack(alignment: .leading, spacing: 8) {
                if !recentAgentFolders.isEmpty {
                    Text("Recent folders").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(recentAgentFolders, id: \.directory) { run in
                                HStack(spacing: 10) {
                                    Image(systemName: run.kind.symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.folderName).font(.body.bold())
                                        HStack(spacing: 4) {
                                            Text(run.kind.displayName)
                                            Text("·")
                                            Text(run.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                .lineLimit(1).truncationMode(.head)
                                            Text("·")
                                            Text(run.updated.formatted(.relative(presentation: .named)))
                                        }
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        model.showWelcome = false
                                        model.startAgent(run.kind, directory: run.directory)
                                    } label: { Image(systemName: "plus.circle").font(.title2) }
                                        .buttonStyle(.borderless)
                                        .help("New \(run.kind.displayName) session in this folder")
                                    Image(systemName: resumable(run) ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                                        .font(.title2).foregroundStyle(Color.accentColor)
                                }
                                .padding(.vertical, 4)
                                .interactiveRow {
                                    model.showWelcome = false
                                    if resumable(run) { model.openSession(run) }
                                    else { model.startAgent(run.kind, directory: run.directory) }
                                }
                                .help(resumable(run) ? "Continue the last \(run.kind.displayName) session in this folder"
                                                     : "Start \(run.kind.displayName) in this folder")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                } else {
                    ContentUnavailableView("No sessions yet", systemImage: "flame",
                                           description: Text("Choose a folder and an agent – Claude Code, Codex, Copilot or OpenCode."))
                        .frame(maxHeight: 180)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            Divider()

            HStack {
                Toggle("Show at launch", isOn: Binding(get: { showOnLaunch.wrappedValue }, set: {
                    showOnLaunch.wrappedValue = $0
                    AppModel.welcomeEnabled = $0
                }))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Continue without an agent") { model.showWelcome = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.welcomeStartAgent()
                } label: {
                    Label("Start agent…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600)
    }
}
