# Architektur

Stand v0.4.3. Hearth ist eine SwiftUI-App ohne eigenen Agenten: Sie startet die
Agent-CLIs der Nutzer in einer nono-Sandbox und zeigt drumherum Inbox, Editor,
Git, Tests, Build & Deployment und CI.

## Überblick

```mermaid
flowchart TB
  subgraph UI["SwiftUI-Ansichten"]
    Inbox["InboxView"]
    Chat["ChatView → AgentRunView (Terminal)"]
    Insp["InspectorView: Directory, Git, Editor, Tests,<br/>Architecture, Build & Deployment, CI/CD, Terminal"]
  end
  subgraph Model["AppModel (Komposition)"]
    Layout["LayoutStore"]
    Editor["EditorStore"]
    WS["WorkspaceState"]
    Zoom["TextZoomStore"]
    CIA["CIAccounts"]
    Agents["AgentHost"]
    Builds["BuildDeployStore"]
    Updates["UpdateChecker"]
  end
  subgraph Sandbox["Sandbox-Schicht"]
    Policy["SandboxPolicy<br/>(SandboxPurpose + SandboxContext)"]
    Home["AgentHome"]
    Manager["SandboxManager.prepare"]
    Runner["SandboxCommandRunner<br/>NonoCommandRunner"]
  end
  nono[["nono (Contents/Helpers)"]]
  UI --> Model
  Agents --> Manager
  Builds --> Runner
  GitRunner["SandboxGitRunner"] --> Runner
  Model --> GitRunner
  Runner --> Manager
  Manager --> Policy & Home
  Manager --> nono
  HostGit["Git (Host, nur lesen, sandbox-exec)"]
  Model --> HostGit
  CIA --> CIClients["CIClient: GitLabAPI, GitHubAPI"]
```

## Bausteine

