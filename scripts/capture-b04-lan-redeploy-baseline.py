#!/usr/bin/env python3
"""Capture a read-only recovery baseline before redeploying a stopped LAN canary.

This is deliberately distinct from ``capture-b04-canary-baseline.py``.  The
first-canary baseline requires that /data/u60 does not exist.  A stopped,
nonpersistent LAN canary legitimately leaves its content-addressed release in
that directory, while current/previous and the agent remain absent.
"""

from __future__ import annotations

import argparse
import importlib.util
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


class BaselineError(RuntimeError):
    pass


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise BaselineError(f"could not load reviewed helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DEPLOY = load_module("u60_lan_redeploy_deploy", ROOT / "scripts" / "deploy-b04-v1.py")
DEVICE_GATE = load_module("u60_lan_redeploy_gate", ROOT / "scripts" / "_device_gate.py")


def parse_release_id(value: str) -> str:
    if not DEPLOY.HEX64.fullmatch(value):
        raise BaselineError("expected release must be a lowercase SHA-256 identifier")
    return value


def verify_expected_release(release_id: str) -> None:
    release = f"{DEPLOY.DEVICE_ROOT}/releases/{release_id}"
    DEPLOY.adb_shell(
        DEPLOY.verify_device_release_script(release_id, release), timeout=45
    )


def assert_stopped_lan_canary(release_id: str) -> None:
    if DEPLOY.read_release_links() != {"current": None, "previous": None}:
        raise BaselineError(
            "LAN redeploy baseline requires absent current and previous release links"
        )
    if DEPLOY.adb_shell("pidof zte-agent 2>/dev/null || true", limit=4_096):
        raise BaselineError("LAN redeploy baseline requires no running zte-agent")
    verify_expected_release(release_id)


def capture(release_id: str) -> Path:
    before = DEPLOY.capture_invariants()
    assert_stopped_lan_canary(release_id)
    rc_local = DEPLOY.read_rc_local()

    after = DEPLOY.capture_invariants()
    assert_stopped_lan_canary(release_id)
    DEPLOY.assert_invariants(before, after)
    if DEPLOY.read_rc_local() != rc_local:
        raise BaselineError("rc.local changed during the LAN redeploy baseline")

    return DEPLOY.write_evidence(
        "lan-redeploy-baseline",
        before,
        after,
        {
            "expected_release_id": release_id,
            "release_integrity_verified_before_after": True,
            "release_links_absent_before_after": True,
            "zte_agent_absent_before_after": True,
            "device_writes_performed": False,
            "boot_or_firewall_path_touched": False,
        },
        rc_backup=rc_local,
    )


def main() -> None:
    # This is a live-device read only operation, and is never an implicit
    # consequence of source tests or documentation commands.
    DEVICE_GATE.require_read_only_probe()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-release", required=True, type=parse_release_id)
    arguments = parser.parse_args()
    try:
        destination = capture(arguments.expected_release)
    except (
        BaselineError,
        DEPLOY.DeployError,
        DEPLOY.PROBE.ProbeError,
        OSError,
        subprocess.SubprocessError,
        UnicodeError,
    ) as error:
        print(f"LAN redeploy baseline refused: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(f"LAN redeploy baseline published: {destination}")


if __name__ == "__main__":
    main()
