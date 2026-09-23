import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    /// Images and videos that were copied as data, one file each, named by content hash.
    static let media: URL = {
        let d = dir.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}

// MARK: - Config

struct Config: Codable {
    var maxItems: Int = 500          // how many clips to retain on disk
    var listLimit: Int = 60          // how many to offer the Shortcuts picker
    var pollSeconds: Double = 0.5
    var maxChars: Int = 1_000_000    // skip anything bigger than this
    var recordMedia: Bool = true     // keep images and videos copied as data
    var maxMediaMB: Int = 100        // skip any single image or video bigger than this
    var mediaBudgetMB: Int = 1024    // beyond this, the oldest images and videos go first
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
        recordMedia = try c.decodeIfPresent(Bool.self, forKey: .recordMedia) ?? recordMedia
        maxMediaMB = try c.decodeIfPresent(Int.self, forKey: .maxMediaMB) ?? maxMediaMB
        mediaBudgetMB = try c.decodeIfPresent(Int.self, forKey: .mediaBudgetMB) ?? mediaBudgetMB
        ignoredBundleIDs = try c.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? ignoredBundleIDs
    }
}

// MARK: - Model

/// An image or video that was on the clipboard as data (not as a file).
struct Media: Codable, Equatable {
    var file: String          // name inside Paths.media
    var type: String          // the UTI it was copied as, e.g. public.png
    var kind: String          // "image" or "video"
    var width: Int? = nil
    var height: Int? = nil
    var bytes: Int

    var url: URL { Paths.media.appendingPathComponent(file) }
    var isVideo: Bool { kind == "video" }

    var title: String {
        if isVideo { return "🎬 Video " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        if let width, let height { return "🖼 Image \(width)×\(height)" }
        return "🖼 Image"
    }
}

struct Clip: Codable, Equatable {
    /// The text. For file clips, the paths one per line; for media, any text
    /// that came with it (a browser's image URL, say), often empty.
    var text: String
    var app: String?
    var at: Date
    var pinned: Bool = false
    /// Files copied in Finder or elsewhere; pasted back as the files themselves.
    var files: [String]? = nil
    var media: Media? = nil

    /// What makes two clips the same, for de-duplication and pinning.
    var key: String {
        if let media { return "media:" + media.file }
        if let files { return "files:" + files.joined(separator: "\n") }
        return "text:" + text
    }

    /// Text for scripts (`list`, `--sep`). Images and videos are named as such,
    /// followed by any text that came with them.
    var plainText: String {
        guard let media else { return text }
        return text.isEmpty ? media.title : media.title + " · " + text
    }

    /// Single-line, bounded rendering used for listings and pickers.
    func label(width: Int = 78) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: "  ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let line: String
        if let media {
            line = flat.isEmpty ? media.title : media.title + " · " + flat
        } else if let files {
            line = Clip.describe(files: files)
        } else {
            line = flat
        }
        if line.count <= width { return line }
        return String(line.prefix(width - 1)) + "…"
    }

    static func describe(files: [String]) -> String {
        let names = files.map { ($0 as NSString).lastPathComponent }
        if files.count == 1 { return icon(for: files[0]) + " " + names[0] }
        return "🗂 \(files.count) files: " + names.joined(separator: ", ")
    }

    /// Picked from the extension alone, so listing never touches the disk.
    static func icon(for path: String) -> String {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "📄" }
        if type.conforms(to: .movie) { return "🎬" }
        if type.conforms(to: .image) { return "🖼" }
        if type.conforms(to: .audio) { return "🎵" }
        return "📄"
    }
}

// MARK: - Media files

enum MediaStore {
    /// Formats kept exactly as copied. Anything else (TIFF above all, which is
    /// uncompressed and huge) is stored as PNG instead.
    private static let keptImageTypes: [UTType] = [.png, .jpeg, .gif, .heic, .webP]

    /// Writes image or video data into Paths.media and describes it. Returns
    /// nil when it is over `maxBytes` or can't be read. Safe off the main thread.
    static func save(_ data: Data, type: UTType, maxBytes: Int) -> Media? {
        var data = data
        var type = type
        let isVideo = type.conforms(to: .movie)
        if !isVideo, !keptImageTypes.contains(where: { type.conforms(to: $0) }) {
            guard let png = PNGEncoder.encode(data) else { return nil }
            data = png
            type = .png
        }
        guard data.count <= maxBytes else { return nil }

        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let ext = type.preferredFilenameExtension ?? (isVideo ? "mov" : "png")
        let name = "\(digest).\(ext)"
        let url = Paths.media.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }

