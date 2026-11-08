import Foundation

/// Installs an update after the app has quit: a detached helper waits for this
/// process to exit, then runs the existing installer (fixed HTTPS URL, SHA-256
/// verified by install.sh), which starts the new version. On failure the old,
/// untouched app is reopened and the result is reported on the next launch.
enum AppUpdateInstaller {
    static let installerURL = "https://github.com/botgarten/hearth-ide/releases/latest/download/install.sh"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hearth IDE")
    }
    static var logURL: URL { supportDirectory.appendingPathComponent("update.log") }
    static var statusURL: URL { supportDirectory.appendingPathComponent("update-status") }

    /// Positional args: $1 pid, $2 log, $3 status file, $4 current app bundle, $5 installer URL.
    /// HEARTH_UPDATE_WAIT (seconds) bounds the wait for the app to quit.
    static let helperScript = #"""
    set -u
    pid="$1"; log="$2"; status="$3"; app="$4"; url="$5"
    waited=0; limit="${HEARTH_UPDATE_WAIT:-300}"
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$limit" ]; then echo "aborted" > "$status"; echo "The app did not quit – update cancelled." >> "$log"; exit 0; fi
      sleep 1; waited=$((waited + 1))
    done
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    echo "== $(date) Update starting" >> "$log"
    if curl -fsSL --proto '=https' --max-time 60 -H "Cache-Control: no-cache" -o "$tmp/install.sh" "$url?t=$(date +%s)" >> "$log" 2>&1 \
       && bash "$tmp/install.sh" >> "$log" 2>&1; then
      echo "succeeded" > "$status"
    else
      echo "failed" > "$status"
      echo "== Update failed; reopening the previous app" >> "$log"
      [ -d "$app" ] && open "$app"
    fi
    """#

    /// Starts the helper. Call only once termination is certain.
    @discardableResult
    static func launchHelper(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             appPath: String = Bundle.main.bundlePath,
                             url: String = installerURL,
                             environment: [String: String]? = nil) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: statusURL)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", helperScript, "hearth-update", String(pid), logURL.path, statusURL.path, appPath, url]
        var env = environment ?? ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true } catch { return false }
    }

    enum Outcome: Equatable { case succeeded, failed, aborted }

    /// Reads and clears the result of the last update attempt.
    static func consumeOutcome(statusURL: URL = statusURL) -> Outcome? {
        guard let raw = try? String(contentsOf: statusURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: statusURL)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "succeeded": return .succeeded
        case "failed": return .failed
        case "aborted": return .aborted
        default: return nil
        }
    }
}
