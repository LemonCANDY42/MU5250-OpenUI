#!/usr/bin/env bash
# emulate.sh - boot the ZTE U60 Pro (MU5250) firmware in QEMU and run the
# zte-agent + fakemodem payload inside it, for dashboard/agent testing.
#
# Usage:
#   bash scripts/emulate.sh           # build everything, boot VM, install payload
#   bash scripts/emulate.sh stop      # stop the VM
#   bash scripts/emulate.sh status    # check VM + agent reachability
#
# Layout (all under firmware/emulation/):
#   rootfs-a.img          QEMU-bootable copy of system_a.img (patched once)
#   openwrt-armsr-kernel.bin  OpenWrt 23.05.4 armsr kernel (virtio+builtin ext4)
#   payload.img           ext4 disk with agent, fakemodem, rpcd stubs
#   console.sock          guest serial console (use console.py)
#
# Host port forwards: 9090 agent, 9080->80 stock web UI, 9443->443, 2222->(unused)

set -euo pipefail
cd "$(dirname "$0")/.."
EMU=firmware/emulation
KERNEL=$EMU/openwrt-armsr-kernel.bin
ROOTFS=$EMU/rootfs-a.img
PAYLOAD=$EMU/payload.img
TARGET=aarch64-unknown-linux-musl

log() { echo -e "\033[0;36m[emu]\033[0m $*"; }

stop_vm() {
	pkill -f "qemu-system-aarch64.*rootfs-a" 2>/dev/null || true
	rm -f "$EMU/console.sock" "$EMU/monitor.sock"
}

build_payload() {
	log "building agent + fakemodem ($TARGET)"
	cargo build -q --release --target "$TARGET" -p zte-agent
	(cd "$EMU/fakemodem" && cargo build -q --release --target "$TARGET")

	cp "target/$TARGET/release/zte-agent" "$EMU/payload/root/"
	cp "$EMU/fakemodem/target/$TARGET/release/fakemodem" "$EMU/payload/root/"
	# Tracked emulator overlays. The firmware images and expanded payload tree
	# are intentionally gitignored, so test doubles must be copied from here.
	cp scripts/emulator-payload/install.sh "$EMU/payload/root/install.sh"
	mkdir -p "$EMU/payload/root/rpcd"
	cp scripts/emulator-payload/zte_agent_emu_wms "$EMU/payload/root/rpcd/zte_agent_emu_wms"
	chmod +x "$EMU/payload/root/"* 2>/dev/null || true
	# Optional full stock-UI asset tree pulled from a live device:
	#   tar czf - -C / usr/zte_web/web  →  unpack into firmware/emulation/payload/ztedata/
	[ -d "$EMU/ztedata" ] && { rm -rf "$EMU/payload/root/ztedata"; cp -R "$EMU/ztedata" "$EMU/payload/root/ztedata"; }

	log "rebuilding payload.img"
	rm -f "$PAYLOAD"
	dd if=/dev/zero of="$PAYLOAD" bs=1m count=32 2>/dev/null
	/opt/homebrew/opt/e2fsprogs/sbin/mke2fs -q -t ext4 -d "$EMU/payload/root" -L payload "$PAYLOAD"
}

boot_vm() {
	stop_vm
	log "booting VM (HVF accelerated, 1 GiB, 2 vCPU)"
	nohup qemu-system-aarch64 \
		-machine virt,accel=hvf -cpu host -m 1024 -smp 2 \
		-kernel "$KERNEL" \
		-append "root=/dev/vda rw rootwait console=ttyAMA0" \
		-drive file="$ROOTFS",format=raw,if=virtio \
		-drive file="$PAYLOAD",format=raw,if=virtio \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
		-netdev user,id=n1,hostfwd=tcp:127.0.0.1:9090-:9090,hostfwd=tcp:127.0.0.1:8080-:8080,hostfwd=tcp:127.0.0.1:9080-:80,hostfwd=tcp:127.0.0.1:9443-:443 \
		-device virtio-net-pci,netdev=n1 \
		-display none \
		-serial unix:"$EMU/console.sock",server=on,wait=off \
		-monitor unix:"$EMU/monitor.sock",server=on,wait=off \
		>"$EMU/qemu-stdout.log" 2>&1 &
	echo $! > "$EMU/qemu.pid"
	log "QEMU PID $(cat "$EMU/qemu.pid")"
}

wait_shell() {
	log "waiting for guest shell"
	local i
	for i in $(seq 1 24); do
		sleep 15
		if python3 "$EMU/console.py" run "" 3 2>/dev/null | grep -q 'root@'; then
			log "shell up after ~$((15 * i))s"
			return 0
		fi
	done
	log "WARNING: no shell prompt yet (boot still in progress)"
	return 0
}

wait_agent() {
	log "waiting for agent API on 127.0.0.1:9090"
	for _ in $(seq 1 12); do
		if curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9090/api/auth/login \
			-H 'Content-Type: application/json' -d '{"password":"emu-test-password"}' 2>/dev/null | grep -q 200; then
			log "agent API is UP"
			return 0
		fi
		sleep 10
	done
	log "WARNING: agent not reachable yet - check /tmp/emu-payload.log in guest"
	return 1
}

case "${1:-start}" in
stop)
	stop_vm; log "stopped" ;;
status)
	pgrep -f "qemu-system-aarch64.*rootfs-a" >/dev/null && log "VM running (PID $(pgrep -f 'qemu-system-aarch64.*rootfs-a'))" || log "VM not running"
	curl -s -m 3 http://127.0.0.1:9090/api/health 2>/dev/null || true
	echo ;;
start|*)
	build_payload
	boot_vm
	wait_shell
	log "payload auto-installs via /etc/rc.d/S99emu-payload (needs ~1-2 min of boot)"
	wait_agent
	cat <<'EOF'

  Emulated U60 Pro is up:
    agent API     http://127.0.0.1:9090  (password: emu-test-password)
    stock web UI  http://127.0.0.1:9080  (https: 9443)
    dashboard     cd web-app && npm run dev   (proxy to 127.0.0.1:9090)
    serial shell  cd firmware/emulation && python3 console.py run "<cmd>"

EOF
	;;
esac
