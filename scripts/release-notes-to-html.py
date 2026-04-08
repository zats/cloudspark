#!/usr/bin/env python3
from html import escape
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: release-notes-to-html.py <input.md> <output.html>", file=sys.stderr)
        return 1

    source_path, output_path = sys.argv[1], sys.argv[2]
    with open(source_path, "r", encoding="utf-8") as handle:
        lines = [line.rstrip() for line in handle]

    bullets = [line[2:].strip() for line in lines if line.startswith("- ")]
    paragraphs = [line.strip() for line in lines if line.strip() and not line.startswith("- ")]

    parts = []
    if bullets:
        parts.append("<ul>")
        parts.extend(f"<li>{escape(item)}</li>" for item in bullets)
        parts.append("</ul>")
    for paragraph in paragraphs:
        parts.append(f"<p>{escape(paragraph)}</p>")
    if not parts:
        parts.append("<p>Update available.</p>")

    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(parts) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
