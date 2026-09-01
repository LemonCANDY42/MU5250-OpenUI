from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
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

    def test_device_release_verifier_rejects_non_regular_or_unlisted_entries(self) -> None:
        with tempfile.TemporaryDirectory(prefix="u60-device-release-test-") as temporary:
            release = Path(temporary) / "release"
            release.mkdir()
            agent = release / "zte-agent"
            agent.write_bytes(b"synthetic agent")
            digest = hashlib.sha256(agent.read_bytes()).hexdigest()
            checksum = f"{digest}  zte-agent\n".encode()
            release_id = hashlib.sha256(checksum).hexdigest()
            (release / "release.sha256").write_bytes(checksum)
            (release / "release.complete").write_text(
                f"u60-b04-v1-release:{release_id}\n"
            )
            script = DEPLOY.verify_device_release_script(
                release_id, str(release), require_basename=False
            )

            def run_verifier() -> subprocess.CompletedProcess[bytes]:
                return subprocess.run(
                    ["sh", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )

            self.assertEqual(run_verifier().returncode, 0)
            (release / "unexpected").write_bytes(b"unlisted")
            self.assertNotEqual(run_verifier().returncode, 0)
            (release / "unexpected").unlink()
            external = Path(temporary) / "external-agent"
            external.write_bytes(agent.read_bytes())
            agent.unlink()
            agent.symlink_to(external)
            self.assertNotEqual(run_verifier().returncode, 0)

    def test_device_release_verifier_fails_closed_when_busybox_rejects_quit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="u60-device-release-test-") as temporary:
            release = Path(temporary) / "release"
            release.mkdir()
            agent = release / "zte-agent"
            agent.write_bytes(b"synthetic agent")
            digest = hashlib.sha256(agent.read_bytes()).hexdigest()
            checksum = f"{digest}  zte-agent\n".encode()
            release_id = hashlib.sha256(checksum).hexdigest()
            (release / "release.sha256").write_bytes(checksum)
            (release / "release.complete").write_text(
                f"u60-b04-v1-release:{release_id}\n"
            )
            script = DEPLOY.verify_device_release_script(
                release_id, str(release), require_basename=False
            )
            real_find = shutil.which("find")
            self.assertIsNotNone(real_find)
            commands = Path(temporary) / "commands"
            commands.mkdir()
            find = commands / "find"
            find.write_text(
                "#!/bin/sh\n"
                'if [ "${FAIL_FIRST_FIND:-}" = 1 ] && [ ! -e "$FIND_FAILURE_MARKER" ]; then\n'
                '  : > "$FIND_FAILURE_MARKER"\n'
                "  exit 2\n"
                "fi\n"
                'for argument do [ "$argument" = -quit ] && exit 2; done\n'
                'exec "$REAL_FIND" "$@"\n'
            )
            os.chmod(find, 0o700)
            environment = os.environ | {
                "PATH": f"{commands}:{os.environ['PATH']}",
                "REAL_FIND": real_find,
            }

            def run_verifier() -> subprocess.CompletedProcess[bytes]:
                return subprocess.run(
                    ["sh", "-c", script],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=environment,
                )

            valid_result = run_verifier()
            self.assertEqual(valid_result.returncode, 0, valid_result.stderr.decode())
            os.mkfifo(release / "unexpected-fifo")
            result = run_verifier()
            self.assertNotEqual(result.returncode, 0, result.stderr.decode())
            (release / "unexpected-fifo").unlink()
            find_failure = subprocess.run(
                ["sh", "-c", script],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment
                | {
                    "FAIL_FIRST_FIND": "1",
                    "FIND_FAILURE_MARKER": str(Path(temporary) / "find-failed"),
                },
            )
            self.assertNotEqual(find_failure.returncode, 0, find_failure.stderr.decode())