| Bereich | Typen | Aufgabe |
|---|---|---|
| Zustand | `AppModel` | Komposition und Auswahl: Die gewählte Agenten-Sitzung bestimmt den Arbeitsordner (`workspaceRoot`) und damit Inspector, Editor-Tabs und Build & Deployment. Startet Agenten, leitet „Auftrag an den Agenten“ ins Terminal, hält die privaten `NonoCommandRunner` (ein Runner je Ordner + Zweck). |
| | `LayoutStore` | Bereiche, Splits, eigene Fenster, Maximieren; gespeichert in `UIStateStore`. |
| | `EditorStore`, `EditorGroup` | Editoren pro Preview-Bereich, Tabs, ungespeicherte Dokumente, Navigation, „Gehe zu Definition“, Tabs pro Sitzung. |
| | `WorkspaceState` | Git-Stand, Verzeichnisbaum, Revision (lädt Inspector-Tabs neu, wenn ein Agent Dateien ändert). |
| | `TextZoomStore`, `CIAccounts` | Schriftgröße pro Bereich; CI-Tokens pro bestätigtem Origin (GitLab und GitHub getrennt). |
| | `AppLanguage` | Sprache der App (Englisch/Deutsch); schreibt `AppleLanguages`, wirkt nach Neustart. |
| Agenten | `AgentKind` | Katalog: Programm, Login, Status-Quelle, API-Hosts, Sandbox-Spezifikation (`AgentSandboxSpec`). |
| | `AgentHost`, `AgentRun` | Start, Fortsetzen, Stoppen, Status aus `events.jsonl` (Claude-Hooks, Codex-`notify`), Benachrichtigungen, `runs.json`. |
| Sandbox | `SandboxPurpose` | Wofür eine Sandbox ist: `.agent(kind)`, `.build`, `.gitNetwork`, `.gitLocal`. |
| | `SandboxPolicy` | Einzige Quelle aller Rechte: aus Zweck und `SandboxContext` (Home, Arbeitsordner, Einstellungen) wird das nono-Profil. Rein, ohne Dateizugriffe, daher als Golden-Datei testbar. Erlaubt iCloud Drive, iCloud-„Documents“-Ordner und `~/Library/CloudStorage` (Dropbox, OneDrive, Google Drive) als Arbeitsordner; der Rest von `~/Library` bleibt gesperrt. |
| | `AgentHome` | Eigener Konfigurationsordner je Agent mit nur-lesenden Links auf die eigene Konfiguration; Schreibsperren für Agenten ohne Ordner-Variable. |
| | `SandboxManager` | Findet nono und die CLI, prüft den Arbeitsordner, schreibt Profil und Status-Hooks, baut Befehlszeile und Umgebung. |
| | `SandboxCommandRunner`, `NonoCommandRunner` | Typisierte Schnittstelle für Befehle in der Sandbox (Start, Status, Ausgabe-Seiten, Entfernen); jeder Befehl in einer eigenen nono-Sandbox. |
| Git | `Git` | Lesende Host-Abfragen und lokale Änderungen unter `sandbox-exec` ohne Netz und ohne Helfer. |
| | `SandboxGitOperation`, `SandboxGitRunner` | Fetch/Clone in `.gitNetwork`, Fast-forward in `.gitLocal`; Repo-Helfer neutralisiert. |
| Build | `BuildDetector`, `BuildTask`, `BuildCommand`, `BuildDeployStore` | Aufgaben aus Projektdateien (Maven, Gradle, npm, Go, Make, eigene) erkennen, sicher gequotete Befehle bauen, ausführen, Health-Checks über `SandboxCommandRunner`. Maven/Gradle/npm bekommen einen eigenen Cache unter `~/Library/Caches/Hearth/`; Java-Programme (auch Spring Boot mit Vaadin) ein eigenes Home dort, Dev-Server dürfen lokale Hilfsprozesse (z. B. Vite) erreichen. |
| CI/CD | `CIClient` (`GitLabAPI`, `GitHubAPI`), `CIAccounts` | GitLab-Pipelines und GitHub Actions (github.com und Enterprise) über ein gemeinsames Protokoll: Läufe, Jobs als Diagramm oder Liste, Logs, Retry/Cancel, `workflow_dispatch`. Tokens pro bestätigtem Origin. |
| Überblick | `Journal`, `JournalReader`, `JournalSupport`, `JournalView` | Baum aus Schritten, Entscheidungen und Fragen je Sitzung. Der Agent schreibt per `hearth-journal` (Skript im Sitzungsordner, auf dem PATH) Zeilen nach `journal.jsonl`; `AgentHost` liest sie wie `events.jsonl` (begrenzt, bereinigt), Revidieren hängt eine `revoke`-Zeile an und tippt die Anweisung ins Terminal. Claude (`--append-system-prompt`) und Codex (`developer_instructions`) bekommen die Anleitung automatisch. |
| Sonstiges | `TestReports`, `MermaidScanner`, `SymbolFinder`, `AppUpdates` | Testberichte, Architekturdiagramme, Definitionen, Updates. |

## Datenablage

| Ort | Inhalt |
|---|---|
| `~/Library/Application Support/Hearth/settings.json` | Sandbox-Regeln der Nutzer (Domains, Ports, Ordner, Projekte, Credentials-Metadaten) |
| `…/Hearth/runs.json`, `…/Hearth/runs/<id>/` | Sitzungen; je Sitzung nono-Profil, Log, Status-Ereignisse, Hook-Skripte |
| `…/Hearth/agents/<agent>/` | Hearths Konfigurationsordner der Agenten (Login, Verlauf, Einstellungen) |
| `UserDefaults` (`ui.*`) | Layout, Editor-Tabs (auch pro Sitzung), Schriftgrößen, Sprache, Update-Einstellungen |
| Schlüsselbund | `nono` / `hearth.<name>`: Credentials für den nono-Proxy; `hearth-gitlab`: CI-Tokens (GitLab, GitHub) |

## Abläufe

**Agent starten:** `AppModel.startAgent` → `AgentHost.start` → `SandboxManager.prepare(.agent(kind))`
(Arbeitsordner prüfen, `AgentHome.prepare`, Profil aus `SandboxPolicy`, Hooks) → SwiftTerm startet
`nono run --profile … -- <cli>`. Hooks schreiben in `events.jsonl`, `AgentHost` liest alle 0,5 s.

