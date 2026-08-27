mod adapter;
mod api_v1;
mod auth;
mod b04_io;
mod daily;
mod handlers;
mod server;
mod stability_monitor;
mod state_store;
mod util;

use std::io::Read;
use std::net::{SocketAddr, TcpListener};
use std::path::PathBuf;

use auth::{AuthFailure, AuthService};
use handlers::AppState;
use state_store::StateStore;

const DEFAULT_BIND: &str = "127.0.0.1:19443";
const DEFAULT_STATE_ROOT: &str = "/data/u60/state";

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("zte-agent: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let mut arguments = std::env::args().skip(1);
    let command = arguments.next().unwrap_or_else(|| "serve".into());
    match command.as_str() {
        "serve" => {
            let web_root = parse_web_root(arguments)?;
            serve(web_root).await
        }
        "password-set" => {
            no_more_arguments(arguments)?;
            password_set()
        }
        "pair-open" => {
            no_more_arguments(arguments)?;
            pair_open()
        }
        "credential-list" => {
            no_more_arguments(arguments)?;
            credential_list()
        }
        "credential-revoke" => {
            let id = arguments
                .next()
                .ok_or_else(|| "credential-revoke requires an ID".to_string())?;
            no_more_arguments(arguments)?;
            credential_revoke(&id)
        }
        "wifi-rollback-after" => {
            let id = arguments
                .next()
                .ok_or_else(|| "wifi-rollback-after requires an ID".to_string())?;
            let seconds = arguments
                .next()
                .ok_or_else(|| "wifi-rollback-after requires a delay".to_string())?
                .parse::<u64>()
                .map_err(|_| "wifi rollback delay is invalid".to_string())?;
            no_more_arguments(arguments)?;
            wifi_rollback_after(&id, seconds)
        }
        _ => Err(
            "usage: zte-agent [serve [--web-root DIR]|password-set|pair-open|credential-list|credential-revoke ID]".into(),
        ),
    }
}

async fn serve(web_root: Option<PathBuf>) -> Result<(), String> {
    let certificate_path = required_environment("U60_TLS_CERT_PEM")?;
    let private_key_path = required_environment("U60_TLS_KEY_PEM")?;
    // Validate TLS before creating or reading service state. There is
    // deliberately no plaintext listener or certificate-generation path.
    let tls = server::load_tls_config(certificate_path, private_key_path)?;
    let bind = std::env::var("U60_BIND").unwrap_or_else(|_| DEFAULT_BIND.into());
    let bind = bind
        .parse::<SocketAddr>()
        .map_err(|error| format!("invalid U60_BIND: {error}"))?;
    let web_root = web_root.map(server::StaticWebRoot::load).transpose()?;
    let listener = TcpListener::bind(bind)
        .map_err(|error| format!("HTTPS listener failed to bind: {error}"))?;
    listener
        .set_nonblocking(true)
        .map_err(|error| format!("HTTPS listener failed to enter nonblocking mode: {error}"))?;
    let store = StateStore::open(state_root())?;
    let auth = AuthService::open(store.clone())?;
    let daily = daily::DailyService::open(store.clone())?;
    if let Err(error) = stability_monitor::start(store) {
        eprintln!("[stability-monitor] disabled: {error}");
    }
    let state = AppState::with_daily(auth, daily);
    server::start(listener, state, tls, web_root)
        .await
        .map_err(|error| format!("HTTPS listener failed: {error}"))
}

fn parse_web_root(mut arguments: impl Iterator<Item = String>) -> Result<Option<PathBuf>, String> {
    let Some(flag) = arguments.next() else {
        return Ok(None);
    };
    if flag != "--web-root" {
        return Err("serve accepts only --web-root DIR".into());
    }
    let root = arguments
        .next()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "--web-root requires a directory".to_string())?;
    no_more_arguments(arguments)?;
    Ok(Some(root))
}

fn password_set() -> Result<(), String> {
    let mut password = String::new();
    std::io::stdin()
        .read_to_string(&mut password)
        .map_err(|error| format!("read password from stdin: {error}"))?;
    while password.ends_with(['\r', '\n']) {
        password.pop();
    }
    open_auth()?
        .set_password(&password)
        .map_err(cli_auth_error)?;
    println!("password verifier updated");
    Ok(())
}

fn pair_open() -> Result<(), String> {
    let grant = open_auth()?.open_pairing_window().map_err(cli_auth_error)?;
    println!(
        "{}",
        serde_json::to_string(&grant)
            .map_err(|error| format!("serialize pairing window: {error}"))?
    );
    Ok(())
}

fn credential_list() -> Result<(), String> {
    let credentials = open_auth()?.list_credentials();
    println!(
        "{}",
        serde_json::to_string(&credentials)
            .map_err(|error| format!("serialize credential list: {error}"))?
    );
    Ok(())
}

fn credential_revoke(id: &str) -> Result<(), String> {
    if !open_auth()?.revoke_credential(id).map_err(cli_auth_error)? {
        return Err("credential not found".into());
    }
    println!("credential revoked");
    Ok(())
}

fn open_auth() -> Result<AuthService, String> {
    AuthService::open(StateStore::open(state_root())?)
}

fn state_root() -> PathBuf {
    std::env::var_os("U60_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_STATE_ROOT))
}

fn wifi_rollback_after(id: &str, seconds: u64) -> Result<(), String> {
    if seconds == 0 || seconds > 300 {
        return Err("wifi rollback delay must be between 1 and 300 seconds".into());
    }
    std::thread::sleep(std::time::Duration::from_secs(seconds));
    let store = StateStore::open(state_root())?;
    let _ = daily::DailyService::run_wifi_rollback_worker(store, id)?;
    Ok(())
}

fn required_environment(name: &str) -> Result<PathBuf, String> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| format!("{name} must name an existing PEM file"))
}

fn no_more_arguments(mut arguments: impl Iterator<Item = String>) -> Result<(), String> {
    if arguments.next().is_some() {
        Err("unexpected command-line argument".into())
    } else {
        Ok(())
    }
}

fn cli_auth_error(error: AuthFailure) -> String {
    match error {
        AuthFailure::InvalidInput(message) => message.into(),
        AuthFailure::NotConfigured => "password authentication is not configured".into(),
        AuthFailure::Unauthorized => "authentication failed".into(),
        AuthFailure::Forbidden => "operation is not permitted".into(),
        AuthFailure::Locked { .. } => "authentication is temporarily locked".into(),
        AuthFailure::Internal(error) => format!("authentication state failure: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serve_web_root_is_explicit_and_strict() {
        assert_eq!(
            parse_web_root(Vec::<String>::new().into_iter()).unwrap(),
            None
        );
        assert_eq!(
            parse_web_root(["--web-root".to_string(), "web-app/dist".to_string()].into_iter())
                .unwrap(),
            Some(PathBuf::from("web-app/dist"))
        );
        assert!(parse_web_root(["web-app/dist".to_string()].into_iter()).is_err());
        assert!(parse_web_root(["--web-root".to_string()].into_iter()).is_err());
        assert!(parse_web_root(
            [
                "--web-root".to_string(),
                "one".to_string(),
                "--web-root".to_string(),
                "two".to_string(),
            ]
            .into_iter()
        )
        .is_err());
    }
}
