#!/usr/bin/env python3
"""Tests for the iPhone/iPad shortcuts, runnable anywhere.

Shortcuts can't run in CI, so this executes the workflows that
ios/make-shortcuts.py generates with a small interpreter for the handful of
actions they use. The interpreter copies the Shortcuts behaviours that matter
here, including two that bit during device testing:

  - "Get Items in Range" fails when the list is shorter than the range
  - text read from an existing but empty file still "has any value"

    python3 tests/test-ios.py
"""
import hashlib
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("gen", os.path.join(ROOT, "ios", "make-shortcuts.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
S = gen.SENTINEL


class Stop(Exception):
    """The shortcut stopped (an error, or Cancel on an alert)."""


class File:
    """A file: text read from the Shortcuts folder, or an image or video."""

    def __init__(self, text="", name="file.txt", data=None):
        self.text, self.name = text, name
        self.data = data if data is not None else text.encode()

    def __eq__(self, other):
        return isinstance(other, File) and (self.name, self.data) == (other.name, other.data)

    def __repr__(self):
        return f"File({self.name!r}, {len(self.data)} bytes)"


class Image:
    """An image content item: pastes as picture data, not as a file."""

    def __init__(self, data):
        self.data = data


class Device:
    """Clipboard, the Shortcuts folder, and scripted answers to any UI."""

    def __init__(self, files=None, clipboard=""):
        self.files = dict(files or {})
        self.clipboard = clipboard
        self.picks = []        # one list of row indexes per Choose from List
        self.alert_ok = True   # answer to alerts that have a Cancel button
        self.shown = []        # notifications and alerts, in order

    def run(self, workflow, shortcut_input=None):
        Runner(self, workflow, shortcut_input).run()


class Runner:
    def __init__(self, device, workflow, shortcut_input):
        self.d = device
        self.actions = workflow["WFWorkflowActions"]
        self.outputs = {}
        if shortcut_input is None and workflow.get("WFWorkflowNoInputBehavior", {}).get("Name") \
                == "WFWorkflowNoInputBehaviorGetClipboard":
            shortcut_input = device.clipboard
        self.input = shortcut_input

    # --- values ---------------------------------------------------------------

    def ref(self, value):
        if value["Type"] == "ExtensionInput":
            return self.input
        if value["Type"] == "Variable" and value["VariableName"] == "Repeat Item":
            return self.repeat_item
        return self.outputs[value["OutputUUID"]]

    def resolve(self, param):
        if not isinstance(param, dict):
            return param
        if param.get("WFSerializationType") == "WFTextTokenAttachment":
            return self.ref(param["Value"])
        if param.get("WFSerializationType") == "WFTextTokenString":
            string = param["Value"]["string"]
            spots = sorted((int(k.strip("{}").split(",")[0]), v)
                           for k, v in param["Value"]["attachmentsByRange"].items())
            for pos, var in reversed(spots):
                # A variable with nothing in it reads as empty text.
                string = string[:pos] + (as_text(self.ref(var), none_ok=True) or "") + string[pos + 1:]
            return string
        raise ValueError(f"unknown parameter shape: {param}")

    # --- control flow ---------------------------------------------------------

    def run(self):
        tree, i = self.parse(0)
        assert i == len(self.actions), "unbalanced If/Repeat"
        self.block(tree)

    def parse(self, i, group=None):
        """Nests the flat action list into ("do" | "if" | "repeat") nodes."""
        nodes = []
        while i < len(self.actions):
            a = self.actions[i]
            ident, p = a["WFWorkflowActionIdentifier"], a["WFWorkflowActionParameters"]
            if ident in ("is.workflow.actions.conditional", "is.workflow.actions.repeat.each"):
                mode, g = p["WFControlFlowMode"], p["GroupingIdentifier"]
                if mode != 0:
                    assert g == group, "control flow closed out of order"
                    return nodes, i
                then, i = self.parse(i + 1, g)
                other = []
                if self.actions[i]["WFWorkflowActionParameters"]["WFControlFlowMode"] == 1:
                    other, i = self.parse(i + 1, g)
                end = self.actions[i]["WFWorkflowActionParameters"]
                kind = "if" if ident.endswith("conditional") else "repeat"
                nodes.append((kind, p, then, other, end))
            else:
                nodes.append(("do", a))
            i += 1
        return nodes, i

    def block(self, nodes):
        """Runs nodes; returns the output of the last one (for If Result etc.)."""
        last = None
        for node in nodes:
            if node[0] == "do":
                ident = node[1]["WFWorkflowActionIdentifier"].removeprefix("is.workflow.actions.")
                p = node[1]["WFWorkflowActionParameters"]
                last = getattr(self, "do_" + ident.replace(".", "_"))(p)
                if "UUID" in p:
                    self.outputs[p["UUID"]] = last
            elif node[0] == "if":
                _, p, then, other, end = node
                last = self.block(then if self.condition(p) else other)
                if "UUID" in end:
                    self.outputs[end["UUID"]] = last
            else:
                _, p, body, _, end = node
                items = self.resolve(p["WFInput"])
                results = []
                for item in items if isinstance(items, list) else [items]:
                    self.repeat_item = item
                    results.append(self.block(body))
                last = results
                if "UUID" in end:
                    self.outputs[end["UUID"]] = results
        return last

    def condition(self, p):
        value = self.resolve(p["WFInput"]["Variable"])
        c = p["WFCondition"]
        if c == 100:                         # has any value — "" counts, as on device
            return value is not None
        if c == 2:                           # is greater than
            return value > p["WFNumberValue"]
        text = as_text(value, none_ok=True) or ""
        if c == 8:                           # begins with
            return text.startswith(p["WFConditionalActionString"])
        if c == 99:                          # contains
            return p["WFConditionalActionString"] in text
        raise ValueError(f"condition {c} not modelled")

    # --- actions ----------------------------------------------------------------

    def do_detect_text(self, p):
        return as_text(self.resolve(p["WFInput"]), none_ok=True)

    def do_properties_files(self, p):
        item = self.resolve(p["WFInput"])
        file = item if isinstance(item, File) else File(as_text(item, none_ok=True) or "", "text.txt")
        if p["WFContentItemPropertyName"] == "File Extension":
            return file.name.rsplit(".", 1)[-1] if "." in file.name else ""
        if p["WFContentItemPropertyName"] == "File Size":
            return f"{len(file.data) / 1_000_000:.1f} MB"
        raise ValueError(p["WFContentItemPropertyName"])

    def do_hash(self, p):
        assert p["WFHashType"] == "SHA256"
        item = self.resolve(p["WFInput"])
        return hashlib.sha256(item.data if isinstance(item, File) else as_text(item).encode()).hexdigest()

    def do_detect_images(self, p):
        item = self.resolve(p["WFInput"])
        return Image(item.data) if isinstance(item, File) and re.search(gen.IMAGE_EXT + "$", item.name, re.I) else None

    def do_getvariable(self, p):
        return self.resolve(p["WFVariable"])

    def do_file_delete(self, p):
        target = self.resolve(p["WFInput"])
        assert p["WFDeleteFileConfirmDeletion"] is False
        for path in [k for k in self.d.files if k == target.name or k.startswith(target.name + "/")]:
            del self.d.files[path]

    def do_gettext(self, p):
        return self.resolve(p["WFTextActionText"])

    def do_documentpicker_open(self, p):
        assert p["WFShowFilePicker"] is False
        path = self.resolve(p["WFGetFilePath"])
        stored = self.d.files.get(path)
        if stored is None and any(k.startswith(path + "/") for k in self.d.files):
            return File(name=path, data=b"")                  # a folder
        if stored is None:
            if p["WFFileErrorIfNotFound"]:
                raise Stop(f"file not found: {path}")
            return None
        return stored if isinstance(stored, File) else File(stored, path.rsplit("/", 1)[-1])

    def do_documentpicker_save(self, p):
        assert p["WFAskWhereToSave"] is False and p["WFSaveFileOverwrite"] is True
        path, item = self.resolve(p["WFFileDestinationPath"]), self.resolve(p["WFInput"])
        self.d.files[path] = File(name=path.rsplit("/", 1)[-1], data=item.data) if isinstance(item, File) \
            and not item.name.endswith(".txt") else as_text(item)

    def do_text_replace(self, p):
        text = self.resolve(p["WFInput"])
        find, repl = self.resolve(p["WFReplaceTextFind"]), self.resolve(p["WFReplaceTextReplace"])
        assert p["WFReplaceTextCaseSensitive"] is True
        if p["WFReplaceTextRegularExpression"]:
            # ICU's \z is Python's \Z; $1 is \1.
            return re.sub(find.replace(r"\z", r"\Z"), repl.replace("$", "\\"), text)
        return text.replace(find, repl)

    def do_text_split(self, p):
        assert p["WFTextSeparator"] == "Custom"
        return self.resolve(p["text"]).split(p["WFTextCustomSeparator"])

    def do_text_combine(self, p):
        items = self.resolve(p["text"])
        sep = "\n" if p["WFTextSeparator"] == "New Lines" else p["WFTextCustomSeparator"]
        return sep.join(items)

    def do_count(self, p):
        value = self.resolve(p["Input"])
        if p["WFCountType"] == "Characters":
            return len(as_text(value, none_ok=True) or "")
        return 0 if value is None else len(value) if isinstance(value, list) else 1

    def do_getitemfromlist(self, p):
        items = self.resolve(p["WFInput"])
        start, end = p["WFItemRangeStart"], p["WFItemRangeEnd"]
        if end > len(items):
            raise Stop(f"The range you specified was outside of the possible range "
                       f"(you asked for items {start} through {end}, and the list has only {len(items)}).")
        return items[start - 1:end]

    def do_choosefromlist(self, p):
        items = self.resolve(p["WFInput"])
        assert p["WFChooseFromListActionSelectMultiple"] is True
        rows = self.d.picks.pop(0)
        return [items[r] for r in sorted(rows)]   # list order, whatever order they were ticked

    def do_setclipboard(self, p):
        item = self.resolve(p["WFInput"])
        # Images, files and lists go on as they are; anything else as text.
        self.d.clipboard = item if isinstance(item, (File, Image, list)) else as_text(item)

    def do_notification(self, p):
        self.d.shown.append(self.resolve(p["WFNotificationActionBody"]))

    def do_alert(self, p):
        self.d.shown.append(p["WFAlertActionTitle"])
        if p["WFAlertActionCancelButtonShown"] and not self.d.alert_ok:
            raise Stop("cancelled")


def as_text(value, none_ok=False):
    if value is None:
        if none_ok:
            return None
        raise Stop("action got no input")
    if isinstance(value, File):
        return value.text if value.name.endswith(".txt") or not value.data else value.name
    if isinstance(value, list):
        return "\n".join(value)
    return str(value)


# --- the tests -------------------------------------------------------------------

WF = gen.build()
P = gen.PREFIX
SAVE, MERGE, QUEUE, NEXT, CLEAR = (WF[P + n] for n in
                                   ("Save", "Paste Multiple", "Queue Multiple", "Paste Next", "Clear"))
H, Q = gen.HISTORY, gen.QUEUE
PASS = FAIL = 0


def check(desc, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  ok    {desc}")
    else:
        FAIL += 1
        print(f"  FAIL  {desc}\n        expected: {want!r}\n        got:      {got!r}")


def clips(device):
    text = device.files.get(H, "")
    return text.split(S) if text else []


def save(device, text):
    device.run(SAVE, text)


print("==> Save")
d = Device()
save(d, "alpha")
check("first save creates history", clips(d), ["alpha"])
save(d, "beta"); save(d, "gamma")
check("newest first", clips(d), ["gamma", "beta", "alpha"])
save(d, "alpha")
check("re-saving promotes instead of duplicating", clips(d), ["alpha", "gamma", "beta"])
save(d, "alphabet"); save(d, "alph")
check("near-identical clips are kept apart", clips(d), ["alph", "alphabet", "alpha", "gamma", "beta"])
save(d, "gamma")
check("…and promoting one leaves its neighbours alone", clips(d), ["gamma", "alph", "alphabet", "alpha", "beta"])
multi = "line one\nline two\n\n  indented\n"
save(d, multi)
check("multi-line clip is kept exactly", clips(d)[0], multi)
save(d, "héllo — 日本語 🎉")
check("unicode round-trips", clips(d)[0], "héllo — 日本語 🎉")
before = dict(d.files)
save(d, "")
check("empty input changes nothing", d.files, before)
check("…and says so", d.shown[-1], "Nothing to save — the clipboard is empty.")
check("shows what it saved", d.shown[-2], "Saved: héllo — 日本語 🎉")

d = Device(clipboard="from the clipboard")
d.run(SAVE)
check("no input: saves the clipboard", clips(d), ["from the clipboard"])
check("Save is offered in the share sheet", "ActionExtension" in SAVE["WFWorkflowTypes"], True)

d = Device(files={H: S.join(f"clip {i}" for i in range(gen.MAX_CLIPS + 5, 0, -1))})
save(d, "newest")
check(f"history is capped at {gen.MAX_CLIPS}", len(clips(d)), gen.MAX_CLIPS)
check("…dropping the oldest", (clips(d)[0], clips(d)[-1]), ("newest", "clip 7"))
d = Device(files={H: S.join(f"clip {i}" for i in range(gen.MAX_CLIPS - 1, 0, -1))})
save(d, "fills it")
check(f"exactly {gen.MAX_CLIPS} is not trimmed", len(clips(d)), gen.MAX_CLIPS)

print("==> Paste Multiple")
d = Device(files={H: S.join(["+44 7700 900112", "jane@acme.io", "Jane Ferrer"])})
d.picks = [[2, 0, 1]]
d.run(MERGE)
check("merges the ticked clips, one per line, in list order",
      d.clipboard, "+44 7700 900112\njane@acme.io\nJane Ferrer")
check("…and reports how many", d.shown[-1], "Merged 3 clips — ready to paste.")
for name, files in (("missing", {}), ("empty", {H: ""})):
    d = Device(files=files, clipboard="untouched")
    d.run(MERGE)
    check(f"{name} history: says it's empty", d.shown, ["ClipStack is empty"])
    check(f"{name} history: clipboard untouched", d.clipboard, "untouched")

print("==> Queue Multiple / Paste Next")
d = Device(files={H: S.join(["c", "b\nwith a second line", "a"])})
d.picks = [[0, 1, 2]]
d.run(QUEUE)
check("first ticked clip goes on the clipboard", d.clipboard, "c")
check("the rest wait in the queue", d.files[Q], S.join(["b\nwith a second line", "a"]))
d.run(NEXT)
check("next loads the second", d.clipboard, "b\nwith a second line")
check("…and shows it", d.shown[-1], "Next clip is on the clipboard: b\nwith a second line")
d.run(NEXT)
check("next loads the last", d.clipboard, "a")
check("…leaving the queue empty", d.files[Q], "")
d.run(NEXT)
check("next on an empty queue leaves the clipboard alone", d.clipboard, "a")
check("…and says the queue is empty", d.shown[-1], "The queue is empty.")

d = Device(files={H: "only"}, clipboard="x")
d.picks = [[0]]
d.run(QUEUE)
check("queueing one clip copies it", (d.clipboard, d.files[Q]), ("only", ""))
d = Device(clipboard="untouched")
d.run(NEXT)
check("next with no queue file leaves the clipboard alone", d.clipboard, "untouched")

print("==> Clear")
d = Device(files={H: S.join(["a", "b"]), Q: "b"})
d.alert_ok = False
try:
    d.run(CLEAR)
except Stop:
    pass
check("Cancel keeps everything", d.files, {H: S.join(["a", "b"]), Q: "b"})
d.alert_ok = True
d.run(CLEAR)
check("OK empties history and queue", d.files, {H: "", Q: ""})

print("==> Images and videos")
M = gen.MEDIA
shot = File(name="IMG_0412.PNG", data=b"\x89PNG fake image " * 50)
movie = File(name="clip.MOV", data=b"fake video " * 200_000)   # about 2 MB
d = Device()
d.run(SAVE, shot)
saved = [k for k in d.files if k.startswith(M + "/")]
check("an image is saved to the media folder", len(saved), 1)
check("…named by its content", saved[0], f"{M}/{hashlib.sha256(shot.data).hexdigest()[:12]}.PNG")
check("…and listed as an image", clips(d)[0], "🖼 Image 0.0 MB — " + saved[0].rsplit("/", 1)[1])
save(d, "some text")
d.run(SAVE, shot)
check("saving the same image again promotes it", (len(clips(d)), clips(d)[0].startswith("🖼 Image")), (2, True))
d.run(SAVE, movie)
check("a video is saved and listed as a video", clips(d)[0].startswith("🎬 Video 2.2 MB — "), True)
check("…kept whole", d.files[f"{M}/{clips(d)[0].rsplit(' ', 1)[1]}"].data, movie.data)
d.run(SAVE, File("a note shared as a file", "note.txt"))
check("text shared as a .txt file is still text", clips(d)[0], "a note shared as a file")

rows = clips(d)                        # note, video, image, some text
image_row, video_row, text_row = rows.index(next(r for r in rows if r.startswith("🖼"))), 1, rows.index("some text")
d.picks = [[image_row, text_row]]
d.run(MERGE)
check("merging an image with text puts both on the clipboard, as items",
      [x if isinstance(x, str) else x.data for x in d.clipboard], [shot.data, "some text"])
check("…the image as picture data, not a file", type(d.clipboard[0]).__name__, "Image")
d.picks = [[0, text_row]]
d.run(MERGE)
check("merging only text still gives one text", d.clipboard, "a note shared as a file\nsome text")

d.picks = [[video_row, text_row]]
d.run(QUEUE)
check("queueing a video puts the video on the clipboard", d.clipboard.data, movie.data)
check("…as a file, which is what apps take for video", type(d.clipboard).__name__, "File")
d.run(NEXT)
check("…then Paste Next gives the text", d.clipboard, "some text")
d.picks = [[0, image_row]]           # the note, then the image
d.run(QUEUE); d.run(NEXT)
check("Paste Next can give an image", (type(d.clipboard).__name__, d.clipboard.data), ("Image", shot.data))

d.alert_ok = True
d.run(CLEAR)
check("Clear deletes the saved images and videos", [k for k in d.files if k.startswith(M)], [])
d = Device()
d.run(CLEAR)
check("Clear works when nothing was ever saved", d.shown[-1], "History cleared.")

print("==> Structure")
for name, wf in WF.items():
    seen, ok = set(), True
    for a in wf["WFWorkflowActions"]:
        p = a["WFWorkflowActionParameters"]
        for used in re.findall(r"'OutputUUID': '([0-9A-F-]+)'", repr(p)):
            ok &= used in seen
        if "UUID" in p:
            seen.add(p["UUID"])
    check(f"{name}: every variable is set before it is used", ok, True)
    ok = all(a["WFWorkflowActionParameters"]["WFInput"]["Variable"]["Value"].get("OutputName") == "File"
             for a in wf["WFWorkflowActions"]
             if a["WFWorkflowActionParameters"].get("WFCondition") == 100)
    check(f"{name}: tests 'has any value' only on files, never on text", ok, True)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
