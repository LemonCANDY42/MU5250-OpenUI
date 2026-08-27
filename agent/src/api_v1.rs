use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::net::IpAddr;

use crate::adapter::AdapterError;
use crate::daily::{
    SmsSendRequest, TrafficCycleRequest, WifiConfirmRequest, WifiTransactionRequest,
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
                json!({"ok": false, "error": {"code": "invalid_request", "message": "invalid request body"}}),
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
                || message.starts_with("at least ");
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
            (
                status,
                json!({"ok": false, "error": {"code": code, "message": message}}),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::adapter::{
        BatteryStatus, Capability, CapabilityId, CapabilityReport, CapabilityStatus,
        CellularStatus, DeviceAdapter, DeviceDescriptor, LanClients, RecoveryMetadata,
        SignalStatus, SmsPage, SystemStatus, ThermalStatus, TrafficStatus, WifiStatus,
    };
    use crate::auth::AuthService;
    use crate::state_store::StateStore;

    struct StubAdapter;

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
            CapabilityReport {
                adapter: "stub-b04",
                firmware_target: "B04",
                capabilities: vec![Capability {
                    id: CapabilityId::SystemStatus,
                    status: CapabilityStatus::Available,
                    reason: None,
                    recovery: RecoveryMetadata {
                        required: false,
                        action: None,
                    },
                }],
            }
        }

        fn system_status(&self) -> Result<SystemStatus, AdapterError> {
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
        (temp, AppState::with_adapter(auth, Arc::new(StubAdapter)))
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
}
