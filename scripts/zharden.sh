#!/bin/bash
# zharden.sh — post-unlock hardening for the MU5250 (U60 Pro) on B04+.
#
# Run AFTER scripts/zunlock.py (adb up) and setup.sh (agent installed).
# Idempotent: safe to re-run anytime; each step no-ops when already done.
#
# What it does (details in docs/DEPLOYMENT.md):
#   1. installs dropbear SSH (port 2222, key auth) into /data
#   2. cleans rc.local: keeps stock + agent/dropbear lines, removes usb_op
#      write lines (so every boot = stock ECM tethering; adb on demand)
#   3. installs an isolated dashboard web server on :8080
#   4. disables FOTA auto-update
#   5. offers a final reboot into the clean state
#
# DESIGN RULE (2026-07-21): shell/ssh/adb only. This script deliberately
# installs NO boot hooks outside /etc/rc.local and does NOT modify system
# services (no firewall includes/hooks). A boot-time hook that stalls or
# fails can wedge the device before any recovery interface exists. rc.local
# is not FOTA-preserved, so after a firmware update simply re-run:
# zunlock.py -> setup.sh -> zharden.sh (~15 min, see docs/DEPLOYMENT.md).
#
# Usage: bash scripts/zharden.sh [--gw 192.168.0.1]
set -euo pipefail

GW="${1:-192.168.0.1}"; GW="${GW#--gw }"; GW="${GW#--gw=}"
SSH_PORT=2222
SSH="ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts.d/zte -o ConnectTimeout=5 root@$GW"
DROPBEAR_URL="https://downloads.openwrt.org/releases/23.05.4/targets/armsr/armv8/packages/dropbear_2022.82-6_aarch64_generic.ipk"
DROPBEAR_SHA256="4fadd1b8529f22fb5d64ee27159d11f4feb68224657953d298a1acf85a83a5c0"
DASHBOARD_HTTPD_URL="https://downloads.openwrt.org/releases/23.05.4/packages/aarch64_generic/base/uhttpd_2023-06-25-34a8a74d-2_aarch64_generic.ipk"
DASHBOARD_HTTPD_SHA256="bd3f010e71a5ea2ef6405e44dbe8c9e697454ce954c197f177ff0c13b9cf5991"

info() { echo -e "\033[0;36m[*]\033[0m $1"; }
ok()   { echo -e "\033[0;32m[+]\033[0m $1"; }
warn() { echo -e "\033[1;33m[!]\033[0m $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

download_pinned() {
  local url=$1 expected=$2 destination=$3 label=$4 actual
  curl -sfL "$url" -o "$destination"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$destination" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$destination" | awk '{print $1}')
  fi
  if [ "$actual" != "$expected" ]; then
    echo "$label integrity check failed: expected $expected, received $actual" >&2
    exit 1
  fi
}

# ── Channel: prefer adb (always present right after zunlock) ─────────────
if adb devices 2>/dev/null | grep -q 'device$'; then
  CH=adb; info "channel: adb"
elif $SSH 'true' 2>/dev/null; then
  CH=ssh; info "channel: ssh"
else
  echo "No channel: run scripts/zunlock.py first (adb), or have dropbear up (ssh)." >&2
  exit 1
fi
rcmd() { if [ "$CH" = adb ]; then adb shell "$@"; else $SSH "$@"; fi; }

