use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::adapter::{B04Adapter, DeviceAdapter};
use crate::auth::{AuthFailure, AuthService};
use crate::daily::DailyService;

pub struct AppState {
    pub auth: Arc<AuthService>,
    pub adapter: Arc<dyn DeviceAdapter>,
    pub daily: Option<Arc<DailyService>>,
    pub dashboard_guard: Arc<Mutex<()>>,
}

impl Clone for AppState {
    fn clone(&self) -> Self {
        Self {
            auth: Arc::clone(&self.auth),
            adapter: Arc::clone(&self.adapter),
            daily: self.daily.as_ref().map(Arc::clone),
            dashboard_guard: Arc::clone(&self.dashboard_guard),
        }
    }
}

impl AppState {
    #[cfg(test)]
    pub fn new(auth: AuthService) -> Self {
        Self::with_adapter(auth, Arc::new(B04Adapter::new()))
    }

    #[cfg(test)]
    pub fn with_adapter(auth: AuthService, adapter: Arc<dyn DeviceAdapter>) -> Self {
        Self {
            auth: Arc::new(auth),
            adapter,
            daily: None,
            dashboard_guard: Arc::new(Mutex::new(())),
        }
    }

    pub fn with_daily(auth: AuthService, daily: DailyService) -> Self {
        Self {
            auth: Arc::new(auth),
            adapter: Arc::new(B04Adapter::new()),
            daily: Some(Arc::new(daily)),
            dashboard_guard: Arc::new(Mutex::new(())),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasswordRequest {
    password: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChallengeRequest {
    credential_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChallengeVerifyRequest {
    credential_id: String,
    challenge_id: String,
    signature: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairRequest {
    pairing_nonce: String,
    label: String,
    public_key_spki: String,
}

pub fn password_session(state: &AppState, body: &[u8], client_ip: &str) -> (u16, Value) {
    parse::<PasswordRequest>(body)
        .and_then(|request| {
            state
                .auth
                .password_session(&request.password, client_ip)
                .map(success)
        })
        .unwrap_or_else(failure)
}

pub fn advanced_session(state: &AppState, body: &[u8], client_ip: &str) -> (u16, Value) {
    parse::<PasswordRequest>(body)
        .and_then(|request| {
            state
                .auth
                .advanced_session(&request.password, client_ip)
                .map(success)
        })
        .unwrap_or_else(failure)
}

pub fn challenge(state: &AppState, body: &[u8], client_ip: &str) -> (u16, Value) {
    parse::<ChallengeRequest>(body)
        .and_then(|request| {
            state
                .auth
                .create_challenge(&request.credential_id, client_ip)
                .map(success)
        })
        .unwrap_or_else(failure)
}

pub fn challenge_verify(state: &AppState, body: &[u8], client_ip: &str) -> (u16, Value) {
    parse::<ChallengeVerifyRequest>(body)
        .and_then(|request| {
            state
                .auth
                .verify_challenge(
                    &request.credential_id,
                    &request.challenge_id,
                    &request.signature,
                    client_ip,
                )
                .map(success)
        })
        .unwrap_or_else(failure)
}

pub fn pair(state: &AppState, body: &[u8], client_ip: &str) -> (u16, Value) {
    parse::<PairRequest>(body)
        .and_then(|request| {
            state
                .auth
                .register_credential(
                    &request.pairing_nonce,
                    &request.label,
                    &request.public_key_spki,
                    client_ip,
                )
                .map(success)
        })
        .unwrap_or_else(failure)
}

fn parse<T: for<'de> Deserialize<'de>>(body: &[u8]) -> Result<T, AuthFailure> {
    serde_json::from_slice(body).map_err(|_| AuthFailure::InvalidInput("invalid request body"))
}

fn success<T: serde::Serialize>(data: T) -> (u16, Value) {
    (
        200,
        serde_json::to_value(json!({"ok": true, "data": data})).unwrap_or_else(|_| {
            json!({"ok": false, "error": {"code": "internal_error", "message": "internal authentication error"}})
        }),
    )
}

pub fn failure(error: AuthFailure) -> (u16, Value) {
    let (status, code, message, retry_after) = match error {
        AuthFailure::Unauthorized => (401, "authentication_failed", "authentication failed", None),
        AuthFailure::Forbidden => (403, "insufficient_scope", "insufficient scope", None),
        AuthFailure::Locked {
            retry_after_seconds,
        } => (
            429,
            "temporarily_locked",
            "authentication temporarily locked",
            Some(retry_after_seconds),
        ),
        AuthFailure::InvalidInput(message) => (400, "invalid_request", message, None),
        AuthFailure::NotConfigured => (
            503,
            "password_not_configured",
            "password authentication is not configured",
            None,
        ),
        AuthFailure::Internal(error) => {
            eprintln!("[auth] internal failure: {error}");
            (500, "internal_error", "internal authentication error", None)
        }
    };
    let mut error = json!({"code": code, "message": message});
    if let Some(seconds) = retry_after {
        error["retry_after_seconds"] = json!(seconds);
    }
    (status, json!({"ok": false, "error": error}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state_store::StateStore;

    fn state() -> (tempfile::TempDir, AppState) {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        (temp, AppState::new(auth))
    }

    #[test]
    fn malformed_auth_json_is_typed_and_redacted() {
        let (_temp, state) = state();
        let (status, body) = password_session(&state, br#"{"password":7}"#, "127.0.0.1");
        assert_eq!(status, 400);
        assert_eq!(body["error"]["code"], "invalid_request");
        assert!(!body.to_string().contains("password\":7"));
    }
}
