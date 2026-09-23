import AppKit
import Foundation

/// Separator used to hand a multi-selection from Shortcuts to `clipstack queue`.
/// Deliberately something that never occurs in real copied text.
let QUEUE_SENTINEL = "@@CLIPSTACK@@"

struct PasteQueue: Codable {
    var items: [String] = []
    var index: Int = 0
}

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

/// `CLIPSTACK_PASTEBOARD` swaps the system clipboard for a private named
/// pasteboard, so the test suite never touches what you actually copied.
let pasteboard: NSPasteboard = {
    if let name = ProcessInfo.processInfo.environment["CLIPSTACK_PASTEBOARD"], !name.isEmpty {
        return NSPasteboard(name: NSPasteboard.Name(name))
    }
    return .general
}()

func setClipboard(_ text: String) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

func emitJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else {
        out("[]"); return
    }
    out(s)
}

func loadQueue() -> PasteQueue {
    guard let data = try? Data(contentsOf: Paths.queue),
          let q = try? JSONDecoder().decode(PasteQueue.self, from: data) else { return PasteQueue() }
    return q
}

func saveQueue(_ q: PasteQueue) {
    guard let data = try? JSONEncoder().encode(q) else { return }
    try? data.write(to: Paths.queue, options: .atomic)
}

let usage = """
clipstack — clipboard history recorder for macOS

  clipstack watch                 record every copy (run by launchd)
  clipstack list [-n N] [--pretty|--sep]
                                  recent clips; JSON array of strings by default,
                                  --sep joins them with the Shortcuts sentinel
  clipstack copy <index>          put clip #index back on the clipboard
  clipstack search <query>        filter history, same output as list
  clipstack pick [--join SEP]     pick several clips in a dialog, merge onto clipboard
  clipstack pick --queue          pick several clips and start a paste queue
  clipstack merge <index>... [--join SEP]
                                  merge those clips onto the clipboard, in that order
  clipstack queue <index>...      start a paste queue with those clips, in that order
  clipstack queue                 read sentinel-joined items on stdin, start a paste queue
  clipstack next                  load the next queued item onto the clipboard
  clipstack queue-status          how far through the queue you are
  clipstack pin <index> | unpin <index>
  clipstack clear                 wipe history (pinned clips survive)
  clipstack status                where things live and how big they are
"""

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func intFlag(_ name: String, default def: Int) -> Int {
    guard let i = args.firstIndex(of: name), args.count > i + 1, let v = Int(args[i + 1]) else { return def }
    return v
}

/// Arguments after the command, minus flags and the values that follow them.
func positionalArgs() -> [String] {
    let takesValue: Set<String> = ["-n", "--limit", "--join"]
    var result: [String] = []
    var i = 1
    while i < args.count {
        if takesValue.contains(args[i]) { i += 2; continue }
        if !args[i].hasPrefix("-") { result.append(args[i]) }
        i += 1
    }
    return result
}

/// The `--join` separator, with \n and \t spelled as escapes. Defaults to a new line.
func joiner() -> String {
    guard let i = args.firstIndex(of: "--join"), args.count > i + 1 else { return "\n" }
    return args[i + 1]
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
}

/// Maps index arguments onto clip texts, exiting with a message on a bad one.
func clipsAt(_ indexes: [String], in clips: [Clip]) -> [String] {
    indexes.map { arg in
        guard let i = Int(arg), clips.indices.contains(i) else {
            err("clipstack: no clip #\(arg) (valid: 0…\(max(clips.count - 1, 0)))"); exit(1)
        }
        return clips[i].text
    }
}

func mergeOntoClipboard(_ texts: [String]) {
    setClipboard(texts.joined(separator: joiner()))
    out("copied \(texts.count) clips")
}

/// Loads the first item onto the clipboard and leaves the rest for `next`.
func startQueue(_ texts: [String]) {
    setClipboard(texts[0])
    saveQueue(PasteQueue(items: texts, index: 1))
    out("1/\(texts.count)")
}

let config = Config.load()

