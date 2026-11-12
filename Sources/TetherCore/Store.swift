import Foundation

/// Everything Tether knows lives in one JSON file in Application Support. Nothing leaves the Mac.
public final class Store {
    public let url: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
    }

    public func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        do {
            // Lay the stored settings over the current defaults so a newer build can add settings
            // without the old file failing to decode.
            var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any] ?? [:]
            if let stored = root["settings"] as? [String: Any] {
                settings.merge(stored) { _, new in new }
            }
            root["settings"] = settings
            return try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: root))
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.deletingLastPathComponent().appendingPathComponent("state.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("Tether: could not read state (%@); moved it to %@", "\(error)", backup.path)
            return AppState()
        }
    }

    public func save(_ state: AppState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("Tether: could not save state: %@", "\(error)")
        }
    }
}
