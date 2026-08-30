use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

use crate::adapter::{
    AdapterError, BatteryStatus, Capability, CapabilityId, CapabilityReport, CapabilityStatus,
    CellularStatus, DeviceDescriptor, LanClients, RecoveryMetadata, SignalStatus, SmsPage,
    SystemStatus, ThermalStatus, TrafficStatus, WifiStatus,
};
use crate::daily::ChargingStatus;
use crate::daily::{
    SmsSendRequest, TrafficCycleRequest, WifiConfirmRequest, WifiMasterRequest,
    WifiTransactionRequest,
};
use crate::handlers::AppState;

#[derive(Serialize)]
struct Success<T> {
    ok: bool,
    data: T,
}

#[derive(Serialize)]
struct Failure {
    ok: bool,
    error: AdapterError,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum DashboardComponentId {
    SystemStatus,
    BatteryStatus,
    ThermalStatus,
    SignalStatus,
    CellularStatus,
    TrafficStatus,
    WifiStatus,
    LanClients,
    SmsList,
    ChargingStatus,
}

const DASHBOARD_BUDGET: Duration = Duration::from_secs(11);
const DASHBOARD_EVENT_CAPACITY: usize = DASHBOARD_COMPONENTS.len() + 1;
const DASHBOARD_COMPONENTS: [(CapabilityId, DashboardComponentId); 9] = [
    (
        CapabilityId::SystemStatus,
        DashboardComponentId::SystemStatus,
    ),
    (
        CapabilityId::BatteryStatus,
        DashboardComponentId::BatteryStatus,
    ),
    (
        CapabilityId::ThermalStatus,
        DashboardComponentId::ThermalStatus,
    ),
    (
        CapabilityId::SignalStatus,
        DashboardComponentId::SignalStatus,
    ),
    (
        CapabilityId::CellularStatus,
        DashboardComponentId::CellularStatus,
    ),
    (
        CapabilityId::TrafficStatus,
        DashboardComponentId::TrafficStatus,
    ),
    (CapabilityId::WifiStatus, DashboardComponentId::WifiStatus),
    (CapabilityId::LanClients, DashboardComponentId::LanClients),
    (CapabilityId::SmsList, DashboardComponentId::SmsList),
];

#[derive(Serialize)]
struct DashboardFailure {
    component: DashboardComponentId,
    error: AdapterError,
}

#[derive(Serialize)]
struct DashboardSnapshot {
    report: CapabilityReport,
    #[serde(skip_serializing_if = "Option::is_none")]
    device: Option<DeviceDescriptor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<SystemStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    battery: Option<BatteryStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    thermal: Option<ThermalStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    signal: Option<SignalStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cellular: Option<CellularStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    traffic: Option<TrafficStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    wifi: Option<WifiStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    lan_clients: Option<LanClients>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sms: Option<SmsPage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    charging: Option<ChargingStatus>,
    failures: Vec<DashboardFailure>,
}

fn success<T: Serialize>(data: T) -> (u16, Value) {
    (
        200,
        serde_json::to_value(Success { ok: true, data })
            .unwrap_or_else(|_| json!({"ok": false, "error": {"code": "serialization_error", "message": "failed to serialize response"}})),
    )
}

fn adapter_result<T: Serialize>(result: Result<T, AdapterError>) -> (u16, Value) {
    match result {
        Ok(data) => success(data),
        Err(error) => {
            let status = match error.code {
                "invalid_request" => 400,
                "unsupported" | "firmware_mismatch" => 501,
                _ => 503,
            };
            (
                status,
                serde_json::to_value(Failure { ok: false, error }).unwrap_or_else(|_| {
                    json!({"ok": false, "error": {"code": "serialization_error", "message": "failed to serialize error"}})
                }),
            )
        }
    }
}

pub fn device(state: &AppState) -> (u16, Value) {
    success(state.adapter.device())
}

pub fn capabilities(state: &AppState) -> (u16, Value) {
    success(state.adapter.capabilities())
}

pub async fn dashboard(state: AppState, peer: IpAddr) -> (u16, Value) {
    dashboard_with_budget(state, peer, DASHBOARD_BUDGET).await
}

async fn dashboard_with_budget(state: AppState, peer: IpAddr, budget: Duration) -> (u16, Value) {
    let device = state.adapter.device();
    let deadline = tokio::time::Instant::now() + budget;
    let permit = match tokio::time::timeout_at(
        deadline,
        Arc::clone(&state.dashboard_admission).acquire_owned(),
    )
    .await
    {
        Ok(Ok(permit)) => permit,
        Ok(Err(_)) | Err(_) => {
            let mut snapshot = DashboardAccumulator::new(device);
            snapshot.finish_timeouts();
            return success(snapshot.finish());
        }
    };
    let (sender, mut receiver) = mpsc::channel(DASHBOARD_EVENT_CAPACITY);
    let cancelled = Arc::new(AtomicBool::new(false));
    let worker_cancelled = Arc::clone(&cancelled);
    let worker_state = state;

    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        if worker_cancelled.load(Ordering::Acquire) {
            return;
        }
        macro_rules! collect {
            ($variant:ident, $operation:expr) => {{
                if worker_cancelled.load(Ordering::Acquire) {
                    return;
                }
                if sender
                    .blocking_send(DashboardEvent::$variant($operation))
                    .is_err()
                {
                    return;
                }
            }};
        }

        collect!(System, worker_state.adapter.system_status());
        collect!(Battery, worker_state.adapter.battery_status());
        collect!(Thermal, worker_state.adapter.thermal_status());
        collect!(Signal, Box::new(worker_state.adapter.signal_status()));
        collect!(Cellular, worker_state.adapter.cellular_status());
        collect!(Traffic, worker_state.adapter.traffic_status());
        collect!(Wifi, worker_state.adapter.wifi_status_for_peer(peer));
        collect!(LanClients, worker_state.adapter.lan_clients());
        collect!(Sms, worker_state.adapter.sms_list(0, 100));
        let charging = worker_state
            .daily
            .as_ref()
            .ok_or_else(|| "daily management service is unavailable".to_string())
            .and_then(|service| service.charging_status())
            .map_err(daily_adapter_error);
        collect!(Charging, charging);
    });

    let mut snapshot = DashboardAccumulator::new(device);
    while snapshot.completed_count() < DASHBOARD_COMPONENTS.len() + 1 {
        match tokio::time::timeout_at(deadline, receiver.recv()).await {
            Ok(Some(event)) => snapshot.apply(event),
            Ok(None) | Err(_) => break,
        }
    }
    cancelled.store(true, Ordering::Release);
    snapshot.finish_timeouts();
    success(snapshot.finish())
}

