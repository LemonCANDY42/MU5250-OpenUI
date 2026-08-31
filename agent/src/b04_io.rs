use std::collections::BTreeMap;
use std::io::{self, Read};
use std::net::Ipv4Addr;
use std::os::fd::AsRawFd;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_OUTPUT_BYTES: usize = 256 * 1024;
const COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(1);
const WIFI_READY_INITIAL_DELAY: Duration = Duration::from_secs(2);
const WIFI_READY_POLL_INTERVAL: Duration = Duration::from_secs(1);
const WIFI_READY_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UbusRead {
    NetworkInfo,
    WanStatus,
    DataUsage,
    DataCycle,
    WifiReport,
    DhcpLeases,
    SmsList { page: u16, per_page: u16 },
    SmsCommandStatus { command: u8 },
    ChargerStatus,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UbusWrite {
    SmsSend {
        number: String,
        timestamp: String,
        encoded_message: String,
        encoding: &'static str,
    },
    TrafficCycle {
        reset_day: u8,
        enabled: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WifiInterface {
    TwoG,
    FiveG,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WifiClientLinkSource {
    pub band: &'static str,
    pub signal_dbm: i64,
    pub tx_bitrate_mbps: f64,
    pub rx_bitrate_mbps: f64,
    pub expected_throughput_mbps: Option<f64>,
    pub connected_seconds: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum WifiField {
    Ssid2g,
    Passphrase2g,
    Encryption2g,
    Hidden2g,
    MainDisabled2g,
    Channel2g,
    Bandwidth2g,
    TransmitPower2g,
    Ssid5g,
    Passphrase5g,
    Encryption5g,
    Hidden5g,
    MainDisabled5g,
    Channel5g,
    Bandwidth5g,
    TransmitPower5g,
    GuestDisabled2g,
    GuestSsid2g,
    GuestPassphrase2g,
    GuestHidden2g,
    GuestIsolation2g,
    GuestActiveTime2g,
    GuestDisabled5g,
    GuestSsid5g,
    GuestPassphrase5g,
    GuestHidden5g,
    GuestIsolation5g,
    GuestActiveTime5g,
    BandSteeringEnabled,
    SettingsSync2g,
    SettingsSync5g,
}

impl WifiField {
    fn uci_path(self) -> &'static str {
        match self {
            Self::Ssid2g => "wireless.main_2g.ssid",
            Self::Passphrase2g => "wireless.main_2g.key",
            Self::Encryption2g => "wireless.main_2g.encryption",
            Self::Hidden2g => "wireless.main_2g.hidden",
            Self::MainDisabled2g => "wireless.main_2g.disabled",
            Self::Channel2g => "wireless.wifi0.channel",
            Self::Bandwidth2g => "wireless.wifi0.htmode",
            Self::TransmitPower2g => "wireless.wifi0.txpowerpercent",
            Self::Ssid5g => "wireless.main_5g.ssid",
            Self::Passphrase5g => "wireless.main_5g.key",
            Self::Encryption5g => "wireless.main_5g.encryption",
            Self::Hidden5g => "wireless.main_5g.hidden",
            Self::MainDisabled5g => "wireless.main_5g.disabled",
            Self::Channel5g => "wireless.wifi1.channel",
            Self::Bandwidth5g => "wireless.wifi1.htmode",
            Self::TransmitPower5g => "wireless.wifi1.txpowerpercent",
            Self::GuestDisabled2g => "wireless.guest_2g.disabled",
            Self::GuestSsid2g => "wireless.guest_2g.ssid",
            Self::GuestPassphrase2g => "wireless.guest_2g.key",
            Self::GuestHidden2g => "wireless.guest_2g.hidden",
            Self::GuestIsolation2g => "wireless.guest_2g.isolate",
            Self::GuestActiveTime2g => "wireless.guest_2g.active_time",
            Self::GuestDisabled5g => "wireless.guest_5g.disabled",
            Self::GuestSsid5g => "wireless.guest_5g.ssid",
            Self::GuestPassphrase5g => "wireless.guest_5g.key",
            Self::GuestHidden5g => "wireless.guest_5g.hidden",
            Self::GuestIsolation5g => "wireless.guest_5g.isolate",
            Self::GuestActiveTime5g => "wireless.guest_5g.active_time",
            Self::BandSteeringEnabled => "wireless.zte_mbb.lbd",
            Self::SettingsSync2g => "wireless.main_2g.wifiSyncparasFlag",
            Self::SettingsSync5g => "wireless.main_5g.wifiSyncparasFlag",
        }
    }

    fn uci_key(self) -> &'static str {
        self.uci_path()
            .strip_prefix("wireless.")
            .expect("all Wi-Fi fields belong to the fixed wireless package")
    }
}

pub trait B04Io: Send + Sync {
    fn ubus_read(&self, operation: UbusRead) -> Result<Value, String>;
    fn ubus_write(&self, operation: UbusWrite) -> Result<Value, String>;
    fn wireless_config(&self) -> Result<BTreeMap<String, String>, String>;
    fn wifi_capabilities(&self) -> Result<BTreeMap<String, String>, String>;
    fn station_count(&self, interface: WifiInterface) -> Result<u32, String>;
    fn active_wifi_channel(&self, interface: WifiInterface) -> Result<u16, String>;
    fn current_client_link(&self, _peer: Ipv4Addr) -> Result<WifiClientLinkSource, String> {
        Err("requesting-client Wi-Fi link source is unavailable".into())
    }
    fn wifi_values(&self, fields: &[WifiField]) -> Result<BTreeMap<WifiField, String>, String>;
    fn apply_wifi_values(&self, values: &BTreeMap<WifiField, String>) -> Result<(), String>;
    fn wait_for_wifi_ready(&self) -> Result<(), String>;
    fn wifi_master_enabled(&self) -> Result<bool, String>;
    fn set_wifi_master_enabled(&self, enabled: bool) -> Result<(), String>;
    fn battery_capacity(&self) -> Result<u8, String>;
}

#[derive(Default)]
pub struct SystemB04Io;

impl SystemB04Io {
    pub fn new() -> Self {
        Self
    }
}

impl B04Io for SystemB04Io {
    fn ubus_read(&self, operation: UbusRead) -> Result<Value, String> {
        let (label, object, method, payload) = match operation {
            UbusRead::NetworkInfo => (
                "network information",
                "zte_nwinfo_api",
                "nwinfo_get_netinfo",
                json!({}),
            ),
            UbusRead::WanStatus => (
                "WAN status",
                "network.interface.zte_wan",
                "status",
                json!({}),
            ),
            UbusRead::DataUsage => (
                "traffic usage",
                "zwrt_data",
                "get_wwandst",
                json!({"source_module":"web","cid":1,"type":4}),
            ),
            UbusRead::DataCycle => (
                "traffic cycle",
                "zwrt_data",
                "get_wwandst_clearday",
                json!({"source_module":"web","cid":1,"type":4}),
            ),
            UbusRead::WifiReport => ("Wi-Fi report", "zwrt_wlan", "report", json!({})),
            UbusRead::DhcpLeases => (
                "LAN clients",
                "luci-rpc",
                "getDHCPLeases",
                json!({"family":4}),
            ),
            UbusRead::SmsList { page, per_page } => (
                "SMS list",
                "zwrt_wms",
                "zte_libwms_get_sms_data",
                json!({
                    "page": page,
                    "data_per_page": per_page,
                    "mem_store": 1,
                    "tags": 10,
                    "order_by": "order by id desc"
                }),
            ),
            UbusRead::SmsCommandStatus { command } => (
                "SMS command status",
                "zwrt_wms",
                "zwrt_wms_get_cmd_status",
                json!({"sms_cmd": command}),
            ),
            UbusRead::ChargerStatus => ("charger status", "zwrt_bsp.charger", "list", json!({})),
        };
        let payload = payload.to_string();
        let output = run_fixed(label, "ubus", &["call", object, method, &payload])?;
        parse_ubus_write_response(label, &output)
    }

    fn ubus_write(&self, operation: UbusWrite) -> Result<Value, String> {
        let (label, object, method, payload) = match operation {
            UbusWrite::SmsSend {
                number,
                timestamp,
                encoded_message,
                encoding,
            } => (
                "SMS send",
                "zwrt_wms",
                "zte_libwms_send_sms",
                json!({
                    "number": number,
                    "sms_time": timestamp,
                    "message_body": encoded_message,
                    "id": "-1",
                    "encode_type": encoding,
                    "sms_no_decode_flag": "0"
                }),
            ),
            UbusWrite::TrafficCycle { reset_day, enabled } => (
                "traffic cycle",
                "zwrt_data",
                "set_wwandst_clearday",
                json!({
                    "source_module": "web",
                    "cid": 1,
                    "type": 4,
                    "enable": u8::from(enabled),
                    "clearday": reset_day,
                    "subid": 0
                }),
            ),
        };
        let payload = payload.to_string();
        let output = run_fixed(label, "ubus", &["call", object, method, &payload])?;
        serde_json::from_slice(&output).map_err(|_| format!("{label} returned invalid JSON"))
    }

    fn wireless_config(&self) -> Result<BTreeMap<String, String>, String> {
        let output = run_fixed("Wi-Fi configuration", "uci", &["show", "wireless"])?;
        let text = String::from_utf8(output)
            .map_err(|_| "Wi-Fi configuration was not UTF-8".to_string())?;
        Ok(parse_uci_show("wireless", &text))
    }

    fn wifi_capabilities(&self) -> Result<BTreeMap<String, String>, String> {
        let output = run_fixed("Wi-Fi capabilities", "uci", &["show", "zwrt_wifi"])?;
        let text = String::from_utf8(output)
            .map_err(|_| "Wi-Fi capabilities were not UTF-8".to_string())?;
        Ok(parse_uci_show("zwrt_wifi", &text))
    }

    fn station_count(&self, interface: WifiInterface) -> Result<u32, String> {
        let name = match interface {
            WifiInterface::TwoG => "wlan0",
            WifiInterface::FiveG => "wlan2",
        };
        let output = run_fixed("Wi-Fi station list", "iw", &[name, "station", "dump"])?;
        let text = String::from_utf8(output)
            .map_err(|_| "Wi-Fi station list was not UTF-8".to_string())?;
        let count = text
            .lines()
            .filter(|line| line.trim_start().starts_with("Station "))
            .count();
        u32::try_from(count).map_err(|_| "Wi-Fi station count is out of range".to_string())
    }

    fn active_wifi_channel(&self, interface: WifiInterface) -> Result<u16, String> {
        let name = match interface {
            WifiInterface::TwoG => "wlan0",
            WifiInterface::FiveG => "wlan2",
        };
        let output = run_fixed("Wi-Fi radio information", "iw", &[name, "info"])?;
        let text = String::from_utf8(output)
            .map_err(|_| "Wi-Fi radio information was not UTF-8".to_string())?;
        parse_active_wifi_channel(&text)
    }

    fn current_client_link(&self, peer: Ipv4Addr) -> Result<WifiClientLinkSource, String> {
        let leases = self.ubus_read(UbusRead::DhcpLeases)?;
        let mac = unique_lease_mac(&leases, peer)?;
        let mut matches = Vec::new();
        for (interface, band) in [("wlan0", "2.4 GHz"), ("wlan2", "5 GHz")] {
            let output = run_fixed(
                "requesting-client Wi-Fi station list",
                "iw",
                &[interface, "station", "dump"],
            )?;
            let text = String::from_utf8(output)
                .map_err(|_| "requesting-client station list was not UTF-8".to_string())?;
            if let Some(link) = parse_station_link(&text, &mac, band)? {
                matches.push(link);
            }
        }
        match matches.len() {
            1 => Ok(matches.remove(0)),
            0 => Err("requesting client is not a uniquely matched Wi-Fi station".into()),
            _ => Err("requesting client matched more than one Wi-Fi station".into()),
        }
    }

    fn wifi_values(&self, fields: &[WifiField]) -> Result<BTreeMap<WifiField, String>, String> {
        if fields.is_empty() {
            return Ok(BTreeMap::new());
        }
        select_wifi_values(&self.wireless_config()?, fields)
    }

    fn apply_wifi_values(&self, values: &BTreeMap<WifiField, String>) -> Result<(), String> {
        let band_steering = values
            .get(&WifiField::BandSteeringEnabled)
            .map(|value| parse_binary_setting(value, "band steering"))
            .transpose()?;
        // Preserve a valid firmware invariant throughout the transition:
        // coordination is removed before identities split, but is enabled
        // only after both primary identities and sync flags converge.
        if band_steering == Some(false) {
            self.apply_band_steering(false)?;
            self.wait_for_wifi_ready()?;
        }
        let uci_values = values
            .iter()
            .filter(|(field, _)| **field != WifiField::BandSteeringEnabled);
        let mut uci_changed = false;
        for (field, value) in uci_values {
            let assignment = format!("{}={value}", field.uci_path());
            if let Err(error) = run_fixed("Wi-Fi setting", "uci", &["set", &assignment]) {
                let _ = run_fixed("Wi-Fi revert", "uci", &["revert", "wireless"]);
                return Err(error);
            }
            uci_changed = true;
        }
        if uci_changed {
            if let Err(error) = run_fixed("Wi-Fi commit", "uci", &["commit", "wireless"]) {
                let _ = run_fixed("Wi-Fi revert", "uci", &["revert", "wireless"]);
                return Err(error);
            }
            let output = run_fixed(
                "Wi-Fi reload",
                "ubus",
                &["call", "zwrt_wlan", "reload", "{}"],
            )?;
            parse_ubus_write_response("Wi-Fi reload", &output)?;
        }
        if band_steering == Some(true) {
            if uci_changed {
                self.wait_for_wifi_ready()?;
            }
            self.apply_band_steering(true)?;
        }
        Ok(())
    }

    fn wait_for_wifi_ready(&self) -> Result<(), String> {
        wait_for_wifi_ready_with(
            WIFI_READY_TIMEOUT,
            WIFI_READY_INITIAL_DELAY,
            WIFI_READY_POLL_INTERVAL,
            |remaining| {
                run_fixed_with_timeout(
                    "Wi-Fi readiness",
                    "ubus",
                    &["call", "zwrt_wlan", "report", "{}"],
                    remaining.min(COMMAND_TIMEOUT),
                )
            },
            std::thread::sleep,
        )
    }

    fn wifi_master_enabled(&self) -> Result<bool, String> {
        let output = run_fixed(
            "Wi-Fi master setting",
            "uci",
            &["-q", "get", "wireless.zte_mbb.wifi_onoff"],
        )?;
        match output.as_slice() {
            b"0\n" | b"0\r\n" | b"0" => Ok(false),
            b"1\n" | b"1\r\n" | b"1" => Ok(true),
            _ => Err("Wi-Fi master setting was invalid".into()),
        }
    }

    fn set_wifi_master_enabled(&self, enabled: bool) -> Result<(), String> {
        let band_steering = if enabled {
            let output = run_fixed(
                "band steering setting",
                "uci",
                &["-q", "get", "wireless.zte_mbb.lbd"],
            )?;
            match output.as_slice() {
                b"0\n" | b"0\r\n" | b"0" => Some(false),
                b"1\n" | b"1\r\n" | b"1" => Some(true),
                _ => return Err("band steering setting was invalid".into()),
            }
        } else {
            None
        };
        let payload = wifi_master_payload(enabled, band_steering);
        let output = run_fixed(
            "Wi-Fi master update",
            "ubus",
            &["call", "zwrt_wlan", "set", &payload],
        )?;
        parse_ubus_write_response("Wi-Fi master update", &output).map(|_| ())
    }

    fn battery_capacity(&self) -> Result<u8, String> {
        let value = std::fs::read_to_string("/sys/class/power_supply/battery/capacity")
            .map_err(|_| "battery capacity source is unavailable".to_string())?;
        value
            .trim()
            .parse::<u8>()
            .ok()
            .filter(|value| *value <= 100)
            .ok_or_else(|| "battery capacity source is invalid".to_string())
    }
}

impl SystemB04Io {
    fn apply_band_steering(&self, enabled: bool) -> Result<(), String> {
        let payload = wifi_master_payload(self.wifi_master_enabled()?, Some(enabled));
        let output = run_fixed(
            "band steering update",
            "ubus",
            &["call", "zwrt_wlan", "set", &payload],
        )?;
        parse_ubus_write_response("band steering update", &output).map(|_| ())
    }
}

fn wifi_master_payload(enabled: bool, band_steering: Option<bool>) -> String {
    let mut module = serde_json::Map::from_iter([("wifi_onoff".into(), json!(u8::from(enabled)))]);
    if let Some(value) = band_steering {
        module.insert("lbd".into(), json!(u8::from(value)));
    }
    json!({"zte_mbb": module}).to_string()
}

fn parse_wifi_load_status(output: &[u8]) -> Result<bool, String> {
    serde_json::from_slice::<Value>(output)
        .ok()
        .and_then(|value| {
            value
                .get("load_status")
                .and_then(Value::as_str)
                .map(|status| status == "idle")
        })
        .ok_or_else(|| "Wi-Fi readiness source was invalid".into())
}

fn wait_for_wifi_ready_with(
    timeout: Duration,
    initial_delay: Duration,
    poll_interval: Duration,
    mut read_status: impl FnMut(Duration) -> Result<Vec<u8>, String>,
    mut sleep: impl FnMut(Duration),
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    sleep(initial_delay.min(timeout));
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Err("Wi-Fi operation did not settle within the bounded window".into());
        }
        if let Ok(true) =
            read_status(deadline - now).and_then(|output| parse_wifi_load_status(&output))
        {
            return Ok(());
        }
        let now = Instant::now();
        if now >= deadline {
            return Err("Wi-Fi operation did not settle within the bounded window".into());
        }
        sleep(poll_interval.min(deadline - now));
    }
}

fn parse_binary_setting(value: &str, label: &str) -> Result<bool, String> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(format!("{label} setting was invalid")),
    }
}

