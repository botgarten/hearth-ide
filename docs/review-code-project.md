# Code- und Projekt-Review (01.11.2026, Stand v0.4.4)

> **Umsetzung in v0.4.5:** S7 behoben, K1 behoben, K2 für CI/CD umgesetzt
> (`PipelinesStore`), P3 teilweise (Store-Tests). Details stehen am Ende der jeweiligen
> Abschnitte unter „Umgesetzt“.

Ergänzt das [Security- und Architektur-Review](review-security-architecture.md) vom Vormittag.
Geprüft: alle Änderungen seit v0.2.1 (GitHub Actions, Lokalisierung, Build-Caches,
Vaadin/localhost, Cloud-Ordner, CI/CD-Neuladen), Stichproben im übrigen Code, Tests,
CI und Release-Ablauf. Belege sind Dateistellen oder Befehle; „nicht getestet“ ist
markiert.

## Kurzfassung

Der Kern ist in gutem Zustand. Sandbox-Regeln stecken an einer Stelle (`SandboxPolicy`),
jede Rechteänderung erscheint als Diff in den Golden-Dateien, es gibt Live-Tests gegen
echtes nono, CI und Releases laufen automatisch. Die größten Baustellen:

1. **Sicherheit:** Die localhost-Freigabe für Build & Deployment (seit v0.4.2) ist zu
   breit (N1).
2. **Code:** Ansichten laden bei jeder Dateiänderung neu. Das CI/CD-Fenster ist
   behoben, Tests und Architektur haben dasselbe Muster noch (K1). Lade- und Polllogik
   steckt in großen Views und ist deshalb nicht testbar (K2).
3. **Prozess:** Heute gingen neun Versionen raus, die letzten drei direkt auf `main`,
   ohne Branch-Schutz (P1). Die Release-Notes in der App sind deutsch, die App ist
   standardmäßig englisch (P2).

| # | Befund | Schwere | Aufwand |
|---|---|---|---|
| N1 | Build-Sandbox erreicht jeden Dienst auf localhost | **Mittel** | klein |
| S7 | Session-ID aus der Event-Datei geht ungeprüft in die Agent-Argumente | Niedrig | **behoben in v0.4.5** |
| S4 | „Open with default app“ startet vom Agenten geschriebene Programme (offen) | Mittel | klein |
| N2 | `JAVA_TOOL_OPTIONS`/`MAVEN_ARGS` ersetzen eigene Werte des Nutzers | Niedrig | klein |
| N3 | GitHub Actions per Tag statt Commit-SHA eingebunden | Niedrig | sehr klein |
| K1 | Tests- und Architektur-Ansicht laden bei jeder Dateiänderung neu | Mittel | **behoben in v0.4.5** |
| K2 | Lade-/Polllogik in großen SwiftUI-Views, nicht testbar | Mittel | **CI/CD in v0.4.5**, Rest offen |
| K3 | Synchrone `git`-Aufrufe auf dem Main Actor | Niedrig | klein |
| K4 | Swift-5.10-Sprachmodus ohne strikte Concurrency-Prüfung | Niedrig | mittel |
| P1 | Kein Branch-Schutz, Direkt-Pushes auf `main` | Mittel | sehr klein |
| P2 | Release-Notes/CHANGELOG deutsch, App-Standard englisch | Mittel | klein |
| P3 | Keine automatischen UI-Tests; UI-Fehler fanden heute Nutzer | Mittel | teilweise (v0.4.5) |
| P4 | Lokales Remote zeigt noch auf den alten Repo-Namen | Niedrig | sehr klein |
| P5 | nono 0.80 gepinnt, 0.81 verfügbar; kein Update-Ablauf | Niedrig | klein |

Weiterhin offen aus dem ersten Review: S3 (Schlüsselbund), S5 (Host-Terminal),
S8 (Datenabfluss über erlaubte Dienste), S9 (Update-Kette).

## Sicherheit

### N1 · Mittel · Build-Sandbox erreicht jeden Dienst auf localhost

`SandboxPolicy.make` gibt für `.build` die Regel
`(allow network-outbound (remote tcp "localhost:*"))` aus. Nötig ist sie, weil Vaadins
Vite-Dev-Server und sein Watchdog über zufällige Ports mit Java sprechen.

Damit erreicht aber jeder Build jeden lokalen Dienst ohne eigene Anmeldung: den
eingebauten Server von IntelliJ (Port 63342) und dessen MCP-Server, Ollama, eine
lokale Datenbank, Docker mit TCP-Socket. Was ein Build ausführt, stammt aus dem
Repository: `pom.xml`-Plugins, npm-Skripte, `.hearth/tasks.json`. Das kann ein Agent
geschrieben haben. Vor v0.4.2 war localhost aus allen Sandboxes gesperrt.

