from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_checker():
    path = ROOT / "scripts" / "check-api-contract.py"
    spec = importlib.util.spec_from_file_location("check_api_contract", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKER = load_checker()


class ApiContractCheckerTests(unittest.TestCase):
    def test_lifecycle_routes_require_every_runtime_status(self) -> None:
        expected = {"200", "400", "401", "403", "409", "413", "500", "503"}
        self.assertEqual(
            CHECKER.REQUIRED_RESPONSE_CODES[("Post", "/v1/device/reboot")],
            expected,
        )
        self.assertEqual(
            CHECKER.REQUIRED_RESPONSE_CODES[("Post", "/v1/device/power-off")],
            expected,
        )


if __name__ == "__main__":
    unittest.main()
