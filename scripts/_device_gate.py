"""Fail-closed local authorization gates for historical device tools.

These environment values are deliberate operator acknowledgements, not
secrets. Normal builds, tests and documentation commands never set them.
"""

from __future__ import annotations

import os
import sys


def _require(name: str, expected: str, purpose: str) -> None:
    if os.environ.get(name) == expected:
        return
    print(
        f"Refusing {purpose}. This B04 V1 branch defaults to host-only work.\n"
        f"After the documented stage gate, set {name}={expected} for this one command.",
        file=sys.stderr,
    )
    raise SystemExit(64)


def require_read_only_probe() -> None:
    _require(
        "U60_B04_READ_ONLY_PROBE",
        "I_CONFIRMED_B04_AND_ROOT_RECOVERY",
        "device read-only probe",
    )


def require_privileged_research() -> None:
    _require(
        "U60_B04_PRIVILEGED_RESEARCH",
        "I_ACCEPT_ARBITRARY_VENDOR_RPC_RISK",
        "privileged or generic vendor RPC research",
    )


def require_config_restore() -> None:
    _require(
        "U60_B04_CONFIG_RESTORE",
        "I_HAVE_A_FRESH_VERIFIED_BACKUP_AND_RECOVERY_CHANNEL",
        "configuration backup/restore workflow",
    )