# `adb shell` on this device does not reliably propagate the remote exit code.
# Append a success sentinel and require it as the final output line. SSH
# already returns the remote status directly.
rcmd_check() {
  if [ "$CH" = ssh ]; then
    $SSH "set -e; $*"
    return
  fi

  local output last
  if ! output=$(adb shell "(set -e; $*) && echo __ADB_OK__" 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
  last=$(printf '%s\n' "$output" | tr -d '\r' | tail -n 1)
  if [ "$last" != "__ADB_OK__" ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# ── 1. dropbear into /data ───────────────────────────────────────────────
if rcmd_check 'test -x /data/bin/dropbear'; then
  ok "dropbear already installed"
else
  info "installing dropbear to /data/bin ..."
  download_pinned "$DROPBEAR_URL" "$DROPBEAR_SHA256" "$TMP/dropbear.ipk" "dropbear"
  (cd "$TMP" && tar xzf dropbear.ipk data.tar.gz)
  if [ "$CH" = adb ]; then
    adb push "$TMP/data.tar.gz" /tmp/data.tar.gz >/dev/null
    rcmd_check 'cd /tmp && tar xzf data.tar.gz ./usr/sbin/dropbear ./usr/bin/dbclient ./usr/bin/dropbearkey && mkdir -p /data/bin && cp usr/sbin/dropbear usr/bin/dbclient usr/bin/dropbearkey /data/bin/ && chmod +x /data/bin/* && rm -rf /tmp/usr /tmp/data.tar.gz'
  else
    cat "$TMP/data.tar.gz" | $SSH 'cat > /tmp/data.tar.gz; cd /tmp && tar xzf data.tar.gz ./usr/sbin/dropbear ./usr/bin/dbclient ./usr/bin/dropbearkey && mkdir -p /data/bin && cp usr/sbin/dropbear usr/bin/dbclient usr/bin/dropbearkey /data/bin/ && chmod +x /data/bin/* && rm -rf /tmp/usr /tmp/data.tar.gz'
  fi
  rcmd_check 'test -x /data/bin/dropbear'
  ok "dropbear installed (manual ipk extract — opkg is unusable on this firmware)"
fi

# ssh key + host keys + authorized_keys
[ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" >/dev/null
rcmd_check 'mkdir -p /etc/dropbear /data/dropbear && chmod 700 /etc/dropbear'
PUB=$(cat "$HOME/.ssh/id_ed25519.pub")
rcmd_check "grep -qF '$PUB' /etc/dropbear/authorized_keys 2>/dev/null || echo '$PUB' >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys"
rcmd_check 'for k in ed25519 rsa; do f=/etc/dropbear/dropbear_${k}_host_key; [ -s "$f" ] || /data/bin/dropbearkey -t $k -f $f >/dev/null 2>&1; done'
rcmd_check 'cp /etc/dropbear/authorized_keys /etc/dropbear/dropbear_*_host_key /data/dropbear/ 2>/dev/null; chmod 600 /data/dropbear/*'
rcmd_check 'printf "#!/bin/sh\n/data/bin/dropbear -p 2222 -r /etc/dropbear/dropbear_ed25519_host_key -r /etc/dropbear/dropbear_rsa_host_key\n" > /data/local/tmp/start_dropbear.sh && chmod +x /data/local/tmp/start_dropbear.sh'
ok "ssh keys, host keys, startup script in place"

# ZTE's patched uhttpd publishes a singleton zwrt_uhttpd ubus object. A
# second UCI instance can therefore exit while the init script still reports
# success. Install the stock OpenWrt binary under a distinct path for a truly
# independent dashboard listener.
if rcmd_check 'test -f /data/bin/dashboard-uhttpd && test -x /data/bin/dashboard-uhttpd'; then
  ok "isolated dashboard web server already installed"
else
  info "installing isolated dashboard web server ..."
  download_pinned "$DASHBOARD_HTTPD_URL" "$DASHBOARD_HTTPD_SHA256" "$TMP/uhttpd.ipk" "dashboard uhttpd"
  (cd "$TMP" && tar xzf uhttpd.ipk ./data.tar.gz)
  if [ "$CH" = adb ]; then
    adb push "$TMP/data.tar.gz" /tmp/uhttpd-data.tar.gz >/dev/null
  else
    cat "$TMP/data.tar.gz" | $SSH 'cat > /tmp/uhttpd-data.tar.gz'
  fi
  rcmd_check 'set -e; cd /tmp; tar xzf uhttpd-data.tar.gz ./usr/sbin/uhttpd; mkdir -p /data/bin; cp usr/sbin/uhttpd /data/bin/dashboard-uhttpd; chmod +x /data/bin/dashboard-uhttpd; rm -rf /tmp/usr /tmp/uhttpd-data.tar.gz'
  rcmd_check 'test -f /data/bin/dashboard-uhttpd && test -x /data/bin/dashboard-uhttpd'
  ok "isolated dashboard web server installed"
fi

rcmd_check 'mkdir -p /data/www /data/local/tmp
printf "#!/bin/sh\nif [ -s /var/run/dashboard-uhttpd.pid ]; then\n  pid=\$(cat /var/run/dashboard-uhttpd.pid)\n  kill \"\$pid\" 2>/dev/null || true\nfi\nnohup /data/bin/dashboard-uhttpd -f -h /data/www -p 0.0.0.0:8080 -D >/tmp/dashboard-uhttpd.log 2>&1 </dev/null &\necho \$! > /var/run/dashboard-uhttpd.pid\n" > /data/local/tmp/start_dashboard.sh
chmod 700 /data/local/tmp/start_dashboard.sh
uci -q delete uhttpd.dashboard || true
uci commit uhttpd
/etc/init.d/uhttpd restart'
ok "stock web UI and isolated dashboard listener configured"

# ── 2. rc.local: service lines present, usb_op writes removed ────────────
rcmd_check '
grep -qF "start_zte_agent.sh" /etc/rc.local || sed -i "/^exit 0/i sh /data/local/tmp/start_zte_agent.sh" /etc/rc.local
grep -qF "start_dropbear.sh" /etc/rc.local || sed -i "/^exit 0/i sh /data/local/tmp/start_dropbear.sh" /etc/rc.local
grep -qF "start_dashboard.sh" /etc/rc.local || sed -i "/^exit 0/i sh /data/local/tmp/start_dashboard.sh" /etc/rc.local
# remove only usb_op WRITE lines (echo 1 > ...usb_op); the stock flash-protect
# block READS usb_op and must stay (deleting it breaks rc.local syntax)
sed -i "/^echo [0-9] > .*usb_op/d" /etc/rc.local
sh -n /etc/rc.local'
ok "rc.local: agent+dropbear+dashboard lines present, usb_op writes gone, syntax OK"

# ── 3. independent dashboard listener ────────────────────────────────────
rcmd_check 'echo DASHBOARD_READY > /data/www/.installer-health
sh /data/local/tmp/start_dashboard.sh'
sleep 1
rcmd_check 'test "$(/usr/bin/curl --fail --silent --show-error --connect-timeout 5 --max-time 10 http://127.0.0.1:8080/.installer-health)" = DASHBOARD_READY && rm -f /data/www/.installer-health'
ok "isolated dashboard server listening on :8080"

# ── 4. auto-update OFF ───────────────────────────────────────────────────
rcmd 'ubus call zwrt_zte_dm set_update_mode "{\"dm_update_mode\":\"0\"}" >/dev/null 2>&1; uci get zwrt_zte_dm.dm_update.dm_update_mode' | grep -q 0 \
  && ok "FOTA auto-update disabled" || warn "could not confirm dm_update_mode=0 — check manually"

# ── 5. start dropbear now + verify ssh ───────────────────────────────────
rcmd_check 'pidof dropbear >/dev/null 2>&1 || sh /data/local/tmp/start_dropbear.sh'
sleep 2
if $SSH 'echo ok' >/dev/null 2>&1; then
  ok "SSH verified: ssh -p 2222 root@$GW"
else
  warn "SSH not yet reachable (firewall may need a reload, or reboot once)"
fi

echo ""
ok "Hardening complete. Every boot = stock ECM tethering + agent :9090 + ssh :2222."
echo "    Dashboard: http://$GW:8080   (deploy with: bash deploy-dashboard.sh)"
echo "    ADB on demand: ssh -p 2222 root@$GW 'echo 1 > /sys/class/android_usb/android0/usb_op' + reboot"
if [ "$CH" = adb ]; then
  echo ""
  echo "Reboot now to drop the ADB composition and return USB tethering? [y/N]"
  read -r ANS
  if [ "$ANS" = y ] || [ "$ANS" = Y ]; then
    adb reboot
    echo "Rebooting — ~90s. Verify afterwards: ping $GW, then ssh -p 2222 root@$GW"
  fi
fi
