use std::collections::HashMap;
use std::fs;
use std::io::Cursor;
use std::net::{SocketAddr, TcpListener};
use std::path::Path;
use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::rejection::BytesRejection;
use axum::extract::{ConnectInfo, DefaultBodyLimit, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL, CONTENT_TYPE, HOST, ORIGIN, RETRY_AFTER};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post, put};
use axum::{Extension, Json, Router};
use axum_server::tls_rustls::RustlsConfig;
use serde_json::{json, Value};

use crate::api_v1;
use crate::auth::{AuthFailure, Scope};
use crate::handlers::{self, AppState};

const MAX_AUTH_BODY_BYTES: usize = 64 * 1024;
const CONTENT_SECURITY_POLICY_VALUE: &str = "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

#[derive(Clone)]
pub struct StaticWebRoot {
    assets: Arc<HashMap<String, StaticAsset>>,
}

#[derive(Clone)]
struct StaticAsset {
    content: Bytes,
    content_type: &'static str,
}

impl StaticWebRoot {
    pub fn load(root: impl AsRef<Path>) -> Result<Self, String> {
        let root = root.as_ref();
        let metadata = fs::symlink_metadata(root)
            .map_err(|error| format!("read web root metadata: {error}"))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err("web root must be a real directory, not a symlink".into());
        }
        let root = root
            .canonicalize()
            .map_err(|error| format!("canonicalize web root: {error}"))?;
        reject_symlinks(&root)?;

        let mut assets = HashMap::new();
        add_static_asset(&root, &root.join("index.html"), "/", &mut assets)?;
        add_static_asset(&root, &root.join("index.html"), "/index.html", &mut assets)?;
        for name in ["favicon.ico", "favicon.svg", "manifest.json"] {
            let path = root.join(name);
            if path.exists() {
                add_static_asset(&root, &path, &format!("/{name}"), &mut assets)?;
            }
        }
        let asset_root = root.join("assets");
        if asset_root.exists() {
            collect_static_assets(&root, &asset_root, &mut assets)?;
        }

        Ok(Self {
            assets: Arc::new(assets),
        })
    }

    fn response(&self, path: &str, head_only: bool) -> Option<Response> {
        let asset = self.assets.get(path)?;
        let body = if head_only {
            Body::empty()
        } else {
            Body::from(asset.content.clone())
        };
        Some(
            (
                StatusCode::OK,
                [(CONTENT_TYPE, HeaderValue::from_static(asset.content_type))],
                body,
            )
                .into_response(),
        )
    }
}

fn reject_symlinks(path: &Path) -> Result<(), String> {
    for entry in fs::read_dir(path).map_err(|error| format!("scan web root: {error}"))? {
        let entry = entry.map_err(|error| format!("scan web root entry: {error}"))?;
        let metadata = fs::symlink_metadata(entry.path())
            .map_err(|error| format!("read web asset metadata: {error}"))?;
        if metadata.file_type().is_symlink() {
            return Err("web root must not contain symlinks".into());
        }
        if metadata.is_dir() {
            reject_symlinks(&entry.path())?;
        }
    }
    Ok(())
}

fn collect_static_assets(
    root: &Path,
    directory: &Path,
    assets: &mut HashMap<String, StaticAsset>,
) -> Result<(), String> {
    let metadata = fs::symlink_metadata(directory)
        .map_err(|error| format!("read web assets directory metadata: {error}"))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err("web assets path must be a real directory".into());
    }
    for entry in fs::read_dir(directory).map_err(|error| format!("scan web assets: {error}"))? {
        let entry = entry.map_err(|error| format!("scan web asset entry: {error}"))?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)
            .map_err(|error| format!("read web asset metadata: {error}"))?;
        if metadata.is_dir() {
            collect_static_assets(root, &path, assets)?;
            continue;
        }
        if !metadata.is_file() || content_type(&path).is_none() {
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .map_err(|_| "web asset escaped the canonical root".to_string())?;
        let relative = relative
            .to_str()
            .ok_or_else(|| "web asset path must be valid UTF-8".to_string())?;
        if relative.contains(['\\', '\0']) {
            return Err("web asset path contains an invalid character".into());
        }
        add_static_asset(root, &path, &format!("/{relative}"), assets)?;
    }
    Ok(())
}

