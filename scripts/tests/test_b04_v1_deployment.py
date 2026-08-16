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
        for name in ("common.sh", "run-agent.sh", "run-dropbear.sh", "start-current.sh"):
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
                return_value={"sha256": digest, "size": self.dropbear.stat().st_size, "file": "test"},
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
            DEPLOY.build_rc_candidate(b"#!/bin/sh\n/data/u60/start-current.sh --unsafe\nexit 0\n")

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
        for forbidden in ("usb_op", "/dev/block", "fw_setenv", "abctl", "uci ", "ubus ", "fota"):
            self.assertNotIn(forbidden, combined.lower())
        dropbear = (ROOT / "device/b04-v1/run-dropbear.sh").read_text()
        self.assertIn("-F -E -s -g -j -k -m", dropbear)
        self.assertIn("192.168.0.1:2222", dropbear)
        agent = (ROOT / "device/b04-v1/run-agent.sh").read_text()
        self.assertIn("127.0.0.1:19443", agent)
        self.assertIn("192.168.0.1:9443", agent)


if __name__ == "__main__":
    unittest.main()
