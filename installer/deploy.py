"""deploy.py — MU5250 installer core: device channels, release fetch, and
the agent / harden / dashboard deploy steps.

Python port of the shell flows in setup.sh (steps 3-8), scripts/zharden.sh
and deploy-dashboard.sh, driven by installer/app.py. Same design rules as
the scripts: shell/ssh/adb only, no boot hooks outside /etc/rc.local,
idempotent steps.
"""

import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

REPO = "dklasens/MU5250-OpenUI"
RELEASE_API = f"https://api.github.com/repos/{REPO}/releases/latest"
SSH_PORT = 2222
AGENT_PORT = 9090
REMOTE_BIN = "/data/zte-agent"
STARTUP_SCRIPT = "/data/local/tmp/start_zte_agent.sh"
DROPBEAR_URL = ("https://downloads.openwrt.org/releases/23.05.4/targets/"
                "armsr/armv8/packages/dropbear_2022.82-6_aarch64_generic.ipk")


class DeployError(Exception):
    pass


# ---------- adb ----------

def find_adb():
    """Bundled platform-tools first (packaged app), then PATH (dev)."""
    base = getattr(sys, "_MEIPASS", None) or \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")
    name = "adb.exe" if os.name == "nt" else "adb"
    for cand in (os.path.join(base, "platform-tools", name),
                 os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "assets", "platform-tools", name)):
        if os.path.isfile(cand):
            return cand
    return shutil.which("adb")


def adb_devices(adb):
    if not adb:
        return []
    try:
        out = subprocess.run([adb, "devices"], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [l.split()[0] for l in out.splitlines()[1:]
            if l.strip() and l.endswith("device")]


class AdbChannel:
    name = "adb"

    def __init__(self, adb, serial=None):
        self.adb = adb
        self.serial = serial

    def _base(self):
        return [self.adb] + (["-s", self.serial] if self.serial else [])

    def shell(self, cmd, check=True):
        # sentinel pattern (same as setup.sh rcmd_check): adb shell exit codes
        # are unreliable across adb versions
        full = f"({cmd}); echo __RC__$?"
        p = subprocess.run(self._base() + ["shell", full],
                           capture_output=True, text=True, timeout=300)
        out = p.stdout
        i = out.rfind("__RC__")
        rc = int(out[i + 6:].strip() or "1") if i >= 0 else 1
        body = out[:i] if i >= 0 else out
        if check and rc != 0:
            raise DeployError(f"adb command failed (rc {rc}): {cmd}\n{body}"
                              f"{p.stderr}")
        return body.strip()

    def push(self, local, remote):
        p = subprocess.run(self._base() + ["push", local, remote],
                           capture_output=True, text=True, timeout=600)
        if p.returncode != 0:
            raise DeployError(f"adb push failed: {p.stderr or p.stdout}")

    def forward(self, lport, rport):
        subprocess.run(self._base() + ["forward", f"tcp:{lport}",
                                       f"tcp:{rport}"], check=True,
                       capture_output=True)

    def forward_remove(self, lport):
        subprocess.run(self._base() + ["forward", "--remove",
                                       f"tcp:{lport}"],
                       capture_output=True)

    def reboot(self):
        subprocess.run(self._base() + ["reboot"], capture_output=True)

    def wait(self, timeout=180, log=print):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if adb_devices(self.adb):
                return
            time.sleep(3)
            log("[*] waiting for device (adb)...")
        raise DeployError("device did not appear on adb within "
                          f"{timeout}s — check the USB cable/port")


class SshChannel:
    name = "ssh"

    def __init__(self, gw):
        self.gw = gw
        known = os.path.join(os.path.expanduser("~"), ".ssh",
                             "known_hosts.d", "zte")
        self.base = ["ssh", "-p", str(SSH_PORT), "-o", "BatchMode=yes",
                     "-o", "StrictHostKeyChecking=accept-new",
                     "-o", f"UserKnownHostsFile={known}",
                     "-o", "ConnectTimeout=10", f"root@{gw}"]

    def shell(self, cmd, check=True):
        p = subprocess.run(self.base + [cmd], capture_output=True, text=True,
                           timeout=300)
        if check and p.returncode != 0:
            raise DeployError(f"ssh command failed (rc {p.returncode}): "
                              f"{cmd}\n{p.stdout}{p.stderr}")
        return p.stdout.strip()

    def push(self, local, remote):
        # device dropbear has no sftp/scp — stream via ssh (deploy.sh pattern)
        data = open(local, "rb").read()
        p = subprocess.run(self.base + [f"cat > {remote}"], input=data,
                           capture_output=True, timeout=600)
        if p.returncode != 0:
            raise DeployError(f"ssh push failed: {p.stderr.decode()}")

    def up(self):
        p = subprocess.run(self.base + ["true"], capture_output=True,
                           timeout=15)
        return p.returncode == 0


# ---------- probing ----------

def _tcp_up(gw, port, timeout=2.0):
    try:
        with socket.create_connection((gw, port), timeout=timeout):
            return True
    except OSError:
        return False


def probe(gw, adb=None):
    return {
        "web": _tcp_up(gw, 80),
        "agent": _tcp_up(gw, AGENT_PORT),
        "ssh": _tcp_up(gw, SSH_PORT),
        "adb": bool(adb_devices(adb)),
    }


def recommend_mode(state):
    if state["adb"]:
        return "adb"       # unlocked, mid-flow
    if state["ssh"]:
        return "ssh"       # provisioned: repair / update
    if state["web"]:
        return "unlock"    # locked firmware: full flow
    return None


# ---------- release assets ----------

def latest_release(log=print):
    req = urllib.request.Request(RELEASE_API, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "mu5250-installer"})
    rel = json.loads(urllib.request.urlopen(req, timeout=30).read())
    assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
    for need in ("zte-agent", "dashboard-dist.tar.gz", "sha256sums.txt"):
        if need not in assets:
            raise DeployError(f"release {rel.get('tag_name')} is missing "
                              f"asset {need}")
    log(f"[*] release: {rel['tag_name']}")
    return assets