class DeploymentBoundaryTests(unittest.TestCase):
    def test_adb_shell_requires_an_explicit_remote_status_sentinel(self) -> None:
        success = subprocess.CompletedProcess(
            ["adb", "exec-out", "wrapped"],
            0,
            b"value\n\n" + DEPLOY.ADB_SHELL_STATUS_PREFIX + b"0\n",
            b"",
        )
        with mock.patch.object(DEPLOY, "run", return_value=success) as run:
            self.assertEqual(DEPLOY.adb_shell("printf value"), "value")
        remote = run.call_args.args[0]
        self.assertEqual(remote[:2], ["adb", "exec-out"])
        self.assertIn("base64 -d | sh", remote[2])

        failure = subprocess.CompletedProcess(
            ["adb", "exec-out", "wrapped"],
            0,
            b"\n" + DEPLOY.ADB_SHELL_STATUS_PREFIX + b"7\n",
            b"",
        )
        with mock.patch.object(DEPLOY, "run", return_value=failure):
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.adb_shell("exit 7")

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
            mock.patch.object(DEPLOY, "verify_device_public_ca_matches") as ca_match,
            mock.patch.object(DEPLOY, "stop_managed_agent") as stop,
            mock.patch.object(
                DEPLOY, "stop_legacy_canary_without_pid_file"
            ) as stop_legacy,
            mock.patch.object(DEPLOY, "assert_no_zte_agent_processes") as no_agent,
            mock.patch.object(DEPLOY, "adb_shell") as adb_shell,
            mock.patch.object(DEPLOY, "run") as run,
            mock.patch.object(
                DEPLOY, "verify_device_lan_tls_unauthorized"
            ) as verify_tls,
            mock.patch.object(DEPLOY, "switch_current") as switch_current,
        ):
            details = DEPLOY.command_lan_canary(arguments)
        self.assertEqual(
            stop.call_args_list, [mock.call("canary.pid"), mock.call("agent.pid")]
        )
        ca_match.assert_called_once_with(arguments.ca_cert)
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
                    ["adb", "forward", "--remove", "tcp:9443"],
                    timeout=10,
                    limit=4096,
                    check=False,
                ),
            ],
        )
        verify_tls.assert_called_once_with()
        switch_current.assert_not_called()
        self.assertEqual(details["lan_canary"], True)

    def test_lan_canary_stops_when_tls_fails(self) -> None:
        arguments = mock.Mock(
            release=Path("/accepted/release"), ca_cert=Path("/accepted/ca.pem")
        )
        with (
            mock.patch.object(DEPLOY, "require_local_release", return_value="a" * 64),
            mock.patch.object(DEPLOY, "install_release", return_value=False),
            mock.patch.object(DEPLOY, "verify_device_public_ca_matches"),
            mock.patch.object(DEPLOY, "stop_managed_agent") as stop,
            mock.patch.object(DEPLOY, "stop_legacy_canary_without_pid_file"),
            mock.patch.object(DEPLOY, "assert_no_zte_agent_processes"),
            mock.patch.object(DEPLOY, "adb_shell"),
            mock.patch.object(DEPLOY, "run"),
            mock.patch.object(
                DEPLOY,
                "verify_device_lan_tls_unauthorized",
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

    def test_activate_checks_the_lan_listener_from_the_device(self) -> None:
        arguments = mock.Mock(
            release=Path("/accepted/release"), ca_cert=Path("/accepted/ca.pem")
        )
        with (
            mock.patch.object(DEPLOY, "require_local_release", return_value="a" * 64),
            mock.patch.object(DEPLOY, "install_release", return_value=False),
            mock.patch.object(DEPLOY, "verify_device_public_ca_matches") as ca_match,
            mock.patch.object(DEPLOY, "switch_current") as switch_current,
            mock.patch.object(DEPLOY, "stop_managed_agent") as stop,
            mock.patch.object(DEPLOY, "adb_shell") as adb_shell,
            mock.patch.object(DEPLOY, "run") as run,
            mock.patch.object(
                DEPLOY, "verify_device_lan_tls_unauthorized"
            ) as verify_tls,
        ):
            details = DEPLOY.command_activate(arguments)
        ca_match.assert_called_once_with(arguments.ca_cert)
        switch_current.assert_called_once_with("a" * 64)
        stop.assert_called_once_with("agent.pid")
        adb_shell.assert_called_once_with(
            f"{DEPLOY.DEVICE_ROOT}/releases/{'a' * 64}/bin/run-agent.sh stable",
            timeout=30,
        )
        verify_tls.assert_called_once_with()
        run.assert_not_called()
        self.assertEqual(details["tls_401"], True)

    def test_activate_rolls_back_when_the_new_agent_cannot_start(self) -> None:
        arguments = mock.Mock(
            release=Path("/accepted/release"), ca_cert=Path("/accepted/ca.pem")
        )
        with (
            mock.patch.object(DEPLOY, "require_local_release", return_value="a" * 64),
            mock.patch.object(DEPLOY, "install_release", return_value=False),
            mock.patch.object(DEPLOY, "verify_device_public_ca_matches"),
            mock.patch.object(DEPLOY, "switch_current"),
            mock.patch.object(DEPLOY, "stop_managed_agent"),
            mock.patch.object(
                DEPLOY,
                "adb_shell",
                side_effect=DEPLOY.DeployError("synthetic start failure"),
            ),
            mock.patch.object(
                DEPLOY,
                "read_release_links",
                return_value={"current": "new", "previous": "old"},
            ),
            mock.patch.object(DEPLOY, "rollback_current") as rollback,
        ):
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.command_activate(arguments)
        rollback.assert_called_once_with()

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

    def test_boot_install_requires_both_live_services_and_two_keys(self) -> None:
        original = b"#!/bin/sh\necho stock\nexit 0\n"
        candidate = DEPLOY.build_rc_candidate(original)
        start_digest = DEPLOY.sha256_file(DEPLOY.START_CURRENT_SOURCE)
        with (
            mock.patch.object(DEPLOY, "adb_push"),
            mock.patch.object(
                DEPLOY,
                "adb_shell",
                side_effect=lambda script, **_kwargs: (
                    start_digest if script.startswith("sha256sum ") else ""
                ),
            ) as adb_shell,
            mock.patch.object(DEPLOY, "read_rc_local", return_value=candidate),
            mock.patch.object(
                DEPLOY,
                "read_rc_metadata",
                return_value={"mode": 0o775, "uid": 0, "gid": 0},
            ),
        ):
            self.assertTrue(
                DEPLOY.install_boot_hook(
                    original,
                    {"mode": 0o775, "uid": 0, "gid": 0},
                )
            )
        gate = next(
            call.args[0]
            for call in adb_shell.call_args_list
            if f"{DEPLOY.DEVICE_ROOT}/runtime/agent.pid" in call.args[0]
        )
        self.assertIn(f"{DEPLOY.DEVICE_ROOT}/runtime/agent.pid", gate)
        self.assertIn(f"{DEPLOY.DEVICE_ROOT}/runtime/dropbear.pid", gate)
        self.assertIn(f"{DEPLOY.DEVICE_ROOT}/ssh/authorized_keys", gate)
        self.assertIn('" -eq 2 ]', gate)
        self.assertIn("mv -fT", gate)

    def test_boot_install_rejects_missing_post_write_readback(self) -> None:
        original = b"#!/bin/sh\necho stock\nexit 0\n"
        with (
            mock.patch.object(DEPLOY, "adb_push"),
            mock.patch.object(DEPLOY, "adb_shell"),
            mock.patch.object(DEPLOY, "read_rc_local", return_value=original),
        ):
            with self.assertRaises(DEPLOY.DeployError):
                DEPLOY.install_boot_hook(
                    original,
                    {"mode": 0o775, "uid": 0, "gid": 0},
                )

    def test_release_switch_uses_no_directory_target_and_checks_readback(self) -> None:
        old_id = "a" * 64
        new_id = "b" * 64
        old = f"{DEPLOY.DEVICE_ROOT}/releases/{old_id}"
        new = f"{DEPLOY.DEVICE_ROOT}/releases/{new_id}"
        with (
            mock.patch.object(
                DEPLOY,
                "read_release_links",
                side_effect=[
                    {"current": old, "previous": None},
                    {"current": new, "previous": old},
                ],
            ),
            mock.patch.object(DEPLOY, "adb_shell") as adb_shell,
        ):
            DEPLOY.switch_current(new_id)
        switch_script = adb_shell.call_args_list[-1].args[0]
        self.assertIn("mv -fT previous.next previous", switch_script)
        self.assertIn("mv -fT current.next current", switch_script)

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
        self.assertIn("-F -j -k -m", dropbear)
        self.assertNotIn("-E", dropbear)
        self.assertNotIn("-s -g", dropbear)
        self.assertIn("192.168.0.1:2222", dropbear)
        compile_options = (ROOT / "device/dropbear/localoptions.h").read_text()
        self.assertIn("#define DROPBEAR_SVR_PASSWORD_AUTH 0", compile_options)
        self.assertIn("#define DROPBEAR_SVR_PAM_AUTH 0", compile_options)
        self.assertIn("#define DROPBEAR_SVR_PUBKEY_AUTH 1", compile_options)
        agent = (ROOT / "device/b04-v1/run-agent.sh").read_text()
        self.assertIn("127.0.0.1:19443", agent)
        self.assertIn("192.168.0.1:9443", agent)

    def test_boot_start_is_network_gated_and_has_finite_retries(self) -> None:
        startup = (ROOT / "device/b04-v1/start-current.sh").read_text()
        self.assertIn("ip -4 addr show", startup)
        self.assertIn("boot_wait_remaining=24", startup)
        self.assertIn("start_attempts=3", startup)
        self.assertIn('sleep 5', startup)
        self.assertIn('"$release/bin/run-agent.sh" stable', startup)
        self.assertIn('"$release/bin/run-dropbear.sh"', startup)

    def test_long_running_services_do_not_write_process_logs(self) -> None:
        agent = (ROOT / "device/b04-v1/run-agent.sh").read_text()
        dropbear = (ROOT / "device/b04-v1/run-dropbear.sh").read_text()
        self.assertIn('>/dev/null 2>&1 </dev/null &', agent)
        self.assertIn('>/dev/null 2>&1 </dev/null &', dropbear)
        self.assertNotIn('>>"$log"', agent)
        self.assertNotIn('>>"$log"', dropbear)

    def test_ssh_host_scan_must_match_the_adb_device_key(self) -> None:
        expected = "ssh-ed25519 " + "A" * 48
        accepted = f"[192.168.0.1]:2222 {expected}\n".encode()
        DEPLOY.verify_scanned_ssh_host_key(accepted, expected)
        with self.assertRaises(DEPLOY.DeployError):
            DEPLOY.verify_scanned_ssh_host_key(
                b"[192.168.0.1]:2222 ssh-ed25519 " + b"B" * 48 + b"\n",
                expected,
            )
        with self.assertRaises(DEPLOY.DeployError):
            DEPLOY.verify_scanned_ssh_host_key(
                accepted + b"[192.168.0.1]:2222 ssh-rsa " + b"C" * 48 + b"\n",
                expected,
            )


if __name__ == "__main__":
    unittest.main()
