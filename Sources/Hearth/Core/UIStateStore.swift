import Foundation

/// Small JSON-in-UserDefaults store for UI state that should survive restarts.
enum UIStateStore {
    enum Key: String {
        case paneTree, splitWeights, previewMode, previewFile, textScales, openTabs, detachedTabs,
             editorWorkspaces, shownEditorWorkspace, savedLayouts
    }

    static func save<T: Encodable>(_ value: T?, as key: Key) {
        // Snapshot runs must not change the user's saved state.
        guard ProcessInfo.processInfo.environment["HEARTH_SNAPSHOT"] == nil else { return }
        let k = "ui." + key.rawValue
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: k)
            return
        }
        UserDefaults.standard.set(data, forKey: k)
    }

    static func load<T: Decodable>(_ key: Key) -> T? {
        guard let data = UserDefaults.standard.data(forKey: "ui." + key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
