# Hearth IDE – Änderungen

## Unveröffentlicht

- Bereiche verschieben: Die blaue Vorschau, wo ein Bereich landet, bleibt nach dem Loslassen nicht mehr stehen. Es gibt nur noch eine Vorschau zur Zeit, und sie verschwindet, sobald die Maustaste losgelassen ist, auch wenn macOS das Ende des Ziehens nicht meldet.

## 0.4.5 · 2026-11-01

- Während ein Agent arbeitet, laden Tests, Architektur, Branches, Git-Status, Dateisuche und CI/CD nicht mehr bei jeder geschriebenen Datei neu, sondern sobald es 1,5 s ruhig ist (spätestens alle 10 s). Verzeichnisbaum und Editor folgen weiter sofort, „Aktualisieren“ wirkt sofort. Die Tests-Ansicht flackert beim Nachladen nicht mehr.
- CI/CD: Laden und Polling stecken jetzt in einem eigenen, getesteten Baustein. An der Bedienung ändert sich nichts.
- Sicherheit: Sitzungs-IDs aus der Event-Datei einer Sitzung werden geprüft, bevor Hearth sie beim Fortsetzen an den Agenten übergibt. Eine ID wie `--dangerously-skip-permissions` wird nicht mehr zur Option. Die Event-Datei wird höchstens 1 MB pro Durchlauf gelesen.
- Neu: [Code- und Projekt-Review](docs/review-code-project.md).

## 0.4.4 · 2026-11-01

- CI/CD: Die Ansicht lädt nicht mehr bei jeder Dateiänderung neu, während ein Agent arbeitet. Sie lädt neu beim Ordnerwechsel, beim Branchwechsel, im gewohnten Intervall (15 s bei laufenden Pipelines, sonst 60 s) und wenn sich das Git-Remote ändert.

## 0.4.3 · 2026-11-01

