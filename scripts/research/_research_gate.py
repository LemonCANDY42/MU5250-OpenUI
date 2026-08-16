"""Import the repository-level fail-closed gate for legacy research tools."""

from __future__ import annotations

import sys
from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from _device_gate import require_privileged_research  # noqa: E402


def require_research_authorization() -> None:
    """Require an explicit one-command acknowledgement before any side effect."""

    require_privileged_research()