```mermaid
sequenceDiagram
  participant U as Nutzer
  participant M as AppModel
  participant H as AgentHost
  participant S as SandboxManager
  participant Home as AgentHome
  participant P as SandboxPolicy
  participant T as SwiftTerm (LocalProcessTerminalView)
  participant N as nono
  participant E as events.jsonl

  U->>M: startAgent(kind, directory)
  M->>H: start(kind, directory)
  H->>H: AgentRun anlegen, in runs einfügen
  H->>S: prepare(.agent(kind), runID, directory, arguments)
  S->>S: locateNono(), locate(kind)
  S->>S: validateWorkdir(directory)
  S->>Home: layout(for: kind) + prepare()
  Home-->>S: eigener Ordner, Nur-Lese-Links, Umgebung
  S->>P: make(.agent(kind), context)
  P-->>S: SandboxPolicy (Rechte, Domains, Ports)
  S->>S: Profil schreiben (nono-profile.json), Status-Hooks installieren
  S-->>H: Launch(executable: nono, arguments, environment, directory)
  H->>T: startProcess(nono run --profile … -- <cli>)
  T->>N: Prozess startet in der Sandbox
  loop alle 0,5 s
    H->>E: pollEvents() liest neue Zeilen
    E-->>H: Status-Ereignis (running/needsInput/done)
    H->>M: onAttention / onFilesChanged
  end
```

**Pull:** `AppModel.pull` → `SandboxGitRunner(.fetchUpstream)` in `.gitNetwork` → bei Erfolg
`SandboxGitRunner(.fastForward)` in `.gitLocal`.

```mermaid
sequenceDiagram
  participant U as Nutzer
  participant M as AppModel
  participant G as Git (Host, sandbox-exec)
  participant R as SandboxGitRunner
  participant NetSB as Sandbox .gitNetwork
  participant LocSB as Sandbox .gitLocal

  U->>M: pull(in: directory)
  M->>G: networkSandboxOverrides(in: directory)
  G-->>M: neutralisierte Repo-Config-Schlüssel
  M->>R: run(.fetchUpstream) über Runner(.gitNetwork)
  R->>NetSB: git fetch --prune (SSH-Schlüssel, Keychain, Port 22)
  NetSB-->>R: Ergebnis
  R-->>M: fetched (ok/Ausgabe)
  alt fetch erfolgreich
    M->>R: run(.fastForward) über Runner(.gitLocal)
    R->>LocSB: git merge --ff-only @{u} (ohne Schlüssel, ohne Helfer)
    LocSB-->>R: Ergebnis
    R-->>M: merged (ok/Ausgabe)
  else fetch fehlgeschlagen
    M-->>U: Fehler aus fetch, kein Merge
  end
  M-->>U: Git.OpResult (ok, Ausgabe)
```

**Build-Aufgabe:** `BuildDeployStore.start` → `NonoCommandRunner(.build).start` → Ausgabe seitenweise,
Health-Check vom Mac aus über `LocalPortProbe`. Maven/Gradle greifen über den nono-Proxy der Sandbox
(`BuildCommand.proxySetup`) statt über `HTTP(S)_PROXY`, das Java ignoriert.

```mermaid
sequenceDiagram
  participant U as Nutzer
  participant V as BuildDeployView
  participant D as BuildDeployStore
  participant C as BuildCommand
  participant Run as NonoCommandRunner (.build)
  participant SB as Sandbox-Prozess
  participant Probe as LocalPortProbe

  U->>V: Aufgabe/Dienst starten
  V->>D: start(task, root, serverID, client)
  D->>D: unavailableReason() prüfen (Werkzeug im Sandbox-Probe vorhanden?)
  D->>C: render(task, profile, port)
  C-->>D: Befehlszeile (Prelude, ggf. Maven-/Gradle-Proxy, exec …)
  D->>Run: start(SandboxCommandRequest(command, cwd, port))
  Run->>SB: nono-Sandbox mit eigenem Profil startet Befehl
  loop solange running
    D->>Run: output(from:, limit:) / state(of:)
    Run-->>D: neue Ausgabe-Seite / Zustand
  end
  opt Dienst mit Port
    loop healthInterval
      D->>Probe: status(port)
      Probe->>SB: lokaler Health-Check vom Mac aus
      Probe-->>D: erreichbar/nicht erreichbar
    end
  end
  D-->>V: BuildRun-Zustand (running/failed/stopped), Log
```

