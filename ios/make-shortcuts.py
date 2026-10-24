#!/usr/bin/env python3
"""Generate and sign the ClipStack shortcuts for iPhone and iPad.

iOS lets nothing watch the clipboard in the background, so here saving is a
shortcut you trigger (Back Tap, the Action Button, a widget, Control Center or
the share sheet). Everything else — ticking several clips, merging them, or
queueing them — works as on the Mac. Text, images and videos all work.

"ClipStack" does all of it from one menu, so installing is a single Add
Shortcut; shared to from the share sheet, it saves straight away. The
"ClipStack iOS - …" shortcuts each do one of those jobs, for a Back Tap or a
widget that should act without a menu. They all share the same history.

History lives in the Shortcuts folder (iCloud Drive › Shortcuts › ClipStack, or
On My iPhone › Shortcuts › ClipStack when iCloud Drive is off), one text file
with clips separated by a sentinel, newest first:

    history.txt   clip@@CLIPSTACK@@clip@@CLIPSTACK@@clip
    queue.txt     the clips still waiting in the paste queue, same format
    media/        images and videos, each saved once under a hash of its content

An image or video appears in history as a line such as

    🖼 Image 1.2 MB — 3f9a1c2b0d4e.png

and is swapped back for the file itself whenever it is pasted.

These shortcuts contain nothing machine-specific, so the signed files in this
folder can be shared as they are. Run this script only to rebuild them.
"""
import os
import plistlib
import subprocess
import sys
import uuid

SENTINEL = "@@CLIPSTACK@@"
HISTORY = "ClipStack/history.txt"
QUEUE = "ClipStack/queue.txt"
MEDIA = "ClipStack/media"
IMAGE, VIDEO = "🖼 Image", "🎬 Video"
IMAGE_EXT = "png|jpe?g|heic|heif|gif|tiff?|webp|bmp"
VIDEO_EXT = "mov|mp4|m4v|3gp|avi|webm|mkv"
# How an image or video line in history looks; group 1 is its file in MEDIA.
MEDIA_LINE = rf"(?:{IMAGE}|{VIDEO}) .* — ([0-9a-fA-F]{{12}}\.\w+)"
MAX_CLIPS = 200
OUT = os.path.dirname(os.path.abspath(__file__))
PREFIX = "ClipStack iOS - "
ALL_IN_ONE = "ClipStack"
# What ClipStack's menu offers, in order.
MENU = ["Save Clipboard", "Paste Multiple", "Queue Multiple", "Paste Next", "Clear History"]

# Object replacement character: marks where a variable sits inside a text field.
VAR = "\ufffc"


def new_id():
    return str(uuid.uuid4()).upper()


# --- values that can go in an action's parameters ---------------------------

def output(ref):
    """A reference to an earlier action's output. `ref` is (uuid, output name)."""
    return {"OutputUUID": ref[0], "OutputName": ref[1], "Type": "ActionOutput"}


SHORTCUT_INPUT = {"Type": "ExtensionInput"}
REPEAT_ITEM = {"Type": "Variable", "VariableName": "Repeat Item"}


def value(x):
    """Accepts an action's output reference or a ready-made variable."""
    return x if isinstance(x, dict) else output(x)


def text(*parts):
    """A text field mixing literal strings with variables (outputs or refs)."""
    string, attachments = "", {}
    for part in parts:
        if isinstance(part, str):
            string += part
        else:
            attachments[f"{{{len(string.encode('utf-16-le')) // 2}, 1}}"] = value(part)
            string += VAR
    return {"Value": {"string": string, "attachmentsByRange": attachments},
            "WFSerializationType": "WFTextTokenString"}


def var(value):
    """A parameter that is a variable on its own (not text around it)."""
    return {"Value": value, "WFSerializationType": "WFTextTokenAttachment"}


# --- actions -----------------------------------------------------------------