fn add_static_asset(
    root: &Path,
    path: &Path,
    url_path: &str,
    assets: &mut HashMap<String, StaticAsset>,
) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("read required web asset metadata: {error}"))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("web assets must be real regular files".into());
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("canonicalize web asset: {error}"))?;
    if !canonical.starts_with(root) {
        return Err("web asset escaped the canonical root".into());
    }
    let content_type = content_type(&canonical)
        .ok_or_else(|| "web asset has an unsupported content type".to_string())?;
    let content = fs::read(&canonical).map_err(|error| format!("read web asset: {error}"))?;
    assets.insert(
        url_path.to_owned(),
        StaticAsset {
            content: Bytes::from(content),
            content_type,
        },
    );
    Ok(())
}

fn content_type(path: &Path) -> Option<&'static str> {
    match path.extension().and_then(|extension| extension.to_str())? {
        "html" => Some("text/html; charset=utf-8"),
        "css" => Some("text/css; charset=utf-8"),
        "js" => Some("text/javascript; charset=utf-8"),
        "json" => Some("application/json; charset=utf-8"),
        "svg" => Some("image/svg+xml"),
        "ico" => Some("image/x-icon"),
        "png" => Some("image/png"),
        "webp" => Some("image/webp"),
        "woff" => Some("font/woff"),
        "woff2" => Some("font/woff2"),
        _ => None,
    }
}

pub fn router_with_web_root(state: AppState, web_root: Option<StaticWebRoot>) -> Router {
    Router::new()
        .route("/v1/device", get(device))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/status/system", get(system_status))
        .route("/v1/status/battery", get(battery_status))
        .route("/v1/status/thermal", get(thermal_status))
        .route("/v1/status/signal", get(signal_status))
        .route("/v1/status/cellular", get(cellular_status))
        .route("/v1/status/traffic", get(traffic_status))
        .route("/v1/status/wifi", get(wifi_status))
        .route("/v1/lan/clients", get(lan_clients))
        .route("/v1/sms", get(sms_list))
        .route("/v1/sms/send", post(sms_send))
        .route("/v1/charging", get(charging_status))
        .route("/v1/traffic/cycle", put(traffic_cycle_update))
        .route("/v1/wifi/transaction", post(wifi_transaction_begin))
        .route(
            "/v1/wifi/transaction/confirm",
            post(wifi_transaction_confirm),
        )
        .route("/v1/auth/password/session", post(password_session))
        .route("/v1/auth/password/advanced", post(advanced_session))
        .route("/v1/auth/challenge", post(challenge))
        .route("/v1/auth/challenge/verify", post(challenge_verify))
        .route("/v1/auth/pair", post(pair))
        .fallback(static_or_not_found)
        .layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES))
        .layer(middleware::from_fn(require_same_origin))
        .layer(Extension(web_root))
        .with_state(state)
}

pub fn load_tls_config(
    certificate_path: impl AsRef<Path>,
    private_key_path: impl AsRef<Path>,
) -> Result<RustlsConfig, String> {
    let certificate_pem = fs::read(certificate_path.as_ref())
        .map_err(|error| format!("read TLS certificate PEM: {error}"))?;
    let private_key_pem = fs::read(private_key_path.as_ref())
        .map_err(|error| format!("read TLS private-key PEM: {error}"))?;
    if certificate_pem.is_empty() || private_key_pem.is_empty() {
        return Err("TLS certificate and private-key PEM files must not be empty".into());
    }

    let certificates = rustls_pemfile::certs(&mut Cursor::new(certificate_pem))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("parse TLS certificate PEM: {error}"))?;
    if certificates.is_empty() {
        return Err("TLS certificate PEM contains no certificates".into());
    }
    let private_key = rustls_pemfile::private_key(&mut Cursor::new(private_key_pem))
        .map_err(|error| format!("parse TLS private-key PEM: {error}"))?
        .ok_or_else(|| "TLS private-key PEM contains no private key".to_string())?;

    // Explicit current RustCrypto provider and TLS 1.3-only profile. This
    // avoids tiny_http's rustls 0.20 integration (RUSTSEC-2024-0336).
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|error| format!("configure TLS 1.3: {error}"))?
        .with_no_client_auth()
        .with_single_cert(certificates, private_key)
        .map_err(|error| format!("configure TLS certificate: {error}"))?;
    Ok(RustlsConfig::from_config(Arc::new(config)))
}

