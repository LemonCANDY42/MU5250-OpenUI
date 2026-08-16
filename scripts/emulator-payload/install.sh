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
ip addr show eth1 | grep 'inet '

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