Die nono-Proxys anderer Sitzungen sind durch Zugangsdaten pro Sitzung geschützt
(aus `lsof` und Proxy-URL abgeleitet, nicht gezielt getestet).

**Vorschlag:** Die Freigabe nicht pauschal erteilen, sondern pro Projekt in den
Einstellungen (Projects › „Dev-Server darf localhost nutzen“), standardmäßig aus. Der
Fehlerhinweis erkennt `connect EPERM 127.0.0.1` und verweist auf den Schalter. Nur
eigene Ports zu erlauben gibt Seatbelt nicht her.

### S7 · Niedrig · Session-ID ungeprüft (weiterhin offen)

`AgentHost.apply` übernimmt `session_id`/`thread-id` aus `events.jsonl` und reicht sie
bei „Fortsetzen“ als `--resume <id>` weiter (`AgentKind.arguments(resume:)`). Die Datei
liegt im Run-Ordner, den die Sandbox beschreiben darf. Eine ID wie
`--dangerously-skip-permissions` würde zur Option. Das bleibt in der Sandbox, hebelt aber
die Rückfragen des Agenten aus.

**Vorschlag:** IDs nur übernehmen, wenn sie auf `^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`
passen. Dafür reicht ein Einzeiler plus Test.

**Umgesetzt (v0.4.5):** `AgentHost.validSessionID` (zusätzlich `.` und `:` erlaubt, die
manche Agenten nutzen) prüft beim Lesen und vor dem Fortsetzen. Zusätzlich liest
`pollEvents` höchstens 1 MB pro Durchlauf. Details im
[ersten Review](review-security-architecture.md#s7--niedrig--session-id-aus-eventsjsonl-ungeprüft).

### S4 · Mittel · „Open with default app“ (weiterhin offen)

`DirectoryActions.swift:348` ruft `NSWorkspace.shared.open(url)` für jede Datei im
Projekt auf. Für `.app`, `.command`, `.terminal`, `.workflow` oder ausführbare Dateien
heißt das: Code des Agenten läuft auf dem Host. Für das Vorschau-Symbol in
`PreviewView.swift:352` gilt dasselbe.

**Vorschlag:** Bei ausführbaren Typen eine Rückfrage stellen oder nur „Im Finder zeigen“
anbieten.

### N2 · Niedrig · Umgebungsvariablen überschreiben Nutzerwerte

`buildToolEnvironment` setzt `JAVA_TOOL_OPTIONS`, `MAVEN_ARGS`, `GRADLE_USER_HOME` und
`npm_config_cache` fest. Eigene Werte des Nutzers, etwa Speicheroptionen in
`JAVA_TOOL_OPTIONS`, gehen in der Sandbox verloren. Jede JVM schreibt außerdem
„Picked up JAVA_TOOL_OPTIONS“ nach stderr. Gradles Toolchain-Erkennung liest die
Ausgabe von `java`; mit Gradle-Projekten ist das nicht getestet.

**Vorschlag:** Den Wert im Build-Prelude an vorhandene Werte anhängen statt ihn im
Profil zu setzen. `user.home` alternativ nur für Service-Aufgaben setzen.

### N3 · Niedrig · Actions per Tag eingebunden

`.github/workflows/ci.yml` nutzt `actions/checkout@v4` usw. Der Release-Job baut und
veröffentlicht das Bundle, das der Updater installiert (siehe S9). Ein verschobener
Tag eines Actions-Repositories landet so im Release.

**Vorschlag:** Auf Commit-SHAs pinnen (Kommentar mit Version) und Dependabot für
Actions aktivieren.

### Anmerkung zu den Cloud-Ordnern (v0.4.3)

Die Freigabe ist eng gefasst: nur iCloud Drive, `iCloud~*/Documents` und
`~/Library/CloudStorage/<Anbieter>`. Tests decken `..` und die Container-Wurzeln ab.
Bei App-Ordnern wie einem Obsidian-Vault gilt aber dasselbe wie bei `.git/hooks` (S2):
`.obsidian/plugins` enthält JavaScript, das Obsidian auf dem Host ausführt. Das ist
kein neuer Fehler. Der Hinweis gehört in die Doku zu S2.

## Code

### K1 · Mittel · Neuladen bei jeder Dateiänderung

`workspace.revision` zählt bei jeder Dateiänderung hoch, während ein Agent arbeitet
also mehrmals pro Sekunde. Für den Verzeichnisbaum ist das gewollt. Diese Ansichten
hängen ebenfalls daran:

- `TestsView.swift:30`: lädt alle Testberichte neu und schaltet dabei den Ladezustand
  (Flackern).
- `ArchitectureView.swift:29`: durchsucht das ganze Projekt nach Mermaid-Diagrammen,
  ohne Entprellung.
- `InspectorView.swift:531`: lädt die Branches neu.
- `PipelinesView`: in v0.4.4 behoben (entprellt, prüft nur das Remote).

**Vorschlag:** Ein gemeinsames, entprelltes Signal, etwa `workspace.settledRevision`
(1–2 s nach der letzten Änderung). Ansichten laden still nach, ohne Ladezustand, und
nur bei relevanten Dateien (Tests: `target/surefire-reports`, `build/test-results`;
Architektur: `*.md`, `*.mmd`).

**Umgesetzt (v0.4.5):** `WorkspaceState.settledRevision` folgt `revision`, sobald 1,5 s
lang nichts geändert wurde, spätestens aber nach 10 s, auch wenn ein Agent ununterbrochen
schreibt. Ausdrückliche Aktionen (Sitzungswechsel, Aktualisieren-Knopf, Git-Aktionen,
Klonen) laufen über `refreshNow()` sofort. Am verzögerten Signal hängen jetzt Tests,
Architektur, Branches, Git-Status, Dateisuche und die Remote-Prüfung von CI/CD. Direkt
folgen nur noch Verzeichnisbaum und Editor. Die Tests-Ansicht legt beim Nachladen kein
Overlay mehr über die Ergebnisse, das unübersetzte Label „Lese Reports …“ ist dabei
entfallen. Nicht umgesetzt ist das Filtern nach relevanten Dateien.
Test: `LoadingTests.settledRevisionWaitsForQuietButNotForever`.

### K2 · Mittel · Logik in großen Views

Die größten Dateien sind Views: `InspectorView` (824 Zeilen), `PreviewView` (777),
`CodeEditor` (766), `SettingsView` (618), `PipelinesView` (550). Laden, Pollen und
Fehlerzustände liegen in `.task(id:)`-Blöcken und `State`-Properties. Die beiden
UI-Fehler von heute (Build-Ansicht springt, CI/CD lädt ständig) saßen genau dort und
waren deshalb nicht per Test abgedeckt.

`BuildDeployStore` zeigt das bessere Muster: Zustand und Ablauf im `@Observable`-Store,
die View zeichnet nur, Tests nutzen einen Fake-Runner.

**Vorschlag:** `PipelinesView` als Nächstes so aufteilen (`PipelinesStore` mit
`CIClient`-Fake, Polling-Intervalle testbar), danach `PreviewView`.

**Umgesetzt für CI/CD (v0.4.5):** `Core/Model/PipelinesStore.swift` hält Remote,
Läufe, Jobs, Workflows, Fehler und Polling. Abhängigkeiten (Remote-Erkennung,
Zugangsdaten, Client) werden übergeben, das Warten beim Polling ebenfalls. In der View
bleiben nur Darstellung, Dialoge und die Token-Einrichtung, sie schrumpft um rund
60 Zeilen. Tests mit Fake-Client in `LoadingTests`: Dateiänderungen behalten die Liste,
ein geändertes Remote leert sie, Fehler behalten die alte Liste, Branch-Filter und
Polling-Intervalle. Offen: Tests-, Architektur- und Preview-Ansicht nach demselben
Muster.

### K3 · Niedrig · Synchrone Prozesse

`Git.networkSandboxOverrides(in:)` (`Git.swift:173`) startet `git config` und wartet mit
`waitUntilExit()`. Aufgerufen wird es aus `AppModel.networkGit`, also auf dem Main
Actor. Das dauert normalerweise Millisekunden. Bei einem langsamen Dateisystem, etwa
einem iCloud-Ordner mit ausgelagerten Dateien, friert die UI so lange ein. Weitere
`waitUntilExit`-Stellen in `Git.swift`, `SandboxGit.swift` und `TerminalLauncher.swift`
habe ich nicht einzeln geprüft.

**Vorschlag:** In `Task.detached` auslagern, wie es `BuildDeployView.rescan` schon tut.

### K4 · Niedrig · Concurrency-Prüfung

`Package.swift` nutzt tools-version 5.10 ohne `StrictConcurrency`. Im Code stehen drei
`@unchecked Sendable` und drei `nonisolated(unsafe)`. Mit Swift 6 werden das Fehler.

**Vorschlag:** Erst `-strict-concurrency=complete` als Warnung in CI aktivieren, dann
schrittweise umstellen.

### Kleinigkeiten

- `try!` bei zwei statischen Regex (`InlineDiff`, `Highlighter`) und
  `URL(string:)!` bei festen URLs: unkritisch, weil konstant.
- `CI.swift:50` baut die API-URL mit `!` aus dem Host des Remotes. Der Host stammt aus
  einer bereits geparsten URL, abstürzen dürfte das nicht. `guard let` wäre trotzdem
  sauberer.
- Wegen fehlendem Xcode im lokalen Setup steht `State(initialValue:)` statt `@State`.
  Das funktioniert, ist aber wortreich und für Mitwirkende ungewohnt. CI hat Xcode.
  Mittelfristig: Xcode voraussetzen und auf `@State` umstellen.

## Tests

45 Tests in 12 Suites, Laufzeit etwa 5 s. Stark abgedeckt sind die Sandbox-Profile
(Golden-Dateien für jede Sandbox-Art), Git im Sandbox-Betrieb, GitHub/GitLab-Clients,
die Lokalisierung (inklusive Platzhalterprüfung), App-Updates und
Sicherheitsregressionen. `LiveSandboxTests` laufen gegen echtes nono.

### P3 · Mittel · Keine UI-Tests

Alle drei UI-Fehler von heute haben Nutzer gemeldet. Mit K2 ließe sich das Meiste über
Store-Tests abdecken. Für das Layout gibt es schon `Snapshotter` (`build-wide`,
`build-narrow`). Daraus ließen sich Bildvergleiche in CI machen.

**Teilweise umgesetzt (v0.4.5):** Das Neuladeverhalten von CI/CD und das verzögerte
Signal haben jetzt Tests (`LoadingTests`, 50 Tests insgesamt). Bildvergleiche und
Live-Build-Tests fehlen noch.

Fehlende Live-Tests mit konkreten Werkzeugen: Maven, Gradle und npm in der
Build-Sandbox. Die Fehler mit `~/.m2` und `~/.vaadin` hätte ein Live-Test mit einem
Mini-Projekt gefunden. Maven ist auf den GitHub-Runnern installiert.

## Projekt und Prozess

### P1 · Mittel · Kein Branch-Schutz

`gh api repos/botgarten/hearth-ide/branches/main/protection` antwortet „Branch not
protected“. Von heute neun Releases gingen v0.4.1 per PR raus, v0.4.2–v0.4.4 als
Direkt-Push. `release.sh` lässt die Tests lokal laufen, das fängt viel ab. Ein Push
ohne Release läuft aber erst nach dem Push durch CI.

**Vorschlag:** `main` schützen und den CI-Job „Build & Tests“ als Pflicht setzen. Auch
bei Selbst-Merges kostet das nur einen Klick.

### P2 · Mittel · Sprache der Release-Notes

README, Landingpage und App sind standardmäßig englisch. `CHANGELOG.md`, die
Release-Notes auf GitHub, der Update-Dialog in der App (er liest `CHANGELOG.md`) und
`docs/` sind deutsch. Englischsprachige Nutzer sehen beim Update deutschen Text.

**Vorschlag:** CHANGELOG ab der nächsten Version englisch, `## Unreleased` statt
`## Unveröffentlicht` (in `release.sh` anpassen). `docs/` nach und nach übersetzen.

### P4 · Niedrig · Altes Remote

`git remote -v` zeigt `git@github.com:pvanissem/hearth.git`. GitHub leitet um und warnt
bei jedem Push. **Vorschlag:**
`git remote set-url origin git@github.com:botgarten/hearth-ide.git`.

### P5 · Niedrig · nono-Updates

nono 0.80 ist gepinnt (`scripts/fetch-nono.sh` mit SHA-256), 0.81 ist erschienen.
Gepinnt ist richtig. Es fehlt aber ein fester Ablauf für Updates: Version anheben,
Live-Tests laufen lassen, Golden-Dateien prüfen.

### Bekannt und eingeplant

Die App ist nur ad-hoc signiert, nicht notarisiert. Das steht in der Roadmap
(„Signed, notarized builds“) und hängt mit S9 zusammen.

## Empfohlene Reihenfolge

Erledigt in v0.4.5: S7, K1, K2 für CI/CD, Teile von P3.

1. **Sofort, je unter einer Stunde:** N1 (localhost nur auf Projekt-Opt-in),
   P1 (Branch-Schutz), P4 (Remote).
2. **Nächste Version:** S4 (Rückfrage bei ausführbaren Dateien), P2 (englischer
   CHANGELOG), N3 (Actions-SHAs).
3. **Danach:** K2 für Tests/Architektur/Preview, Live-Build-Tests (Maven/npm), K3, K4.
