use std::collections::BTreeMap;
use std::fs;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;

use crate::b04_io::{B04Io, SystemB04Io, UbusRead, WifiInterface};

const ADAPTER_ID: &str = "zte-mu5250-hk-b04";
const FIRMWARE_TARGET: &str = "BD_XCBZHKMU5250V1.0.0B04";
const WEB_VERSION_PATH: &str = "/usr/zte_web/web/version";
const SUPPORTED_WEB_VERSION: &str = "WEB_XCBZHKU60PROV1.0.0B04";

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityStatus {
    Available,
    Degraded,
    Unsupported,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityId {
    DeviceIdentity,
    SystemStatus,
    BatteryStatus,
    ThermalStatus,
    SignalStatus,
    CellularStatus,
    TrafficStatus,
    WifiStatus,
    LanClients,
    SmsList,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RecoveryMetadata {
    pub required: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Capability {
    pub id: CapabilityId,
    pub status: CapabilityStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub recovery: RecoveryMetadata,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CapabilityReport {
    pub adapter: &'static str,
    pub firmware_target: &'static str,
    pub capabilities: Vec<Capability>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct DeviceDescriptor {
    pub manufacturer: &'static str,
    pub model: &'static str,
    pub adapter: &'static str,
    pub firmware_target: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub firmware_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hardware_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SystemStatus {
    pub hostname: String,
    pub uptime_seconds: u64,
    pub load_average: [f64; 3],
    pub kernel: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct BatteryStatus {
    pub state: String,
    pub capacity_percent: i64,
    pub voltage_mv: i64,
    pub current_ma: i64,
    pub temperature_c: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ThermalSensorReading {
    pub sensor: &'static str,
    pub temperature_c: f64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ThermalStatus {
    pub sensors: Vec<ThermalSensorReading>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct RadioSignal {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub band: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pci: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cell_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bandwidth: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rsrp_dbm: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rsrq_db: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rssi_dbm: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub snr_db: Option<f64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct SignalStatus {
    pub network_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    pub bars: u8,
    pub roaming: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_band: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lte: Option<RadioSignal>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nr5g: Option<RadioSignal>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CellularStatus {
    pub connected: bool,
    pub uptime_seconds: u64,
    pub protocol: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interface: Option<String>,
    pub ipv4_addresses: Vec<String>,
    pub ipv6_addresses: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TrafficPeriod {
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub rx_packets: u64,
    pub tx_packets: u64,
    pub time_seconds: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct TrafficStatus {
    pub day: TrafficPeriod,
    pub cycle: TrafficPeriod,
    pub since_power_on: TrafficPeriod,
    pub total: TrafficPeriod,
    pub reset_day: u8,
    pub reset_enabled: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiBandStatus {
    pub band: &'static str,
    pub enabled: bool,
    pub ssid: String,
    pub hidden: bool,
    pub encryption: String,
    pub channel: String,
    pub bandwidth: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transmit_power_percent: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clients: Option<u32>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiStatus {
    pub enabled: bool,
    pub bands: Vec<WifiBandStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guest: Option<WifiGuestStatus>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiGuestStatus {
    pub enabled_2g: bool,
    pub enabled_5g: bool,
    pub ssid: String,
    pub hidden: bool,
    pub isolation: bool,
    pub active_time_minutes: u16,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LanClient {
    pub hostname: String,
    pub ipv4_address: String,
    pub mac_address: String,
    pub expires_seconds: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LanClients {
    pub clients: Vec<LanClient>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SmsMessage {
    pub id: u64,
    pub sender: String,
    pub timestamp: String,
    pub content: String,
    pub content_truncated: bool,
    pub read: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SmsPage {
    pub page: u16,
    pub per_page: u16,
    pub messages: Vec<SmsMessage>,
    pub omitted_messages: u16,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AdapterError {
    pub code: &'static str,
    pub message: String,
    pub recovery: RecoveryMetadata,
}

pub trait DeviceAdapter: Send + Sync {
    fn device(&self) -> DeviceDescriptor;
    fn capabilities(&self) -> CapabilityReport;
    fn system_status(&self) -> Result<SystemStatus, AdapterError>;
    fn battery_status(&self) -> Result<BatteryStatus, AdapterError>;
    fn thermal_status(&self) -> Result<ThermalStatus, AdapterError>;
    fn signal_status(&self) -> Result<SignalStatus, AdapterError>;
    fn cellular_status(&self) -> Result<CellularStatus, AdapterError>;
    fn traffic_status(&self) -> Result<TrafficStatus, AdapterError>;
    fn wifi_status(&self) -> Result<WifiStatus, AdapterError>;
    fn lan_clients(&self) -> Result<LanClients, AdapterError>;
    fn sms_list(&self, page: u16, per_page: u16) -> Result<SmsPage, AdapterError>;
}

/// Firmware-specific boundary for the user's HK B04 MU5250.
///
/// The fixed firmware file and proc/sysfs sources are parsed here and never
/// returned directly by `/v1`. Public handlers receive only the stable domain
/// structs above.
pub struct B04Adapter {
    io: Arc<dyn B04Io>,
}

struct RawDeviceInfo {
    hostname: String,
    uptime_secs: u64,
    load_avg: [f64; 3],
    kernel: String,
}

struct RawBatteryInfo {
    status: String,
    capacity: i64,
    voltage_uv: i64,
    current_ua: i64,
    temperature: i64,
}

impl B04Adapter {
    pub fn new() -> Self {
        Self {
            io: Arc::new(SystemB04Io::new()),
        }
    }

    fn firmware_identity(&self) -> Option<String> {
        fs::read_to_string(WEB_VERSION_PATH)
            .ok()
            .and_then(|value| parse_web_firmware_identity(&value))
    }

    fn capability(
        id: CapabilityId,
        status: CapabilityStatus,
        reason: Option<&str>,
        recovery_action: Option<&str>,
    ) -> Capability {
        Capability {
            id,
            status,
            reason: reason.map(str::to_owned),
            recovery: RecoveryMetadata {
                required: recovery_action.is_some(),
                action: recovery_action.map(str::to_owned),
            },
        }
    }

    fn probed_capability<T>(id: CapabilityId, result: Result<T, AdapterError>) -> Capability {
        match result {
            Ok(_) => Self::capability(id, CapabilityStatus::Available, None, None),
            Err(error) => Capability {
                id,
                status: if error.code == "unsupported" || error.code == "firmware_mismatch" {
                    CapabilityStatus::Unsupported
                } else {
                    CapabilityStatus::Degraded
                },
                reason: Some(error.message),
                recovery: error.recovery,
            },
        }
    }

    fn firmware_gate(&self) -> Result<(), AdapterError> {
        let device = self.device();
        match firmware_support(device.firmware_version.as_deref()) {
            CapabilityStatus::Available => Ok(()),
            CapabilityStatus::Degraded => Err(AdapterError {
                code: "firmware_unverified",
                message: "the fixed identity probe did not return a firmware version".into(),
                recovery: RecoveryMetadata {
                    required: true,
                    action: Some(
                        "verify the exact firmware build through the maintenance channel".into(),
                    ),
                },
            }),
            CapabilityStatus::Unsupported => Err(AdapterError {
                code: "firmware_mismatch",
                message: "the detected firmware is not supported by the HK B04 adapter".into(),
                recovery: RecoveryMetadata {
                    required: true,
                    action: Some("select an adapter verified for the detected firmware".into()),
                },
            }),
        }
    }
}

impl DeviceAdapter for B04Adapter {
    fn device(&self) -> DeviceDescriptor {
        let firmware_version = self.firmware_identity();
        DeviceDescriptor {
            manufacturer: "ZTE",
            model: "MU5250",
            adapter: ADAPTER_ID,
            firmware_target: FIRMWARE_TARGET,
            firmware_version,
            hardware_version: None,
        }
    }

    fn capabilities(&self) -> CapabilityReport {
        let device = self.device();
        let firmware_status = firmware_support(device.firmware_version.as_deref());

        if firmware_status != CapabilityStatus::Available {
            let (reason, action) = match firmware_status {
                CapabilityStatus::Degraded => (
                    "firmware identity is unavailable; HK B04 ownership is not verified",
                    "verify the exact firmware build through the maintenance channel",
                ),
                CapabilityStatus::Unsupported => (
                    "detected firmware does not match an explicitly supported HK B04 identifier",
                    "select an adapter verified for the detected firmware",
                ),
                CapabilityStatus::Available => unreachable!(),
            };
            return CapabilityReport {
                adapter: ADAPTER_ID,
                firmware_target: FIRMWARE_TARGET,
                capabilities: [
                    CapabilityId::DeviceIdentity,
                    CapabilityId::SystemStatus,
                    CapabilityId::BatteryStatus,
                    CapabilityId::ThermalStatus,
                    CapabilityId::SignalStatus,
                    CapabilityId::CellularStatus,
                    CapabilityId::TrafficStatus,
                    CapabilityId::WifiStatus,
                    CapabilityId::LanClients,
                    CapabilityId::SmsList,
                ]
                .into_iter()
                .map(|id| Self::capability(id, firmware_status, Some(reason), Some(action)))
                .collect(),
            };
        }

        let system_info = read_device_info();
        let battery_available = read_battery().filter(valid_battery).is_some();
        let thermal_available = !read_thermal_sensors().is_empty();

        let identity = Self::capability(
            CapabilityId::DeviceIdentity,
            CapabilityStatus::Available,
            None,
            None,
        );

        let system_status = if system_info.hostname.is_empty() || system_info.kernel.is_empty() {
            Self::capability(
                CapabilityId::SystemStatus,
                CapabilityStatus::Degraded,
                Some("one or more procfs system fields are unavailable"),
                Some("confirm procfs is mounted and readable"),
            )
        } else {
            Self::capability(
                CapabilityId::SystemStatus,
                CapabilityStatus::Available,
                None,
                None,
            )
        };

        let battery_status = if battery_available {
            Self::capability(
                CapabilityId::BatteryStatus,
                CapabilityStatus::Available,
                None,
                None,
            )
        } else {
            Self::capability(
                CapabilityId::BatteryStatus,
                CapabilityStatus::Degraded,
                Some("battery sysfs is unavailable or returned incomplete/out-of-range data"),
                Some("confirm battery power-supply sysfs is mounted and readable"),
            )
        };

        let thermal_status = if thermal_available {
            Self::capability(
                CapabilityId::ThermalStatus,
                CapabilityStatus::Available,
                None,
                None,
            )
        } else {
            Self::capability(
                CapabilityId::ThermalStatus,
                CapabilityStatus::Degraded,
                Some("known HK B04 thermal sysfs sensors could not be read"),
                Some("confirm thermal sysfs is mounted and readable"),
            )
        };

        let mut capabilities = vec![identity, system_status, battery_status, thermal_status];
        capabilities.extend([
            Self::probed_capability(CapabilityId::SignalStatus, self.signal_status()),
            Self::probed_capability(CapabilityId::CellularStatus, self.cellular_status()),
            Self::probed_capability(CapabilityId::TrafficStatus, self.traffic_status()),
            Self::probed_capability(CapabilityId::WifiStatus, self.wifi_status()),
            Self::probed_capability(CapabilityId::LanClients, self.lan_clients()),
            Self::probed_capability(CapabilityId::SmsList, self.sms_list(0, 1)),
        ]);

        CapabilityReport {
            adapter: ADAPTER_ID,
            firmware_target: FIRMWARE_TARGET,
            capabilities,
        }
    }

    fn system_status(&self) -> Result<SystemStatus, AdapterError> {
        self.firmware_gate()?;
        let info = read_device_info();
        if info.hostname.is_empty() || info.kernel.is_empty() {
            return Err(AdapterError {
                code: "source_unavailable",
                message: "procfs system identity is incomplete".into(),
                recovery: RecoveryMetadata {
                    required: true,
                    action: Some("confirm procfs is mounted and readable".into()),
                },
            });
        }
        Ok(SystemStatus {
            hostname: info.hostname,
            uptime_seconds: info.uptime_secs,
            load_average: info.load_avg,
            kernel: info.kernel,
        })
    }

    fn battery_status(&self) -> Result<BatteryStatus, AdapterError> {
        self.firmware_gate()?;
        let battery = read_battery().ok_or_else(|| AdapterError {
            code: "source_unavailable",
            message: "battery power-supply sysfs is not available".into(),
            recovery: RecoveryMetadata {
                required: true,
                action: Some("confirm battery power-supply sysfs is mounted and readable".into()),
            },
        })?;
        if !valid_battery(&battery) {
            return Err(AdapterError {
                code: "invalid_source_data",
                message: "battery sysfs returned incomplete or out-of-range data".into(),
                recovery: RecoveryMetadata {
                    required: true,
                    action: Some(
                        "verify the B04 battery sysfs layout before using this source".into(),
                    ),
                },
            });
        }
        Ok(BatteryStatus {
            state: battery.status,
            capacity_percent: battery.capacity,
            voltage_mv: battery.voltage_uv / 1000,
            current_ma: battery.current_ua / 1000,
            temperature_c: battery.temperature as f64 / 10.0,
        })
    }

    fn thermal_status(&self) -> Result<ThermalStatus, AdapterError> {
        self.firmware_gate()?;
        let sensors = read_thermal_sensors();
        if sensors.is_empty() {
            return Err(AdapterError {
                code: "source_unavailable",
                message: "known HK B04 thermal sysfs sensors are not available".into(),
                recovery: RecoveryMetadata {
                    required: true,
                    action: Some("confirm thermal sysfs is mounted and readable".into()),
                },
            });
        }
        Ok(ThermalStatus { sensors })
    }

    fn signal_status(&self) -> Result<SignalStatus, AdapterError> {
        self.firmware_gate()?;
        self.io
            .ubus_read(UbusRead::NetworkInfo)
            .and_then(|value| parse_signal_status(&value))
            .map_err(|message| {
                source_error(
                    "signal_source_unavailable",
                    message,
                    "verify the B04 network-information ubus object",
                )
            })
    }

    fn cellular_status(&self) -> Result<CellularStatus, AdapterError> {
        self.firmware_gate()?;
        self.io
            .ubus_read(UbusRead::WanStatus)
            .and_then(|value| parse_cellular_status(&value))
            .map_err(|message| {
                source_error(
                    "cellular_source_unavailable",
                    message,
                    "verify the B04 WAN-status ubus object",
                )
            })
    }

    fn traffic_status(&self) -> Result<TrafficStatus, AdapterError> {
        self.firmware_gate()?;
        let usage = self.io.ubus_read(UbusRead::DataUsage).map_err(|message| {
            source_error(
                "traffic_source_unavailable",
                message,
                "verify the B04 data-usage ubus object",
            )
        })?;
        let cycle = self.io.ubus_read(UbusRead::DataCycle).map_err(|message| {
            source_error(
                "traffic_source_unavailable",
                message,
                "verify the B04 data-cycle ubus object",
            )
        })?;
        parse_traffic_status(&usage, &cycle).map_err(|message| {
            source_error(
                "traffic_source_invalid",
                message,
                "verify the B04 data-usage response layout",
            )
        })
    }

    fn wifi_status(&self) -> Result<WifiStatus, AdapterError> {
        self.firmware_gate()?;
        let config = self.io.wireless_config().map_err(|message| {
            source_error(
                "wifi_source_unavailable",
                message,
                "verify the B04 wireless UCI configuration",
            )
        })?;
        let report = self.io.ubus_read(UbusRead::WifiReport).ok();
        parse_wifi_status(
            &config,
            report.as_ref(),
            self.io.station_count(WifiInterface::TwoG).ok(),
            self.io.station_count(WifiInterface::FiveG).ok(),
        )
        .map_err(|message| {
            source_error(
                "wifi_source_invalid",
                message,
                "verify the B04 wireless UCI layout",
            )
        })
    }

    fn lan_clients(&self) -> Result<LanClients, AdapterError> {
        self.firmware_gate()?;
        self.io
            .ubus_read(UbusRead::DhcpLeases)
            .and_then(|value| parse_lan_clients(&value))
            .map_err(|message| {
                source_error(
                    "lan_clients_unavailable",
                    message,
                    "verify the B04 DHCP lease source",
                )
            })
    }

    fn sms_list(&self, page: u16, per_page: u16) -> Result<SmsPage, AdapterError> {
        self.firmware_gate()?;
        if per_page == 0 || per_page > 100 {
            return Err(AdapterError {
                code: "invalid_request",
                message: "per_page must be between 1 and 100".into(),
                recovery: RecoveryMetadata {
                    required: false,
                    action: None,
                },
            });
        }
        self.io
            .ubus_read(UbusRead::SmsList { page, per_page })
            .and_then(|value| parse_sms_page(&value, page, per_page))
            .map_err(|message| {
                source_error(
                    "sms_source_unavailable",
                    message,
                    "verify the B04 WMS read-only object",
                )
            })
    }
}

impl Default for B04Adapter {
    fn default() -> Self {
        Self::new()
    }
}

fn source_error(code: &'static str, message: String, action: &str) -> AdapterError {
    AdapterError {
        code,
        message,
        recovery: RecoveryMetadata {
            required: true,
            action: Some(action.to_owned()),
        },
    }
}

fn parse_signal_status(value: &Value) -> Result<SignalStatus, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "network information was not an object".to_string())?;
    let network_type = required_string(object.get("network_type"), "network_type")?;
    let bars = value_u64(object.get("signalbar"))
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| *value <= 5)
        .ok_or_else(|| "signalbar was missing or out of range".to_string())?;
    let lte = radio_signal(
        object, "lte_band", None, None, None, None, "lte_rsrp", "lte_rsrq", "lte_rssi", "lte_snr",
    );
    let nr5g = radio_signal(
        object,
        "nr5g_action_band",
        Some("nr5g_action_channel"),
        Some("nr5g_pci"),
        Some("nr5g_cell_id"),
        Some("nr5g_bandwidth"),
        "nr5g_rsrp",
        "nr5g_rsrq",
        "nr5g_rssi",
        "nr5g_snr",
    );
    Ok(SignalStatus {
        network_type,
        provider: optional_string(object.get("network_provider_fullname"))
            .or_else(|| optional_string(object.get("network_provider"))),
        bars,
        roaming: boolish(object.get("simcard_roam")).unwrap_or(false),
        active_band: optional_string(object.get("wan_active_band")),
        lte,
        nr5g,
    })
}

#[allow(clippy::too_many_arguments)]
fn radio_signal(
    object: &serde_json::Map<String, Value>,
    band_key: &str,
    channel_key: Option<&str>,
    pci_key: Option<&str>,
    cell_id_key: Option<&str>,
    bandwidth_key: Option<&str>,
    rsrp_key: &str,
    rsrq_key: &str,
    rssi_key: &str,
    snr_key: &str,
) -> Option<RadioSignal> {
    let signal = RadioSignal {
        band: optional_string(object.get(band_key)),
        channel: channel_key.and_then(|key| value_u64(object.get(key))),
        pci: pci_key.and_then(|key| value_u64(object.get(key))),
        cell_id: cell_id_key.and_then(|key| value_u64(object.get(key))),
        bandwidth: bandwidth_key.and_then(|key| optional_string(object.get(key))),
        rsrp_dbm: value_i64(object.get(rsrp_key)).filter(|value| (-200..=0).contains(value)),
        rsrq_db: value_i64(object.get(rsrq_key)).filter(|value| (-100..=100).contains(value)),
        rssi_dbm: value_i64(object.get(rssi_key)).filter(|value| (-200..=0).contains(value)),
        snr_db: value_f64(object.get(snr_key)).filter(|value| (-100.0..=100.0).contains(value)),
    };
    (signal.band.is_some()
        || signal.channel.is_some()
        || signal.pci.is_some()
        || signal.rsrp_dbm.is_some())
    .then_some(signal)
}

fn parse_cellular_status(value: &Value) -> Result<CellularStatus, String> {
    let object = value
        .as_object()
        .ok_or_else(|| "WAN status was not an object".to_string())?;
    let connected = object
        .get("up")
        .and_then(Value::as_bool)
        .ok_or_else(|| "WAN status did not contain a boolean up field".to_string())?;
    let uptime_seconds = value_u64(object.get("uptime")).unwrap_or(0);
    let protocol = required_string(object.get("proto"), "proto")?;
    Ok(CellularStatus {
        connected,
        uptime_seconds,
        protocol,
        interface: optional_string(object.get("l3_device")),
        ipv4_addresses: parse_ip_addresses(object.get("ipv4-address"), false),
        ipv6_addresses: parse_ip_addresses(object.get("ipv6-address"), true),
    })
}

fn parse_ip_addresses(value: Option<&Value>, ipv6: bool) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.get("address").and_then(Value::as_str))
        .filter_map(|address| address.parse::<IpAddr>().ok())
        .filter(|address| address.is_ipv6() == ipv6)
        .take(8)
        .map(|address| address.to_string())
        .collect()
}

fn parse_traffic_status(usage: &Value, cycle: &Value) -> Result<TrafficStatus, String> {
    let usage = usage
        .as_object()
        .ok_or_else(|| "traffic usage was not an object".to_string())?;
    let cycle = cycle
        .as_object()
        .ok_or_else(|| "traffic cycle was not an object".to_string())?;
    let reset_day = value_u64(cycle.get("clearday"))
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=31).contains(value))
        .ok_or_else(|| "traffic reset day was missing or invalid".to_string())?;
    Ok(TrafficStatus {
        day: parse_traffic_period(usage, "day")?,
        cycle: parse_traffic_period(usage, "month")?,
        since_power_on: parse_traffic_period(usage, "real")?,
        total: parse_traffic_period(usage, "total")?,
        reset_day,
        reset_enabled: boolish(cycle.get("enable")).unwrap_or(false),
    })
}

fn parse_traffic_period(
    object: &serde_json::Map<String, Value>,
    prefix: &str,
) -> Result<TrafficPeriod, String> {
    let required = |suffix: &str| {
        value_u64(object.get(&format!("{prefix}_{suffix}")))
            .ok_or_else(|| format!("traffic field {prefix}_{suffix} was missing"))
    };
    Ok(TrafficPeriod {
        rx_bytes: required("rx_bytes")?,
        tx_bytes: required("tx_bytes")?,
        rx_packets: required("rx_packets")?,
        tx_packets: required("tx_packets")?,
        time_seconds: required("time")?,
    })
}

fn parse_wifi_status(
    config: &BTreeMap<String, String>,
    report: Option<&Value>,
    clients_2g: Option<u32>,
    clients_5g: Option<u32>,
) -> Result<WifiStatus, String> {
    let band = |name: &'static str,
                radio: &str,
                network: &str,
                clients: Option<u32>|
     -> Result<WifiBandStatus, String> {
        let required = |key: &str| {
            config
                .get(key)
                .cloned()
                .ok_or_else(|| format!("wireless key {key} was missing"))
        };
        let power = config
            .get(&format!("{radio}.txpowerpercent"))
            .and_then(|value| value.parse::<u8>().ok())
            .filter(|value| *value <= 100);
        Ok(WifiBandStatus {
            band: name,
            enabled: !disabled(config.get(&format!("{radio}.disabled")))
                && !disabled(config.get(&format!("{network}.disabled"))),
            ssid: required(&format!("{network}.ssid"))?,
            hidden: boolish_string(config.get(&format!("{network}.hidden"))).unwrap_or(false),
            encryption: required(&format!("{network}.encryption"))?,
            channel: required(&format!("{radio}.channel"))?,
            bandwidth: required(&format!("{radio}.htmode"))?,
            transmit_power_percent: power,
            clients,
        })
    };
    let bands = vec![
        band("2.4 GHz", "wifi0", "main_2g", clients_2g)?,
        band("5 GHz", "wifi1", "main_5g", clients_5g)?,
    ];
    let report_enabled = report
        .and_then(|value| value.get("wifi_onoff"))
        .and_then(|value| boolish(Some(value)));
    let guest = (|| {
        let ssid = config.get("guest_2g.ssid")?.clone();
        let active_time_minutes = config.get("guest_2g.active_time")?.parse::<u16>().ok()?;
        Some(WifiGuestStatus {
            enabled_2g: !disabled(config.get("guest_2g.disabled")),
            enabled_5g: !disabled(config.get("guest_5g.disabled")),
            ssid,
            hidden: boolish_string(config.get("guest_2g.hidden")).unwrap_or(false),
            isolation: boolish_string(config.get("guest_2g.isolate")).unwrap_or(false),
            active_time_minutes,
        })
    })();
    Ok(WifiStatus {
        enabled: report_enabled.unwrap_or_else(|| bands.iter().any(|band| band.enabled)),
        bands,
        guest,
    })
}

fn parse_lan_clients(value: &Value) -> Result<LanClients, String> {
    let leases = value
        .get("dhcp_leases")
        .and_then(Value::as_array)
        .ok_or_else(|| "DHCP leases were missing".to_string())?;
    if leases.len() > 256 {
        return Err("DHCP lease count exceeded the fixed limit".into());
    }
    let mut clients = Vec::with_capacity(leases.len());
    for lease in leases {
        let object = lease
            .as_object()
            .ok_or_else(|| "DHCP lease was not an object".to_string())?;
        let ipv4_address = required_string(object.get("ipaddr"), "ipaddr")?;
        ipv4_address
            .parse::<Ipv4Addr>()
            .map_err(|_| "DHCP lease contained an invalid IPv4 address".to_string())?;
        let mac_address = required_string(object.get("macaddr"), "macaddr")?;
        if !valid_mac(&mac_address) {
            return Err("DHCP lease contained an invalid MAC address".into());
        }
        let hostname = optional_string(object.get("hostname")).unwrap_or_default();
        if hostname.len() > 255 || hostname.chars().any(char::is_control) {
            return Err("DHCP lease hostname was invalid".into());
        }
        clients.push(LanClient {
            hostname,
            ipv4_address,
            mac_address: mac_address.to_ascii_lowercase(),
            expires_seconds: value_u64(object.get("expires")).unwrap_or(0),
        });
    }
    Ok(LanClients { clients })
}

fn parse_sms_page(value: &Value, page: u16, per_page: u16) -> Result<SmsPage, String> {
    let messages = value
        .get("messages")
        .and_then(Value::as_array)
        .ok_or_else(|| "SMS response did not contain messages".to_string())?;
    if messages.len() > usize::from(per_page) {
        return Err("SMS response exceeded the requested page size".into());
    }
    let mut parsed = Vec::with_capacity(messages.len());
    let mut omitted_messages = 0u16;
    for message in messages {
        let Some(object) = message.as_object() else {
            omitted_messages += 1;
            continue;
        };
        let Some(sender_raw) = optional_string(object.get("number")) else {
            omitted_messages += 1;
            continue;
        };
        let Some(timestamp) = optional_string(object.get("date")) else {
            omitted_messages += 1;
            continue;
        };
        let Some(content_raw) = object.get("content").and_then(Value::as_str) else {
            omitted_messages += 1;
            continue;
        };
        let Some(id) = value_u64(object.get("id")).filter(|value| *value > 0) else {
            omitted_messages += 1;
            continue;
        };
        if sender_raw.len() > 512 || content_raw.len() > 32_768 || timestamp.len() > 64 {
            omitted_messages += 1;
            continue;
        }
        let Ok(sender) = decode_ucs2_hex_if_present(&sender_raw) else {
            omitted_messages += 1;
            continue;
        };
        let Ok(content) = decode_ucs2_hex_if_present(content_raw) else {
            omitted_messages += 1;
            continue;
        };
        if sender.chars().count() > 64 {
            omitted_messages += 1;
            continue;
        }
        let (content, content_truncated) = truncate_utf8_bytes(content, 4096);
        parsed.push(SmsMessage {
            id,
            sender,
            timestamp,
            content,
            content_truncated,
            read: optional_string(object.get("tag")).as_deref() == Some("0"),
        });
    }
    Ok(SmsPage {
        page,
        per_page,
        messages: parsed,
        omitted_messages,
    })
}

fn decode_ucs2_hex_if_present(value: &str) -> Result<String, ()> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || !trimmed.len().is_multiple_of(4)
        || !trimmed.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Ok(value.to_owned());
    }
    let units = trimmed
        .as_bytes()
        .chunks_exact(4)
        .map(|chunk| {
            std::str::from_utf8(chunk)
                .map_err(|_| ())
                .and_then(|hex| u16::from_str_radix(hex, 16).map_err(|_| ()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    String::from_utf16(&units).map_err(|_| ())
}

fn truncate_utf8_bytes(value: String, maximum: usize) -> (String, bool) {
    if value.len() <= maximum {
        return (value, false);
    }
    let mut boundary = maximum;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    (value[..boundary].to_owned(), true)
}

fn required_string(value: Option<&Value>, name: &str) -> Result<String, String> {
    optional_string(value).ok_or_else(|| format!("{name} was missing or empty"))
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn value_u64(value: Option<&Value>) -> Option<u64> {
    match value? {
        Value::Number(number) => number.as_u64(),
        Value::String(value) => value.trim().parse().ok(),
        _ => None,
    }
}

fn value_i64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_i64(),
        Value::String(value) => value.trim().parse().ok(),
        _ => None,
    }
}

fn value_f64(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(number) => number.as_f64(),
        Value::String(value) => value.trim().parse().ok(),
        _ => None,
    }
    .filter(|value| value.is_finite())
}

fn boolish(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(value) => Some(*value),
        Value::Number(value) => value.as_u64().map(|value| value != 0),
        Value::String(value) => boolish_text(value),
        _ => None,
    }
}

fn boolish_string(value: Option<&String>) -> Option<bool> {
    value.and_then(|value| boolish_text(value))
}

fn boolish_text(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" | "enabled" => Some(true),
        "0" | "false" | "no" | "off" | "disabled" => Some(false),
        _ => None,
    }
}

fn disabled(value: Option<&String>) -> bool {
    boolish_string(value).unwrap_or(false)
}

fn valid_mac(value: &str) -> bool {
    let parts: Vec<&str> = value.split(':').collect();
    parts.len() == 6
        && parts
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn firmware_support(version: Option<&str>) -> CapabilityStatus {
    match version.map(str::trim).filter(|value| !value.is_empty()) {
        None => CapabilityStatus::Degraded,
        Some(FIRMWARE_TARGET) => CapabilityStatus::Available,
        Some(_) => CapabilityStatus::Unsupported,
    }
}

fn valid_battery(battery: &RawBatteryInfo) -> bool {
    (0..=100).contains(&battery.capacity)
        && battery.voltage_uv > 0
        && (-400..=1500).contains(&battery.temperature)
}

fn read_device_info() -> RawDeviceInfo {
    let hostname = fs::read_to_string("/proc/sys/kernel/hostname")
        .unwrap_or_default()
        .trim()
        .to_owned();
    let uptime_secs = fs::read_to_string("/proc/uptime")
        .unwrap_or_default()
        .split_whitespace()
        .next()
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or_default() as u64;
    let load_values: Vec<f64> = fs::read_to_string("/proc/loadavg")
        .unwrap_or_default()
        .split_whitespace()
        .take(3)
        .filter_map(|value| value.parse().ok())
        .collect();
    let kernel = fs::read_to_string("/proc/version")
        .unwrap_or_default()
        .trim()
        .to_owned();
    RawDeviceInfo {
        hostname,
        uptime_secs,
        load_avg: [
            load_values.first().copied().unwrap_or_default(),
            load_values.get(1).copied().unwrap_or_default(),
            load_values.get(2).copied().unwrap_or_default(),
        ],
        kernel,
    }
}

fn read_battery() -> Option<RawBatteryInfo> {
    let base = "/sys/class/power_supply/battery";
    let read = |name: &str| {
        fs::read_to_string(format!("{base}/{name}"))
            .ok()
            .map(|value| value.trim().to_owned())
    };
    let parse = |name: &str| read(name)?.parse::<i64>().ok();
    Some(RawBatteryInfo {
        status: read("status")?,
        capacity: parse("capacity")?,
        voltage_uv: parse("voltage_now")?,
        current_ua: parse("current_now")?,
        temperature: parse("temp")?,
    })
}

fn parse_web_firmware_identity(content: &str) -> Option<String> {
    let lf = format!(
        "software_version={SUPPORTED_WEB_VERSION}\ninner_software_version={SUPPORTED_WEB_VERSION}"
    );
    let crlf = format!(
        "software_version={SUPPORTED_WEB_VERSION}\r\ninner_software_version={SUPPORTED_WEB_VERSION}"
    );
    matches!(content, value if value == lf || value == format!("{lf}\n") || value == crlf || value == format!("{crlf}\r\n"))
        .then(|| FIRMWARE_TARGET.to_owned())
}

fn read_thermal_sensors() -> Vec<ThermalSensorReading> {
    const SENSORS: &[(&str, &str)] = &[
        ("cpu_0", "/sys/class/thermal/thermal_zone16/temp"),
        ("cpu_1", "/sys/class/thermal/thermal_zone17/temp"),
        ("cpu_2", "/sys/class/thermal/thermal_zone18/temp"),
        ("cpu_3", "/sys/class/thermal/thermal_zone19/temp"),
        ("modem", "/sys/class/thermal/thermal_zone22/temp"),
        ("battery", "/sys/class/thermal/thermal_zone39/temp"),
        ("usb", "/sys/class/thermal/thermal_zone38/temp"),
    ];

    SENSORS
        .iter()
        .filter_map(|(sensor, path)| {
            let millidegrees = fs::read_to_string(path).ok()?.trim().parse::<i64>().ok()?;
            (-40_000..150_000)
                .contains(&millidegrees)
                .then_some(ThermalSensorReading {
                    sensor,
                    temperature_c: millidegrees as f64 / 1000.0,
                })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn capability_status_serializes_as_contract_value() {
        assert_eq!(
            serde_json::to_value(CapabilityStatus::Available).unwrap(),
            json!("available")
        );
        assert_eq!(
            serde_json::to_value(CapabilityStatus::Degraded).unwrap(),
            json!("degraded")
        );
        assert_eq!(
            serde_json::to_value(CapabilityStatus::Unsupported).unwrap(),
            json!("unsupported")
        );
    }

    #[test]
    fn firmware_identity_parser_requires_both_exact_web_build_fields() {
        assert_eq!(
            parse_web_firmware_identity(
                "software_version=WEB_XCBZHKU60PROV1.0.0B04\r\n\
                 inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\r\n"
            ),
            Some("BD_XCBZHKMU5250V1.0.0B04".into())
        );
        assert_eq!(
            parse_web_firmware_identity(
                "software_version=WEB_XCBZHKU60PROV1.0.0B04\n\
                 inner_software_version=WEB_XCBZHKU60PROV1.0.0B03\n"
            ),
            None
        );
        assert_eq!(
            parse_web_firmware_identity(
                "software_version=WEB_XCBZHKU60PROV1.0.0B04\nsecret=unexpected\n"
            ),
            None
        );
        assert_eq!(
            parse_web_firmware_identity(
                "software_version=WEB_XCBZHKU60PROV1.0.0B04\n\
                 software_version=WEB_XCBZHKU60PROV1.0.0B04\n\
                 inner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n"
            ),
            None
        );
        for content in [
            " software_version=WEB_XCBZHKU60PROV1.0.0B04\ninner_software_version=WEB_XCBZHKU60PROV1.0.0B04",
            "software_version=WEB_XCBZHKU60PROV1.0.0B04 \ninner_software_version=WEB_XCBZHKU60PROV1.0.0B04",
            "software_version=WEB_XCBZHKU60PROV1.0.0B04\rinner_software_version=WEB_XCBZHKU60PROV1.0.0B04",
            "software_version=WEB_XCBZHKU60PROV1.0.0B04\r\ninner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n",
            "software_version=WEB_XCBZHKU60PROV1.0.0B04\ninner_software_version=WEB_XCBZHKU60PROV1.0.0B04\n\n",
        ] {
            assert_eq!(parse_web_firmware_identity(content), None);
        }
    }

    #[test]
    fn firmware_gate_accepts_only_explicit_b04_identifiers() {
        assert_eq!(
            firmware_support(Some("BD_XCBZHKMU5250V1.0.0B04")),
            CapabilityStatus::Available
        );
        assert_eq!(firmware_support(None), CapabilityStatus::Degraded);
        assert_eq!(
            firmware_support(Some("XCBZ_HK_MU5250V1.0.0B04")),
            CapabilityStatus::Unsupported
        );
        assert_eq!(
            firmware_support(Some("CN_ZTE_MU5250V1.0.0B28")),
            CapabilityStatus::Unsupported
        );
        assert_eq!(firmware_support(Some("B04")), CapabilityStatus::Unsupported);
    }

    #[test]
    fn battery_validation_rejects_incomplete_and_out_of_range_data() {
        let valid = RawBatteryInfo {
            status: "Charging".into(),
            capacity: 80,
            voltage_uv: 4_000_000,
            current_ua: 0,
            temperature: 250,
        };
        assert!(valid_battery(&valid));

        let missing_voltage = RawBatteryInfo {
            voltage_uv: 0,
            ..valid
        };
        assert!(!valid_battery(&missing_voltage));
    }

    #[test]
    fn parses_redacted_live_shape_into_typed_signal_and_cellular_status() {
        let signal = parse_signal_status(&json!({
            "network_type": "NR5G",
            "network_provider_fullname": "Example",
            "signalbar": "4",
            "simcard_roam": "0",
            "wan_active_band": "n78",
            "lte_band": "B3",
            "lte_rsrp": -91,
            "lte_rsrq": -9,
            "lte_rssi": -63,
            "lte_snr": "18.5",
            "nr5g_action_band": "n78",
            "nr5g_action_channel": 640000,
            "nr5g_pci": 42,
            "nr5g_cell_id": 7,
            "nr5g_bandwidth": "100MHz",
            "nr5g_rsrp": -88,
            "nr5g_rsrq": -11,
            "nr5g_rssi": -59,
            "nr5g_snr": "22.0"
        }))
        .unwrap();
        assert_eq!(signal.bars, 4);
        assert_eq!(signal.nr5g.unwrap().pci, Some(42));

        let cellular = parse_cellular_status(&json!({
            "up": true,
            "uptime": 123,
            "proto": "dhcp",
            "l3_device": "rmnet_data0",
            "ipv4-address": [{"address":"10.0.0.2"}],
            "ipv6-address": [{"address":"2001:db8::2"}]
        }))
        .unwrap();
        assert!(cellular.connected);
        assert_eq!(cellular.ipv4_addresses, ["10.0.0.2"]);
    }

    #[test]
    fn parses_traffic_wifi_lan_and_sms_without_vendor_passthrough() {
        let mut usage = serde_json::Map::new();
        for prefix in ["day", "month", "real", "total"] {
            for suffix in ["rx_bytes", "tx_bytes", "rx_packets", "tx_packets", "time"] {
                usage.insert(format!("{prefix}_{suffix}"), json!(10));
            }
        }
        let traffic =
            parse_traffic_status(&Value::Object(usage), &json!({"clearday": 12, "enable": 1}))
                .unwrap();
        assert_eq!(traffic.reset_day, 12);
        assert!(traffic.reset_enabled);

        let config = BTreeMap::from([
            ("wifi0.disabled".into(), "0".into()),
            ("wifi0.channel".into(), "auto".into()),
            ("wifi0.htmode".into(), "HE40".into()),
            ("wifi0.txpowerpercent".into(), "100".into()),
            ("main_2g.disabled".into(), "0".into()),
            ("main_2g.ssid".into(), "Two".into()),
            ("main_2g.hidden".into(), "0".into()),
            ("main_2g.encryption".into(), "psk2".into()),
            ("wifi1.disabled".into(), "0".into()),
            ("wifi1.channel".into(), "36".into()),
            ("wifi1.htmode".into(), "HE80".into()),
            ("wifi1.txpowerpercent".into(), "80".into()),
            ("main_5g.disabled".into(), "0".into()),
            ("main_5g.ssid".into(), "Five".into()),
            ("main_5g.hidden".into(), "1".into()),
            ("main_5g.encryption".into(), "sae-mixed".into()),
            ("guest_2g.disabled".into(), "0".into()),
            ("guest_2g.ssid".into(), "Guest".into()),
            ("guest_2g.hidden".into(), "0".into()),
            ("guest_2g.isolate".into(), "1".into()),
            ("guest_2g.active_time".into(), "120".into()),
            ("guest_5g.disabled".into(), "1".into()),
        ]);
        let wifi =
            parse_wifi_status(&config, Some(&json!({"wifi_onoff":"1"})), Some(1), Some(2)).unwrap();
        assert!(wifi.enabled);
        assert_eq!(wifi.bands[1].clients, Some(2));
        assert!(wifi.bands[1].hidden);
        let guest = wifi.guest.unwrap();
        assert!(guest.enabled_2g);
        assert!(!guest.enabled_5g);
        assert!(guest.isolation);
        assert_eq!(guest.active_time_minutes, 120);

        let clients = parse_lan_clients(&json!({"dhcp_leases":[{
            "hostname":"phone", "ipaddr":"192.168.0.2",
            "macaddr":"02:00:00:00:00:01", "expires":120
        }]}))
        .unwrap();
        assert_eq!(clients.clients.len(), 1);

        let sms = parse_sms_page(
            &json!({"messages":[{
                "id":1, "number":"+100", "date":"2026-08-16",
                "content":"hello", "tag":"0"
            }]}),
            0,
            100,
        )
        .unwrap();
        assert!(sms.messages[0].read);
        assert_eq!(sms.messages[0].content, "hello");
        assert!(!sms.messages[0].content_truncated);
        assert_eq!(sms.omitted_messages, 0);

        let decoded = parse_sms_page(
            &json!({"messages":[{
                "id":2, "number":"002B003100300030", "date":"now",
                "content":"4F60597DD83DDE00", "tag":"1"
            }]}),
            0,
            100,
        )
        .unwrap();
        assert_eq!(decoded.messages[0].sender, "+100");
        assert_eq!(decoded.messages[0].content, "你好😀");
    }

    #[test]
    fn rejects_oversized_or_malformed_vendor_records() {
        assert!(parse_lan_clients(&json!({"dhcp_leases":[{
            "hostname":"bad", "ipaddr":"not-an-ip",
            "macaddr":"not-a-mac", "expires":1
        }]}))
        .is_err());
        let sms = parse_sms_page(
            &json!({"messages":[{
                "id":0, "number":"+100", "date":"now", "content":"", "tag":"1"
            }]}),
            0,
            100,
        )
        .unwrap();
        assert!(sms.messages.is_empty());
        assert_eq!(sms.omitted_messages, 1);

        let sms = parse_sms_page(
            &json!({"messages":[{
                "id":1, "number":"002B0031", "date":"now", "content":"D800", "tag":"1"
            }]}),
            0,
            100,
        )
        .unwrap();
        assert!(sms.messages.is_empty());
        assert_eq!(sms.omitted_messages, 1);

        let oversized = format!("{}é", "a".repeat(4095));
        let sms = parse_sms_page(
            &json!({"messages":[{
                "id":1, "number":"+100", "date":"now", "content":oversized, "tag":"1"
            }]}),
            0,
            100,
        )
        .unwrap();
        assert_eq!(sms.messages[0].content.len(), 4095);
        assert!(sms.messages[0].content_truncated);
        assert_eq!(sms.omitted_messages, 0);
    }
}
