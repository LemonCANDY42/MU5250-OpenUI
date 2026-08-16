#!/usr/bin/env python3
"""app.py — MU5250 one-click installer GUI (Tkinter).

Deploys the full stack (unlock -> agent -> SSH hardening -> dashboard) on a
ZTE U60 Pro (MU5250) from Mac, Windows or Linux, using the pre-built
artifacts from this repo's GitHub releases. No Rust/Node toolchain needed.

Run from source:   python3 installer/app.py
Packaged builds:   see installer/README.md (PyInstaller, CI matrix)
"""

import os
import queue
import sys
import tempfile
import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "scripts"))
import deploy  # noqa: E402  (installer/deploy.py, same directory)
import zunlock  # noqa: E402  (scripts/zunlock.py)

MODE_LABELS = {
    "unlock": "Locked firmware — full flow: unlock, agent, SSH, dashboard",
    "adb": "Unlocked (adb present) — agent, SSH, dashboard",
    "ssh": "Provisioned (SSH up) — repair/update agent, SSH, dashboard",
    None: "Device not reachable — connect via USB-C or Wi-Fi and re-detect",
}


class InstallerApp:
    def __init__(self, root):
        self.root = root
        self.q = queue.Queue()
        self.adb = deploy.find_adb()
        self.state = None
        self.mode = None
        self.running = False
        self._confirm_answer = None
        self._confirm_event = threading.Event()
        self._build()
        self.root.after(100, self._drain)
        self.root.after(200, self.detect)

    # ---------- UI ----------

    def _build(self):
        self.root.title("MU5250 Installer (U60 Pro)")
        self.root.resizable(False, False)
        pad = {"padx": 10, "pady": 4}

        frm = ttk.Frame(self.root)
        frm.grid(sticky="nsew", **pad)

        def row(i, label, show=None):
            ttk.Label(frm, text=label).grid(row=i, column=0, sticky="e",
                                            padx=(0, 8), pady=3)
            e = ttk.Entry(frm, width=42, show=show or "")
            e.grid(row=i, column=1, sticky="we", pady=3)
            return e

        self.gw = row(0, "Device address")
        self.gw.insert(0, "192.168.0.1")
        self.router_pw = row(1, "Router admin password", show="*")
        self.suffix = row(2, "Backup-key suffix", show="*")
        self.agent_pw = row(3, "Agent password (your choice)", show="*")
        self.pin = row(4, "Agent PIN (optional, 6 digits)")

        ttk.Label(frm, text="Suffix: from the community / a rooted unit — "
                  "only needed for the unlock step.\nSee docs/DEPLOYMENT.md. "
                  "Nothing is stored or transmitted except to your device."
                  ).grid(row=5, column=0, columnspan=2, sticky="w", pady=4)

        self.status = ttk.Label(self.root, text="", wraplength=520,
                                justify="left")
        self.status.grid(sticky="we", **pad)

        btns = ttk.Frame(self.root)
        btns.grid(sticky="we", **pad)
        self.detect_btn = ttk.Button(btns, text="Detect device",
                                     command=self.detect)
        self.detect_btn.pack(side="left")
        self.dry = tk.BooleanVar(value=False)
        ttk.Checkbutton(btns, text="Unlock dry-run (prepare, don't upload)",
                        variable=self.dry).pack(side="left", padx=10)
        self.reboot_after = tk.BooleanVar(value=True)
        ttk.Checkbutton(btns, text="Reboot when done",
                        variable=self.reboot_after).pack(side="left")

        self.run_btn = ttk.Button(self.root, text="Install",
                                  command=self.run, state="disabled")
        self.run_btn.grid(sticky="we", **pad)

        steps = ttk.LabelFrame(self.root, text="Steps")
        steps.grid(sticky="we", **pad)
        self.step_labels = []
        for i, name in enumerate(["Unlock", "Wait for device",
                                  "Agent", "SSH hardening", "Dashboard"]):
            lab = ttk.Label(steps, text=f"○  {name}")
            lab.grid(row=0, column=i, padx=8, pady=4)
            self.step_labels.append(lab)

        self.log = scrolledtext.ScrolledText(self.root, width=78, height=16,
                                             state="disabled")
        self.log.grid(**pad)

    def _set_step(self, i, mark):
        marks = {"run": "▶", "ok": "✔", "fail": "✖", "skip": "–",
                 "reset": "○"}
        text = self.step_labels[i].cget("text")
        self.step_labels[i].config(text=f"{marks[mark]}  {text[3:]}")

    def _log(self, msg):
        self.log.config(state="normal")
        self.log.insert("end", msg + "\n")
        self.log.see("end")
        self.log.config(state="disabled")

    def _drain(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "log":
                    self._log(payload)
                elif kind == "step":
                    self._set_step(*payload)
                elif kind == "status":
                    self.status.config(text=payload)
                elif kind == "detect-done":
                    self._detect_done(*payload)
                elif kind == "confirm":
                    msg, = payload
                    ok = messagebox.askyesno(
                        "Confirm — device will reboot", msg,
                        icon="warning")
                    self._confirm_answer = ok
                    self._confirm_event.set()
                elif kind == "done":
                    self.running = False
                    self.run_btn.config(state="normal")
                    self.detect_btn.config(state="normal")
                    if payload:
                        messagebox.showerror("Install failed", payload)
        except queue.Empty:
            pass
        self.root.after(100, self._drain)

    # ---------- detection ----------

    def detect(self):
        gw = self.gw.get().strip() or "192.168.0.1"
        self.status.config(text="Detecting...")
        self.detect_btn.config(state="disabled")
        self.run_btn.config(state="disabled")

        def work():
            state = deploy.probe(gw, self.adb)
            self.q.put(("detect-done", (state, deploy.recommend_mode(state))))

        threading.Thread(target=work, daemon=True).start()

    def _detect_done(self, state, mode):
        self.state, self.mode = state, mode
        s = state
        bits = [f"web UI :80 {'up' if s['web'] else 'down'}",
                f"agent :9090 {'up' if s['agent'] else 'down'}",
                f"ssh :2222 {'up' if s['ssh'] else 'down'}",
                f"adb {'device found' if s['adb'] else 'none'}",
                f"adb binary: {self.adb or 'NOT FOUND'}"]
        self.status.config(text=MODE_LABELS[mode] + "\n" +
                           "  |  ".join(bits))
        self.detect_btn.config(state="normal")
        self.run_btn.config(state="normal" if mode else "disabled")

    # ---------- confirm bridge ----------

    def _confirm(self, msg):
        self._confirm_event.clear()
        self.q.put(("confirm", (msg,)))
        self._confirm_event.wait()
        return self._confirm_answer

    # ---------- flow ----------

    def run(self):
        if self.running or not self.mode:
            return
        gw = self.gw.get().strip() or "192.168.0.1"
        router_pw = self.router_pw.get()
        suffix = self.suffix.get()
        agent_pw = self.agent_pw.get()
        pin = self.pin.get().strip()

        if self.mode in ("unlock",) and (not router_pw or not suffix):
            messagebox.showerror(
                "Missing input",
                "The unlock step needs the router admin password and the "
                "backup-key suffix.")
            return
        if not agent_pw:
            messagebox.showerror("Missing input",
                                 "Choose an agent password (you will use it "
                                 "to log into the dashboard).")
            return
        if pin and (len(pin) != 6 or not pin.isdigit()):
            messagebox.showerror("Invalid PIN",
                                 "Agent PIN must be exactly 6 digits "
                                 "(or leave it empty).")
            return

        for i in range(5):
            self._set_step(i, "reset")
        self.running = True
        self.run_btn.config(state="disabled")
        self.detect_btn.config(state="disabled")
        threading.Thread(target=self._worker,
                         args=(gw, router_pw, suffix, agent_pw, pin),
                         daemon=True).start()

    def _worker(self, gw, router_pw, suffix, agent_pw, pin):
        q = self.q
        log = lambda m: q.put(("log", m))
        step = lambda i, m: q.put(("step", (i, m)))
        err = None
        try:
            work = tempfile.mkdtemp(prefix="mu-install-")
            log(f"[*] work dir: {work}")
            ch = None

            if self.mode == "unlock":
                step(0, "run")
                log("[*] === Step 1: unlock (config backup/restore) ===")
                zunlock.run_unlock(
                    gw, router_pw, suffix,
                    dry_run=self.dry.get(),
                    log=log,
                    confirm=lambda: self._confirm(
                        "Upload the patched backup and trigger restore?\n\n"
                        "The device will apply settings and REBOOT "
                        "(~90 s offline), then come back with adb enabled."))
                step(0, "ok")
                if self.dry.get():
                    log("[*] dry-run complete — nothing was uploaded. "
                        "Uncheck dry-run to install for real.")
                    q.put(("done", None))
                    return
                step(1, "run")
                adb = self.adb or deploy.find_adb()
                if not adb:
                    raise deploy.DeployError(
                        "adb binary not found — install Android platform-"
                        "tools or put adb on PATH")
                ch = deploy.AdbChannel(adb)
                ch.wait(timeout=240, log=log)
                step(1, "ok")
            elif self.mode == "adb":
                step(0, "skip")
                step(1, "skip")
                ch = deploy.AdbChannel(self.adb)
            else:  # ssh
                step(0, "skip")
                step(1, "skip")
                ch = deploy.SshChannel(gw)
                if not ch.up():
                    raise deploy.DeployError("SSH channel not reachable")

            log(f"[*] channel: {ch.name}")

            step(2, "run")
            log("[*] === Step 2: agent (from GitHub release) ===")
            assets = deploy.latest_release(log)
            files = deploy.fetch_assets(assets, work, log)
            deploy.step_agent(ch, gw, agent_pw, pin, files, log)
            step(2, "ok")

            step(3, "run")
            log("[*] === Step 3: SSH hardening ===")
            deploy.step_harden(ch, gw, work, log)
            step(3, "ok")

            step(4, "run")
            log("[*] === Step 4: dashboard ===")
            deploy.step_dashboard(ch, gw, files, log)
            step(4, "ok")

            if ch.name == "adb" and self.reboot_after.get():
                if self._confirm(
                        "All steps done. Reboot now to drop the adb USB "
                        "composition and restore normal tethering?\n\n"
                        "(~90 s; afterwards SSH :2222 and the dashboard "
                        ":8080 are up.)"):
                    log("[*] rebooting device...")
                    ch.reboot()

            log("")
            log("[+] Install complete.")
            log(f"    Dashboard:  http://{gw}:8080  (agent password)")
            log(f"    Agent API:  http://{gw}:9090")
            log(f"    SSH:        ssh -p 2222 root@{gw}")
            q.put(("status", "Install complete. Dashboard: "
                             f"http://{gw}:8080"))
        except zunlock.UnlockError as e:
            err = str(e)
            log(f"[x] {e}")
        except deploy.DeployError as e:
            err = str(e)
            log(f"[x] {e}")
        except Exception as e:  # noqa: BLE001 — surface anything in the GUI
            err = f"{type(e).__name__}: {e}"
            log(f"[x] unexpected: {err}")
        finally:
            if err:
                for i, lab in enumerate(self.step_labels):
                    if "▶" in lab.cget("text"):
                        q.put(("step", (i, "fail")))
            q.put(("done", err))


def main():
    # keep the platform default theme (aqua on macOS): forcing clam/alt
    # makes ttk widgets render invisible on macOS dark mode
    root = tk.Tk()
    InstallerApp(root)
    if sys.platform == "darwin":
        # packaged --noconsole apps start as background agents on macOS and
        # the Tk window can render blank until activated; force it forward
        root.lift()
        root.attributes("-topmost", True)
        root.after(500, lambda: root.attributes("-topmost", False))
        try:
            from AppKit import NSApplication, NSApplicationActivationPolicyRegular
            NSApplication.sharedApplication().setActivationPolicy_(
                NSApplicationActivationPolicyRegular)
        except ImportError:
            pass
    root.mainloop()


if __name__ == "__main__":
    main()