class Flow:
    """Collects actions. Each helper returns a reference to its output.

    `how_to_save` finishes "Copy something, then …", for when history is empty.
    """

    def __init__(self, how_to_save=f"run “{PREFIX}Save”"):
        self.actions = []
        self.how_to_save = how_to_save

    def add(self, identifier, params=None, output_name=None):
        p = dict(params or {})
        ref = None
        if output_name:
            p["UUID"] = new_id()
            ref = (p["UUID"], output_name)
        self.actions.append({"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": p})
        return ref

    def get_text(self, source):
        return self.add("is.workflow.actions.detect.text", {"WFInput": var(value(source))}, "Text")

    def text(self, *parts):
        return self.add("is.workflow.actions.gettext", {"WFTextActionText": text(*parts)}, "Text")

    def get_file(self, path):
        """A file or folder in the Shortcuts folder, or nothing if it isn't there.
        `path` is a string, or an output holding one."""
        return self.add("is.workflow.actions.documentpicker.open", {
            "WFGetFilePath": path if isinstance(path, str) else text(path),
            "WFFileErrorIfNotFound": False,
            "WFShowFilePicker": False,
        }, "File")

    def read_file(self, path):
        """The file's text, or nothing when it doesn't exist yet."""
        return self.get_text(self.get_file(path))

    def save_file(self, path, content):
        """`path` is a string, or a text() mixing strings and outputs."""
        self.add("is.workflow.actions.documentpicker.save", {
            "WFInput": var(value(content)),
            "WFAskWhereToSave": False,
            "WFFileDestinationPath": path,
            "WFSaveFileOverwrite": True,
        })

    def delete(self, source):
        self.add("is.workflow.actions.file.delete", {
            "WFInput": var(value(source)), "WFDeleteFileConfirmDeletion": False})

    def file_detail(self, source, detail):
        """e.g. "File Extension" or "File Size" (text counts as a .txt file)."""
        return self.add("is.workflow.actions.properties.files", {
            "WFInput": var(value(source)), "WFContentItemPropertyName": detail}, detail)

    def images(self, source):
        return self.add("is.workflow.actions.detect.images", {"WFInput": var(value(source))}, "Images")

    def get_variable(self, source):
        return self.add("is.workflow.actions.getvariable", {"WFVariable": var(value(source))}, "Variable")

    def sha256(self, source):
        return self.add("is.workflow.actions.hash", {
            "WFInput": var(value(source)), "WFHashType": "SHA256"}, "Hash")

    def replace(self, source, find, replace="", regex=False):
        return self.add("is.workflow.actions.text.replace", {
            "WFInput": text(source),
            "WFReplaceTextFind": find if isinstance(find, dict) else text(find),
            "WFReplaceTextReplace": text(replace),
            "WFReplaceTextRegularExpression": regex,
            "WFReplaceTextCaseSensitive": True,
        }, "Updated Text")

    def split(self, source, separator=SENTINEL):
        params = {"text": text(source)}
        if separator == "\n":
            params["WFTextSeparator"] = "New Lines"
        else:
            params.update({"WFTextSeparator": "Custom", "WFTextCustomSeparator": separator})
        return self.add("is.workflow.actions.text.split", params, "Split Text")

    def combine(self, source, separator=SENTINEL):
        params = {"text": var(output(source))}
        if separator == "\n":
            params["WFTextSeparator"] = "New Lines"
        else:
            params.update({"WFTextSeparator": "Custom", "WFTextCustomSeparator": separator})
        return self.add("is.workflow.actions.text.combine", params, "Combined Text")

    def first_clips(self, source, count):
        return self.add("is.workflow.actions.getitemfromlist", {
            "WFInput": var(output(source)),
            "WFItemSpecifier": "Items in Range",
            "WFItemRangeStart": 1,
            "WFItemRangeEnd": count,
        }, "Items in Range")

    def choose(self, source, prompt, multiple=True):
        return self.add("is.workflow.actions.choosefromlist", {
            "WFInput": var(output(source)),
            "WFChooseFromListActionPrompt": prompt,
            "WFChooseFromListActionSelectMultiple": multiple,
        }, "Chosen Item")

    def count(self, source, what="Items"):
        return self.add("is.workflow.actions.count", {
            "Input": var(value(source)), "WFCountType": what}, "Count")

    def copy(self, source):
        self.add("is.workflow.actions.setclipboard", {"WFInput": var(value(source))})

    def get_clipboard(self):
        return self.add("is.workflow.actions.getclipboard", {}, "Clipboard")

    def notify(self, *body):
        self.add("is.workflow.actions.notification", {
            "WFNotificationActionTitle": "ClipStack",
            "WFNotificationActionBody": text(*body),
            "WFNotificationActionSound": False,
        })

    def alert(self, title, message, cancel=False):
        self.add("is.workflow.actions.alert", {
            "WFAlertActionTitle": title,
            "WFAlertActionMessage": message,
            "WFAlertActionCancelButtonShown": cancel,
        })

    def _if(self, source, condition, **extra):
        group = new_id()
        self.add("is.workflow.actions.conditional", {
            "GroupingIdentifier": group,
            "WFControlFlowMode": 0,
            "WFCondition": condition,
            "WFInput": {"Type": "Variable", "Variable": var(value(source))},
            **extra,
        })
        return group

    def if_begins(self, source, string):
        return self._if(source, 8, WFConditionalActionString=string)

    def if_contains(self, source, string):
        return self._if(source, 99, WFConditionalActionString=string)

    def if_exists(self, file_ref):
        """Only for files, where a missing one has no value. Text is never tested
        this way: text from an existing but empty file still "has a value"."""
        return self._if(file_ref, 100)

    def if_greater(self, source, number):
        """Opens `If <source> is greater than <number>`. Returns a token for otherwise()/end_if()."""
        return self._if(source, 2, WFNumberValue=number)

    def if_not_empty(self, source):
        """Opens an If that runs when the text has at least one character.

        ("Has any value" is no use here: text read from an existing but empty
        file still counts as a value.)
        """
        return self.if_greater(self.count(source, "Characters"), 0)

    def otherwise(self, group):
        self.add("is.workflow.actions.conditional", {"GroupingIdentifier": group, "WFControlFlowMode": 1})

    def end_if(self, group, result=False):
        """Closes an If. With result=True, returns the "If Result": the output
        of the last action in whichever branch ran."""
        params = {"GroupingIdentifier": group, "WFControlFlowMode": 2}
        return self.add("is.workflow.actions.conditional", params, "If Result" if result else None)

    def repeat_each(self, source):
        group = new_id()
        self.add("is.workflow.actions.repeat.each", {
            "GroupingIdentifier": group, "WFControlFlowMode": 0, "WFInput": var(value(source))})
        return group

    def end_repeat(self, group):
        """Returns the "Repeat Results": the last output of every pass."""
        return self.add("is.workflow.actions.repeat.each", {
            "GroupingIdentifier": group, "WFControlFlowMode": 2}, "Repeat Results")

    # --- ClipStack's own building blocks --------------------------------------

    def resolve(self, entry):
        """A history line, as what should be pasted: the picture itself for an
        image line (so it pastes as an image, not a file), the file for a
        video line, and the text for anything else."""
        path = self.replace(entry, r"\A" + MEDIA_LINE + r"\z", MEDIA + "/$1", regex=True)
        is_media = self.if_begins(path, MEDIA + "/")
        file = self.get_file(path)
        is_image = self.if_begins(entry, IMAGE)
        self.images(file)
        self.otherwise(is_image)
        self.get_variable(file)
        self.end_if(is_image, result=True)
        self.otherwise(is_media)
        self.text(entry)
        return self.end_if(is_media, result=True)

    def resolve_each(self, entries):
        group = self.repeat_each(entries)
        self.resolve(REPEAT_ITEM)
        return self.end_repeat(group)

    def first_and_rest(self, joined):
        """Splits sentinel-joined text into its first clip and the remainder."""
        first = self.replace(joined, SENTINEL + r"[\s\S]*\z", regex=True)
        rest = self.replace(joined, r"\A[\s\S]*?(?:" + SENTINEL + r"|\z)", regex=True)
        return first, rest

    def pick_from_history(self, prompt):
        """Shows history as a multi-select list; returns the ticked clips.

        When history is empty it says so and the caller's steps are skipped:
        call `done()` on the returned group once they have been added.
        """
        history = self.read_file(HISTORY)
        group = self.if_not_empty(history)
        chosen = self.choose(self.split(history), prompt)
        return chosen, group

    def done(self, group):
        self.otherwise(group)
        self.alert("ClipStack is empty", f"Copy something, then {self.how_to_save} to add it to your history.")
        self.end_if(group)