        var media = Media(file: name, type: type.identifier, kind: isVideo ? "video" : "image", bytes: data.count)
        if !isVideo, let size = pixelSize(of: data) { (media.width, media.height) = size }
        return media
    }

    /// Reads the size from the image header, without decoding any pixels.
    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

/// PNG encoding through ImageIO, which (unlike AppKit) is fine on any thread.
enum PNGEncoder {
    static func encode(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Paste queue

struct PasteQueue: Codable {
    var items: [Clip] = []
    var index: Int = 0
}

func loadQueue() -> PasteQueue {
    guard let data = try? Data(contentsOf: Paths.queue),
          let q = try? Store.decoder.decode(PasteQueue.self, from: data) else { return PasteQueue() }
    return q
}

func saveQueue(_ q: PasteQueue) {
    guard let data = try? Store.encoder.encode(q) else { return }
    try? data.write(to: Paths.queue, options: .atomic)
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

    /// Adds a text clip. Returns true when the store changed.
    @discardableResult
    func add(text: String, app: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.count <= config.maxChars else { return false }
        return record(Clip(text: text, app: app, at: Date()))
    }

    /// Adds files by reference: nothing is copied, however large they are.
    @discardableResult
    func add(files: [String], app: String?) -> Bool {
        guard !files.isEmpty else { return false }
        return record(Clip(text: files.joined(separator: "\n"), app: app, at: Date(), files: files))
    }

    /// Adds an image or video already written by `MediaStore.save`.
    @discardableResult
    func add(media: Media, text: String, app: String?) -> Bool {
        record(Clip(text: text, app: app, at: Date(), media: media))
    }

    /// Moves an existing clip to the top, e.g. when ClipStack itself pasted it back.
    @discardableResult
    func promote(key: String) -> Bool {
        if let fresh = Store.readFromDisk() { history = fresh }
        guard let existing = history.items.first(where: { $0.key == key }) else { return false }
        return record(existing)
    }

    /// Inserts a clip at the top, promoting an existing identical one instead of duplicating.
    private func record(_ clip: Clip) -> Bool {
        // The CLI edits history.json too (pin, clear, …). Start from what is on
        // disk so a long-running watcher never writes a stale copy over those edits.
        if let fresh = Store.readFromDisk() { history = fresh }
        if history.items.first?.key == clip.key { return false }

        if let idx = history.items.firstIndex(where: { $0.key == clip.key }) {
            var existing = history.items.remove(at: idx)
            existing.at = Date()
            existing.app = clip.app ?? existing.app
            history.items.insert(existing, at: 0)
        } else {
            history.items.insert(clip, at: 0)
        }
        let dropped = trim()
        save()
        if dropped { pruneMedia() }
        return true
    }

    /// Enforces `maxItems` and the media budget. Returns true if anything went.
    private func trim() -> Bool {
        let before = history.items.count
        var unpinned = 0
        var mediaBytes = 0
        let budget = config.mediaBudgetMB * 1_048_576
        history.items = history.items.filter { clip in
            if clip.pinned { return true }
            unpinned += 1
            if unpinned > config.maxItems { return false }
            // Newest first, so once the budget is spent every older image or video goes.
            if let media = clip.media {
                mediaBytes += media.bytes
                if mediaBytes > budget { return false }
            }
            return true
        }
        return history.items.count != before
    }

    /// Deletes media files that neither history nor the paste queue points at.
    func pruneMedia() {
        var used = Set(history.items.compactMap { $0.media?.file })
        used.formUnion(loadQueue().items.compactMap { $0.media?.file })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.media.path)) ?? []
        for name in files where !used.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: Paths.media.appendingPathComponent(name))
        }
    }

    func save() {
        guard let data = try? Store.encoder.encode(history) else { return }
        try? data.write(to: Paths.history, options: .atomic)
    }

    /// Returns true when the clip with this key had its pin flag changed.
    @discardableResult
    func setPinned(key: String, pinned: Bool) -> Bool {
        guard let idx = history.items.firstIndex(where: { $0.key == key }) else { return false }
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
        pruneMedia()
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

    /// Size of everything in Paths.media, for `status`.
    static func mediaUsage() -> (files: Int, bytes: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.media.path)) ?? []
        var bytes = 0
        for name in names where !name.hasPrefix(".") {
            let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.media.appendingPathComponent(name).path)
            bytes += (attrs?[.size] as? Int) ?? 0
        }
        return (names.filter { !$0.hasPrefix(".") }.count, bytes)
    }
}
