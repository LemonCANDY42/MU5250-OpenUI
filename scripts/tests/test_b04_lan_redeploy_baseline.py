from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASELINE = load(
    "capture_b04_lan_redeploy_baseline",
    ROOT / "scripts" / "capture-b04-lan-redeploy-baseline.py",
)


class LanRedeployBaselineTests(unittest.TestCase):
    def test_release_identifier_is_strict(self) -> None:
        self.assertEqual(BASELINE.parse_release_id("a" * 64), "a" * 64)
        for invalid in ("A" * 64, "a" * 63, "a" * 64 + "x", "../" + "a" * 64):
            with self.assertRaises(BASELINE.BaselineError):
                BASELINE.parse_release_id(invalid)

    def test_stopped_canary_requires_absent_links_and_process(self) -> None:
        release_id = "a" * 64
        with (
            mock.patch.object(
                BASELINE.DEPLOY,
                "read_release_links",
                return_value={"current": None, "previous": None},
            ),
            mock.patch.object(BASELINE.DEPLOY, "adb_shell", return_value=""),
            mock.patch.object(BASELINE, "verify_expected_release") as verify,
        ):
            BASELINE.assert_stopped_lan_canary(release_id)
        verify.assert_called_once_with(release_id)

        with mock.patch.object(
            BASELINE.DEPLOY,
            "read_release_links",
            return_value={"current": "/foreign", "previous": None},
        ):
            with self.assertRaises(BASELINE.BaselineError):
                BASELINE.assert_stopped_lan_canary(release_id)

    def test_capture_rechecks_preconditions_and_publishes_rc_backup(self) -> None:
        release_id = "a" * 64
        invariant = {
            "firmware": "BD_XCBZHKMU5250V1.0.0B04",
            "root_adb": True,
            "network": {"default_interface": "en0"},
            "usb": {},
            "rc_local_sha256": "b" * 64,
            "rc_local_metadata": {"mode": 0o775, "uid": 0, "gid": 0},
            "release_links": {"current": None, "previous": None},
        }
        rc_local = b"#!/bin/sh\nexit 0\n"
        destination = Path("/approved/B04-v1-lan-redeploy-baseline-test")
        with (
            mock.patch.object(
                BASELINE.DEPLOY,
                "capture_invariants",
                side_effect=[invariant, invariant],
            ),
            mock.patch.object(BASELINE, "assert_stopped_lan_canary") as stopped,
            mock.patch.object(BASELINE.DEPLOY, "read_rc_local", return_value=rc_local),
            mock.patch.object(BASELINE.DEPLOY, "assert_invariants") as invariants,
            mock.patch.object(
                BASELINE.DEPLOY, "write_evidence", return_value=destination
            ) as publish,
        ):
            self.assertEqual(BASELINE.capture(release_id), destination)
        self.assertEqual(stopped.call_args_list, [mock.call(release_id), mock.call(release_id)])
        invariants.assert_called_once_with(invariant, invariant)
        self.assertEqual(
            publish.call_args.kwargs["rc_backup"],
            rc_local,
        )
        self.assertEqual(
            publish.call_args.args[3]["expected_release_id"],
            release_id,
        )


if __name__ == "__main__":
    unittest.main()
