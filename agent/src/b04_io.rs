use std::collections::BTreeMap;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use wait_timeout::ChildExt;

const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_OUTPUT_BYTES: usize = 256 * 1024;

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
    ChargePaused(bool),
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum WifiField {
    Ssid2g,
    Passphrase2g,
    Hidden2g,
    Channel2g,
    Bandwidth2g,
    TransmitPower2g,
    Ssid5g,
    Passphrase5g,
    Hidden5g,
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
}

impl WifiField {
    fn uci_path(self) -> &'static str {
        match self {
            Self::Ssid2g => "wireless.main_2g.ssid",
            Self::Passphrase2g => "wireless.main_2g.key",
            Self::Hidden2g => "wireless.main_2g.hidden",
            Self::Channel2g => "wireless.wifi0.channel",
            Self::Bandwidth2g => "wireless.wifi0.htmode",
            Self::TransmitPower2g => "wireless.wifi0.txpowerpercent",
            Self::Ssid5g => "wireless.main_5g.ssid",
            Self::Passphrase5g => "wireless.main_5g.key",
            Self::Hidden5g => "wireless.main_5g.hidden",
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
        }
    }
}

pub trait B04Io: Send + Sync {
    fn ubus_read(&self, operation: UbusRead) -> Result<Value, String>;
    fn ubus_write(&self, operation: UbusWrite) -> Result<Value, String>;
    fn wireless_config(&self) -> Result<BTreeMap<String, String>, String>;
    fn station_count(&self, interface: WifiInterface) -> Result<u32, String>;
    fn wifi_values(&self, fields: &[WifiField]) -> Result<BTreeMap<WifiField, String>, String>;
    fn apply_wifi_values(&self, values: &BTreeMap<WifiField, String>) -> Result<(), String>;
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
            UbusWrite::ChargePaused(paused) => (
                "charging control",
                "zwrt_bsp.charger",
                "set",
                json!({
                    "direct_power_supply_mode": if paused { "enable" } else { "disable" }
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
        Ok(parse_uci_show(&text))
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

    fn wifi_values(&self, fields: &[WifiField]) -> Result<BTreeMap<WifiField, String>, String> {
        fields
            .iter()
            .copied()
            .map(|field| {
                let output = run_fixed("Wi-Fi setting", "uci", &["-q", "get", field.uci_path()])?;
                let value = String::from_utf8(output)
                    .map_err(|_| "Wi-Fi setting was not UTF-8".to_string())?
                    .trim_end_matches(['\r', '\n'])
                    .to_owned();
                Ok((field, value))
            })
            .collect()
    }

    fn apply_wifi_values(&self, values: &BTreeMap<WifiField, String>) -> Result<(), String> {
        for (field, value) in values {
            let assignment = format!("{}={value}", field.uci_path());
            if let Err(error) = run_fixed("Wi-Fi setting", "uci", &["set", &assignment]) {
                let _ = run_fixed("Wi-Fi revert", "uci", &["revert", "wireless"]);
                return Err(error);
            }
        }
        if let Err(error) = run_fixed("Wi-Fi commit", "uci", &["commit", "wireless"]) {
            let _ = run_fixed("Wi-Fi revert", "uci", &["revert", "wireless"]);
            return Err(error);
        }
        let output = run_fixed(
            "Wi-Fi reload",
            "ubus",
            &["call", "zwrt_wlan", "reload", "{}"],
        )?;
        parse_ubus_write_response("Wi-Fi reload", &output).map(|_| ())
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

fn parse_ubus_write_response(label: &str, output: &[u8]) -> Result<Value, String> {
    // Several accepted B04 write methods acknowledge success with an empty
    // stdout stream. The command exit status remains mandatory, and every
    // state-changing caller performs an independent readback afterwards.
    if output.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    serde_json::from_slice(output).map_err(|_| format!("{label} returned invalid JSON"))
}

fn run_fixed(label: &str, program: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| format!("{label} source is unavailable"))?;

    // Drain stdout while the child is running. Waiting before reading can
    // deadlock once a valid response grows beyond the kernel pipe buffer.
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| format!("{label} returned no output stream"))?;
    let reader = std::thread::spawn(move || {
        let mut output = Vec::new();
        stdout
            .take((MAX_OUTPUT_BYTES + 1) as u64)
            .read_to_end(&mut output)
            .map(|_| output)
    });

    let status = match child.wait_timeout(COMMAND_TIMEOUT) {
        Ok(Some(status)) => status,
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(format!("{label} timed out"));
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(format!("{label} could not be observed"));
        }
    };
    let output = reader
        .join()
        .map_err(|_| format!("{label} output reader stopped unexpectedly"))?
        .map_err(|_| format!("{label} output could not be read"))?;
    if !status.success() {
        return Err(format!("{label} source failed"));
    }
    if output.len() > MAX_OUTPUT_BYTES {
        return Err(format!("{label} output exceeded the fixed limit"));
    }
    Ok(output)
}

fn parse_uci_show(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            let key = key.strip_prefix("wireless.")?;
            Some((key.to_owned(), uci_unquote(value)))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uci_parser_keeps_named_values_without_shell_evaluation() {
        let parsed = parse_uci_show(
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
            WifiField::Hidden2g,
            WifiField::Ssid5g,
            WifiField::Passphrase5g,
            WifiField::Hidden5g,
        ]
        .map(WifiField::uci_path);
        assert_eq!(paths.len(), 6);
        assert!(paths.iter().all(|path| path.starts_with("wireless.")));
    }

    #[test]
    fn ubus_writes_accept_empty_success_but_reject_non_json_output() {
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
            parse_ubus_write_response("write", b"not-json").unwrap_err(),
            "write returned invalid JSON"
        );
    }
}