**CI/CD laden:** `CIAccounts` löst aus dem Git-Remote Anbieter und Origin auf → passendes `CIClient`
(`GitLabAPI` oder `GitHubAPI`) liest Pipelines/Workflows, Jobs und Logs über das gemeinsame Protokoll.

## Klassendiagramme

### Agenten: Start, Sitzung, Katalog

```mermaid
classDiagram
  class AppModel {
    +AgentHost agents
    +BuildDeployStore builds
    +CIAccounts ci
    +startAgent(kind, directory)
    +ask(prompt)
    +selectRun(id)
  }
  class AgentHost {
    +AgentRun[] runs
    +selectedRunID: String?
    +start(kind, directory, purpose) AgentRun
    +resume(run)
    +stop(run)
    +pollEvents()
  }
  class AgentRun {
    +String id
    +AgentKind kind
    +String directory
    +Purpose purpose
    +AgentStatus status
    +String? sessionID
    +LocalProcessTerminalView? terminal
    +canResume: Bool
  }
  class AgentKind {
    <<enum>>
    claude
    codex
    opencode
    copilot
    gemini
    shell
    +displayName: String
    +sandbox: AgentSandboxSpec
  }
  class AgentSandboxSpec {
    +String[] groups
    +String[] domains
    +Int[] openPorts
    +Bool keychain
  }
  class AgentStatus {
    <<enum>>
    inactive
    running
    needsInput
    done
    error
  }
  AppModel --> AgentHost
  AgentHost "1" o-- "*" AgentRun
  AgentRun --> AgentKind
  AgentKind --> AgentSandboxSpec
  AgentRun --> AgentStatus
```

### Sandbox-Schicht: Rechte, Profile, Befehle

```mermaid
classDiagram
  class SandboxPurpose {
    <<enum>>
    agent(AgentKind)
    build
    gitNetwork
    gitLocal
    +kind: AgentKind
    +isAgent: Bool
  }
  class SandboxContext {
    +String home
    +String support
    +String runDirectory
    +String? workdir
    +SandboxSettings settings
    +String[] hookScripts
    +String[] gitHosts
  }
  class SandboxPolicy {
    +String[] readWrite
    +String[] read
    +String[] domains
    +Int[] openPorts
    +Dictionary envCredentials
    +make(purpose, context) SandboxPolicy
    +profile() String
  }
  class AgentHome {
    +String? root
    +String[] hostReadWrite
    +String[] linkTargets
    +layout(kind, support, home) AgentHome
  }
  class SandboxManager {
    <<enum>>
    +locateNono() String?
    +prepare(purpose, context) …
    +searchPath: String
  }
  class SandboxCommandRunner {
    <<protocol>>
    +start(request) SandboxCommandInfo
    +status(id) SandboxCommandState
    +output(id, page) SandboxOutputPage
    +remove(id)
  }
  class NonoCommandRunner {
    +String root
    +SandboxPurpose purpose
  }
  class SandboxSettings {
    +Folder[] folders
    +Credential[] credentials
    +String[] domains
    +Int[] ports
    +Bool gitSSH
    +Bool agentKeychain
    +validFolder(path, home, support) String?
  }
  SandboxPolicy ..> SandboxPurpose : uses
  SandboxPolicy ..> SandboxContext : uses
  SandboxPolicy ..> AgentHome : resolves
  SandboxContext --> SandboxSettings
  SandboxManager --> SandboxPolicy : writes profile from
  SandboxManager --> AgentHome
  NonoCommandRunner ..|> SandboxCommandRunner
  NonoCommandRunner --> SandboxManager : locates nono via
```