def download(url, dst, log=print, expect_sha=None):
    log(f"[*] downloading {os.path.basename(dst)} ...")
    with urllib.request.urlopen(url, timeout=120) as r, open(dst, "wb") as f:
        shutil.copyfileobj(r, f)
    sha = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    if expect_sha and sha != expect_sha:
        raise DeployError(f"sha256 mismatch for {os.path.basename(dst)}: "
                          f"got {sha[:16]}, expected {expect_sha[:16]}")
    log(f"[+] {os.path.basename(dst)}: {os.path.getsize(dst)} bytes, "
        f"sha256 {sha[:16]}... verified" if expect_sha else
        f"[+] {os.path.basename(dst)}: {os.path.getsize(dst)} bytes")
    return sha


def fetch_assets(assets, work, log=print):
    """Download zte-agent + dashboard tarball, verify against sha256sums.txt."""
    sums_path = os.path.join(work, "sha256sums.txt")
    download(assets["sha256sums.txt"], sums_path, log)
    sums = {}
    for line in open(sums_path):
        parts = line.split()
        if len(parts) == 2:
            sums[parts[1]] = parts[0]
    out = {}
    for name in ("zte-agent", "dashboard-dist.tar.gz"):
        dst = os.path.join(work, name)
        download(assets[name], dst, log, expect_sha=sums.get(name))
        out[name] = dst
    return out


# ---------- agent helpers ----------

def agent_login(base_url, password):
    body = json.dumps({"password": password}).encode()
    req = urllib.request.Request(base_url + "/api/auth/login", data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=10).read())
        return (resp.get("data") or {}).get("token")
    except Exception:
        return None


def startup_script_content(password, pin=""):
    # identical layout to setup.sh step 5 (syslog, not /tmp file redirect);
    # passwords are embedded shell-escaped inside single quotes
    lines = ["#!/bin/sh",
             f"export ZTE_AGENT_PASSWORD={_sh_quote(password)}",
             "# Log via syslog (logd's fixed-size ring buffer) rather than a "
             "file on /tmp:",
             "# /tmp is tmpfs, so a plain redirect grows in RAM forever with "
             "no rotation.",
             "# Read it back with: logread -e zte-agent",
             "nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' "
             ">/dev/null 2>&1 </dev/null &"]
    if pin:
        lines.insert(2, f"export ZTE_AGENT_PIN={_sh_quote(pin)}")
    return "\n".join(lines) + "\n"


def _sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------- steps ----------

