import Foundation

/// A picker built on AppleScript's `choose from list`, which supports multiple
/// selection natively. Used as a Shortcuts-free path to the same behaviour.
enum Picker {

    /// Shows `labels` and returns the indices the user ticked, in list order.
    /// Returns an empty array when the dialog is cancelled.
    static func choose(labels: [String], prompt: String) -> [Int] {
        guard !labels.isEmpty else { return [] }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstack-picker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? labels.joined(separator: QUEUE_SENTINEL).write(to: tmp, atomically: true, encoding: .utf8)) != nil
        else { return [] }

        // The list is handed over via a file so that no clip text ever has to be
        // escaped into the AppleScript source.
        let script = """
        set raw to do shell script "cat " & quoted form of "\(tmp.path)"
        set AppleScript's text item delimiters to "\(QUEUE_SENTINEL)"
        set theItems to text items of raw
        set chosen to choose from list theItems with prompt "\(prompt)" with multiple selections allowed
        if chosen is false then return ""
        set AppleScript's text item delimiters to "\(QUEUE_SENTINEL)"
        return chosen as text
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }

        stdinPipe.fileHandleForWriting.write(script.data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let reply = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return [] }

        return reply.components(separatedBy: QUEUE_SENTINEL).compactMap { label in
            guard let dot = label.range(of: ". ") else { return nil }
            return Int(label[label.startIndex..<dot.lowerBound])
        }
    }

    /// Numbered single-line labels, so the chosen entries can be mapped back.
    static func labels(for clips: [Clip]) -> [String] {
        clips.enumerated().map { "\($0.offset). \($0.element.label(width: 90))" }
    }
}
