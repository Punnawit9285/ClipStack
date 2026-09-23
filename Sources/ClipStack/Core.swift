import Foundation

// MARK: - Locations

enum Paths {
    /// `CLIPSTACK_HOME` moves everything elsewhere, e.g. so tests never touch real history.
    static let dir: URL = {
        let d: URL
        if let custom = ProcessInfo.processInfo.environment["CLIPSTACK_HOME"], !custom.isEmpty {
            d = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            d = base.appendingPathComponent("ClipStack", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var history: URL { dir.appendingPathComponent("history.json") }
    static var queue: URL   { dir.appendingPathComponent("queue.json") }
    static var config: URL  { dir.appendingPathComponent("config.json") }
}

// MARK: - Config

struct Config: Codable {
    var maxItems: Int = 500          // how many clips to retain on disk
    var listLimit: Int = 60          // how many to offer the Shortcuts picker
    var pollSeconds: Double = 0.5
    var maxChars: Int = 1_000_000    // skip anything bigger than this
    var ignoredBundleIDs: [String] = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
    ]

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write("clipstack: ignoring \(Paths.config.path): \(error)\n".data(using: .utf8)!)
            return Config()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Paths.config, options: .atomic) }
    }
}

extension Config {
    // Decoded by hand so a config.json that sets only a few keys keeps the
    // defaults for the rest, instead of failing and being ignored wholesale.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? maxItems
        listLimit = try c.decodeIfPresent(Int.self, forKey: .listLimit) ?? listLimit
        pollSeconds = max(0.1, try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? pollSeconds)
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? maxChars
        ignoredBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? ignoredBundleIDs
    }
}

// MARK: - Model

struct Clip: Codable, Equatable {
    var text: String
    var app: String?
    var at: Date
    var pinned: Bool = false

    /// Single-line, bounded rendering used for `--pretty` listings.
    func label(width: Int = 78) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: "  ")
        let squashed = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        if squashed.count <= width { return squashed }
        return String(squashed.prefix(width - 1)) + "…"
    }
}

// MARK: - Store

struct History: Codable {
    var version = 1
    var items: [Clip] = []
}

final class Store {
    private(set) var history: History
    private let config: Config

    init(config: Config = .load()) {
        self.config = config
        self.history = Store.readFromDisk() ?? History()
    }

    /// Nil when the file exists but can't be decoded, so a bad read never wipes history.
    private static func readFromDisk() -> History? {
        guard FileManager.default.fileExists(atPath: Paths.history.path) else { return History() }
        guard let data = try? Data(contentsOf: Paths.history) else { return nil }
        return try? decoder.decode(History.self, from: data)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()

    /// Adds a clip, promoting an existing identical one instead of duplicating.
    /// Returns true when the store changed.
    @discardableResult
    func add(text: String, app: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.count <= config.maxChars else { return false }
        // The CLI edits history.json too (pin, clear, …). Start from what is on
        // disk so a long-running watcher never writes a stale copy over those edits.
        if let fresh = Store.readFromDisk() { history = fresh }
        if history.items.first?.text == text { return false }

        if let idx = history.items.firstIndex(where: { $0.text == text }) {
            var existing = history.items.remove(at: idx)
            existing.at = Date()
            existing.app = app ?? existing.app
            history.items.insert(existing, at: 0)
        } else {
            history.items.insert(Clip(text: text, app: app, at: Date()), at: 0)
        }
        trim()
        save()
        return true
    }

    private func trim() {
        guard history.items.count > config.maxItems else { return }
        var kept: [Clip] = []
        var unpinned = 0
        for clip in history.items {
            if clip.pinned { kept.append(clip); continue }
            if unpinned < config.maxItems { kept.append(clip); unpinned += 1 }
        }
        history.items = kept
    }

    func save() {
        guard let data = try? Store.encoder.encode(history) else { return }
        try? data.write(to: Paths.history, options: .atomic)
    }

    /// Returns true when a clip with exactly this text had its pin flag changed.
    @discardableResult
    func setPinned(text: String, pinned: Bool) -> Bool {
        guard let idx = history.items.firstIndex(where: { $0.text == text }) else { return false }
        history.items[idx].pinned = pinned
        save()
        return true
    }

    /// Drops everything except pinned clips. Returns how many were removed.
    @discardableResult
    func clearUnpinned() -> Int {
        let before = history.items.count
        history.items = history.items.filter(\.pinned)
        save()
        return before - history.items.count
    }

    /// Most recent first, pinned clips hoisted to the top.
    func ordered(limit: Int? = nil) -> [Clip] {
        let sorted = history.items.enumerated()
            .sorted { a, b in
                if a.element.pinned != b.element.pinned { return a.element.pinned }
                return a.offset < b.offset
            }
            .map(\.element)
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }
}