pub async fn start(
    listener: TcpListener,
    state: AppState,
    tls: RustlsConfig,
    web_root: Option<StaticWebRoot>,
) -> Result<(), std::io::Error> {
    axum_server::from_tcp_rustls(listener, tls)?
        .serve(
            router_with_web_root(state, web_root)
                .into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
}

async fn device(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || api_v1::device(&state))
}

async fn capabilities(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::capabilities(&state)
    })
}

async fn system_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::system_status(&state)
    })
}

async fn battery_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::battery_status(&state)
    })
}

async fn thermal_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::thermal_status(&state)
    })
}

async fn signal_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::signal_status(&state)
    })
}

async fn cellular_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::cellular_status(&state)
    })
}

async fn traffic_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::traffic_status(&state)
    })
}

async fn wifi_status(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::wifi_status(&state, peer.ip())
    })
}

async fn lan_clients(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::lan_clients(&state)
    })
}

async fn sms_list(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || api_v1::sms_list(&state))
}

async fn sms_send(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    protected_body(&state, &headers, Scope::Daily, body, |body| {
        api_v1::sms_send(&state, body)
    })
}

async fn charging_status(State(state): State<AppState>, headers: HeaderMap) -> Response {
    protected(&state, &headers, Scope::Read, || {
        api_v1::charging_status(&state)
    })
}

async fn traffic_cycle_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    protected_body(&state, &headers, Scope::Daily, body, |body| {
        api_v1::traffic_cycle_update(&state, body)
    })
}

async fn wifi_transaction_begin(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    protected_body(&state, &headers, Scope::Daily, body, |body| {
        api_v1::wifi_transaction_begin(&state, body)
    })
}

async fn wifi_transaction_confirm(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    protected_body(&state, &headers, Scope::Daily, body, |body| {
        api_v1::wifi_transaction_confirm(&state, body)
    })
}

async fn password_session(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(handlers::password_session(
        &state,
        &body,
        &peer.ip().to_string(),
    ))
}

async fn advanced_session(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    if let Err(error) = authorize(&state, &headers, Scope::Admin) {
        return value_response(handlers::failure(error));
    }
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(handlers::advanced_session(
        &state,
        &body,
        &peer.ip().to_string(),
    ))
}

async fn challenge(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(handlers::challenge(&state, &body, &peer.ip().to_string()))
}

async fn challenge_verify(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(handlers::challenge_verify(
        &state,
        &body,
        &peer.ip().to_string(),
    ))
}

async fn pair(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(handlers::pair(&state, &body, &peer.ip().to_string()))
}

fn auth_body(body: Result<Bytes, BytesRejection>) -> Result<Bytes, (u16, Value)> {
    body.map_err(|rejection| {
        let status = if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
            413
        } else {
            400
        };
        (
            status,
            json!({"ok": false, "error": {"code": "invalid_request", "message": "invalid request body"}}),
        )
    })
}

fn protected(
    state: &AppState,
    headers: &HeaderMap,
    scope: Scope,
    operation: impl FnOnce() -> (u16, Value),
) -> Response {
    match authorize(state, headers, scope) {
        Ok(()) => value_response(operation()),
        Err(error) => value_response(handlers::failure(error)),
    }
}

fn protected_body(
    state: &AppState,
    headers: &HeaderMap,
    scope: Scope,
    body: Result<Bytes, BytesRejection>,
    operation: impl FnOnce(&[u8]) -> (u16, Value),
) -> Response {
    if let Err(error) = authorize(state, headers, scope) {
        return value_response(handlers::failure(error));
    }
    let body = match auth_body(body) {
        Ok(body) => body,
        Err(error) => return value_response(error),
    };
    value_response(operation(&body))
}

fn authorize(state: &AppState, headers: &HeaderMap, scope: Scope) -> Result<(), AuthFailure> {
    let token = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|token| !token.is_empty())
        .ok_or(AuthFailure::Unauthorized)?;
    state.auth.validate_token(token, scope)
}