enum DashboardEvent {
    System(Result<SystemStatus, AdapterError>),
    Battery(Result<BatteryStatus, AdapterError>),
    Thermal(Result<ThermalStatus, AdapterError>),
    Signal(Box<Result<SignalStatus, AdapterError>>),
    Cellular(Result<CellularStatus, AdapterError>),
    Traffic(Result<TrafficStatus, AdapterError>),
    Wifi(Result<WifiStatus, AdapterError>),
    LanClients(Result<LanClients, AdapterError>),
    Sms(Result<SmsPage, AdapterError>),
    Charging(Result<ChargingStatus, AdapterError>),
}

struct DashboardAccumulator {
    device: DeviceDescriptor,
    system: Option<SystemStatus>,
    battery: Option<BatteryStatus>,
    thermal: Option<ThermalStatus>,
    signal: Option<SignalStatus>,
    cellular: Option<CellularStatus>,
    traffic: Option<TrafficStatus>,
    wifi: Option<WifiStatus>,
    lan_clients: Option<LanClients>,
    sms: Option<SmsPage>,
    charging: Option<ChargingStatus>,
    outcomes: Vec<(CapabilityId, Result<(), AdapterError>)>,
    failures: Vec<DashboardFailure>,
    charging_completed: bool,
}

impl DashboardAccumulator {
    fn new(device: DeviceDescriptor) -> Self {
        Self {
            device,
            system: None,
            battery: None,
            thermal: None,
            signal: None,
            cellular: None,
            traffic: None,
            wifi: None,
            lan_clients: None,
            sms: None,
            charging: None,
            outcomes: Vec::with_capacity(DASHBOARD_COMPONENTS.len()),
            failures: Vec::new(),
            charging_completed: false,
        }
    }

