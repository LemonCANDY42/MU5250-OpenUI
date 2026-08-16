from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile
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


PREPARE = load("prepare_b04_v1_release", ROOT / "scripts/prepare-b04-v1-release.py")
DEPLOY = load("deploy_b04_v1", ROOT / "scripts/deploy-b04-v1.py")


class ReleasePreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="u60-release-test-")
        self.root = Path(self.temporary.name)
        self.output = self.root / "releases"
        self.output.mkdir(mode=0o700)
        self.build = self.root / "build"
        self.build.mkdir(mode=0o700)
        agent = self.build / "zte-agent"
        agent.write_bytes(b"synthetic static aarch64 agent")
        os.chmod(agent, 0o700)
        agent_digest = hashlib.sha256(agent.read_bytes()).hexdigest()
        manifest = {
            "binary": {
                "path": "zte-agent",
                "sha256": agent_digest,
                "size": agent.stat().st_size,
                "elf": {
                    "class": "elf64",
                    "endianness": "little",
                    "linkage": "static",
                    "machine": "aarch64",
                    "stripped": True,
                },
            },
            "git": {"commit": "0" * 40, "tree": "1" * 40},
            "profile": "release",
            "target": "aarch64-unknown-linux-musl",
        }
        (self.build / "BUILD-MANIFEST.json").write_text(json.dumps(manifest))
        (self.build / "build.complete").write_bytes(PREPARE.BUILD_MARKER)
        self.dropbear = self.root / "dropbearmulti"
        self.dropbear.write_bytes(b"synthetic static dropbear")
        os.chmod(self.dropbear, 0o700)
        self.web = self.root / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("<main>safe</main>")
        self.device = self.root / "device"
        self.device.mkdir()
        for name in (
            "common.sh",
            "run-agent.sh",
            "run-dropbear.sh",
            "start-current.sh",
        ):
            path = self.device / name
            path.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(path, 0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def build_release(self) -> Path:
        digest = hashlib.sha256(self.dropbear.read_bytes()).hexdigest()
        with (
            mock.patch.object(PREPARE, "APPROVED_OUTPUT_ROOT", self.output),
            mock.patch.object(PREPARE, "validate_output_root"),
            mock.patch.object(
                PREPARE,
                "clean_git_identity",
                return_value={"commit": "2" * 40, "tree": "3" * 40},
            ),
            mock.patch.object(PREPARE, "WEB_ROOT", self.web),
            mock.patch.object(PREPARE, "DEVICE_ROOT", self.device),
            mock.patch.object(
                PREPARE,
                "verify_dropbear",
                return_value={
                    "sha256": digest,
                    "size": self.dropbear.stat().st_size,
                    "file": "test",
                },
            ),
        ):
            return PREPARE.build_release(self.build, self.dropbear, digest, self.output)

    def test_release_id_binds_checksum_list_and_payload(self) -> None:
        release = self.build_release()
        self.assertRegex(release.name, r"^[0-9a-f]{64}$")
        self.assertEqual(
            release.name,
            hashlib.sha256((release / "release.sha256").read_bytes()).hexdigest(),
        )
        self.assertEqual(
            (release / "release.complete").read_text(),
            f"u60-b04-v1-release:{release.name}\n",
        )
        result = subprocess.run(
            ["sha256sum", "-c", "release.sha256"],
            cwd=release,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue((release / "bin/start-current.sh").is_file())

    def test_repeated_identical_release_does_not_overwrite(self) -> None:
        first = self.build_release()
        second = self.build_release()
        self.assertEqual(first, second)
        self.assertTrue(first.is_dir())

    def test_web_symlink_is_rejected_without_partial_publication(self) -> None:
        (self.web / "bad.js").symlink_to(self.web / "index.html")
        with self.assertRaises(PREPARE.ReleaseError):
            self.build_release()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_deployer_rechecks_release_tree_and_rejects_tamper(self) -> None:
        release = self.build_release()
        with mock.patch.object(DEPLOY, "APPROVED_RELEASE_ROOT", self.output):
            self.assertEqual(DEPLOY.require_local_release(release), release.name)
            (release / "web/index.html").write_text("tampered")
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.require_local_release(release)


class DeploymentBoundaryTests(unittest.TestCase):
    def test_invariants_reject_unexpected_release_link_change(self) -> None:
        before = {
            "firmware": "HK-B04",
            "root_adb": True,
            "network": {"default_interface": "en0"},
            "usb": {"sys.usb.config": "adb"},
            "rc_local_sha256": "a" * 64,
            "release_links": {"current": None, "previous": None},
        }
        after = dict(before)
        after["release_links"] = {
            "current": f"{DEPLOY.DEVICE_ROOT}/releases/{'b' * 64}",
            "previous": None,
        }
        with self.assertRaises(DEPLOY.DeployError):
            DEPLOY.assert_invariants(before, after)
        DEPLOY.assert_invariants(before, after, allow_release_link_change=True)

    def test_lan_canary_uses_stable_listener_without_release_switch(self) -> None:
        arguments = mock.Mock(
            release=Path("/accepted/release"), ca_cert=Path("/accepted/ca.pem")
        )
        with (
            mock.patch.object(DEPLOY, "require_local_release", return_value="a" * 64),
            mock.patch.object(DEPLOY, "install_release", return_value=False),
            mock.patch.object(DEPLOY, "stop_managed_agent") as stop,
            mock.patch.object(
                DEPLOY, "stop_legacy_canary_without_pid_file"
            ) as stop_legacy,
            mock.patch.object(DEPLOY, "assert_no_zte_agent_processes") as no_agent,
            mock.patch.object(DEPLOY, "adb_shell") as adb_shell,
            mock.patch.object(DEPLOY, "run") as run,
            mock.patch.object(DEPLOY, "verify_tls_unauthorized") as verify_tls,
            mock.patch.object(DEPLOY, "switch_current") as switch_current,
        ):
            details = DEPLOY.command_lan_canary(arguments)
        self.assertEqual(
            stop.call_args_list, [mock.call("canary.pid"), mock.call("agent.pid")]
        )
        stop_legacy.assert_called_once_with()
        no_agent.assert_called_once_with()
        adb_shell.assert_called_once_with(
            f"{DEPLOY.DEVICE_ROOT}/releases/{'a' * 64}/bin/run-agent.sh stable",
            timeout=30,
        )
        self.assertEqual(
            run.call_args_list,
            [
                mock.call(
                    ["adb", "forward", "--remove", "tcp:19443"],
                    timeout=10,
                    limit=4096,
                    check=False,
                ),
                mock.call(
                    ["adb", "forward", "tcp:9443", "tcp:9443"],
                    timeout=10,
                    limit=4096,
                ),
            ],
        )
        verify_tls.assert_called_once_with(9443, arguments.ca_cert)
        switch_current.assert_not_called()
        self.assertEqual(details["lan_canary"], True)

    def test_lan_canary_stops_and_removes_forward_when_tls_fails(self) -> None:
        arguments = mock.Mock(
            release=Path("/accepted/release"), ca_cert=Path("/accepted/ca.pem")
        )
        with (
            mock.patch.object(DEPLOY, "require_local_release", return_value="a" * 64),
            mock.patch.object(DEPLOY, "install_release", return_value=False),
            mock.patch.object(DEPLOY, "stop_managed_agent") as stop,
            mock.patch.object(DEPLOY, "stop_legacy_canary_without_pid_file"),
            mock.patch.object(DEPLOY, "assert_no_zte_agent_processes"),
            mock.patch.object(DEPLOY, "adb_shell"),
            mock.patch.object(DEPLOY, "run") as run,
            mock.patch.object(
                DEPLOY,
                "verify_tls_unauthorized",
                side_effect=DEPLOY.DeployError("synthetic TLS failure"),
            ),
        ):
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.command_lan_canary(arguments)
        self.assertEqual(
            stop.call_args_list,
            [
                mock.call("canary.pid"),
                mock.call("agent.pid"),
                mock.call("agent.pid"),
            ],
        )
        self.assertEqual(
            run.call_args_list[-1],
            mock.call(
                ["adb", "forward", "--remove", "tcp:9443"],
                timeout=10,
                limit=4096,
                check=False,
            ),
        )

    def test_rc_metadata_accepts_only_exact_b04_baseline(self) -> None:
        with mock.patch.object(DEPLOY, "adb_shell", return_value="775|0|0"):
            self.assertEqual(
                DEPLOY.read_rc_metadata(), {"mode": 0o775, "uid": 0, "gid": 0}
            )
        for rejected in ("755|0|0", "775|1|0", "775|0|1", "777|0|0"):
            with mock.patch.object(DEPLOY, "adb_shell", return_value=rejected):
                with self.assertRaises(DEPLOY.DeployError):
                    DEPLOY.read_rc_metadata()

    def test_evidence_publication_is_hash_bound_and_completion_last(self) -> None:
        with tempfile.TemporaryDirectory(prefix="u60-evidence-test-") as temporary:
            root = Path(temporary)
            os.chmod(root, 0o700)
            with (
                mock.patch.object(DEPLOY, "APPROVED_NAS_ROOT", root),
                mock.patch.object(
                    DEPLOY.PROBE,
                    "open_validated_output_root",
                    side_effect=lambda path: os.open(
                        path, os.O_RDONLY | os.O_DIRECTORY
                    ),
                ),
            ):
                published = DEPLOY.write_evidence(
                    "canary",
                    {"root_adb": True},
                    {"root_adb": True},
                    {"release_id": "0" * 64},
                )
            manifest_bytes = (published / "EVIDENCE-MANIFEST.json").read_bytes()
            marker = (published / "evidence.complete").read_text()
            self.assertEqual(
                marker,
                f"{DEPLOY.COMPLETION_PREFIX}{hashlib.sha256(manifest_bytes).hexdigest()}\n",
            )
            manifest = json.loads(manifest_bytes)
            evidence = (published / "evidence.json").read_bytes()
            self.assertEqual(manifest["files"][0]["path"], "evidence.json")
            self.assertEqual(manifest["files"][0]["size"], len(evidence))
            self.assertEqual(
                manifest["files"][0]["sha256"], hashlib.sha256(evidence).hexdigest()
            )

    def test_failed_evidence_publication_leaves_no_partial_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="u60-evidence-test-") as temporary:
            root = Path(temporary)
            os.chmod(root, 0o700)
            real_write = DEPLOY.PROBE.atomic_write_at
            calls = 0

            def fail_second_write(directory_fd: int, name: str, data: bytes) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("synthetic publication interruption")
                real_write(directory_fd, name, data)

            with (
                mock.patch.object(DEPLOY, "APPROVED_NAS_ROOT", root),
                mock.patch.object(
                    DEPLOY.PROBE,
                    "open_validated_output_root",
                    side_effect=lambda path: os.open(
                        path, os.O_RDONLY | os.O_DIRECTORY
                    ),
                ),
                mock.patch.object(
                    DEPLOY.PROBE, "atomic_write_at", side_effect=fail_second_write
                ),
            ):
                with self.assertRaises(OSError):
                    DEPLOY.write_evidence(
                        "boot-hook",
                        {"root_adb": True},
                        {"root_adb": True},
                        {},
                        rc_backup=b"#!/bin/sh\nexit 0\n",
                    )
            self.assertEqual(list(root.iterdir()), [])

    def test_boot_candidate_is_exact_and_idempotent(self) -> None:
        original = b"#!/bin/sh\necho stock\nexit 0\n"
        candidate = DEPLOY.build_rc_candidate(original)
        self.assertEqual(candidate.count(DEPLOY.BOOT_LINE), 1)
        self.assertEqual(DEPLOY.build_rc_candidate(candidate), candidate)
        self.assertEqual(candidate.replace(DEPLOY.BOOT_LINE, b""), original)

    def test_boot_candidate_rejects_ambiguous_or_foreign_reference(self) -> None:
        with self.assertRaises(DEPLOY.DeployError):
            DEPLOY.build_rc_candidate(b"#!/bin/sh\nexit 0\nexit 0\n")
        with self.assertRaises(DEPLOY.DeployError):
            DEPLOY.build_rc_candidate(
                b"#!/bin/sh\n/data/u60/start-current.sh --unsafe\nexit 0\n"
            )

    def test_authorized_keys_requires_two_independent_safe_public_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "authorized_keys"
            first = "A" * 48
            second = "B" * 48
            path.write_text(f"ssh-ed25519 {first}\necdsa-sha2-nistp256 {second}\n")
            accepted = DEPLOY.validate_authorized_keys(path)
            self.assertEqual(accepted.count(b"\n"), 2)
            path.write_text(f"ssh-ed25519 {first}\nssh-ed25519 {first}\n")
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.validate_authorized_keys(path)
            path.write_text("-----BEGIN OPENSSH " + "PRIVATE KEY-----\n")
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.validate_authorized_keys(path)

    def test_device_scripts_have_fixed_safe_surface(self) -> None:
        combined = "\n".join(
            line
            for path in sorted((ROOT / "device/b04-v1").glob("*.sh"))
            for line in path.read_text().splitlines()
            if not line.lstrip().startswith("#")
        )
        for forbidden in (
            "usb_op",
            "/dev/block",
            "fw_setenv",
            "abctl",
            "uci ",
            "ubus ",
            "fota",
        ):
            self.assertNotIn(forbidden, combined.lower())
        dropbear = (ROOT / "device/b04-v1/run-dropbear.sh").read_text()
        self.assertIn("-F -E -s -g -j -k -m", dropbear)
        self.assertIn("192.168.0.1:2222", dropbear)
        agent = (ROOT / "device/b04-v1/run-agent.sh").read_text()
        self.assertIn("127.0.0.1:19443", agent)
        self.assertIn("192.168.0.1:9443", agent)


if __name__ == "__main__":
    unittest.main()
