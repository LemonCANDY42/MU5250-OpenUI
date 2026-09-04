#!/usr/bin/env python3
"""Verify every legacy device entry point refuses execution by default."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PYTHON_TOOLS = (
    "scripts/zaction.py",
    "scripts/zcall.py",
    "scripts/zdiag.py",
    "scripts/zexplore.py",
    "scripts/zidentity.py",
    "scripts/zrecon.py",
    "scripts/zunlock.py",
    "scripts/research/zacs.py",
    "scripts/research/zadb.py",
    "scripts/research/zdns.py",
    "scripts/research/zgap.py",
    "scripts/research/zhidden.py",
    "scripts/research/zinj.py",
    "scripts/research/zrce.py",
    "scripts/research/zstrings.py",
    "scripts/research/zwrite.py",
    "installer/app.py",
    "scripts/capture-b04-lan-redeploy-baseline.py",
    "scripts/deploy-b04-v1.py",
)
SHELL_TOOLS = (
    "setup.sh",
    "deploy.sh",
    "deploy-dashboard.sh",
    "scripts/zharden.sh",
)
ACKNOWLEDGEMENT_VARIABLES = (
    "U60_B04_READ_ONLY_PROBE",
    "U60_B04_PRIVILEGED_RESEARCH",
    "U60_B04_CONFIG_RESTORE",
    "U60_B04_V1_DEPLOY",
)


def run_guarded(command: list[str], label: str, env: dict[str, str]) -> None:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    if result.returncode != 64 or "Refusing" not in result.stderr:
        raise SystemExit(
            f"{label} did not fail closed (exit={result.returncode})"
        )


def main() -> None:
    env = os.environ.copy()
    for name in ACKNOWLEDGEMENT_VARIABLES:
        env.pop(name, None)

    for path in PYTHON_TOOLS:
        run_guarded([sys.executable, path], path, env)
    for path in SHELL_TOOLS:
        run_guarded(["bash", path], path, env)

    script_source = (ROOT / "zte-script-ng.js").read_text()
    marker = "ZTE-Script-NG is quarantined reference code and is disabled"
    if marker not in script_source.split("const VERSION", 1)[0]:
        raise SystemExit("zte-script-ng.js is not fail-closed before initialization")

    print(
        f"device gates verified: {len(PYTHON_TOOLS)} Python and "
        f"{len(SHELL_TOOLS)} shell entry points"
    )


if __name__ == "__main__":
    main()
