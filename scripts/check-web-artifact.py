#!/usr/bin/env python3
"""Reject legacy transport and session-persistence markers in the built dashboard."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "web-app/dist"
FORBIDDEN = {
    b"/api/": "legacy unversioned API path",
    b"http://": "plaintext URL",
    b"9090": "legacy split-origin agent port",
    b"localStorage": "persistent browser storage API",
    b"sessionStorage": "persistent browser storage API",
    b"zte_token": "legacy persisted token key",
}


def main() -> int:
    if not DIST.is_dir():
        print("missing web-app/dist; run the dashboard build first", file=sys.stderr)
        return 1
    files = sorted(path for path in DIST.rglob("*") if path.is_file())
    if not files or not (DIST / "index.html").is_file():
        print("dashboard artifact is incomplete", file=sys.stderr)
        return 1

    findings: list[str] = []
    for path in files:
        content = path.read_bytes()
        for marker, description in FORBIDDEN.items():
            if marker in content:
                findings.append(f"{path.relative_to(ROOT)}: {description}")
    if findings:
        print("dashboard artifact contains forbidden markers:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        return 1

    print(f"OK: scanned {len(files)} dashboard artifacts; no forbidden markers found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