def workflow(flow, *, share_sheet=False, clipboard_when_no_input=False):
    wf = {
        "WFWorkflowClientVersion": "2607.1.3",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {
            "WFWorkflowIconStartColor": 4274264319,
            "WFWorkflowIconGlyphNumber": 59829,
        },
        "WFWorkflowImportQuestions": [],
        "WFWorkflowTypes": [],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowActions": flow.actions,
    }
    if share_sheet:
        wf["WFWorkflowTypes"] = ["ActionExtension"]
        wf["WFWorkflowInputContentItemClasses"] = [
            "WFStringContentItem", "WFRichTextContentItem", "WFURLContentItem",
            "WFImageContentItem", "WFAVAssetContentItem", "WFGenericFileContentItem"]
        wf["WFWorkflowHasShortcutInputVariables"] = True
    if clipboard_when_no_input:
        wf["WFWorkflowNoInputBehavior"] = {"Name": "WFWorkflowNoInputBehaviorGetClipboard", "Parameters": {}}
    return wf


# --- the shortcuts -------------------------------------------------------------
# Each job adds its actions to a Flow, so the single-purpose shortcuts and
# ClipStack's menu are built from the same steps.

def add_save(f, source):
    """Adds `source` (the clipboard, or whatever was shared) to the top of history.

    Images and videos are saved once each in MEDIA, named by a hash of their
    content, and appear in history as a line naming that file.
    """
    ext = f.file_detail(source, "File Extension")   # text arrives as a .txt file
    kind = f.replace(ext, rf"(?i)\A(?:{IMAGE_EXT})\z", IMAGE, regex=True)
    kind = f.replace(kind, rf"(?i)\A(?:{VIDEO_EXT})\z", VIDEO, regex=True)
    is_media = f.if_contains(kind, " ")      # "🖼 Image" / "🎬 Video"; an extension has no space
    short = f.replace(f.sha256(source), r"\A([0-9a-fA-F]{12})[\s\S]*\z", "$1", regex=True)
    name = f.text(short, ".", ext)
    f.save_file(text(MEDIA + "/", name), source)
    f.text(kind, " ", f.file_detail(source, "File Size"), " — ", name)
    f.otherwise(is_media)
    f.get_text(source)
    clip = f.end_if(is_media, result=True)

    group = f.if_not_empty(clip)
    history = f.read_file(HISTORY)
    # With a sentinel on both sides, every clip is delimited exactly, so a plain
    # (non-regex) replace removes an older copy of this clip and nothing else.
    wrapped = f.text(SENTINEL, output(history), SENTINEL)
    without_old = f.replace(wrapped, text(SENTINEL, output(clip), SENTINEL), SENTINEL)
    joined = f.text(output(clip), SENTINEL, output(without_old))
    joined = f.replace(joined, f"(?:{SENTINEL})+", SENTINEL, regex=True)
    joined = f.replace(joined, rf"\A{SENTINEL}|{SENTINEL}\z", regex=True)
    # Keep the newest MAX_CLIPS. "Get Items in Range" fails when the list is
    # shorter than the range, so only trim once there is something to trim.
    clips = f.split(joined)
    too_many = f.if_greater(f.count(clips), MAX_CLIPS)
    f.save_file(HISTORY, f.combine(f.first_clips(clips, MAX_CLIPS)))
    f.otherwise(too_many)
    f.save_file(HISTORY, joined)
    f.end_if(too_many)
    f.notify("Saved: ", output(clip))
    f.otherwise(group)
    f.notify("Nothing to save — the clipboard is empty.")
    f.end_if(group)