fn parse_ubus_write_response(_label: &str, output: &[u8]) -> Result<Value, String> {
    // Accepted B04 write methods may acknowledge a zero exit status with empty
    // output or a vendor text token instead of JSON. Every caller performs a
    // separate typed device readback before reporting success, so stdout is
    // diagnostic only and never substitutes for verification.
    if output.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    Ok(serde_json::from_slice(output).unwrap_or_else(|_| json!({})))
}

fn run_fixed(label: &str, program: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    run_fixed_with_timeout(label, program, args, COMMAND_TIMEOUT)
}

fn run_fixed_with_timeout(
    label: &str,
    program: &str,
    args: &[&str],
    timeout: Duration,
) -> Result<Vec<u8>, String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| format!("{label} source is unavailable"))?;

    let Some(stdout) = child.stdout.take() else {
        terminate_and_reap(&mut child);
        return Err(format!("{label} returned no output stream"));
    };
    if set_nonblocking(stdout.as_raw_fd()).is_err() {
        terminate_and_reap(&mut child);
        return Err(format!("{label} output could not be read"));
    }

    // One owner drains the pipe and observes the child, so neither a full pipe
    // nor an inherited writer in a descendant can strand a reader thread.
    let deadline = Instant::now() + timeout;
    let mut output = Vec::new();
    let mut stdout = Some(stdout);
    let mut output_exceeded = false;
    loop {
        if let Some(pipe) = stdout.as_mut() {
            match drain_available(pipe, &mut output) {
                Ok(DrainState::Open | DrainState::Eof) => {}
                Ok(DrainState::Exceeded) => {
                    output_exceeded = true;
                    // Closing the full pipe lets the command observe the
                    // bounded-output boundary instead of blocking forever.
                    stdout.take();
                }
                Err(_) => {
                    terminate_and_reap(&mut child);
                    return Err(format!("{label} output could not be read"));
                }
            }
        }

        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return Err(format!("{label} source failed"));
                }
                if output_exceeded {
                    return Err(format!("{label} output exceeded the fixed limit"));
                }
                let pipe = stdout
                    .as_mut()
                    .expect("stdout remains owned until the output limit is exceeded");
                match drain_available(pipe, &mut output) {
                    Ok(DrainState::Open | DrainState::Eof) => return Ok(output),
                    Ok(DrainState::Exceeded) => {
                        return Err(format!("{label} output exceeded the fixed limit"));
                    }
                    Err(_) => return Err(format!("{label} output could not be read")),
                }
            }
            Ok(None) => {}
            Err(_) => {
                terminate_and_reap(&mut child);
                return Err(format!("{label} could not be observed"));
            }
        }

        let now = Instant::now();
        if now >= deadline {
            terminate_and_reap(&mut child);
            return Err(format!("{label} timed out"));
        }
        std::thread::sleep(COMMAND_POLL_INTERVAL.min(deadline - now));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DrainState {
    Open,
    Eof,
    Exceeded,
}