async fn require_same_origin(request: Request<axum::body::Body>, next: Next) -> Response {
    if let Some(origin) = request.headers().get(ORIGIN) {
        let origin = origin.to_str().ok();
        let host = request
            .headers()
            .get(HOST)
            .and_then(|value| value.to_str().ok());
        if !matches!((origin, host), (Some(origin), Some(host)) if same_origin(origin, host)) {
            return secure_response(value_response((
                403,
                json!({"ok": false, "error": {"code": "origin_forbidden", "message": "cross-origin requests are not allowed"}}),
            )));
        }
    }
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        CACHE_CONTROL,
        "no-store".parse().expect("static cache-control header"),
    );
    secure_response(response)
}

fn same_origin(origin: &str, host: &str) -> bool {
    origin
        .strip_prefix("https://")
        .and_then(|value| value.split('/').next())
        .is_some_and(|authority| authority.eq_ignore_ascii_case(host))
}

async fn static_or_not_found(
    Extension(web_root): Extension<Option<StaticWebRoot>>,
    request: Request<Body>,
) -> Response {
    let path = request.uri().path();
    let is_v1 = path == "/v1" || path.starts_with("/v1/");
    if !is_v1 && matches!(request.method(), &Method::GET | &Method::HEAD) {
        if let Some(response) = web_root
            .as_ref()
            .and_then(|root| root.response(path, request.method() == Method::HEAD))
        {
            return response;
        }
    }
    value_response((
        404,
        json!({"ok": false, "error": {"code": "not_found", "message": "not found"}}),
    ))
}

fn secure_response(mut response: Response) -> Response {
    for (name, value) in [
        (
            HeaderName::from_static("content-security-policy"),
            HeaderValue::from_static(CONTENT_SECURITY_POLICY_VALUE),
        ),
        (
            HeaderName::from_static("x-content-type-options"),
            HeaderValue::from_static("nosniff"),
        ),
        (
            HeaderName::from_static("referrer-policy"),
            HeaderValue::from_static("no-referrer"),
        ),
        (
            HeaderName::from_static("x-frame-options"),
            HeaderValue::from_static("DENY"),
        ),
    ] {
        response.headers_mut().insert(name, value);
    }
    response
}

fn value_response((status, body): (u16, Value)) -> Response {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let retry_after = body
        .pointer("/error/retry_after_seconds")
        .and_then(Value::as_u64);
    let mut response = (status, Json(body)).into_response();
    response.headers_mut().insert(
        CACHE_CONTROL,
        "no-store".parse().expect("static cache-control header"),
    );
    if let Some(seconds) = retry_after {
        if let Ok(value) = seconds.to_string().parse() {
            response.headers_mut().insert(RETRY_AFTER, value);
        }
    }
    response
}

#[cfg(test)]
mod tests {
    use axum::body::{to_bytes, Body};
    use axum::http::{Method, Request};
    use tower::ServiceExt;

    use super::*;
    use crate::auth::AuthService;
    use crate::state_store::StateStore;

    fn state() -> (tempfile::TempDir, AppState) {
        let temp = tempfile::tempdir().unwrap();
        let auth = AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        (temp, AppState::new(auth))
    }