def add_paste_multiple(f):
    """Tick several clips. Text is merged onto the clipboard, one per line; if
    any are images or videos, everything goes on as separate items instead."""
    chosen, group = f.pick_from_history("Pick clips to merge")
    joined = f.combine(chosen, "\n")
    probe = f.replace(joined, "(?m)^" + MEDIA_LINE + "$", "@@MEDIA@@", regex=True)
    has_media = f.if_contains(probe, "@@MEDIA@@")
    f.copy(f.resolve_each(chosen))
    f.notify("Copied ", f.count(chosen), " clips, images and videos included — ready to paste.")
    f.otherwise(has_media)
    f.copy(joined)
    f.notify("Merged ", f.count(chosen), " clips — ready to paste.")
    f.end_if(has_media)
    f.done(group)


def add_queue_multiple(f):
    """Tick several clips; the first goes on the clipboard, the rest wait for Paste Next."""
    chosen, group = f.pick_from_history("Pick clips to queue (pasted top to bottom)")
    first, rest = f.first_and_rest(f.combine(chosen))
    f.copy(f.resolve(first))
    f.save_file(QUEUE, rest)
    f.notify("Queued ", output(f.count(chosen)),
             " clips. The first is on the clipboard; run Paste Next for each of the others.")
    f.done(group)