def step_agent(ch, gw, password, pin, files, log):
    """setup.sh steps 3-8: push binary, startup script, rc.local, start,
    verify."""
    log("[*] checking zte-agent binary on device...")
    local = files["zte-agent"]
    local_sha = hashlib.sha256(open(local, "rb").read()).hexdigest()
    remote_sha = ch.shell(f"sha256sum {REMOTE_BIN} 2>/dev/null | "
                          "awk '{print $1}'", check=False)
    if remote_sha == local_sha:
        log("[+] binary unchanged, skipping push")
        changed = False
    else:
        log("[*] stopping running agent, pushing binary...")
        ch.shell("killall zte-agent 2>/dev/null; sleep 1", check=False)
        ch.push(local, REMOTE_BIN)
        ch.shell(f"chmod +x {REMOTE_BIN}")
        log(f"[+] binary deployed to {REMOTE_BIN}")
        changed = True

    log("[*] checking startup script...")
    script = startup_script_content(password, pin)
    # remote grep pattern must include the literal quotes the startup script
    # stores, so double-quote: inner quotes for the pattern, outer for the shell
    want_marker = _sh_quote("ZTE_AGENT_PASSWORD=" + _sh_quote(password))
    probe_rc = ch.shell(f"grep -qF {want_marker} {STARTUP_SCRIPT} "
                        "2>/dev/null && grep -qF 'logger -t zte-agent' "
                        f"{STARTUP_SCRIPT} 2>/dev/null && echo OK",
                        check=False)
    if probe_rc == "OK":
        log("[+] startup script already up to date")
    else:
        log("[*] creating startup script...")
        with tempfile.NamedTemporaryFile("w", suffix=".sh",
                                         delete=False) as f:
            f.write(script)
            tmp = f.name
        try:
            ch.shell(f"mkdir -p {os.path.dirname(STARTUP_SCRIPT)}")
            ch.push(tmp, STARTUP_SCRIPT)
        finally:
            os.unlink(tmp)
        ch.shell(f"chmod 700 {STARTUP_SCRIPT}")
        log(f"[+] startup script created at {STARTUP_SCRIPT}")

    log("[*] configuring auto-start on boot...")
    rc_line = f"sh {STARTUP_SCRIPT}"
    have_rc = ch.shell(f"grep -qF '{rc_line}' /etc/rc.local 2>/dev/null "
                       "&& echo OK", check=False)
    if have_rc != "OK":
        ch.shell(f"grep -q '^exit 0' /etc/rc.local "
                 f"&& sed -i '/^exit 0/i {rc_line}' /etc/rc.local "
                 f"|| echo {rc_line} >> /etc/rc.local")
        log("[+] added zte-agent to /etc/rc.local")
    else:
        log("[+] rc.local already configured")

    running = agent_login(f"http://{gw}:{AGENT_PORT}", password)
    if not changed and running:
        log("[+] agent already running with current binary")
    else:
        log("[*] starting zte-agent...")
        ch.shell("killall zte-agent 2>/dev/null; true", check=False)
        time.sleep(1)
        ch.shell(f"sh {STARTUP_SCRIPT}")
        time.sleep(2)
        log("[+] agent (re)started")

    log("[*] verifying agent login...")
    if ch.name == "adb":
        ch.forward(19090, AGENT_PORT)
        try:
            token = agent_login("http://127.0.0.1:19090", password)
        finally:
            ch.forward_remove(19090)
    else:
        token = agent_login(f"http://{gw}:{AGENT_PORT}", password)
    if not token:
        raise DeployError("agent started but login verification failed — "
                          "check 'logread -e zte-agent' on the device")
    log("[+] agent is running and authenticated")


def ensure_local_ssh_key(log):
    """Same key zharden.sh uses (~/.ssh/id_ed25519); generate if missing."""
    home = os.path.expanduser("~")
    priv = os.path.join(home, ".ssh", "id_ed25519")
    pub = priv + ".pub"
    if os.path.isfile(priv) and os.path.isfile(pub):
        return open(pub).read().strip()
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import \
        Ed25519PrivateKey
    key = Ed25519PrivateKey.generate()
    os.makedirs(os.path.dirname(priv), exist_ok=True)
    with open(priv, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.OpenSSH,
                                  serialization.NoEncryption()))
    os.chmod(priv, 0o600)
    pubdata = key.public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
    with open(pub, "wb") as f:
        f.write(pubdata + b"\n")
    log(f"[+] generated new ed25519 key at {priv}")
    return pubdata.decode()