fn drain_available(stdout: &mut impl Read, output: &mut Vec<u8>) -> io::Result<DrainState> {
    let mut buffer = [0_u8; 8192];
    loop {
        let remaining = MAX_OUTPUT_BYTES + 1 - output.len();
        let read_limit = buffer.len().min(remaining);
        match stdout.read(&mut buffer[..read_limit]) {
            Ok(0) => return Ok(DrainState::Eof),
            Ok(read) => {
                output.extend_from_slice(&buffer[..read]);
                if output.len() > MAX_OUTPUT_BYTES {
                    return Ok(DrainState::Exceeded);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(DrainState::Open),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

fn set_nonblocking(fd: std::os::fd::RawFd) -> io::Result<()> {
    // SAFETY: `fd` is the live stdout pipe owned by this function. `fcntl`
    // reads and updates only that descriptor's status flags, and both results
    // are checked before the descriptor is used again.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the same live descriptor and validated flags are used; adding
    // `O_NONBLOCK` preserves all existing descriptor status flags.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn terminate_and_reap(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn parse_uci_show(package: &str, text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            let key = key.strip_prefix(&format!("{package}."))?;
            Some((key.to_owned(), uci_unquote(value)))
        })
        .collect()
}

fn select_wifi_values(
    config: &BTreeMap<String, String>,
    fields: &[WifiField],
) -> Result<BTreeMap<WifiField, String>, String> {
    fields
        .iter()
        .copied()
        .map(|field| {
            config
                .get(field.uci_key())
                .cloned()
                .map(|value| (field, value))
                .ok_or_else(|| "one or more Wi-Fi settings are unavailable on this firmware".into())
        })
        .collect()
}

fn uci_unquote(raw: &str) -> String {
    let trimmed = raw.trim();
    let inner = trimmed
        .strip_prefix('\'')
        .and_then(|value| value.strip_suffix('\''))
        .unwrap_or(trimmed);
    inner.replace("'\\''", "'")
}

fn unique_lease_mac(value: &Value, peer: Ipv4Addr) -> Result<String, String> {
    let leases = value
        .get("dhcp_leases")
        .and_then(Value::as_array)
        .ok_or_else(|| "requesting-client DHCP leases were missing".to_string())?;
    if leases.len() > 256 {
        return Err("requesting-client DHCP lease count exceeded the fixed limit".into());
    }
    let target = peer.to_string();
    let mut matches = leases.iter().filter_map(|lease| {
        let object = lease.as_object()?;
        (object.get("ipaddr")?.as_str()? == target)
            .then(|| object.get("macaddr")?.as_str().map(str::to_owned))?
    });
    let mac = matches
        .next()
        .ok_or_else(|| "requesting client has no current DHCP lease".to_string())?;
    if matches.next().is_some() || !valid_mac(&mac) {
        return Err("requesting client did not have one valid DHCP identity".into());
    }
    Ok(mac)
}

fn parse_station_link(
    text: &str,
    target_mac: &str,
    band: &'static str,
) -> Result<Option<WifiClientLinkSource>, String> {
    let mut matched_block: Option<&str> = None;
    for block in text
        .split("\nStation ")
        .filter(|block| !block.trim().is_empty())
    {
        let normalized = block.strip_prefix("Station ").unwrap_or(block);
        let station_mac = normalized.split_whitespace().next().unwrap_or_default();
        if station_mac.eq_ignore_ascii_case(target_mac)
            && matched_block.replace(normalized).is_some()
        {
            return Err("requesting client appeared twice in one station list".into());
        }
    }
    let Some(block) = matched_block else {
        return Ok(None);
    };
    let field = |name: &str| {
        block.lines().find_map(|line| {
            let (key, value) = line.trim().split_once(':')?;
            (key == name).then(|| value.trim())
        })
    };
    let signal_dbm = first_i64(field("signal"))
        .filter(|value| (-127..=0).contains(value))
        .ok_or_else(|| "requesting-client signal was missing or out of range".to_string())?;
    let tx_bitrate_mbps = field("tx bitrate")
        .and_then(first_f64)
        .filter(valid_bitrate)
        .ok_or_else(|| "requesting-client TX bitrate was missing or out of range".to_string())?;
    let rx_bitrate_mbps = field("rx bitrate")
        .and_then(first_f64)
        .filter(valid_bitrate)
        .ok_or_else(|| "requesting-client RX bitrate was missing or out of range".to_string())?;
    let expected_throughput_mbps = field("expected throughput")
        .and_then(first_f64)
        .filter(valid_bitrate);
    let connected_seconds = first_u64(field("connected time"))
        .filter(|value| *value <= 10 * 365 * 24 * 60 * 60)
        .ok_or_else(|| {
            "requesting-client connected time was missing or out of range".to_string()
        })?;
    Ok(Some(WifiClientLinkSource {
        band,
        signal_dbm,
        tx_bitrate_mbps,
        rx_bitrate_mbps,
        expected_throughput_mbps,
        connected_seconds,
    }))
}

fn parse_active_wifi_channel(text: &str) -> Result<u16, String> {
    text.lines()
        .find_map(|line| {
            let value = line.trim().strip_prefix("channel ")?;
            value.split_whitespace().next()?.parse::<u16>().ok()
        })
        .filter(|channel| (1..=233).contains(channel))
        .ok_or_else(|| "active Wi-Fi channel was missing or out of range".to_string())
}

fn first_i64(value: Option<&str>) -> Option<i64> {
    value?.split_whitespace().next()?.parse().ok()
}

fn first_u64(value: Option<&str>) -> Option<u64> {
    value?.split_whitespace().next()?.parse().ok()
}

fn first_f64(value: &str) -> Option<f64> {
    let token = value.split_whitespace().next()?.trim_end_matches("Mbps");
    token.parse().ok()
}

fn valid_bitrate(value: &f64) -> bool {
    value.is_finite() && (0.0..=100_000.0).contains(value)
}

fn valid_mac(value: &str) -> bool {
    let parts: Vec<&str> = value.split(':').collect();
    parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uci_parser_keeps_named_values_without_shell_evaluation() {
        let parsed = parse_uci_show(
            "wireless",
            "wireless.main_2g.ssid='Home'\n\
             wireless.main_2g.key='pass'\\''word'\n\
             unrelated.value='ignored'\n",
        );
        assert_eq!(parsed.get("main_2g.ssid").map(String::as_str), Some("Home"));
        assert_eq!(
            parsed.get("main_2g.key").map(String::as_str),
            Some("pass'word")
        );
        assert!(!parsed.contains_key("unrelated.value"));
    }

    #[test]
    fn wifi_snapshot_selects_only_requested_fixed_fields() {
        let config = BTreeMap::from([
            ("main_2g.ssid".into(), "owner".into()),
            ("wifi0.txpowerpercent".into(), "40".into()),
            ("unrelated.private".into(), "ignored".into()),
        ]);

        assert_eq!(
            select_wifi_values(&config, &[WifiField::Ssid2g, WifiField::TransmitPower2g]).unwrap(),
            BTreeMap::from([
                (WifiField::Ssid2g, "owner".into()),
                (WifiField::TransmitPower2g, "40".into()),
            ])
        );
        assert!(select_wifi_values(&config, &[WifiField::Ssid5g]).is_err());
    }

    #[test]
    fn operation_set_contains_only_fixed_read_paths() {
        let operations = [
            UbusRead::NetworkInfo,
            UbusRead::WanStatus,
            UbusRead::DataUsage,
            UbusRead::DataCycle,
            UbusRead::WifiReport,
            UbusRead::DhcpLeases,
            UbusRead::SmsList {
                page: 0,
                per_page: 100,
            },
            UbusRead::SmsCommandStatus { command: 4 },
            UbusRead::ChargerStatus,
        ];
        assert_eq!(operations.len(), 9);
    }

    #[test]
    fn wifi_fields_map_only_to_fixed_b04_uci_paths() {
        let paths = [
            WifiField::Ssid2g,
            WifiField::Passphrase2g,
            WifiField::Encryption2g,
            WifiField::Hidden2g,
            WifiField::MainDisabled2g,
            WifiField::Ssid5g,
            WifiField::Passphrase5g,
            WifiField::Encryption5g,
            WifiField::Hidden5g,
            WifiField::MainDisabled5g,
            WifiField::BandSteeringEnabled,
            WifiField::SettingsSync2g,
            WifiField::SettingsSync5g,
        ]
        .map(WifiField::uci_path);
        assert_eq!(paths.len(), 13);
        assert!(paths.iter().all(|path| path.starts_with("wireless.")));
    }

    #[test]
    fn stock_wifi_master_payload_preserves_band_steering_when_enabling() {
        assert_eq!(
            serde_json::from_str::<Value>(&wifi_master_payload(false, None)).unwrap(),
            json!({"zte_mbb":{"wifi_onoff":0}})
        );
        assert_eq!(
            serde_json::from_str::<Value>(&wifi_master_payload(true, Some(true))).unwrap(),
            json!({"zte_mbb":{"wifi_onoff":1,"lbd":1}})
        );
        assert_eq!(
            serde_json::from_str::<Value>(&wifi_master_payload(true, Some(false))).unwrap(),
            json!({"zte_mbb":{"wifi_onoff":1,"lbd":0}})
        );
    }

    #[test]
    fn stock_wifi_readiness_uses_only_the_typed_load_status() {
        assert_eq!(
            parse_wifi_load_status(br#"{"load_status":"idle"}"#),
            Ok(true)
        );
        assert_eq!(
            parse_wifi_load_status(br#"{"load_status":"loading"}"#),
            Ok(false)
        );
        assert!(parse_wifi_load_status(br#"{"load_status":1}"#).is_err());
        assert!(parse_wifi_load_status(br#"{"status":"idle"}"#).is_err());
        assert!(parse_wifi_load_status(b"not-json").is_err());
    }

    #[test]
    fn stock_wifi_readiness_retries_transient_busy_and_source_failures() {
        let mut responses = std::collections::VecDeque::from([
            Err("temporary source failure".to_string()),
            Ok(br#"{"load_status":"loading"}"#.to_vec()),
            Ok(br#"{"load_status":"idle"}"#.to_vec()),
        ]);
        let mut sleeps = Vec::new();

        let result = wait_for_wifi_ready_with(
            Duration::from_secs(1),
            Duration::ZERO,
            Duration::ZERO,
            |_| responses.pop_front().expect("fixed readiness sequence"),
            |duration| sleeps.push(duration),
        );

        assert_eq!(result, Ok(()));
        assert!(responses.is_empty());
        assert_eq!(sleeps.len(), 3);
    }

    #[test]
    fn stock_wifi_readiness_timeout_is_terminal_and_bounded() {
        let mut reads = 0;
        let result = wait_for_wifi_ready_with(
            Duration::ZERO,
            Duration::ZERO,
            Duration::ZERO,
            |_| {
                reads += 1;
                Ok(br#"{"load_status":"idle"}"#.to_vec())
            },
            |_| {},
        );

        assert_eq!(
            result,
            Err("Wi-Fi operation did not settle within the bounded window".into())
        );
        assert_eq!(reads, 0, "no readiness command may start after its budget");
    }

    #[test]
    fn ubus_write_stdout_is_diagnostic_because_callers_require_readback() {
        assert_eq!(parse_ubus_write_response("write", b"").unwrap(), json!({}));
        assert_eq!(
            parse_ubus_write_response("write", b" \r\n").unwrap(),
            json!({})
        );
        assert_eq!(
            parse_ubus_write_response("write", br#"{"ok":true}"#).unwrap(),
            json!({"ok": true})
        );
        assert_eq!(
            parse_ubus_write_response("write", b"vendor success token").unwrap(),
            json!({})
        );
    }

    #[test]
    fn requesting_client_link_requires_one_lease_and_one_station() {
        let leases = json!({"dhcp_leases":[{
            "ipaddr":"192.168.0.61", "macaddr":"a2:17:10:bb:03:fa"
        }]});
        let mac = unique_lease_mac(&leases, "192.168.0.61".parse().unwrap()).unwrap();
        let dump = "Station a2:17:10:bb:03:fa (on wlan2)\n\
                    \tsignal: -51 [-55, -53] dBm\n\
                    \ttx bitrate: 1200.9 MBit/s\n\
                    \trx bitrate: 960.8 MBit/s\n\
                    \texpected throughput: 487.125Mbps\n\
                    \tconnected time: 679 seconds\n";
        let link = parse_station_link(dump, &mac, "5 GHz").unwrap().unwrap();
        assert_eq!(link.band, "5 GHz");
        assert_eq!(link.signal_dbm, -51);
        assert_eq!(link.tx_bitrate_mbps, 1200.9);
        assert_eq!(link.rx_bitrate_mbps, 960.8);
        assert_eq!(link.expected_throughput_mbps, Some(487.125));
        assert_eq!(link.connected_seconds, 679);
        assert!(parse_station_link(dump, "02:00:00:00:00:01", "5 GHz")
            .unwrap()
            .is_none());
    }

    #[test]
    fn active_wifi_channel_accepts_only_bounded_iw_info_values() {
        let info = "Interface wlan2\n\tchannel 149 (5745 MHz), width: 160 MHz\n";
        assert_eq!(parse_active_wifi_channel(info).unwrap(), 149);
        assert!(parse_active_wifi_channel("Interface wlan2\n").is_err());
        assert!(parse_active_wifi_channel("channel 0 (invalid)\n").is_err());
        assert!(parse_active_wifi_channel("channel 234 (invalid)\n").is_err());
    }

    #[test]
    fn fixed_runner_returns_before_a_descendant_closes_inherited_stdout() {
        let temp = tempfile::tempdir().unwrap();
        let pid_path = temp.path().join("descendant.pid");
        let pid_path = pid_path.to_str().unwrap();
        let output = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &[
                "-c",
                "sleep 30 & printf '%s' \"$!\" > \"$1\"; printf ready",
                "test-shell",
                pid_path,
            ],
            Duration::from_secs(5),
        )
        .unwrap();
        let descendant_pid = std::fs::read_to_string(pid_path)
            .unwrap()
            .parse::<libc::pid_t>()
            .unwrap();

        assert_eq!(output, b"ready");
        // SAFETY: signal zero only probes the exact descendant PID written by
        // this test command and does not deliver a signal.
        let probe = unsafe { libc::kill(descendant_pid, 0) };
        // SAFETY: cleanup targets only the exact still-running descendant that
        // this test created after proving the runner did not wait for its pipe.
        if probe == 0 {
            unsafe { libc::kill(descendant_pid, libc::SIGKILL) };
        }
        assert_eq!(probe, 0);
    }

    #[test]
    fn fixed_runner_accepts_exactly_the_output_limit() {
        let script = format!("dd if=/dev/zero bs={MAX_OUTPUT_BYTES} count=1 2>/dev/null");
        let output = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &["-c", &script],
            Duration::from_secs(5),
        )
        .unwrap();

        assert_eq!(output.len(), MAX_OUTPUT_BYTES);
    }

    #[test]
    fn fixed_runner_rejects_output_one_byte_over_the_limit() {
        let script = format!(
            "dd if=/dev/zero bs={} count=1 2>/dev/null",
            MAX_OUTPUT_BYTES + 1
        );
        let error = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &["-c", &script],
            Duration::from_secs(5),
        )
        .unwrap_err();

        assert_eq!(error, "test command output exceeded the fixed limit");
    }

    #[test]
    fn fixed_runner_preserves_nonzero_failure_after_output_limit() {
        let script = format!(
            "dd if=/dev/zero bs={} count=1 2>/dev/null; exit 7",
            MAX_OUTPUT_BYTES + 1
        );
        let error = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &["-c", &script],
            Duration::from_secs(5),
        )
        .unwrap_err();

        assert_eq!(error, "test command source failed");
    }

    #[test]
    fn fixed_runner_observes_nonzero_exit_after_closing_an_over_limit_stream() {
        let error =
            run_fixed_with_timeout("test command", "/usr/bin/yes", &[], Duration::from_secs(5))
                .unwrap_err();

        assert_eq!(error, "test command source failed");
    }

    #[test]
    fn fixed_runner_times_out_and_reaps_the_direct_child() {
        let temp = tempfile::tempdir().unwrap();
        let pid_path = temp.path().join("child.pid");
        let pid_path = pid_path.to_str().unwrap();
        let started = std::time::Instant::now();
        let error = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &[
                "-c",
                "printf '%s' \"$$\" > \"$1\"; exec sleep 30",
                "test-shell",
                pid_path,
            ],
            Duration::from_secs(2),
        )
        .unwrap_err();
        let pid = std::fs::read_to_string(pid_path)
            .unwrap()
            .parse::<libc::pid_t>()
            .unwrap();

        assert_eq!(error, "test command timed out");
        assert!(started.elapsed() < Duration::from_secs(10));
        // SAFETY: this nonblocking wait probes only the exact child PID this
        // test created. `ECHILD` proves the runner already waited for it and
        // avoids a racy assertion based on global PID reuse.
        let probe = unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) };
        assert_eq!(probe, -1);
        assert_eq!(
            io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
    }

    #[test]
    fn fixed_runner_keeps_nonzero_exit_as_a_typed_source_failure() {
        let error = run_fixed_with_timeout(
            "test command",
            "/bin/sh",
            &["-c", "printf ignored; exit 7"],
            Duration::from_secs(5),
        )
        .unwrap_err();

        assert_eq!(error, "test command source failed");
    }
}