    fn completed_count(&self) -> usize {
        self.outcomes.len() + usize::from(self.charging_completed)
    }

    fn apply(&mut self, event: DashboardEvent) {
        macro_rules! apply {
            ($result:expr, $field:ident, $capability:expr, $component:expr) => {
                match $result {
                    Ok(value) => {
                        self.$field = Some(value);
                        self.outcomes.push(($capability, Ok(())));
                    }
                    Err(error) => {
                        self.outcomes.push(($capability, Err(error.clone())));
                        self.failures.push(DashboardFailure {
                            component: $component,
                            error,
                        });
                    }
                }
            };
        }
        match event {
            DashboardEvent::System(result) => apply!(
                result,
                system,
                CapabilityId::SystemStatus,
                DashboardComponentId::SystemStatus
            ),
            DashboardEvent::Battery(result) => apply!(
                result,
                battery,
                CapabilityId::BatteryStatus,
                DashboardComponentId::BatteryStatus
            ),
            DashboardEvent::Thermal(result) => apply!(
                result,
                thermal,
                CapabilityId::ThermalStatus,
                DashboardComponentId::ThermalStatus
            ),
            DashboardEvent::Signal(result) => apply!(
                *result,
                signal,
                CapabilityId::SignalStatus,
                DashboardComponentId::SignalStatus
            ),
            DashboardEvent::Cellular(result) => apply!(
                result,
                cellular,
                CapabilityId::CellularStatus,
                DashboardComponentId::CellularStatus
            ),
            DashboardEvent::Traffic(result) => apply!(
                result,
                traffic,
                CapabilityId::TrafficStatus,
                DashboardComponentId::TrafficStatus
            ),
            DashboardEvent::Wifi(result) => apply!(
                result,
                wifi,
                CapabilityId::WifiStatus,
                DashboardComponentId::WifiStatus
            ),
            DashboardEvent::LanClients(result) => apply!(
                result,
                lan_clients,
                CapabilityId::LanClients,
                DashboardComponentId::LanClients
            ),
            DashboardEvent::Sms(result) => apply!(
                result,
                sms,
                CapabilityId::SmsList,
                DashboardComponentId::SmsList
            ),
            DashboardEvent::Charging(result) => {
                self.charging_completed = true;
                match result {
                    Ok(value) => self.charging = Some(value),
                    Err(error) => self.failures.push(DashboardFailure {
                        component: DashboardComponentId::ChargingStatus,
                        error,
                    }),
                }
            }
        }
    }

    fn finish_timeouts(&mut self) {
        for (capability, component) in DASHBOARD_COMPONENTS {
            if self.outcomes.iter().any(|(id, _)| *id == capability) {
                continue;
            }
            let error = dashboard_timeout_error();
            self.outcomes.push((capability, Err(error.clone())));
            self.failures.push(DashboardFailure { component, error });
        }
        if !self.charging_completed {
            self.charging_completed = true;
            self.failures.push(DashboardFailure {
                component: DashboardComponentId::ChargingStatus,
                error: dashboard_timeout_error(),
            });
        }
    }

    fn finish(self) -> DashboardSnapshot {
        let report = dashboard_capability_report(&self.device, &self.outcomes);
        DashboardSnapshot {
            report,
            device: Some(self.device),
            system: self.system,
            battery: self.battery,
            thermal: self.thermal,
            signal: self.signal,
            cellular: self.cellular,
            traffic: self.traffic,
            wifi: self.wifi,
            lan_clients: self.lan_clients,
            sms: self.sms,
            charging: self.charging,
            failures: self.failures,
        }
    }
}

