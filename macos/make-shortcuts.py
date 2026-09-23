#!/usr/bin/env python3
"""Generate and sign the ClipStack shortcuts.

Shortcuts files are property lists describing a list of actions. `shortcuts sign`
wraps one into the signed container the Shortcuts app will import.
"""
import os
import plistlib
import subprocess
import sys
import uuid

SENTINEL = "@@CLIPSTACK@@"
CLI = os.environ.get("CLIPSTACK_BIN", os.path.expanduser("~/.local/bin/clipstack"))
OUT = os.path.dirname(os.path.abspath(__file__))


def action(identifier, params=None, action_uuid=None):
    p = dict(params or {})
    if action_uuid:
        p["UUID"] = action_uuid
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": p}


def output_of(action_uuid, name):
    """A reference to an earlier action's output."""
    return {
        "Value": {"OutputUUID": action_uuid, "OutputName": name, "Type": "ActionOutput"},
        "WFSerializationType": "WFTextTokenAttachment",
    }


def shell(script, action_uuid=None, stdin=None):
    params = {"Script": script, "Shell": "/bin/zsh", "RunAsAdministrator": False}
    if stdin is not None:
        params["Input"] = stdin
        params["InputMode"] = "to stdin"
    return action("is.workflow.actions.runshellscript", params, action_uuid)


def workflow(actions):
    return {
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
        "WFWorkflowActions": actions,
    }


def pick_actions(prompt):
    """Shared opening: read history, split it, let the user tick several."""
    return [
        shell(f'"{CLI}" list --sep'),
        action("is.workflow.actions.text.split", {
            "WFTextSeparator": "Custom",
            "WFTextCustomSeparator": SENTINEL,
        }),
        action("is.workflow.actions.choosefromlist", {
            "WFChooseFromListActionPrompt": prompt,
            "WFChooseFromListActionSelectMultiple": True,
        }),
    ]


def build():
    combine_uuid = str(uuid.uuid4()).upper()

    # 1. Pick several clips, join them, put the result on the clipboard.
    paste_multiple = workflow(pick_actions("Pick clips to paste") + [
        action("is.workflow.actions.text.combine", {"WFTextSeparator": "New Lines"}),
        action("is.workflow.actions.setclipboard", {}),
    ])

    # 2. Pick several clips and load them into the queue, in order.
    queue_multiple = workflow(pick_actions("Queue clips in paste order") + [
        action("is.workflow.actions.text.combine", {
            "WFTextSeparator": "Custom",
            "WFTextCustomSeparator": SENTINEL,
        }, combine_uuid),
        shell(f'"{CLI}" queue', stdin=output_of(combine_uuid, "Combined Text")),
    ])

    # 3. Advance the queue by one.
    paste_next = workflow([shell(f'"{CLI}" next')])

    return {
        "ClipStack - Paste Multiple": paste_multiple,
        "ClipStack - Queue Multiple": queue_multiple,
        "ClipStack - Paste Next": paste_next,
    }


def main():
    failures = []
    for name, wf in build().items():
        # `shortcuts sign` insists on a .shortcut extension for its input too.
        raw = os.path.join(OUT, f"{name}.unsigned.shortcut")
        signed = os.path.join(OUT, f"{name}.shortcut")
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