### Git: Host-Lesezugriffe und Sandbox-Operationen

```mermaid
classDiagram
  class Git {
    <<enum>>
    +snapshot(root) GitSnapshot
    +diff(root, path) String
    +networkSandboxOverrides(root) String[]
  }
  class GitSnapshot {
    +GitFileChange[] changes
    +String? branch
    +Int ahead
    +Int behind
  }
  class SandboxGitOperation {
    <<enum>>
    fetch
    fetchUpstream
    fastForward
    clone(url)
    +needsNetwork: Bool
    +command(repoOverrides) String
  }
  class SandboxGitRunner {
    +SandboxCommandRunner runner
    +URL root
    +String[] repoOverrides
    +run(operation) …
  }
  class AppModel {
    +pull()
  }
  AppModel --> Git : liest Stand (Host, sandbox-exec)
  AppModel --> SandboxGitRunner : Fetch/Fast-forward
  SandboxGitRunner --> SandboxGitOperation
  SandboxGitRunner --> SandboxCommandRunner
  Git --> GitSnapshot
```

### Build & Deployment

```mermaid
classDiagram
  class BuildDetector {
    <<enum>>
    +scan(root) BuildProject[]
  }
  class BuildProject {
    +String path
    +String name
    +Tool[] tools
    +BuildTask[] tasks
    +String[] profiles
  }
  class BuildTask {
    +String id
    +Tool tool
    +String project
    +Kind kind
    +String[] argv
    +String? script
    +Int? port
    +Bool acceptsProfile
  }
  class BuildCommand {
    <<enum>>
    +quote(value) String
    +render(task, profile, port) String
  }
  class BuildDeployStore {
    +BuildProject[] projects
    +BuildRun[] runs
    +start(task, root) BuildRun
    +stop(run)
  }
  class BuildRun {
    +String id
    +String serverID
    +BuildTask task
    +SandboxCommandState state
  }
  class LocalPortProbe {
    +healthy(port, path) Bool
  }
  BuildDetector --> BuildProject
  BuildProject "1" o-- "*" BuildTask
  BuildDeployStore --> BuildDetector : scan on open
  BuildDeployStore "1" o-- "*" BuildRun
  BuildRun --> BuildTask
  BuildDeployStore --> BuildCommand : render argv
  BuildDeployStore --> LocalPortProbe : health check
  BuildCommand ..> BuildTask
```

### CI/CD: GitLab und GitHub über ein Protokoll

```mermaid
classDiagram
  class CIClient {
    <<protocol>>
    +pipelines(origin, token) CIPipeline[]
    +jobs(pipeline, token) CIJob[]
    +log(job, token) String
    +retry(job, token)
    +cancel(run, token)
  }
  class GitLabAPI {
    +pipelines(...)
    +jobs(...)
  }
  class GitHubAPI {
    +workflows(...)
    +runs(...)
    +dispatch(workflow, branch)
  }
  class CIOrigin {
    +String host
    +CIProvider provider
  }
  class CIProvider {
    <<enum>>
    gitlab
    github
  }
  class CIAccounts {
    +Dictionary tokens
    +client(for origin) CIClient
  }
  class CIPipeline {
    +String id
    +CIStatus status
  }
  class CIJob {
    +String id
    +String name
    +CIStatus status
  }
  CIAccounts --> CIOrigin
  CIAccounts --> CIClient : resolves per origin
  GitLabAPI ..|> CIClient
  GitHubAPI ..|> CIClient
  CIOrigin --> CIProvider
  CIClient --> CIPipeline
  CIClient --> CIJob
```

## Tests und Auslieferung

- `scripts/test.sh` (swift-testing, auch ohne Xcode). Golden-Profile in `Tests/HearthTests/Golden`,
  Live-Tests gegen echtes nono, Fakes für die Sandbox-Schnittstelle (`FakeCommandRunner`).
- `.github/workflows/ci.yml`: Build und Tests bei jedem Push/PR, App-Bundle als Artefakt,
  Release bei Versions-Tag. `scripts/release.sh` setzt Changelog und Tag.