fn dashboard_capability_report(
    device: &DeviceDescriptor,
    outcomes: &[(CapabilityId, Result<(), AdapterError>)],
) -> CapabilityReport {
    let firmware_status = match device.firmware_version.as_deref() {
        Some(version) if version == device.firmware_target => CapabilityStatus::Available,
        None => CapabilityStatus::Degraded,
        Some(_) => CapabilityStatus::Unsupported,
    };
    let mut capabilities = Vec::with_capacity(DASHBOARD_COMPONENTS.len() + 1);
    capabilities.push(Capability {
        id: CapabilityId::DeviceIdentity,
        status: firmware_status,
        reason: (firmware_status != CapabilityStatus::Available)
            .then(|| "firmware identity did not prove the required target".into()),
        recovery: RecoveryMetadata {
            required: firmware_status != CapabilityStatus::Available,
            action: (firmware_status != CapabilityStatus::Available)
                .then(|| "verify the exact firmware build through the maintenance channel".into()),
        },
    });
    for (id, _) in DASHBOARD_COMPONENTS {
        let outcome = outcomes.iter().find(|(candidate, _)| *candidate == id);
        let (status, reason, recovery) = match outcome {
            Some((_, Ok(()))) if firmware_status == CapabilityStatus::Available => (
                CapabilityStatus::Available,
                None,
                RecoveryMetadata {
                    required: false,
                    action: None,
                },
            ),
            Some((_, Err(error))) => (
                if error.code == "unsupported" || error.code == "firmware_mismatch" {
                    CapabilityStatus::Unsupported
                } else {
                    CapabilityStatus::Degraded
                },
                Some(error.message.clone()),
                error.recovery.clone(),
            ),
            _ => (
                firmware_status,
                Some("firmware identity did not prove the required target".into()),
                RecoveryMetadata {
                    required: firmware_status != CapabilityStatus::Available,
                    action: (firmware_status != CapabilityStatus::Available).then(|| {
                        "verify the exact firmware build through the maintenance channel".into()
                    }),
                },
            ),
        };
        capabilities.push(Capability {
            id,
            status,
            reason,
            recovery,
        });
    }
    CapabilityReport {
        adapter: device.adapter,
        firmware_target: device.firmware_target,
        capabilities,
    }
}

fn dashboard_timeout_error() -> AdapterError {
    AdapterError {
        code: "snapshot_timeout",
        message: "dashboard snapshot budget elapsed before this component completed".into(),
        recovery: RecoveryMetadata {
            required: false,
            action: None,
        },
    }
}

fn daily_adapter_error(message: String) -> AdapterError {
    AdapterError {
        code: "source_unavailable",
        message,
        recovery: RecoveryMetadata {
            required: false,
            action: None,
        },
    }
}

pub fn system_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.system_status())
}

pub fn battery_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.battery_status())
}

pub fn thermal_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.thermal_status())
}

pub fn signal_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.signal_status())
}

pub fn cellular_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.cellular_status())
}

pub fn traffic_status(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.traffic_status())
}

pub fn wifi_status(state: &AppState, peer: IpAddr) -> (u16, Value) {
    adapter_result(state.adapter.wifi_status_for_peer(peer))
}

pub fn lan_clients(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.lan_clients())
}

pub fn sms_list(state: &AppState) -> (u16, Value) {
    adapter_result(state.adapter.sms_list(0, 100))
}

pub fn sms_send(state: &AppState, body: &[u8]) -> (u16, Value) {
    daily_request::<SmsSendRequest, _>(state, body, |service, request| service.sms_send(request))
}

pub fn charging_status(state: &AppState) -> (u16, Value) {
    daily_result(
        state
            .daily
            .as_ref()
            .ok_or_else(|| "daily management service is unavailable".to_string())
            .and_then(|service| service.charging_status()),
    )
}

pub fn traffic_cycle_update(state: &AppState, body: &[u8]) -> (u16, Value) {
    daily_request::<TrafficCycleRequest, _>(state, body, |service, request| {
        service.traffic_cycle_update(request)
    })
}

pub fn wifi_transaction_begin(state: &AppState, body: &[u8]) -> (u16, Value) {
    daily_request::<WifiTransactionRequest, _>(state, body, |service, request| {
        service.wifi_transaction_begin(request)
    })
}

