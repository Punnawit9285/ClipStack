import AppKit
import Foundation
import UniformTypeIdentifiers

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

/// TIFF is added next to other image formats for apps that only read TIFF, but
/// not for very large images, where it would cost hundreds of megabytes.
private let maxTIFFPixels = 25_000_000

/// Puts a clip back on the clipboard the way it was copied: text as text, an
/// image as that image, a video as its data plus a file, files as the files.
func setClipboard(_ clip: Clip) {
    if let files = clip.files {
        writeFiles(files, text: clip.text)
        return
    }
    guard let media = clip.media else {
        setClipboard(clip.text)
        return
    }
    guard let data = try? Data(contentsOf: media.url, options: .mappedIfSafe) else {
        err("clipstack: the stored \(media.kind) is missing; copying its description instead")
        setClipboard(clip.plainText)
        return
    }
    let item = NSPasteboardItem()
    item.setData(data, forType: NSPasteboard.PasteboardType(media.type))
    if media.isVideo {
        // Few apps take raw video data; a file they all understand.
        item.setString(media.url.absoluteString, forType: .fileURL)
    } else if media.type != UTType.tiff.identifier,
              (media.width ?? 0) * (media.height ?? 0) <= maxTIFFPixels,
              let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
        item.setData(tiff, forType: .tiff)
    }
    if !clip.text.isEmpty { item.setString(clip.text, forType: .string) }
    item.setString(clip.key, forType: Watcher.restoredType)
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

/// One pasteboard item per file, so Finder, Mail and Messages paste them all.
private func writeFiles(_ paths: [String], text: String) {
    let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
    if !missing.isEmpty { err("clipstack: no longer on disk: \(missing.joined(separator: ", "))") }
    let items: [NSPasteboardItem] = paths.enumerated().map { i, path in
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        if i == 0 { item.setString(text, forType: .string) }
        return item
    }
    pasteboard.clearContents()
    pasteboard.writeObjects(items)
}

/// Pastes several clips as one:
/// - only text: joined with the separator, as plain text
/// - only files: all of the files at once
/// - anything with an image or video: a rich document with the pictures
///   inline (RTFD for Mac apps, HTML for browsers), plus the text on its own
func mergeOntoClipboard(_ clips: [Clip], separator: String) {
    if clips.count == 1 {
        setClipboard(clips[0])
    } else if clips.allSatisfy({ $0.media == nil && $0.files == nil }) {
        setClipboard(clips.map(\.text).joined(separator: separator))
    } else if clips.allSatisfy({ $0.files != nil }) {
        writeFiles(clips.flatMap { $0.files! }, text: clips.map(\.text).joined(separator: separator))
    } else {
        writeRich(clips, separator: separator)
    }
    out("copied \(clips.count) clips")
}

private func writeRich(_ clips: [Clip], separator: String) {
    let doc = NSMutableAttributedString()
    var html = "<meta charset=\"utf-8\">"
    var plain: [String] = []
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    for (i, clip) in clips.enumerated() {
        if i > 0 {
            doc.append(NSAttributedString(string: separator, attributes: [.font: font]))
            html += escapeHTML(separator)
        }
        if let media = clip.media, let wrapper = try? FileWrapper(url: media.url, options: []) {
            doc.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            if !media.isVideo, let data = wrapper.regularFileContents {
                let mime = UTType(media.type)?.preferredMIMEType ?? "image/png"
                html += "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\""
                if let w = media.width, let h = media.height { html += " width=\"\(w)\" height=\"\(h)\"" }
                html += ">"
            } else {
                html += escapeHTML(media.url.path)
            }
        } else {
            doc.append(NSAttributedString(string: clip.text, attributes: [.font: font]))
            html += escapeHTML(clip.text)
            plain.append(clip.text)
        }
    }

    let item = NSPasteboardItem()
    if let rtfd = doc.rtfd(from: NSRange(location: 0, length: doc.length), documentAttributes: [:]) {
        item.setData(rtfd, forType: .rtfd)
    }
    item.setString(html, forType: .html)
    let text = plain.joined(separator: separator)
    if !text.isEmpty { item.setString(text, forType: .string) }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

private func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\n", with: "<br>")
}