    fn request(method: Method, path: &str, body: &'static str) -> Request<Body> {
        let mut request = Request::builder()
            .method(method)
            .uri(path)
            .header(HOST, "127.0.0.1:19443")
            .body(Body::from(body))
            .unwrap();
        request
            .extensions_mut()
            .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 41234))));
        request
    }

    fn web_root() -> (tempfile::TempDir, StaticWebRoot) {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir(temp.path().join("assets")).unwrap();
        fs::write(
            temp.path().join("index.html"),
            "<!doctype html><title>U60</title>",
        )
        .unwrap();
        fs::write(temp.path().join("assets/app.js"), "export {};\n").unwrap();
        fs::write(temp.path().join("private.txt"), "must not be served").unwrap();
        let root = StaticWebRoot::load(temp.path()).unwrap();
        (temp, root)
    }

    #[tokio::test]
    async fn old_login_and_legacy_routes_are_not_found() {
        let (_temp, state) = state();
        for (method, path) in [
            (Method::POST, "/api/auth/login"),
            (Method::POST, "/api/at/send"),
            (Method::POST, "/api/system/kill-bloat"),
            (Method::GET, "/api/system/top"),
            (Method::POST, "/api/device/reboot"),
        ] {
            let response = router_with_web_root(state.clone(), None)
                .oneshot(request(method, path, "{}"))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
        }
    }

    #[tokio::test]
    async fn web_root_is_opt_in_and_unknown_v1_paths_remain_json() {
        let (_temp, state) = state();
        let response = router_with_web_root(state.clone(), None)
            .oneshot(request(Method::GET, "/", ""))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert!(response
            .headers()
            .get(CONTENT_TYPE)
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("application/json"));

        let (_web_temp, web_root) = web_root();
        let response = router_with_web_root(state, Some(web_root))
            .oneshot(request(Method::GET, "/v1/not-a-route", ""))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert!(response
            .headers()
            .get(CONTENT_TYPE)
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("application/json"));
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert!(body.starts_with(b"{"));
    }

    #[tokio::test]
    async fn configured_web_root_serves_only_allowlisted_assets_with_security_headers() {
        let (_temp, state) = state();
        let (_web_temp, web_root) = web_root();
        let app = router_with_web_root(state, Some(web_root));

        for (path, expected_type) in [
            ("/", "text/html; charset=utf-8"),
            ("/assets/app.js", "text/javascript; charset=utf-8"),
        ] {
            let response = app
                .clone()
                .oneshot(request(Method::GET, path, ""))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK, "{path}");
            assert_eq!(response.headers().get(CONTENT_TYPE).unwrap(), expected_type);
            assert_eq!(
                response.headers().get("x-content-type-options").unwrap(),
                "nosniff"
            );
            assert_eq!(
                response.headers().get("referrer-policy").unwrap(),
                "no-referrer"
            );
            let csp = response
                .headers()
                .get("content-security-policy")
                .unwrap()
                .to_str()
                .unwrap();
            assert!(csp.contains("default-src 'self'"));
            assert!(csp.contains("connect-src 'self'"));
            assert!(csp.contains("frame-ancestors 'none'"));
        }

        for path in [
            "/private.txt",
            "/assets/missing.js",
            "/%2e%2e/private.txt",
            "/assets/%2e%2e/private.txt",
        ] {
            let response = app
                .clone()
                .oneshot(request(Method::GET, path, ""))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn web_root_rejects_root_and_nested_symlinks() {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir().unwrap();
        let real = temp.path().join("real");
        fs::create_dir(&real).unwrap();
        fs::write(real.join("index.html"), "safe").unwrap();
        let linked_root = temp.path().join("linked-root");
        symlink(&real, &linked_root).unwrap();
        assert!(StaticWebRoot::load(&linked_root).is_err());

        let assets = real.join("assets");
        fs::create_dir(&assets).unwrap();
        symlink(real.join("index.html"), assets.join("linked.js")).unwrap();
        assert!(StaticWebRoot::load(&real).is_err());
    }

    #[tokio::test]
    async fn protected_status_requires_a_read_scope_token() {
        let (_temp, state) = state();
        let response = router_with_web_root(state, None)
            .oneshot(request(Method::GET, "/v1/device", ""))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn every_daily_write_requires_a_daily_scope_token() {
        let (_temp, state) = state();
        for (method, path, body) in [
            (
                Method::POST,
                "/v1/sms/send",
                r#"{"recipient":"1","message":"x"}"#,
            ),
            (
                Method::PUT,
                "/v1/traffic/cycle",
                r#"{"reset_day":1,"enabled":false}"#,
            ),
            (
                Method::POST,
                "/v1/wifi/transaction",
                r#"{"transaction_id":"abcdefghijklmnopqrstuvwx","ssid_2g":"test"}"#,
            ),
            (
                Method::POST,
                "/v1/wifi/transaction/confirm",
                r#"{"transaction_id":"AAAAAAAAAAAAAAAAAAAAAAAA"}"#,
            ),
        ] {
            let response = router_with_web_root(state.clone(), None)
                .oneshot(request(method, path, body))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{path}");
        }

        let response = router_with_web_root(state, None)
            .oneshot(request(Method::PUT, "/v1/charging", "{}"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::METHOD_NOT_ALLOWED);
    }

    #[tokio::test]
    async fn versioned_auth_routes_exist() {
        let (_temp, state) = state();
        for path in [
            "/v1/auth/password/session",
            "/v1/auth/challenge",
            "/v1/auth/challenge/verify",
            "/v1/auth/pair",
        ] {
            let response = router_with_web_root(state.clone(), None)
                .oneshot(request(Method::POST, path, "{}"))
                .await
                .unwrap();
            assert_ne!(response.status(), StatusCode::NOT_FOUND, "{path}");
        }
    }

    #[tokio::test]
    async fn advanced_route_requires_admin_before_password_reentry() {
        let (_temp, state) = state();
        let response = router_with_web_root(state, None)
            .oneshot(request(
                Method::POST,
                "/v1/auth/password/advanced",
                r#"{"password":"not examined"}"#,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn admin_session_and_password_reentry_create_advanced_session() {
        let (_temp, state) = state();
        let password = "host test management password";
        state.auth.set_password(password).unwrap();
        let normal = state.auth.password_session(password, "127.0.0.1").unwrap();
        let mut request = request(
            Method::POST,
            "/v1/auth/password/advanced",
            r#"{"password":"host test management password"}"#,
        );
        request.headers_mut().insert(
            AUTHORIZATION,
            format!("Bearer {}", normal.token).parse().unwrap(),
        );
        let response = router_with_web_root(state, None)
            .oneshot(request)
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn cross_origin_is_rejected_and_no_cors_header_is_emitted() {
        let (_temp, state) = state();
        let mut request = request(Method::POST, "/v1/auth/password/session", "{}");
        request
            .headers_mut()
            .insert(ORIGIN, "https://example.invalid".parse().unwrap());
        let response = router_with_web_root(state, None)
            .oneshot(request)
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert!(response
            .headers()
            .get("access-control-allow-origin")
            .is_none());
    }

    #[tokio::test]
    async fn oversized_auth_body_is_a_typed_error() {
        let (_temp, state) = state();
        let oversized = "x".repeat(MAX_AUTH_BODY_BYTES + 1);
        let mut request = Request::builder()
            .method(Method::POST)
            .uri("/v1/auth/password/session")
            .header(HOST, "127.0.0.1:19443")
            .body(Body::from(oversized))
            .unwrap();
        request
            .extensions_mut()
            .insert(ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 41234))));
        let response = router_with_web_root(state, None)
            .oneshot(request)
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(response.headers().get(CACHE_CONTROL).unwrap(), "no-store");
    }

    #[test]
    fn tls_fails_closed_for_missing_or_empty_material() {
        let temp = tempfile::tempdir().unwrap();
        assert!(load_tls_config(
            temp.path().join("missing.crt"),
            temp.path().join("missing.key")
        )
        .is_err());
        let certificate = temp.path().join("certificate.pem");
        let private_key = temp.path().join("leaf-key.pem");
        fs::write(&certificate, []).unwrap();
        fs::write(&private_key, []).unwrap();
        assert!(load_tls_config(certificate, private_key).is_err());
    }

    #[test]
    fn listener_has_no_plaintext_fallback_and_uses_safe_rustls_line() {
        let source = include_str!("server.rs");
        let production = source.split("#[cfg(test)]").next().unwrap();
        assert!(!production.contains("Server::http"));
        assert!(!production.contains("axum_server::bind("));
        assert!(production.contains("axum_server::from_tcp_rustls"));
        let manifest = include_str!("../Cargo.toml");
        assert!(!manifest.contains("tiny_http"));
        assert!(manifest.contains("rustls = { version = \">=0.23.5, <0.24\""));
    }

    #[test]
    fn origin_must_be_https_and_match_host() {
        assert!(same_origin("https://127.0.0.1:19443", "127.0.0.1:19443"));
        assert!(!same_origin("http://127.0.0.1:19443", "127.0.0.1:19443"));
        assert!(!same_origin("https://example.invalid", "127.0.0.1:19443"));
    }

    #[test]
    fn lockout_response_sets_retry_after_without_echoing_client_data() {
        let response = value_response(handlers::failure(AuthFailure::Locked {
            retry_after_seconds: 15,
        }));
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers().get(RETRY_AFTER).unwrap(), "15");
    }
}
