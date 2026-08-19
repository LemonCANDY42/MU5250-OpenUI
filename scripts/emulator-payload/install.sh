#!/bin/sh
# Emulation payload installer - mirrors the real device deploy layout.
set -x
mkdir -p /data/local/tmp
cp /payload/zte-agent /data/zte-agent
cp /payload/fakemodem /data/local/tmp/fakemodem
chmod +x /data/zte-agent /data/local/tmp/fakemodem

killall fakemodem 2>/dev/null
nohup /data/local/tmp/fakemodem >/tmp/fakemodem.log 2>&1 &
sleep 1

# Management network on eth1 (QEMU hostfwd NIC).
udhcpc -i eth1 -q -n 2>/dev/null
# Give the guest its real-device address as a secondary address.  QEMU's
# explicit guest-address forwards can then continue reaching the agent after
# the production installer replaces its startup script and restores the safe
# 192.168.0.1-only bind.
ip addr add 192.168.0.1/32 dev eth1 2>/dev/null || true
ip addr show eth1 | grep 'inet '

# Expose a key-only SSH management channel matching a hardened modem.  The
# package and public key are staged by scripts/emulate.sh; all changes remain
# inside the disposable QEMU rootfs.
if [ -f /payload/dropbear.ipk ] && [ -f /payload/installer_authorized_key ]; then
	mkdir -p /data/bin /data/dropbear /etc/dropbear /tmp/emu-dropbear
	chmod 700 /etc/dropbear
	if (
		set -e
		cd /tmp/emu-dropbear || exit 1
		tar xzf /payload/dropbear.ipk ./data.tar.gz
		tar xzf data.tar.gz ./usr/sbin/dropbear ./usr/bin/dbclient ./usr/bin/dropbearkey
		cp usr/sbin/dropbear usr/bin/dbclient usr/bin/dropbearkey /data/bin/
	); then
		chmod +x /data/bin/dropbear /data/bin/dbclient /data/bin/dropbearkey
		cp /payload/installer_authorized_key /etc/dropbear/authorized_keys
		chmod 600 /etc/dropbear/authorized_keys
		for k in ed25519 rsa; do
			key=/etc/dropbear/dropbear_${k}_host_key
			[ -s "$key" ] || /data/bin/dropbearkey -t "$k" -f "$key" >/dev/null 2>&1
		done
		cp /etc/dropbear/authorized_keys /etc/dropbear/dropbear_*_host_key /data/dropbear/
		chmod 600 /data/dropbear/*
		killall dropbear 2>/dev/null
		/data/bin/dropbear -p 2222 \
			-r /etc/dropbear/dropbear_ed25519_host_key \
			-r /etc/dropbear/dropbear_rsa_host_key
	else
		echo "ERROR: could not extract the emulated Dropbear package" >&2
	fi
fi

cat > /data/local/tmp/start_zte_agent.sh <<'EOS'
#!/bin/sh
export ZTE_AGENT_PASSWORD='emu-test-password'
export ZTE_AGENT_BIND='0.0.0.0:9090'
export ZTE_AGENT_WMS_OBJECT='zte_agent_emu_wms'
nohup sh -c '/data/zte-agent 2>&1 | logger -t zte-agent' >/dev/null 2>&1 </dev/null &
EOS
chmod +x /data/local/tmp/start_zte_agent.sh
killall zte-agent 2>/dev/null
sleep 1
sh /data/local/tmp/start_zte_agent.sh

# Objects whose stock daemons need physical modem/thermal hardware.
if [ -d /payload/rpcd ]; then
	mkdir -p /data/emu
	cp /payload/netinfo.json /data/emu/ 2>/dev/null
	cp /payload/rpcd/* /usr/libexec/rpcd/
	chmod +x /usr/libexec/rpcd/zte_nwinfo_api /usr/libexec/rpcd/zwrt_bsp.thermal /usr/libexec/rpcd/zte_agent_emu_wms
	/etc/init.d/rpcd restart
fi

if [ -d /payload/webui ]; then
	cp -R /payload/webui/. /usr/zte_web/web/
fi
if [ -d /payload/ztedata ]; then
	cp -R /payload/ztedata/. /usr/zte_web/web/
fi
echo "PAYLOAD INSTALLED"
