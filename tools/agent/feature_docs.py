#!/usr/bin/env python3
"""A bounded map of repository feature docs, rebuilt each run as docs evolve."""
from pathlib import Path
import re
import subprocess
import sys


def context(root):
    root = Path(root)
    paths = subprocess.run(["git", "-C", str(root), "ls-files", "--", "*.md", "*.mdx"],
                           capture_output=True, text=True, check=True).stdout.splitlines()
    paths = [p for p in paths if not any(part.startswith(".") for part in Path(p).parts)]
    priority = ["docs/project-goal.md", "product_specs.md", "README.md"]
    paths.sort(key=lambda p: (priority.index(p) if p in priority else len(priority), p))
    lines = ["FEATURE VISION CONTRACT (repository documentation):",
        "Before proposing a feature, changing behavior or resolving a feature disagreement:",
        "1. Read docs/project-goal.md and the relevant product_specs.md sections if present.",
        "2. Find and READ relevant feature docs using the map below and a repository search.",
        "   This map is a navigation aid, not a substitute for reading the actual sections.",
        "3. Cite document paths/sections in your plan, review or PR under Feature docs:.",
        "   Explain how the proposal fits the intended user workflow and documented invariants.",
        "4. The latest explicit human direction wins over older docs. If docs conflict, cite",
        "   both and explain the resolution; if intent remains ambiguous, state the exact gap",
        "   rather than inventing a feature or treating current code as the product vision.",
        "5. When no relevant feature doc exists, say so explicitly and use the issue scope.",
        "   Never rewrite protected human vision documents unless a human explicitly requests it.",
        "Documentation map (tracked files; search for additional documents when needed):"]
    for path in paths[:60]:
        try:
            headings = []
            for number, line in enumerate((root / path).read_text().splitlines(), 1):
                if re.match(r"^#{1,4} ", line):
                    headings.append(f"{number}:{line.lstrip('# ').strip()[:100]}")
            lines.append(f"- {path}: " + " | ".join(headings[:10]))
        except (OSError, UnicodeError):
            continue
    return "\n".join(lines)[:9000] + "\n"


if __name__ == "__main__":
    print(context(sys.argv[1]))
