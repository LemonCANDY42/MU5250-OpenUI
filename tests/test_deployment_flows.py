import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class DeploymentFlowTests(unittest.TestCase):
    def test_zharden_does_not_trust_local_adb_success(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir = temp_path / "bin"
            bin_dir.mkdir()

            adb = bin_dir / "adb"
            adb.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = devices ]; then printf 'List of devices attached\\nserial\\tdevice\\n'; fi\n"
                "exit 0\n"
            )
            adb.chmod(adb.stat().st_mode | stat.S_IXUSR)

            curl = bin_dir / "curl"
            curl.write_text("#!/bin/sh\nexit 22\n")
            curl.chmod(curl.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["HOME"] = temp
            result = subprocess.run(
                ["/bin/bash", "scripts/zharden.sh"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installing dropbear", result.stdout)
        self.assertNotIn("dropbear already installed", result.stdout)

    def test_zharden_stops_when_remote_dropbear_extract_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir = temp_path / "bin"
            bin_dir.mkdir()

            inner = io.BytesIO()
            with tarfile.open(fileobj=inner, mode="w:gz"):
                pass
            ipk = temp_path / "dropbear.ipk"
            with tarfile.open(ipk, mode="w:gz") as archive:
                info = tarfile.TarInfo("data.tar.gz")
                info.size = len(inner.getvalue())
                archive.addfile(info, io.BytesIO(inner.getvalue()))

            adb = bin_dir / "adb"
            adb.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = devices ]; then printf 'List of devices attached\\nserial\\tdevice\\n'; fi\n"
                "exit 0\n"
            )
            adb.chmod(adb.stat().st_mode | stat.S_IXUSR)

            curl = bin_dir / "curl"
            curl.write_text(
                "#!/bin/sh\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = -o ]; then cp \"$FAKE_IPK\" \"$2\"; exit; fi\n"
                "  shift\n"
                "done\n"
                "exit 2\n"
            )
            curl.chmod(curl.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env["PATH"] = f"{bin_dir}:{env['PATH']}"
            env["HOME"] = temp
            env["FAKE_IPK"] = str(ipk)
            result = subprocess.run(
                ["/bin/bash", "scripts/zharden.sh"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=15,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installing dropbear", result.stdout)
        self.assertNotIn("dropbear installed (", result.stdout)

    def test_shell_flows_use_device_local_verification(self):
        setup = (ROOT / "setup.sh").read_text()
        harden = (ROOT / "scripts" / "zharden.sh").read_text()
        dashboard = (ROOT / "deploy-dashboard.sh").read_text()

        self.assertNotIn("adb forward tcp:19090", setup)
        self.assertIn("/usr/bin/curl", setup)
        self.assertLess(
            harden.index("mkdir -p /data/www"),
            harden.index("/etc/init.d/uhttpd restart"),
        )
        self.assertIn("/data/bin/dashboard-uhttpd", harden)
        self.assertIn("start_dashboard.sh", harden)
        self.assertIn("uci -q delete uhttpd.dashboard", harden)
        self.assertIn("sh /data/local/tmp/start_dashboard.sh", dashboard)
        self.assertNotIn("restart 2>/dev/null; true", harden)
        self.assertLess(dashboard.index("npm ci"), dashboard.index("npm run build"))

    def test_tauri_installer_preserves_deployment_guards(self):
        deploy = (ROOT / "installer" / "src-tauri" / "src" / "deploy.rs").read_text()
        app = (ROOT / "installer" / "src" / "App.tsx").read_text()
        production_deploy = deploy.split("#[cfg(test)]", maxsplit=1)[0]

        self.assertIn("__MU5250_RC__", deploy)
        self.assertIn("[ -f /data/bin/dropbear ] && [ -x /data/bin/dropbear ]", deploy)
        self.assertIn("192.168.0.1:9090/api/auth/login", deploy)
        self.assertNotIn("adb forward", production_deploy)
        self.assertIn("/data/bin/dashboard-uhttpd", deploy)
        self.assertIn("start_dashboard.sh", deploy)
        self.assertIn("uci -q delete uhttpd.dashboard", deploy)
        self.assertIn("agentPasswordConfirmation", app)
        self.assertIn("invalidate_detection", app)
        self.assertNotIn("Cancel", app)

    @unittest.skipUnless(shutil.which("node"), "Node.js is required")
    def test_node_version_matrix_matches_package_engine(self):
        checker = ROOT / "web-app" / "tools" / "check-node-version.mjs"
        expected = {
            "18.19.1": False,
            "20.18.0": False,
            "20.19.0": True,
            "21.7.3": False,
            "22.11.0": False,
            "22.12.0": True,
            "24.0.0": True,
        }
        for version, supported in expected.items():
            with self.subTest(version=version):
                result = subprocess.run(
                    ["node", str(checker), version],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode == 0, supported)

        dashboard_package = json.loads((ROOT / "web-app" / "package.json").read_text())
        installer_package = json.loads((ROOT / "installer" / "package.json").read_text())
        expected_engine = "^20.19.0 || >=22.12.0"
        self.assertEqual(dashboard_package["engines"]["node"], expected_engine)
        self.assertEqual(installer_package["engines"]["node"], expected_engine)


if __name__ == "__main__":
    unittest.main()
