import Foundation

/// Hand-off folder between the share extension and the app, inside the shared
/// app-group container. When the app group isn't available (it depends on how the
/// app was signed), `isAvailable` is false and the extension copies links instead.
enum SharedInbox {
    static let appGroupID = "group.com.adeal.sauti"

    struct Item: Codable {
        enum Kind: String, Codable {
            case url, text
        }

        var kind: Kind
        var value: String
        var title: String?
        var date: Date
    }

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    static var isAvailable: Bool { directory != nil }

    @discardableResult
    static func add(_ item: Item) -> Bool {
        guard let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
            try JSONEncoder().encode(item).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Returns waiting items (oldest first) and removes them from the inbox.
    static func drain() -> [Item] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        var items: [Item] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let item = try? JSONDecoder().decode(Item.self, from: data) {
                items.append(item)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return items.sorted { $0.date < $1.date }
    }
}
