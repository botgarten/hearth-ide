# Update-Prüfung in Hearth IDE

## Bedienung

- Beim App-Start wird standardmäßig einmal asynchron nach einem neuen Release
  gesucht. Der Start wartet nicht auf das Netzwerk.
- Ein neueres Release erscheint als nichtmodaler Hinweis im Hauptfenster und auf
  dem Welcome-Screen. Der Hinweis bietet den Download und im Hauptfenster einen
  kopierbaren Installer-Befehl. Er lässt sich für diese Version bis zum nächsten
  App-Start ausblenden.
- Unter **Hearth IDE → Einstellungen → Updates** stehen installierte Version,
  veröffentlichtes Release, Prüfergebnis und Zeitpunkt der letzten Prüfung.
  Dort lässt sich die Start-Prüfung dauerhaft abschalten und jederzeit manuell
  erneut prüfen. Zeitstempel und Schalter bleiben nach einem Neustart erhalten.
- Netzwerkprobleme werden in den Einstellungen angezeigt, nicht als
  blockierender Startdialog. Ein Fehler bedeutet nicht „aktuell“.

## Release-Quelle und Versionsvergleich

Die Quelle ist die Datei, die `scripts/release.sh` an jedes GitHub-Release hängt:

`https://github.com/botgarten/hearth-ide/releases/latest/download/latest-version.txt`

Akzeptiert werden ausschließlich stabile Versionsnummern `vMAJOR.MINOR.PATCH`
oder `MAJOR.MINOR.PATCH`. Der Vergleich erfolgt numerisch, nicht alphabetisch.
Eine neuere installierte Version wird nicht zum Downgrade aufgefordert.

`scripts/release.sh` übergibt die Release-Version an `scripts/bundle.sh`. Diese
Bundles tragen den Build-Kanal `release`. Lokale Builds ohne explizites `VERSION`
bekommen `development` und eine Git-Beschreibung einschließlich Dirty-Markierung.
Für Entwicklungsbuilds zeigt die Oberfläche das verfügbare Release, empfiehlt
aber kein vermeintliches Update anhand des alten Tags im Git-Präfix.

## Installation per Klick

„Jetzt aktualisieren“ (Update-Hinweis bzw. Einstellungen → Updates) ist nur aktiv,
wenn ein bestätigt neueres Release vorliegt (nicht für Entwicklungsbuilds).

1. Bestätigungsdialog, danach normales Beenden über `NSApp.terminate`. Abfragen zu
   ungesicherten Dateien und laufenden Sandboxes gelten unverändert.
2. Wird das Beenden abgebrochen, wird das Update verworfen – es startet nicht
   versehentlich bei einem späteren Beenden.
3. Erst in `applicationWillTerminate` startet ein losgelöstes Hilfsskript. Es wartet,
   bis der App-Prozess wirklich beendet ist (höchstens 5 Minuten, sonst Abbruch ohne
   Installation), lädt den Installer von der festen HTTPS-Adresse und führt ihn aus.
   Der Installer prüft SHA-256, ersetzt das Bundle und startet die neue Version.
4. Schlägt das Update fehl, wird die bisherige (unveränderte) App wieder geöffnet.
   Beim nächsten Start zeigt Hearth IDE das Ergebnis an (Erfolg, Fehler oder Abbruch).
   Protokoll: `~/Library/Logs/Hearth IDE/update.log`.

Der ZIP-Download und der kopierbare Terminal-Befehl bleiben als Alternative erhalten.
Bereits ausgelieferte ältere Apps erhalten diese Funktion erst mit einem neuen
Release.

## Transport und Tests

Die Versionsprüfung verwendet eine separate ephemere URLSession ohne Cookies,
Credential-Storage oder Cache. Es werden keine GitLab-/Copilot-Tokens verwendet,
Redirects nur per HTTPS zu `github.com` und GitHubs Asset-Hosts verfolgt (GitHub leitet
`releases/latest/download/…` immer weiter) und maximal 128 Antwortbytes gelesen. Die Prüfung hat
einen Request-Timeout von zehn Sekunden. Fehler enthalten keinen Response-Body.
Feed und Downloadziel sind feste HTTPS-Adressen; Feed-Inhalt kann keine URL oder
einen Shell-Befehl vorgeben. Requests und Downloadlinks umgehen alte Proxy-Caches
mit Query-Parametern.

`AppUpdateTests.swift` prüft mit HTTP-Fixtures Versionsvergleich, ungültige und
überlange Antworten, Redirect-Allowlist, Header, parallele Prüfungen, Einstellungen,
Fehlerzustände, ausgeblendete Hinweise und Entwicklungsbuilds. Zusätzlich werden
der echte native Einstellungen-View und der Installer-Abbruch mit ausschließlich
gemockten Beenden-Befehlen geprüft. `scripts/test.sh` führt
diese Tests ohne Zugangsdaten, echten App-Austausch oder echte Downloads aus.
Der Klick-Updater wird mit dem echten Hilfsskript und nachgebildetem `curl`,
Installer und `open` geprüft: Warten auf das App-Ende, Erfolg, Wiederöffnen bei
Fehler und Abbruch, falls die App weiterläuft.

## Änderungsnotizen (Changelog)

`scripts/release.sh` erzeugt bei jedem Release aus den Commit-Titeln seit dem letzten
Tag einen Abschnitt `## <Version> · <Datum>` und stellt ihn vor die bisher
veröffentlichte `CHANGELOG.md` (kumulativ, neueste zuerst). Die Datei wird mit dem
Release an das GitHub-Release gehängt und über
`releases/latest/download/CHANGELOG.md` gelesen; ältere Releases ohne Datei sind erlaubt.

Der Bestätigungsdialog von „Jetzt aktualisieren“ zeigt die Notizen aller
übersprungenen Versionen (installierte < Version ≤ neueste). Nach einem Update gibt
es „Was ist neu?“ im Hinweis bzw. in den Einstellungen. Die Datei wird ohne
Zugangsdaten, nur mit GitHub-Weiterleitungen und auf 200 KB begrenzt geladen; dargestellt
wird nur Inline-Markdown. Fehlt die Datei oder ist sie nicht erreichbar, erscheint
ein Hinweis statt der Notizen – das Update bleibt möglich.

Das Beenden aus dem geöffneten Willkommensdialog funktioniert: Offene Sheets werden
vor dem Beenden geschlossen, da sie das Beenden sonst blockieren.