def step_harden(ch, gw, files_work, log):
    """zharden.sh port: dropbear, keys, rc.local cleanup, dashboard uhttpd,
    FOTA off."""
    have = ch.shell("test -x /data/bin/dropbear && echo OK", check=False)
    if have == "OK":
        log("[+] dropbear already installed")
    else:
        log("[*] installing dropbear to /data/bin ...")
        ipk = os.path.join(files_work, "dropbear.ipk")
        download(DROPBEAR_URL, ipk, log)
        with tarfile.open(ipk, "r:gz") as t:
            member = next(m for m in t.getmembers()
                          if os.path.basename(m.name) == "data.tar.gz")
            data = t.extractfile(member).read()
        dtgz = os.path.join(files_work, "data.tar.gz")
        with open(dtgz, "wb") as f:
            f.write(data)
        ch.push(dtgz, "/tmp/data.tar.gz")
        ch.shell("cd /tmp && tar xzf data.tar.gz ./usr/sbin/dropbear "
                 "./usr/bin/dbclient ./usr/bin/dropbearkey && "
                 "mkdir -p /data/bin && cp usr/sbin/dropbear usr/bin/dbclient "
                 "usr/bin/dropbearkey /data/bin/ && chmod +x /data/bin/* && "
                 "rm -rf /tmp/usr /tmp/data.tar.gz")
        ch.shell("test -x /data/bin/dropbear")
        log("[+] dropbear installed (manual ipk extract — opkg is unusable "
            "on this firmware)")

    log("[*] wiring ssh keys + host keys...")
    pub = ensure_local_ssh_key(log)
    ch.shell("mkdir -p /etc/dropbear /data/dropbear && "
             "chmod 700 /etc/dropbear")
    qpub = _sh_quote(pub)
    ch.shell(f"grep -qF {qpub} /etc/dropbear/authorized_keys 2>/dev/null || "
             f"echo {qpub} >> /etc/dropbear/authorized_keys; "
             "chmod 600 /etc/dropbear/authorized_keys")
    ch.shell("for k in ed25519 rsa; do "
             "f=/etc/dropbear/dropbear_${k}_host_key; "
             '[ -s "$f" ] || /data/bin/dropbearkey -t $k -f $f '
             ">/dev/null 2>&1; done")
    ch.shell("cp /etc/dropbear/authorized_keys "
             "/etc/dropbear/dropbear_*_host_key /data/dropbear/ 2>/dev/null; "
             "chmod 600 /data/dropbear/*")
    ch.shell('printf "#!/bin/sh\\n/data/bin/dropbear -p 2222 '
             "-r /etc/dropbear/dropbear_ed25519_host_key "
             '-r /etc/dropbear/dropbear_rsa_host_key\\n" '
             '> /data/local/tmp/start_dropbear.sh && '
             "chmod +x /data/local/tmp/start_dropbear.sh")
    log("[+] ssh keys, host keys, startup script in place")

    log("[*] cleaning rc.local (service lines in, usb_op writes out)...")
    ch.shell(
        'grep -qF "start_zte_agent.sh" /etc/rc.local || '
        'sed -i "/^exit 0/i sh /data/local/tmp/start_zte_agent.sh" '
        "/etc/rc.local\n"
        'grep -qF "start_dropbear.sh" /etc/rc.local || '
        'sed -i "/^exit 0/i sh /data/local/tmp/start_dropbear.sh" '
        "/etc/rc.local\n"
        'sed -i "/^echo [0-9] > .*usb_op/d" /etc/rc.local\n'
        "sh -n /etc/rc.local")
    log("[+] rc.local: agent+dropbear lines present, usb_op writes gone, "
        "syntax OK")

    log("[*] dashboard uhttpd instance on :8080...")
    ch.shell("uci -q get uhttpd.dashboard >/dev/null 2>&1 || {\n"
             "uci set uhttpd.dashboard=uhttpd\n"
             'uci set uhttpd.dashboard.listen_http="0.0.0.0:8080"\n'
             'uci set uhttpd.dashboard.home="/data/www"\n'
             'uci set uhttpd.dashboard.no_dirlists="1"\n'
             "uci commit uhttpd\n"
             "}; /etc/init.d/uhttpd restart 2>/dev/null; true")
    log("[+] dashboard instance configured")

    log("[*] disabling FOTA auto-update...")
    mode = ch.shell(
        'ubus call zwrt_zte_dm set_update_mode '
        "'{\"dm_update_mode\":\"0\"}' >/dev/null 2>&1; "
        "uci get zwrt_zte_dm.dm_update.dm_update_mode", check=False)
    if "0" in mode:
        log("[+] FOTA auto-update disabled")
    else:
        log("[!] could not confirm dm_update_mode=0 — check manually")

    ch.shell("pidof dropbear >/dev/null 2>&1 || "
             "sh /data/local/tmp/start_dropbear.sh", check=False)
    time.sleep(2)
    if SshChannel(gw).up():
        log(f"[+] SSH verified: ssh -p {SSH_PORT} root@{gw}")
    else:
        log("[!] SSH not yet reachable (may need one reboot)")


def step_dashboard(ch, gw, files, log):
    """deploy-dashboard.sh port, using the release tarball instead of a
    local npm build."""
    log("[*] deploying dashboard to /data/www ...")
    ch.push(files["dashboard-dist.tar.gz"], "/tmp/dashboard-dist.tar.gz")
    ch.shell("mkdir -p /data/www && "
             "tar xzf /tmp/dashboard-dist.tar.gz -C /data/www && "
             "cp /data/www/index.html /data/www/mobile.html && "
             "rm -f /tmp/dashboard-dist.tar.gz")
    # ZTE's patched uhttpd redirects mobile user-agents to /mobile.html;
    # the cp above covers it. Restart so a fresh instance picks up /data/www.
    ch.shell("/etc/init.d/uhttpd restart 2>/dev/null; true", check=False)
    time.sleep(2)
    if _tcp_up(gw, 8080):
        log(f"[+] dashboard live at http://{gw}:8080")
    else:
        log("[!] :8080 not responding yet — a reboot usually fixes it")
