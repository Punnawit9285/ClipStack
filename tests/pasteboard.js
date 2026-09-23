// Reads and writes a named pasteboard, standing in for "another app copied
// something" without touching the real clipboard.
//
//   osascript -l JavaScript pasteboard.js NAME get
//   osascript -l JavaScript pasteboard.js NAME set TEXT [EXTRA_TYPE...]
//   osascript -l JavaScript pasteboard.js NAME file PATH
//   osascript -l JavaScript pasteboard.js NAME release

ObjC.import('AppKit');

function run(argv) {
    const [name, cmd, ...rest] = argv;
    const pb = $.NSPasteboard.pasteboardWithName(name);

    switch (cmd) {
    case 'get': {
        const s = pb.stringForType($.NSPasteboardTypeString);
        return s.isNil() ? '' : ObjC.unwrap(s);
    }
    case 'set':
        pb.clearContents;
        pb.setStringForType($(rest[0]), $.NSPasteboardTypeString);
        // Extra types mimic markers such as org.nspasteboard.ConcealedType.
        for (const type of rest.slice(1)) pb.setStringForType($(''), $(type));
        return '';
    case 'file':
        pb.clearContents;
        pb.writeObjects($([$.NSURL.fileURLWithPath(rest[0])]));
        return '';
    case 'release':
        pb.releaseGlobally;
        return '';
    }
    throw new Error('unknown command: ' + cmd);
}
