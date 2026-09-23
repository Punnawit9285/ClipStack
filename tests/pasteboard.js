// Reads and writes a named pasteboard, standing in for "another app copied
// something" without touching the real clipboard.
//
//   osascript -l JavaScript pasteboard.js NAME get
//   osascript -l JavaScript pasteboard.js NAME set TEXT [EXTRA_TYPE...]
//   osascript -l JavaScript pasteboard.js NAME file PATH...        one item per file
//   osascript -l JavaScript pasteboard.js NAME data TYPE=PATH... [--text TEXT]
//   osascript -l JavaScript pasteboard.js NAME types                types of each item, as JSON
//   osascript -l JavaScript pasteboard.js NAME save TYPE OUT        first item's TYPE data to OUT
//   osascript -l JavaScript pasteboard.js NAME urls                 file URLs on the pasteboard, as JSON
//   osascript -l JavaScript pasteboard.js NAME attachments          attachments in the RTFD, if any
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
        pb.writeObjects($(rest.map(p => $.NSURL.fileURLWithPath(p))));
        return '';
    case 'data': {
        const item = $.NSPasteboardItem.alloc.init;
        for (let i = 0; i < rest.length; i++) {
            if (rest[i] === '--text') { item.setStringForType($(rest[++i]), $.NSPasteboardTypeString); continue; }
            const [type, path] = rest[i].split('=');
            item.setDataForType($.NSData.dataWithContentsOfFile($(path)), $(type));
        }
        pb.clearContents;
        pb.writeObjects($([item]));
        return '';
    }
    case 'types': {
        const items = pb.pasteboardItems, out = [];
        for (let i = 0; i < items.count; i++) out.push(ObjC.deepUnwrap(items.objectAtIndex(i).types));
        return JSON.stringify(out);
    }
    case 'save': {
        const d = pb.pasteboardItems.objectAtIndex(0).dataForType($(rest[0]));
        if (d.isNil()) return 'none';
        d.writeToFileAtomically($(rest[1]), true);
        return String(d.length);
    }
    case 'urls': {
        const urls = pb.readObjectsForClassesOptions($([$.NSURL]), $({}));
        const out = [];
        for (let i = 0; i < (urls.isNil() ? 0 : urls.count); i++) out.push(ObjC.unwrap(urls.objectAtIndex(i).path));
        return JSON.stringify(out);
    }
    case 'attachments': {
        const d = pb.dataForType($.NSPasteboardTypeRTFD);
        if (d.isNil()) return '0';
        const s = ObjC.unwrap($.NSAttributedString.alloc.initWithRTFDDocumentAttributes(d, null).string);
        return String((s.match(/￼/g) || []).length);
    }
    case 'release':
        pb.releaseGlobally;
        return '';
    }
    throw new Error('unknown command: ' + cmd);
}
