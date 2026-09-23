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
    def __init__(self, text):
        self.text = text


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
        jumps = {}   # If -> its Otherwise (or End If); Otherwise -> its End If
        open_ifs = {}
        for i, a in enumerate(self.actions):
            if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.conditional":
                p = a["WFWorkflowActionParameters"]
                g, mode = p["GroupingIdentifier"], p["WFControlFlowMode"]
                if mode == 0:
                    open_ifs[g] = [i]
                else:
                    open_ifs[g].append(i)
                    if mode == 2:
                        marks = open_ifs.pop(g)
                        for a_i, b_i in zip(marks, marks[1:]):
                            jumps[a_i] = b_i
        assert not open_ifs, "unterminated If"

        i = 0
        while i < len(self.actions):
            a = self.actions[i]
            ident = a["WFWorkflowActionIdentifier"].removeprefix("is.workflow.actions.")
            p = a["WFWorkflowActionParameters"]
            if ident == "conditional":
                mode = p["WFControlFlowMode"]
                if mode == 0 and not self.condition(p):
                    i = jumps[i] + 1   # into Otherwise (or past End If)
                    continue
                if mode == 1:          # the If branch ran; skip Otherwise
                    i = jumps[i]
                i += 1
                continue
            result = getattr(self, "do_" + ident.replace(".", "_"))(p)
            if "UUID" in p:
                self.outputs[p["UUID"]] = result
            i += 1

    def condition(self, p):
        value = self.resolve(p["WFInput"]["Variable"])
        if p["WFCondition"] == 100:          # has any value — "" counts, as on device
            return value is not None
        if p["WFCondition"] == 2:            # is greater than
            return value > p["WFNumberValue"]
        raise ValueError(f"condition {p['WFCondition']} not modelled")

    # --- actions ----------------------------------------------------------------

    def do_detect_text(self, p):
        return as_text(self.resolve(p["WFInput"]), none_ok=True)

    def do_gettext(self, p):
        return self.resolve(p["WFTextActionText"])

    def do_documentpicker_open(self, p):
        assert p["WFShowFilePicker"] is False
        path = p["WFGetFilePath"]
        if path not in self.d.files:
            if p["WFFileErrorIfNotFound"]:
                raise Stop(f"file not found: {path}")
            return None
        return File(self.d.files[path])

    def do_documentpicker_save(self, p):
        assert p["WFAskWhereToSave"] is False and p["WFSaveFileOverwrite"] is True
        self.d.files[p["WFFileDestinationPath"]] = as_text(self.resolve(p["WFInput"]))

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
        self.d.clipboard = as_text(self.resolve(p["WFInput"]))

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
        return value.text
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
check("…and says so", d.shown[-1], "Nothing to save — the clipboard has no text.")
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
    check(f"{name}: never tests 'has any value'", "'WFCondition': 100" in repr(wf), False)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
