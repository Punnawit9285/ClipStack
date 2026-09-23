#!/usr/bin/env python3
"""Render demo/transcript.json (from `demo.sh --record`) as an animated SVG.

The SVG replays the session on a loop: commands are typed out, output appears
line by line and the view scrolls like a terminal. It is plain SVG + CSS, so it
animates inside a README on GitHub.

    python3 demo/render-svg.py            writes demo/demo.svg
"""
import json
import os
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))

FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SIZE, LINE, CHAR = 14, 20, 8.43          # font px, line height, approx. glyph width
PAD, BAR = 18, 34                        # inner padding, title bar height
ROWS = 24                                # visible lines
HOLD = 5.0                               # seconds to rest on the last frame

C = {
    "bg": "#1e1e2e", "bar": "#181825", "fg": "#cdd6f4", "dim": "#7f849c",
    "green": "#a6e3a1", "yellow": "#f9e2af", "cyan": "#89dceb", "bold": "#ffffff",
}

# Same pacing as demo.sh at normal speed.
TYPE, AFTER_TYPE, AFTER_OUT, AFTER_NOTE, AFTER_COPY, AFTER_CLIP = 0.035, 0.35, 1.6, 1.2, 0.6, 1.8


def build_lines(events):
    """Turns events into (time, spans, typed_chars) rows. spans = [(colour, text)]."""
    rows, t = [], 0.4
    for e in events:
        kind, text = e["kind"], e["text"]
        if kind == "title":
            rows += [(t, [("bold", text)], 0), (t, [], 0)]
            t += 1.0
        elif kind == "note":
            rows.append((t, [("dim", "# " + text)], 0))
            t += AFTER_NOTE
        elif kind == "copy":
            rows.append((t, [("fg", "  "), ("yellow", "⌘C"), ("fg", "  " + text)], 0))
            t += AFTER_COPY
        elif kind == "cmd":
            rows.append((t, [("green", "$ "), ("fg", text)], len(text)))
            t += len(text) * TYPE + AFTER_TYPE
        elif kind == "out":
            for line in text.split("\n"):
                rows.append((t, [("fg", line)], 0))
            t += AFTER_OUT
        elif kind == "clip":
            rows.append((t, [("cyan", "┌ clipboard")], 0))
            for line in text.split("\n"):
                rows.append((t, [("cyan", "│ "), ("fg", line)], 0))
            rows.append((t, [("cyan", "└")], 0))
            t += AFTER_CLIP
    return rows, t


def render(events):
    rows, end = build_lines(events)
    total = end + HOLD
    pct = lambda s: f"{100 * s / total:.3f}%"

    cols = max(sum(len(s) for _, s in spans) for _, spans, _ in rows)
    width = int(2 * PAD + max(cols, 64) * CHAR)
    height = BAR + 2 * PAD + ROWS * LINE

    css, body = [], []
    css.append(f"""
      svg {{ font-family: {FONT}; font-size: {SIZE}px; }}
      text {{ white-space: pre; dominant-baseline: text-before-edge; }}
      .a {{ animation-duration: {total:.2f}s; animation-iteration-count: infinite;
            animation-timing-function: linear; animation-fill-mode: both; }}
    """)
    for name, colour in C.items():
        css.append(f".{name} {{ fill: {colour}; }}")
    css.append(".bold { font-weight: 700; }")

    scroll = []   # (time, offset) whenever the view has to move up
    for i, (t, spans, typed) in enumerate(rows):
        y = PAD + i * LINE
        if i >= ROWS:
            scroll.append((t, (i - ROWS + 1) * LINE))
        css.append(f"@keyframes r{i} {{ 0%, {pct(t)} {{ opacity: 0; }} {pct(t + 0.001)}, 100% {{ opacity: 1; }} }}")
        tspans = "".join(f'<tspan class="{c}">{escape(s)}</tspan>' for c, s in spans)
        line = f'<text x="{PAD}" y="{y}" class="a" style="animation-name: r{i}">{tspans}</text>'
        if typed:
            # An opaque block over the command slides right, uncovering one character at a time.
            x0 = PAD + 2 * CHAR
            w = typed * CHAR + 2
            done = t + typed * TYPE
            css.append(
                f"@keyframes m{i} {{ 0%, {pct(t)} {{ transform: translateX(0); animation-timing-function: steps({typed}, end); }}"
                f" {pct(done)}, 100% {{ transform: translateX({w:.1f}px); }} }}")
            line += (f'<rect x="{x0:.1f}" y="{y - 2}" width="{w:.1f}" height="{LINE}" fill="{C["bg"]}"'
                     f' class="a" style="animation-name: m{i}"/>')
        body.append(line)

    # Terminal-style scrolling: jump up a line at a time as output arrives.
    frames = [f"0% {{ transform: translateY(0); }}"]
    for t, off in scroll:
        frames.append(f"{pct(t)} {{ transform: translateY(-{off}px); }}")
    css.append("@keyframes scroll { " + " ".join(frames) + " }")
    css.append(".scroll { animation-timing-function: step-end; }")

    dots = "".join(f'<circle cx="{PAD + i * 20}" cy="{BAR / 2}" r="6" fill="{c}"/>'
                   for i, c in enumerate(("#f38ba8", "#f9e2af", "#a6e3a1")))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-label="ClipStack terminal demo: recording copies, merging three clips, queueing them, searching, and skipping a password">
  <style>{''.join(css)}</style>
  <defs><clipPath id="view"><rect x="0" y="{BAR}" width="{width}" height="{height - BAR}"/></clipPath></defs>
  <rect width="{width}" height="{height}" rx="10" fill="{C['bg']}"/>
  <path d="M0 10 a10 10 0 0 1 10 -10 h{width - 20} a10 10 0 0 1 10 10 v{BAR - 10} h-{width} z" fill="{C['bar']}"/>
  {dots}
  <text x="{width / 2}" y="{BAR / 2 - 8}" text-anchor="middle" class="dim" style="font-size: 12px">clipstack — demo</text>
  <g clip-path="url(#view)">
    <g transform="translate(0 {BAR})">
      <g class="a scroll" style="animation-name: scroll">
        {''.join(body)}
      </g>
    </g>
  </g>
</svg>
"""


def main():
    with open(os.path.join(HERE, "transcript.json"), encoding="utf-8") as fh:
        events = json.load(fh)
    svg = render(events)
    out = os.path.join(HERE, "demo.svg")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(svg)
    print(f"wrote {out} ({len(svg) // 1024} KB)")


if __name__ == "__main__":
    main()