switch command {

case "watch":
    let store = Store(config: config)
    Watcher(store: store, config: config).run()

case "list", "search":
    let store = Store(config: config)
    // Each clip keeps its position in the full list, because that is the
    // number `copy`, `pin` and `merge` take — search results included.
    var rows = Array(store.ordered().enumerated())
    if command == "search" {
        let terms = positionalArgs().map { $0.lowercased() }
        if !terms.isEmpty {
            rows = rows.filter { row in
                let hay = (row.element.text + " " + (row.element.app ?? "")).lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
        }
    }
    let limit = intFlag("-n", default: intFlag("--limit", default: config.listLimit))
    rows = Array(rows.prefix(limit))

    if args.contains("--sep") {
        // Sentinel-joined so Shortcuts can Split Text without tripping over
        // newlines inside individual clips.
        out(rows.map(\.element.text).joined(separator: QUEUE_SENTINEL))
    } else if args.contains("--pretty") {
        if rows.isEmpty { out(command == "search" ? "(no matches)" : "(no clips yet)") }
        for (i, clip) in rows {
            let pin = clip.pinned ? "*" : " "
            let src = clip.app.map { " — \($0)" } ?? ""
            out(String(format: "%3d%@ %@%@", i, pin, clip.label(), src))
        }
    } else {
        emitJSON(rows.map(\.element.text))
    }

case "pick":
    let store = Store(config: config)
    let clips = store.ordered(limit: config.listLimit)
    guard !clips.isEmpty else { err("clipstack: history is empty"); exit(1) }
    let wantQueue = args.contains("--queue")
    let picked = Picker.choose(
        labels: Picker.labels(for: clips),
        prompt: wantQueue ? "Queue clips in paste order" : "Pick clips to paste"
    )
    guard !picked.isEmpty else { err("clipstack: nothing picked"); exit(0) }
    let texts = picked.compactMap { clips.indices.contains($0) ? clips[$0].text : nil }
    guard !texts.isEmpty else { exit(0) }
    if wantQueue { startQueue(texts) } else { mergeOntoClipboard(texts) }

case "merge":
    let indexes = positionalArgs()
    guard !indexes.isEmpty else { err("clipstack: merge needs one or more clip indexes"); exit(1) }
    mergeOntoClipboard(clipsAt(indexes, in: Store(config: config).ordered()))

case "copy":
    let store = Store(config: config)
    let clips = store.ordered()
    guard args.count > 1, let idx = Int(args[1]), clips.indices.contains(idx) else {
        err("clipstack: copy needs a valid index (0…\(max(clips.count - 1, 0)))"); exit(1)
    }
    setClipboard(clips[idx].text)
    err("copied #\(idx)")

case "pin", "unpin":
    let store = Store(config: config)
    let clips = store.ordered()
    guard args.count > 1, let idx = Int(args[1]), clips.indices.contains(idx) else {
        err("clipstack: \(command) needs a valid index"); exit(1)
    }
    if store.setPinned(text: clips[idx].text, pinned: command == "pin") {
        err("\(command)ned #\(idx)")
    }

case "queue":
    let indexes = positionalArgs()
    if !indexes.isEmpty {
        startQueue(clipsAt(indexes, in: Store(config: config).ordered()))
        exit(0)
    }
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let items = raw.components(separatedBy: QUEUE_SENTINEL)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }
        .filter { !$0.isEmpty }
    guard !items.isEmpty else { err("clipstack: nothing to queue"); exit(1) }
    startQueue(items)

case "next":
    var q = loadQueue()
    guard q.index < q.items.count else {
        saveQueue(PasteQueue())
        out("queue empty")
        exit(0)
    }
    setClipboard(q.items[q.index])
    q.index += 1
    saveQueue(q)
    out("\(q.index)/\(q.items.count)")

case "queue-status":
    let q = loadQueue()
    out(q.items.isEmpty ? "no queue" : "\(q.index)/\(q.items.count)")

case "clear":
    let store = Store(config: config)
    let removed = store.clearUnpinned()
    saveQueue(PasteQueue())
    err("cleared \(removed) clips, kept \(store.history.items.count) pinned")

case "status":
    let store = Store(config: config)
    let size = (try? Data(contentsOf: Paths.history).count) ?? 0
    out("history : \(Paths.history.path)")
    out("clips   : \(store.history.items.count) (\(store.history.items.filter(\.pinned).count) pinned), \(size / 1024) KB")
    out("config  : \(Paths.config.path)")
    let q = loadQueue()
    out("queue   : \(q.items.isEmpty ? "none" : "\(q.index)/\(q.items.count)")")

default:
    out(usage)
}