def add_paste_next(f):
    """Loads the next queued clip onto the clipboard."""
    queue = f.read_file(QUEUE)
    group = f.if_not_empty(queue)
    first, rest = f.first_and_rest(queue)
    f.copy(f.resolve(first))
    f.save_file(QUEUE, rest)
    f.notify("Next clip is on the clipboard: ", output(first))
    f.otherwise(group)
    f.notify("The queue is empty.")
    f.end_if(group)


def add_clear(f):
    """Empties history and the queue and deletes saved images and videos, after asking."""
    f.alert("Clear ClipStack?", "This deletes your saved clips, images and videos, and the paste queue.",
            cancel=True)
    empty = f.text("")
    f.save_file(HISTORY, empty)
    f.save_file(QUEUE, empty)
    media = f.get_file(MEDIA)
    exists = f.if_exists(media)
    f.delete(media)
    f.end_if(exists)
    f.notify("History cleared.")


def single(add):
    f = Flow()
    add(f)
    return workflow(f)


def save():
    f = Flow()
    add_save(f, SHORTCUT_INPUT)
    return workflow(f, share_sheet=True, clipboard_when_no_input=True)


def all_in_one():
    """Every job from one menu. Shared to from the share sheet, it saves that
    straight away. Otherwise it asks what to do, and reads the clipboard only
    for Save, so the other choices never prompt to paste."""
    f = Flow(how_to_save=f"run {ALL_IN_ONE} and choose {MENU[0]}")
    # No "when there's no input, use the clipboard" here: an empty Shortcut
    # Input is how a run from the share sheet is told apart from any other.
    shared = f.if_greater(f.count(SHORTCUT_INPUT), 0)
    f.text(MENU[0])
    f.otherwise(shared)
    f.choose(f.split(f.text("\n".join(MENU)), "\n"), ALL_IN_ONE, multiple=False)
    choice = f.end_if(shared, result=True)

    def save_it(f):
        shared = f.if_greater(f.count(SHORTCUT_INPUT), 0)
        f.get_variable(SHORTCUT_INPUT)
        f.otherwise(shared)
        f.get_clipboard()
        add_save(f, f.end_if(shared, result=True))

    jobs = [save_it, add_paste_multiple, add_queue_multiple, add_paste_next, add_clear]
    groups = []
    for item, add in zip(MENU, jobs):
        if groups:
            f.otherwise(groups[-1])
        groups.append(f.if_begins(choice, item))
        add(f)
    for group in reversed(groups):
        f.end_if(group)
    return workflow(f, share_sheet=True)


def build():
    return {
        ALL_IN_ONE: all_in_one(),
        PREFIX + "Save": save(),
        PREFIX + "Paste Multiple": single(add_paste_multiple),
        PREFIX + "Queue Multiple": single(add_queue_multiple),
        PREFIX + "Paste Next": single(add_paste_next),
        PREFIX + "Clear": single(add_clear),
    }


def main():
    out = os.environ.get("CLIPSTACK_SHORTCUTS_OUT", OUT)
    failures = []
    for name, wf in build().items():
        # `shortcuts sign` insists on a .shortcut extension for its input too.
        raw = os.path.join(out, f"{name}.unsigned.shortcut")
        signed = os.path.join(out, f"{name}.shortcut")
        with open(raw, "wb") as fh:
            plistlib.dump(wf, fh, fmt=plistlib.FMT_XML)
        result = subprocess.run(
            ["shortcuts", "sign", "--input", raw, "--output", signed, "--mode", "anyone"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            os.remove(raw)
            print(f"  signed  {name}.shortcut")
        else:
            failures.append(name)
            print(f"  FAILED  {name}: {result.stderr.strip()}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