pub fn wifi_master_update(state: &AppState, body: &[u8]) -> (u16, Value) {
    daily_request::<WifiMasterRequest, _>(state, body, |service, request| {
        service.wifi_master_update(request)
    })
}

pub fn wifi_transaction_confirm(state: &AppState, body: &[u8]) -> (u16, Value) {
    daily_request::<WifiConfirmRequest, _>(state, body, |service, request| {
        service.wifi_transaction_confirm(&request.transaction_id)
    })
}

fn daily_request<T: DeserializeOwned, R: Serialize>(
    state: &AppState,
    body: &[u8],
    operation: impl FnOnce(&crate::daily::DailyService, T) -> Result<R, String>,
) -> (u16, Value) {
    let request = match serde_json::from_slice::<T>(body) {
        Ok(request) => request,
        Err(_) => {
            return (
                400,
                json!({"ok": false, "error": {
                    "code": "invalid_request",
                    "message": "invalid request body",
                    "recovery": {"required": false}
                }}),
            )
        }
    };
    daily_result(
        state
            .daily
            .as_ref()
            .ok_or_else(|| "daily management service is unavailable".to_string())
            .and_then(|service| operation(service, request)),
    )
}

fn daily_result<T: Serialize>(result: Result<T, String>) -> (u16, Value) {
    match result {
        Ok(data) => success(data),
        Err(message) => {
            let invalid = message.starts_with("invalid ")
                || message.starts_with("SSID ")
                || message.starts_with("Wi-Fi passphrase ")
                || message.starts_with("recipient ")
                || message.starts_with("message ")
                || message.starts_with("limit_percent ")
                || message.starts_with("reset_day ")
                || message.starts_with("at least ")
                || message.starts_with("multi-band ")
                || message.starts_with("5 GHz SSID ");
            let conflict = message.contains("awaiting confirmation")
                || message.contains("deadline expired")
                || message.contains("identifier did not match");
            let (status, code) = if invalid {
                (400, "invalid_request")
            } else if conflict {
                (409, "state_conflict")
            } else {
                (503, "source_unavailable")
            };
            let recovery_required = message.contains("recovery is still pending")
                || message.contains("automatic rollback remains armed")
                || message.starts_with("another Wi-Fi transaction is awaiting confirmation")
                || message.starts_with("Wi-Fi transaction identifier did not match");
            let recovery = RecoveryMetadata {
                required: recovery_required,
                action: recovery_required.then(|| {
                    "retry confirmation before the deadline or allow automatic rollback".into()
                }),
            };
            (
                status,
                json!({"ok": false, "error": {"code": code, "message": message, "recovery": recovery}}),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::{Arc, Condvar, Mutex};
    use std::thread;

    use super::*;
    use crate::adapter::{
        BatteryStatus, Capability, CapabilityId, CapabilityReport, CapabilityStatus,
        CellularStatus, CurrentClientLink, DeviceAdapter, DeviceDescriptor, LanClients,
        RecoveryMetadata, SignalStatus, SmsPage, SystemStatus, ThermalStatus, TrafficStatus,
        WifiFeatureStatus, WifiStatus,
    };
    use crate::auth::AuthService;
    use crate::state_store::StateStore;

    struct StubAdapter {
        battery_delay: Duration,
        capability_calls: AtomicUsize,
        system_calls: AtomicUsize,
        first_system_gate: Option<Arc<FirstSystemGate>>,
    }

    #[derive(Default)]
    struct FirstSystemGate {
        started: AtomicBool,
        released: Mutex<bool>,
        release_changed: Condvar,
    }

    impl FirstSystemGate {
        fn block(&self) {
            self.started.store(true, Ordering::Release);
            let mut released = self
                .released
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            while !*released {
                released = self
                    .release_changed
                    .wait(released)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
            }
        }

        fn release(&self) {
            *self
                .released
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = true;
            self.release_changed.notify_all();
        }
    }

    struct FirstSystemGateRelease(Arc<FirstSystemGate>);

    impl Drop for FirstSystemGateRelease {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    impl Default for StubAdapter {
        fn default() -> Self {
            Self {
                battery_delay: Duration::ZERO,
                capability_calls: AtomicUsize::new(0),
                system_calls: AtomicUsize::new(0),
                first_system_gate: None,
            }
        }
    }

    impl DeviceAdapter for StubAdapter {
        fn device(&self) -> DeviceDescriptor {
            DeviceDescriptor {
                manufacturer: "ZTE",
                model: "MU5250",
                adapter: "stub-b04",
                firmware_target: "B04",
                firmware_version: Some("B04".into()),
                hardware_version: None,
            }
        }

        fn capabilities(&self) -> CapabilityReport {
            self.capability_calls.fetch_add(1, AtomicOrdering::Relaxed);
            CapabilityReport {
                adapter: "stub-b04",
                firmware_target: "B04",
                capabilities: [
                    CapabilityId::DeviceIdentity,
                    CapabilityId::SystemStatus,
                    CapabilityId::BatteryStatus,
                    CapabilityId::WifiStatus,
                ]
                .into_iter()
                .map(|id| Capability {
                    id,
                    status: CapabilityStatus::Available,
                    reason: None,
                    recovery: RecoveryMetadata {
                        required: false,
                        action: None,
                    },
                })
                .collect(),
            }
        }

        fn system_status(&self) -> Result<SystemStatus, AdapterError> {
            if self.system_calls.fetch_add(1, AtomicOrdering::Relaxed) == 0 {
                if let Some(gate) = &self.first_system_gate {
                    gate.block();
                }
            }
            Ok(SystemStatus {
                hostname: "u60".into(),
                uptime_seconds: 42,
                load_average: [0.1, 0.2, 0.3],
                kernel: "test".into(),
                cpu_usage_percent: None,
                memory_total_mb: None,
                memory_available_mb: None,
                memory_used_percent: None,
                storage_total_mb: None,
                storage_available_mb: None,
                storage_used_percent: None,
            })
        }

        fn battery_status(&self) -> Result<BatteryStatus, AdapterError> {
            thread::sleep(self.battery_delay);
            Err(AdapterError {
                code: "unsupported",
                message: "not present".into(),
                recovery: RecoveryMetadata {
                    required: false,
                    action: None,
                },
            })
        }

        fn thermal_status(&self) -> Result<ThermalStatus, AdapterError> {
            Ok(ThermalStatus { sensors: vec![] })
        }

        fn signal_status(&self) -> Result<SignalStatus, AdapterError> {
            Err(unsupported())
        }

        fn cellular_status(&self) -> Result<CellularStatus, AdapterError> {
            Err(unsupported())
        }

        fn traffic_status(&self) -> Result<TrafficStatus, AdapterError> {
            Err(unsupported())
        }

        fn wifi_status(&self) -> Result<WifiStatus, AdapterError> {
            Err(unsupported())
        }

        fn wifi_status_for_peer(&self, peer: IpAddr) -> Result<WifiStatus, AdapterError> {
            Ok(WifiStatus {
                enabled: true,
                bands: vec![],
                features: WifiFeatureStatus {
                    wifi7_active: false,
                    version_switch_reported_supported: false,
                    version_switch_state_available: false,
                    mlo_supported: false,
                    mlo_enabled: false,
                    band_steering_supported: false,
                    band_steering_enabled: false,
                },
                guest: None,
                current_client_link: Some(CurrentClientLink {
                    observation: "router_observed",
                    band: if peer.is_loopback() {
                        "loopback-test"
                    } else {
                        "peer-test"
                    },
                    signal_dbm: -67,
                    tx_bitrate_mbps: 100.0,
                    rx_bitrate_mbps: 80.0,
                    expected_throughput_mbps: Some(50.0),
                    connected_seconds: 12,
                }),
            })
        }

        fn lan_clients(&self) -> Result<LanClients, AdapterError> {
            Err(unsupported())
        }

        fn sms_list(&self, _page: u16, _per_page: u16) -> Result<SmsPage, AdapterError> {
            Err(unsupported())
        }
    }

    fn unsupported() -> AdapterError {
        AdapterError {
            code: "unsupported",
            message: "not present".into(),
            recovery: RecoveryMetadata {
                required: false,
                action: None,
            },
        }
    }

    fn state() -> (tempfile::TempDir, AppState) {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        (
            temp,
            AppState::with_adapter(auth, Arc::new(StubAdapter::default())),
        )
    }

    #[test]
    fn v1_device_is_stable_typed_shape() {
        let (_temp, state) = state();
        let (status, body) = device(&state);
        assert_eq!(status, 200);
        assert_eq!(body["data"]["model"], "MU5250");
        assert!(body["data"].get("secret").is_none());
    }

    #[test]
    fn unavailable_source_is_a_typed_error() {
        let (_temp, state) = state();
        let (status, body) = battery_status(&state);
        assert_eq!(status, 501);
        assert_eq!(body["error"]["code"], "unsupported");
        assert_eq!(body["error"]["recovery"]["required"], false);
    }

    #[test]
    fn degraded_source_is_a_service_unavailable_error() {
        let error = AdapterError {
            code: "source_unavailable",
            message: "temporarily unavailable".into(),
            recovery: RecoveryMetadata {
                required: true,
                action: Some("check the fixed read-only source".into()),
            },
        };
        let (status, body) = adapter_result::<SystemStatus>(Err(error));
        assert_eq!(status, 503);
        assert_eq!(body["error"]["code"], "source_unavailable");
        assert_eq!(body["error"]["recovery"]["required"], true);
    }

    #[test]
    fn daily_wifi_errors_distinguish_completed_rollback_from_pending_recovery() {
        let (status, rolled_back) = daily_result::<crate::daily::WriteResult>(Err(
            "Wi-Fi transaction was rolled back: readback mismatch".into(),
        ));
        assert_eq!(status, 503);
        assert_eq!(rolled_back["error"]["recovery"]["required"], false);

        let (status, pending) = daily_result::<crate::daily::WriteResult>(Err(
            "Wi-Fi apply failed and recovery is still pending: reload failed".into(),
        ));
        assert_eq!(status, 503);
        assert_eq!(pending["error"]["recovery"]["required"], true);
    }

    #[test]
    fn malformed_daily_request_has_terminal_recovery_metadata() {
        let (_temp, state) = state();
        let (status, body) = wifi_transaction_begin(&state, b"{");
        assert_eq!(status, 400);
        assert_eq!(body["error"]["code"], "invalid_request");
        assert_eq!(body["error"]["recovery"]["required"], false);
    }

    #[tokio::test]
    async fn dashboard_preserves_partial_success_and_request_peer_context() {
        let (_temp, state) = state();
        let (status, body) = dashboard(state, "127.0.0.1".parse().unwrap()).await;
        assert_eq!(status, 200);
        assert_eq!(body["data"]["system"]["hostname"], "u60");
        assert!(body["data"].get("battery").is_none());
        assert_eq!(
            body["data"]["wifi"]["current_client_link"]["band"],
            "loopback-test"
        );
        let failures = body["data"]["failures"].as_array().unwrap();
        assert!(failures.iter().any(|failure| {
            failure["component"] == "battery_status" && failure["error"]["code"] == "unsupported"
        }));
        assert!(failures
            .iter()
            .any(|failure| failure["component"] == "charging_status"));
    }

    #[tokio::test]
    async fn dashboard_returns_completed_components_within_one_budget_without_reprobing() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        let adapter = Arc::new(StubAdapter {
            battery_delay: Duration::from_millis(150),
            capability_calls: AtomicUsize::new(0),
            system_calls: AtomicUsize::new(0),
            first_system_gate: None,
        });
        let state = AppState::with_adapter(auth, adapter.clone());

        let started = tokio::time::Instant::now();
        let (status, body) = dashboard_with_budget(
            state,
            "127.0.0.1".parse().unwrap(),
            Duration::from_millis(30),
        )
        .await;

        assert_eq!(status, 200);
        assert!(started.elapsed() < Duration::from_millis(100));
        assert_eq!(body["data"]["system"]["hostname"], "u60");
        assert!(body["data"].get("battery").is_none());
        assert!(body["data"]["failures"]
            .as_array()
            .unwrap()
            .iter()
            .any(|failure| failure["error"]["code"] == "snapshot_timeout"));
        assert_eq!(adapter.capability_calls.load(AtomicOrdering::Relaxed), 0);
    }

    #[tokio::test]
    async fn overlapping_dashboard_requests_do_not_queue_background_workers() {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        let first_system_gate = Arc::new(FirstSystemGate::default());
        let _release_first_system_gate = FirstSystemGateRelease(Arc::clone(&first_system_gate));
        let adapter = Arc::new(StubAdapter {
            battery_delay: Duration::ZERO,
            capability_calls: AtomicUsize::new(0),
            system_calls: AtomicUsize::new(0),
            first_system_gate: Some(Arc::clone(&first_system_gate)),
        });
        let state = AppState::with_adapter(auth, adapter.clone());
        let peer = "127.0.0.1".parse().unwrap();

        let first_state = state.clone();
        let first = tokio::spawn(async move {
            dashboard_with_budget(first_state, peer, Duration::from_millis(20)).await
        });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !first_system_gate.started.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("first dashboard worker did not enter its source");
        let first_response = first.await.unwrap();

        let lifecycle_adapter = Arc::new(StubAdapter::default());
        let lifecycle_adapter_weak = Arc::downgrade(&lifecycle_adapter);
        let lifecycle_state = AppState {
            auth: Arc::clone(&state.auth),
            adapter: lifecycle_adapter.clone(),
            daily: None,
            dashboard_admission: Arc::clone(&state.dashboard_admission),
        };
        drop(lifecycle_adapter);
        let lifecycle_response =
            dashboard_with_budget(lifecycle_state, peer, Duration::from_millis(20)).await;
        let lifecycle_released_before_worker_exit = lifecycle_adapter_weak.upgrade().is_none();

        let mut burst = Vec::new();
        for _ in 0..16 {
            let burst_state = state.clone();
            burst.push(tokio::spawn(async move {
                dashboard_with_budget(burst_state, peer, Duration::from_millis(20)).await
            }));
        }
        let mut burst_responses = Vec::with_capacity(burst.len());
        for request in burst {
            burst_responses.push(request.await.unwrap());
        }
        let source_calls_before_release = adapter.system_calls.load(AtomicOrdering::Relaxed);

        first_system_gate.release();
        let recovered = tokio::time::timeout(
            Duration::from_secs(1),
            dashboard_with_budget(state.clone(), peer, Duration::from_millis(500)),
        )
        .await
        .expect("dashboard admission did not recover after the worker exited");

        assert_eq!(first_response.0, 200);
        assert!(first_response.1["data"]["failures"]
            .as_array()
            .unwrap()
            .iter()
            .any(|failure| failure["error"]["code"] == "snapshot_timeout"));
        assert_eq!(lifecycle_response.0, 200);
        assert!(lifecycle_response.1["data"]["failures"]
            .as_array()
            .unwrap()
            .iter()
            .all(|failure| failure["error"]["code"] == "snapshot_timeout"));
        assert!(
            lifecycle_released_before_worker_exit,
            "a timed-out request retained its adapter behind the active worker"
        );
        assert_eq!(source_calls_before_release, 1);
        for (status, body) in burst_responses {
            assert_eq!(status, 200);
            assert_eq!(body["data"]["device"]["model"], "MU5250");
            let failures = body["data"]["failures"].as_array().unwrap();
            assert_eq!(failures.len(), DASHBOARD_COMPONENTS.len() + 1);
            assert!(failures
                .iter()
                .all(|failure| failure["error"]["code"] == "snapshot_timeout"));
            assert_eq!(
                failures
                    .iter()
                    .filter_map(|failure| failure["component"].as_str())
                    .collect::<HashSet<_>>()
                    .len(),
                DASHBOARD_COMPONENTS.len() + 1
            );
        }
        assert_eq!(recovered.0, 200);
        assert_eq!(recovered.1["data"]["system"]["hostname"], "u60");
        assert_eq!(adapter.system_calls.load(AtomicOrdering::Relaxed), 2);
    }
}