- Agenten und Builds laufen jetzt auch in Ordnern in iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`), im „Documents“-Ordner von iCloud-Apps und bei Cloud-Anbietern wie Dropbox, OneDrive oder Google Drive (`~/Library/CloudStorage`). Vorher hieß es „This folder contains settings of Hearth, macOS or an agent“. Der Rest von `~/Library` bleibt gesperrt.

## 0.4.2 · 2026-11-01

- Build & Deployment: Spring-Boot-Anwendungen mit Vaadin starten in der Sandbox. Java-Programme bekommen dort ein eigenes Home unter `~/Library/Caches/Hearth/home` (Vaadin schreibt nach `~/.vaadin`, wo auch Werkzeuge liegen, die außerhalb der Sandbox laufen). Dev-Server dürfen sich mit Hilfsprozessen auf localhost verbinden (z. B. Vite); Agenten weiterhin nicht.
- Build & Deployment: Bei gesperrtem Dateizugriff nennt der Hinweis jetzt die Datei. Harmlose Maven-Warnungen zu optionalen Repositories führen nicht mehr zu einem falschen Netzwerk-Hinweis.

## 0.4.1 · 2026-11-01

- Build & Deployment: Maven-, Gradle- und npm-Builds laufen wieder. In der Sandbox sind `~/.m2`, `~/.gradle` und `~/.npm` nicht beschreibbar (Maven scheiterte mit „Could not open file channel … .lock“). Die Werkzeuge nutzen jetzt einen eigenen Cache unter `~/Library/Caches/Hearth/` und lesen bereits geladene Artefakte aus `~/.m2/repository` bzw. `~/.gradle/caches` weiter mit. Das gilt auch für Agenten. JDKs aus `~/Library/Java/JavaVirtualMachines` und SDKMAN sind in der Sandbox nutzbar.
- Build & Deployment: Die Ansicht springt beim Starten einer Aufgabe nicht mehr nach oben; die Aufgabenliste behält ihre Scrollposition, wenn das Log darunter erscheint.

## 0.4.0 · 2026-11-01

- Die App ist jetzt standardmäßig auf Englisch. Deutsch lässt sich unter Settings › General › Language wählen (Neustart per Knopf).
- Landingpage auf Englisch mit deutscher Fassung unter /de/, README auf Englisch.

## 0.3.1 · 2026-11-01

- CI/CD: GitHub Actions funktioniert auch für umbenannte oder verschobene Repositories, deren lokaler Remote noch den alten Namen trägt (vorher „GitHub-Fehler 301“).

## 0.3.0 · 2026-11-01

- CI/CD zeigt jetzt auch GitHub Actions (github.com und GitHub Enterprise): Workflow-Läufe des aktuellen Branchs oder aller Branches, Jobs als Diagramm oder Liste, Job-Logs, fehlgeschlagene Jobs wiederholen, Läufe abbrechen und Workflows mit `workflow_dispatch` für den aktuellen Branch starten. Zugang per Fine-grained Token, getrennt für Lesen („Actions: Read-only“) und Schreiben, gebunden an den bestätigten Server – Job-Logs werden von GitHubs signierter Adresse ohne Token geladen.

## 0.2.1 · 2026-11-01

- Sicherheit: Ein Pull im Git-Bereich lädt nur noch in der Sandbox mit Zugriff auf deine SSH-Schlüssel herunter; das Zusammenführen läuft in einer Sandbox ohne Schlüssel. Filter und Zugangs-Helfer aus der Repository-Konfiguration werden dort ignoriert. Vorher konnte ein Agent über die Konfiguration seines Projekts beim nächsten Pull an die Schlüssel kommen.
- Sicherheit: Claude Code, Codex und OpenCode bekommen in Hearth einen eigenen Konfigurationsordner. Deine Anweisungen, Skills, Agents und Commands werden nur lesend eingebunden, deine Einstellungen einmal kopiert. Ein Agent kann damit keine Hooks oder MCP-Server mehr in deine echte Konfiguration schreiben, die außerhalb von Hearth laufen würden. **Bitte melde dich in Hearth einmal neu an** (Einstellungen › Agenten › Anmelden). Ältere Claude-Sitzungen starten neu statt fortzusetzen.
- Sicherheit: Bei Gemini CLI und Copilot CLI sind die Dateien, die Befehle starten, schreibgeschützt. `.git/hooks` im Projekt ist für alle Sandboxes gesperrt. Als Arbeitsordner lassen sich keine Ordner mit Hearth-, macOS- oder Agent-Einstellungen mehr wählen.
- Der Terminal-Bereich kennzeichnet, dass seine Shell ohne Sandbox läuft.
- „Im Chat erwähnen“ und die Agent-Aufträge aus Tests und Architektur tippen jetzt direkt in den Terminal-Chat des ausgewählten Agenten.
- Entfernt: die alte Anbindung über devkcode und OpenCode-Server (nativer Chat, Sandbox-Profile, Copilot-Verbrauch). Ein nativer Chat kommt über ACP zurück.
- Intern: Sandbox-Regeln als eigene Typen mit Golden-Tests, typisierte Schnittstelle für Sandbox-Befehle, aufgeteiltes App-Modell, Tests mit swift-testing und eine Build-Pipeline in GitHub Actions, die Releases baut und veröffentlicht.

## 0.2.0 · 2026-10-31

- Editor: Jede Sitzung behält ihre eigenen Tabs. Beim Wechsel zu einem anderen Agenten zeigt der Editor nur dessen Dateien, beim Zurückwechseln sind die alten Tabs samt Position wieder da – auch nach einem Neustart.
- Verzeichnis, Git und Editor aktualisieren sich, sobald ein Agent Dateien ändert.
- Updates und Installer laden vom umbenannten Repository pvanissem/hearth-ide.

## 0.1.0 · 2026-10-31

- Settings: show ports without thousands separator
- Git pane: allow the repository's remote hosts
- Native settings for the new sandbox
- Git pane: fetch/pull/clone in Hearth's nono sandbox, SSH included
- New app icon
- Agents: offer resume only when the agent has a conversation to continue
- Build & Deployment: run tasks in Hearth's nono sandbox without devkcode
- Run agents in Hearth's own nono sandbox with a terminal chat
- Hearth IDE: initial import from devkdesk without internal infrastructure
