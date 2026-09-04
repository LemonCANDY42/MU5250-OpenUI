use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use p256::pkcs8::DecodePublicKey;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

#[cfg(test)]
use crate::clock_trust::WallClock;
use crate::clock_trust::{ClockTrust, ClockTrustStatus};
use crate::state_store::StateStore;
use crate::util::MutexExt;

const PASSWORD_FILE: &str = "password.json";
const CREDENTIALS_FILE: &str = "credentials.json";
const PAIRING_FILE: &str = "pairing.json";
const LOGIN_ATTEMPTS_FILE: &str = "login-attempts.json";
const AUDIT_FILE: &str = "audit.json";
const AUTH_LOCK_FILE: &str = "auth.lock";
const AUDIT_LOCK_FILE: &str = "audit.lock";

const ARGON_MEMORY_KIB: u32 = 19 * 1024;
const ARGON_ITERATIONS: u32 = 2;
const ARGON_LANES: u32 = 1;
const ARGON_OUTPUT_LEN: usize = 32;
const MIN_PASSWORD_CHARS: usize = 16;

const NORMAL_IDLE_SECS: u64 = 60 * 60;
const NORMAL_ABSOLUTE_SECS: u64 = 12 * 60 * 60;
const ADVANCED_SECS: u64 = 5 * 60;
const CHALLENGE_SECS: u64 = 120;
const PAIRING_SECS: u64 = 5 * 60;
const FAILURE_TTL_SECS: u64 = 60 * 60;
const MAX_LOGIN_CLIENTS: usize = 128;
const MAX_AUDIT_EVENTS: usize = 256;
const CHALLENGE_DOMAIN: &[u8] = b"u60-b04-auth-v1\0";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    Read,
    Daily,
    Admin,
    Advanced,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SessionGrant {
    pub token: String,
    pub token_type: &'static str,
    pub scopes: Vec<Scope>,
    pub idle_expires_in_seconds: u64,
    pub absolute_expires_in_seconds: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ChallengeGrant {
    pub challenge_id: String,
    pub message: String,
    pub expires_in_seconds: u64,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct PairingGrant {
    pub pairing_nonce: String,
    pub expires_at: u64,
    pub registration_path: &'static str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CredentialSummary {
    pub id: String,
    pub label: String,
    pub created_at: u64,
    pub revoked: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RegisteredCredential {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthFailure {
    Unauthorized,
    Forbidden,
    Locked { retry_after_seconds: u64 },
    InvalidInput(&'static str),
    NotConfigured,
    ClockNotSynchronized,
    Internal(String),
}

pub trait Clock: Send + Sync {
    fn wall_now(&self) -> u64;
    fn monotonic_now(&self) -> Result<u64, String>;
    fn boot_id(&self) -> Result<String, String>;
    #[cfg(test)]
    fn clock_trust_boottime_now(&self) -> Result<u64, String>;
}

struct SystemClock;

impl Clock for SystemClock {
    fn wall_now(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    }

    fn monotonic_now(&self) -> Result<u64, String> {
        system_monotonic_seconds()
    }

    fn boot_id(&self) -> Result<String, String> {
        system_boot_id()
    }

    #[cfg(test)]
    fn clock_trust_boottime_now(&self) -> Result<u64, String> {
        system_monotonic_seconds()
    }
}

fn system_monotonic_seconds() -> Result<u64, String> {
    let mut value = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    #[cfg(target_os = "linux")]
    let clock_id = libc::CLOCK_BOOTTIME;
    #[cfg(not(target_os = "linux"))]
    let clock_id = libc::CLOCK_MONOTONIC;

    // CLOCK_BOOTTIME is shared across processes and includes suspend time on
    // the Linux device target. macOS uses its process-independent monotonic
    // clock for host-only tests and maintenance tooling.
    if unsafe { libc::clock_gettime(clock_id, &mut value) } != 0 {
        return Err(format!(
            "read monotonic clock: {}",
            std::io::Error::last_os_error()
        ));
    }
    u64::try_from(value.tv_sec).map_err(|_| "monotonic clock returned a negative value".into())
}

#[cfg(target_os = "linux")]
fn system_boot_id() -> Result<String, String> {
    let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map_err(|error| format!("read Linux boot identity: {error}"))?;
    let boot_id = boot_id.trim();
    if boot_id.is_empty()
        || boot_id.len() > 128
        || !boot_id
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err("Linux boot identity is invalid".into());
    }
    Ok(boot_id.to_owned())
}

#[cfg(target_os = "macos")]
fn system_boot_id() -> Result<String, String> {
    let mut boot_time = libc::timeval {
        tv_sec: 0,
        tv_usec: 0,
    };
    let mut length = std::mem::size_of::<libc::timeval>();
    let name = b"kern.boottime\0";
    // kern.boottime is a host-only compatibility identity. The deployed Linux
    // build always uses the kernel-provided random boot UUID above.
    let status = unsafe {
        libc::sysctlbyname(
            name.as_ptr().cast(),
            (&mut boot_time as *mut libc::timeval).cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    if status != 0 || length != std::mem::size_of::<libc::timeval>() {
        return Err(format!(
            "read macOS boot identity: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(format!("macos-{}-{}", boot_time.tv_sec, boot_time.tv_usec))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn system_boot_id() -> Result<String, String> {
    Err("boot identity is unavailable on this host".into())
}

#[derive(Clone, Serialize, Deserialize)]
struct PasswordRecord {
    argon2id_phc: String,
    generation: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CredentialRecord {
    id: String,
    label: String,
    public_key_spki: String,
    created_at: u64,
    revoked: bool,
}

#[derive(Serialize, Deserialize)]
struct PairingRecord {
    nonce_sha256: String,
    boot_id: String,
    issued_monotonic: u64,
    expires_monotonic: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AuditEvent {
    timestamp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    clock_trusted: Option<bool>,
    event: String,
    outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    client: Option<String>,
}

struct SessionRecord {
    token_hash: [u8; 32],
    scopes: BTreeSet<Scope>,
    issued_monotonic: u64,
    last_seen_monotonic: u64,
    idle_seconds: u64,
    absolute_seconds: u64,
    sliding: bool,
    origin: SessionOrigin,
}

enum SessionOrigin {
    Password(String),
    Credential(String),
}

struct ChallengeRecord {
    credential_id: String,
    message: Vec<u8>,
    expires_monotonic: u64,
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct LoginAttempt {
    failures: u32,
    locked_until: u64,
    last_failure: u64,
}

pub struct AuthService {
    store: StateStore,
    clock: Arc<dyn Clock>,
    clock_trust: Arc<ClockTrust>,
    password: Mutex<Option<PasswordRecord>>,
    credentials: Mutex<Vec<CredentialRecord>>,
    sessions: Mutex<Vec<SessionRecord>>,
    challenges: Mutex<HashMap<String, ChallengeRecord>>,
    pairing_lock: Mutex<()>,
}

#[cfg(test)]
struct AuthWallClock(Arc<dyn Clock>);

#[cfg(test)]
impl WallClock for AuthWallClock {
    fn now(&self) -> u64 {
        self.0.wall_now()
    }

    fn boottime(&self) -> Result<u64, String> {
        self.0.clock_trust_boottime_now()
    }

    fn boot_id(&self) -> Result<String, String> {
        self.0.boot_id()
    }
}

impl AuthService {
    pub fn open(store: StateStore) -> Result<Self, String> {
        let clock_trust = ClockTrust::open(store.clone())?;
        Self::open_with_clock_and_trust(store, Arc::new(SystemClock), clock_trust)
    }

    #[cfg(test)]
    fn open_with_clock(store: StateStore, clock: Arc<dyn Clock>) -> Result<Self, String> {
        let clock_trust = ClockTrust::open_with_clock(
            store.clone(),
            0,
            Arc::new(AuthWallClock(Arc::clone(&clock))),
        )?;
        Self::open_with_clock_and_trust(store, clock, clock_trust)
    }

    pub(crate) fn open_with_clock_trust(
        store: StateStore,
        clock_trust: Arc<ClockTrust>,
    ) -> Result<Self, String> {
        Self::open_with_clock_and_trust(store, Arc::new(SystemClock), clock_trust)
    }

    fn open_with_clock_and_trust(
        store: StateStore,
        clock: Arc<dyn Clock>,
        clock_trust: Arc<ClockTrust>,
    ) -> Result<Self, String> {
        let password = store.read_json::<PasswordRecord>(PASSWORD_FILE)?;
        if let Some(record) = &password {
            validate_password_record(record)?;
        }
        let credentials = store
            .read_json::<Vec<CredentialRecord>>(CREDENTIALS_FILE)?
            .unwrap_or_default();
        for credential in &credentials {
            validate_spki(&credential.public_key_spki).map_err(|_| {
                format!(
                    "stored credential {} has an invalid public key",
                    credential.id
                )
            })?;
        }
        let now = clock.wall_now();
        let state_lock = store.lock_exclusive(AUTH_LOCK_FILE)?;
        let mut login_attempts = store
            .read_json::<HashMap<String, LoginAttempt>>(LOGIN_ATTEMPTS_FILE)?
            .unwrap_or_default();
        let original_attempts = login_attempts.clone();
        normalize_attempts(&mut login_attempts, now);
        if login_attempts != original_attempts {
            store.write_json(LOGIN_ATTEMPTS_FILE, &login_attempts)?;
        }
        drop(state_lock);
        Ok(Self {
            store,
            clock,
            clock_trust,
            password: Mutex::new(password),
            credentials: Mutex::new(credentials),
            sessions: Mutex::new(Vec::new()),
            challenges: Mutex::new(HashMap::new()),
            pairing_lock: Mutex::new(()),
        })
    }

    pub(crate) fn clock_trust(&self) -> Arc<ClockTrust> {
        Arc::clone(&self.clock_trust)
    }

    pub fn set_password(&self, password: &str) -> Result<(), AuthFailure> {
        if password.chars().count() < MIN_PASSWORD_CHARS {
            return Err(AuthFailure::InvalidInput(
                "password must contain at least 16 characters",
            ));
        }
        let salt = SaltString::generate(&mut OsRng);
        let phc = argon2id()?
            .hash_password(password.as_bytes(), &salt)
            .map_err(|error| AuthFailure::Internal(format!("hash password: {error}")))?
            .to_string();
        let mut generation = [0u8; 16];
        OsRng.fill_bytes(&mut generation);
        let record = PasswordRecord {
            argon2id_phc: phc,
            generation: URL_SAFE_NO_PAD.encode(generation),
        };
        let state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        self.store
            .write_json(PASSWORD_FILE, &record)
            .map_err(AuthFailure::Internal)?;
        *self.password.safe_lock() = Some(record);
        self.sessions
            .safe_lock()
            .retain(|session| !matches!(session.origin, SessionOrigin::Password(_)));
        drop(state_lock);
        self.audit("password_set", "success", None);
        Ok(())
    }

    pub fn password_session(
        &self,
        password: &str,
        client_ip: &str,
    ) -> Result<SessionGrant, AuthFailure> {
        self.require_trusted_clock()?;
        let generation = self.verify_password(password, client_ip)?;
        self.issue_session(
            [Scope::Read, Scope::Daily, Scope::Admin],
            NORMAL_IDLE_SECS,
            NORMAL_ABSOLUTE_SECS,
            true,
            SessionOrigin::Password(generation),
        )
    }

    pub fn advanced_session(
        &self,
        password: &str,
        client_ip: &str,
    ) -> Result<SessionGrant, AuthFailure> {
        self.require_trusted_clock()?;
        let generation = self.verify_password(password, client_ip)?;
        self.issue_session(
            [Scope::Read, Scope::Daily, Scope::Admin, Scope::Advanced],
            ADVANCED_SECS,
            ADVANCED_SECS,
            false,
            SessionOrigin::Password(generation),
        )
    }

    pub fn validate_token(&self, token: &str, required: Scope) -> Result<(), AuthFailure> {
        let token_bytes = URL_SAFE_NO_PAD
            .decode(token)
            .map_err(|_| AuthFailure::Unauthorized)?;
        if token_bytes.len() != 32 {
            return Err(AuthFailure::Unauthorized);
        }
        let wanted = sha256(&token_bytes);
        let now = self.checked_monotonic_now()?;
        let password_generation = self.refresh_password()?.map(|record| record.generation);
        self.refresh_credentials()?;
        let active_credentials = self
            .credentials
            .safe_lock()
            .iter()
            .filter(|credential| !credential.revoked)
            .map(|credential| credential.id.clone())
            .collect::<BTreeSet<_>>();
        let mut sessions = self.sessions.safe_lock();
        sessions.retain(|session| {
            !session_expired(session, now)
                && match &session.origin {
                    SessionOrigin::Password(generation) => {
                        password_generation.as_ref() == Some(generation)
                    }
                    SessionOrigin::Credential(id) => active_credentials.contains(id),
                }
        });
        let Some(session) = sessions
            .iter_mut()
            .find(|session| bool::from(session.token_hash.as_slice().ct_eq(wanted.as_slice())))
        else {
            return Err(AuthFailure::Unauthorized);
        };
        if !session.scopes.contains(&required) {
            return Err(AuthFailure::Forbidden);
        }
        if session.sliding {
            session.last_seen_monotonic = now;
        }
        Ok(())
    }

    pub fn open_pairing_window(&self) -> Result<PairingGrant, AuthFailure> {
        self.require_trusted_clock()?;
        let state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        let wall_now = self.checked_wall_now()?;
        let monotonic_now = self.checked_monotonic_now()?;
        let boot_id = self.clock.boot_id().map_err(AuthFailure::Internal)?;
        let mut nonce = [0u8; 32];
        OsRng.fill_bytes(&mut nonce);
        let expires_at = wall_now.saturating_add(PAIRING_SECS);
        self.store
            .write_json(
                PAIRING_FILE,
                &PairingRecord {
                    nonce_sha256: URL_SAFE_NO_PAD.encode(sha256(&nonce)),
                    boot_id,
                    issued_monotonic: monotonic_now,
                    expires_monotonic: monotonic_now.saturating_add(PAIRING_SECS),
                },
            )
            .map_err(AuthFailure::Internal)?;
        drop(state_lock);
        self.audit("pair_open", "success", None);
        Ok(PairingGrant {
            pairing_nonce: URL_SAFE_NO_PAD.encode(nonce),
            expires_at,
            registration_path: "/v1/auth/pair",
        })
    }

    pub fn register_credential(
        &self,
        nonce: &str,
        label: &str,
        public_key_spki: &str,
        client_ip: &str,
    ) -> Result<RegisteredCredential, AuthFailure> {
        self.require_trusted_clock()?;
        let pairing_lock = self.pairing_lock.safe_lock();
        let state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        let record = self
            .store
            .read_json::<PairingRecord>(PAIRING_FILE)
            .map_err(AuthFailure::Internal)?
            .ok_or(AuthFailure::Unauthorized)?;
        let nonce_bytes = URL_SAFE_NO_PAD
            .decode(nonce)
            .map_err(|_| AuthFailure::Unauthorized)?;
        let supplied_hash = sha256(&nonce_bytes);
        let expected_hash = URL_SAFE_NO_PAD
            .decode(&record.nonce_sha256)
            .map_err(|_| AuthFailure::Internal("invalid pairing state".into()))?;
        if expected_hash.len() != 32
            || !bool::from(expected_hash.as_slice().ct_eq(supplied_hash.as_slice()))
        {
            drop(state_lock);
            drop(pairing_lock);
            self.audit("pair_register", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }

        // A correctly presented nonce is consumed before any client-controlled
        // label or key validation, so a failed registration cannot be replayed.
        let consumed = self
            .store
            .remove(PAIRING_FILE)
            .map_err(AuthFailure::Internal)?;
        if !consumed {
            return Err(AuthFailure::Unauthorized);
        }
        let monotonic_now = self.checked_monotonic_now()?;
        let boot_id = self.clock.boot_id().map_err(AuthFailure::Internal)?;
        if boot_id != record.boot_id
            || monotonic_now < record.issued_monotonic
            || monotonic_now >= record.expires_monotonic
        {
            drop(state_lock);
            drop(pairing_lock);
            self.audit("pair_register", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }

        let label = validate_label(label)?;
        validate_spki(public_key_spki)?;
        let created_at = self.checked_wall_now()?;
        let mut id_bytes = [0u8; 16];
        OsRng.fill_bytes(&mut id_bytes);
        let credential = CredentialRecord {
            id: URL_SAFE_NO_PAD.encode(id_bytes),
            label: label.to_owned(),
            public_key_spki: public_key_spki.to_owned(),
            created_at,
            revoked: false,
        };
        self.refresh_credentials()?;
        let mut credentials = self.credentials.safe_lock();
        credentials.push(credential.clone());
        self.store
            .write_json(CREDENTIALS_FILE, &*credentials)
            .map_err(AuthFailure::Internal)?;
        drop(credentials);
        drop(state_lock);
        drop(pairing_lock);
        self.audit("pair_register", "success", Some(client_ip));
        Ok(RegisteredCredential {
            id: credential.id,
            label: credential.label,
        })
    }

    pub fn list_credentials(&self) -> Vec<CredentialSummary> {
        self.credentials
            .safe_lock()
            .iter()
            .map(|credential| CredentialSummary {
                id: credential.id.clone(),
                label: credential.label.clone(),
                created_at: credential.created_at,
                revoked: credential.revoked,
            })
            .collect()
    }

    pub fn revoke_credential(&self, id: &str) -> Result<bool, AuthFailure> {
        let state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        self.refresh_credentials()?;
        let mut credentials = self.credentials.safe_lock();
        let Some(credential) = credentials
            .iter_mut()
            .find(|credential| credential.id == id)
        else {
            return Ok(false);
        };
        credential.revoked = true;
        self.store
            .write_json(CREDENTIALS_FILE, &*credentials)
            .map_err(AuthFailure::Internal)?;
        self.sessions.safe_lock().retain(|session| {
            !matches!(&session.origin, SessionOrigin::Credential(origin_id) if origin_id == id)
        });
        drop(credentials);
        drop(state_lock);
        self.audit("credential_revoke", "success", None);
        Ok(true)
    }

    pub fn create_challenge(
        &self,
        credential_id: &str,
        client_ip: &str,
    ) -> Result<ChallengeGrant, AuthFailure> {
        if self.active_credential(credential_id)?.is_none() {
            self.audit("challenge_create", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }
        let mut nonce = [0u8; 32];
        let mut challenge_id = [0u8; 16];
        OsRng.fill_bytes(&mut nonce);
        OsRng.fill_bytes(&mut challenge_id);
        let challenge_id = URL_SAFE_NO_PAD.encode(challenge_id);
        let message = challenge_message(credential_id, &challenge_id, &nonce);
        let now = self.checked_monotonic_now()?;
        let mut challenges = self.challenges.safe_lock();
        challenges.retain(|_, challenge| {
            challenge.expires_monotonic > now && challenge.credential_id != credential_id
        });
        challenges.insert(
            challenge_id.clone(),
            ChallengeRecord {
                credential_id: credential_id.to_owned(),
                message: message.clone(),
                expires_monotonic: now.saturating_add(CHALLENGE_SECS),
            },
        );
        drop(challenges);
        self.audit("challenge_create", "success", Some(client_ip));
        Ok(ChallengeGrant {
            challenge_id,
            message: URL_SAFE_NO_PAD.encode(message),
            expires_in_seconds: CHALLENGE_SECS,
        })
    }

    pub fn verify_challenge(
        &self,
        credential_id: &str,
        challenge_id: &str,
        signature: &str,
        client_ip: &str,
    ) -> Result<SessionGrant, AuthFailure> {
        // Remove first. Every verification attempt is single-use, including an
        // expired challenge or malformed/invalid signature.
        let challenge = self
            .challenges
            .safe_lock()
            .remove(challenge_id)
            .ok_or(AuthFailure::Unauthorized)?;
        let now = self.checked_monotonic_now()?;
        if now >= challenge.expires_monotonic || challenge.credential_id != credential_id {
            self.audit("challenge_verify", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }
        let credential = self
            .active_credential(credential_id)?
            .ok_or(AuthFailure::Unauthorized)?;
        let key = validate_spki(&credential.public_key_spki)?;
        let signature_bytes = URL_SAFE_NO_PAD
            .decode(signature)
            .map_err(|_| AuthFailure::Unauthorized)?;
        let valid = verify_signature_candidates(&signature_bytes, |signature| {
            key.verify(&challenge.message, signature).is_ok()
        });
        if !valid {
            self.audit("challenge_verify", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }
        self.audit("challenge_verify", "success", Some(client_ip));
        self.issue_session(
            [Scope::Read, Scope::Daily],
            NORMAL_IDLE_SECS,
            NORMAL_ABSOLUTE_SECS,
            true,
            SessionOrigin::Credential(credential.id),
        )
    }

    fn verify_password(&self, password: &str, client_ip: &str) -> Result<String, AuthFailure> {
        let now = self.checked_wall_now()?;
        if let Some(retry_after_seconds) = self.retry_after(client_ip, now)? {
            self.audit("password_login", "locked", Some(client_ip));
            return Err(AuthFailure::Locked {
                retry_after_seconds,
            });
        }
        let record = self.refresh_password()?.ok_or(AuthFailure::NotConfigured)?;
        let parsed = PasswordHash::new(&record.argon2id_phc)
            .map_err(|error| AuthFailure::Internal(format!("parse password verifier: {error}")))?;
        if argon2id()?
            .verify_password(password.as_bytes(), &parsed)
            .is_err()
        {
            self.record_failure(client_ip, now)?;
            self.audit("password_login", "denied", Some(client_ip));
            return Err(AuthFailure::Unauthorized);
        }
        self.clear_failure(client_ip, now)?;
        self.audit("password_login", "success", Some(client_ip));
        Ok(record.generation)
    }

    fn issue_session<const N: usize>(
        &self,
        scopes: [Scope; N],
        idle_seconds: u64,
        absolute_seconds: u64,
        sliding: bool,
        origin: SessionOrigin,
    ) -> Result<SessionGrant, AuthFailure> {
        let mut token = [0u8; 32];
        OsRng.fill_bytes(&mut token);
        let now = self.checked_monotonic_now()?;
        let scope_set = scopes.into_iter().collect::<BTreeSet<_>>();
        self.sessions.safe_lock().push(SessionRecord {
            token_hash: sha256(&token),
            scopes: scope_set.clone(),
            issued_monotonic: now,
            last_seen_monotonic: now,
            idle_seconds,
            absolute_seconds,
            sliding,
            origin,
        });
        Ok(SessionGrant {
            token: URL_SAFE_NO_PAD.encode(token),
            token_type: "Bearer",
            scopes: scope_set.into_iter().collect(),
            idle_expires_in_seconds: idle_seconds,
            absolute_expires_in_seconds: absolute_seconds,
        })
    }

    fn active_credential(&self, id: &str) -> Result<Option<CredentialRecord>, AuthFailure> {
        self.refresh_credentials()?;
        Ok(self
            .credentials
            .safe_lock()
            .iter()
            .find(|credential| credential.id == id && !credential.revoked)
            .cloned())
    }

    fn refresh_password(&self) -> Result<Option<PasswordRecord>, AuthFailure> {
        let record = self
            .store
            .read_json::<PasswordRecord>(PASSWORD_FILE)
            .map_err(AuthFailure::Internal)?;
        if let Some(record) = &record {
            validate_password_record(record).map_err(AuthFailure::Internal)?;
        }
        *self.password.safe_lock() = record.clone();
        Ok(record)
    }

    fn refresh_credentials(&self) -> Result<(), AuthFailure> {
        let credentials = self
            .store
            .read_json::<Vec<CredentialRecord>>(CREDENTIALS_FILE)
            .map_err(AuthFailure::Internal)?
            .unwrap_or_default();
        for credential in &credentials {
            validate_spki(&credential.public_key_spki).map_err(|_| {
                AuthFailure::Internal(format!(
                    "stored credential {} has an invalid public key",
                    credential.id
                ))
            })?;
        }
        *self.credentials.safe_lock() = credentials;
        Ok(())
    }

    fn retry_after(&self, client_ip: &str, now: u64) -> Result<Option<u64>, AuthFailure> {
        let _state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        let mut attempts = self.load_attempts()?;
        let original = attempts.clone();
        normalize_attempts(&mut attempts, now);
        let retry = attempts.get(&client_key(client_ip)).and_then(|attempt| {
            if now < attempt.last_failure {
                Some(300)
            } else if now < attempt.locked_until {
                Some(attempt.locked_until - now)
            } else {
                None
            }
        });
        if attempts != original {
            self.persist_attempts(&attempts)?;
        }
        Ok(retry)
    }

    fn record_failure(&self, client_ip: &str, now: u64) -> Result<(), AuthFailure> {
        let _state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        let mut attempts = self.load_attempts()?;
        normalize_attempts(&mut attempts, now);
        let key = client_key(client_ip);
        if attempts.len() >= MAX_LOGIN_CLIENTS && !attempts.contains_key(&key) {
            if let Some(oldest) = attempts
                .iter()
                .min_by_key(|(_, attempt)| attempt.last_failure)
                .map(|(key, _)| key.clone())
            {
                attempts.remove(&oldest);
            }
        }
        let attempt = attempts.entry(key).or_insert(LoginAttempt {
            failures: 0,
            locked_until: 0,
            last_failure: now,
        });
        attempt.failures = attempt.failures.saturating_add(1);
        attempt.last_failure = now;
        attempt.locked_until = now.saturating_add(progressive_delay(attempt.failures));
        self.persist_attempts(&attempts)?;
        Ok(())
    }

    fn clear_failure(&self, client_ip: &str, now: u64) -> Result<(), AuthFailure> {
        let _state_lock = self
            .store
            .lock_exclusive(AUTH_LOCK_FILE)
            .map_err(AuthFailure::Internal)?;
        let mut attempts = self.load_attempts()?;
        let original = attempts.clone();
        normalize_attempts(&mut attempts, now);
        attempts.remove(&client_key(client_ip));
        if attempts != original {
            self.persist_attempts(&attempts)?;
        }
        Ok(())
    }

    fn load_attempts(&self) -> Result<HashMap<String, LoginAttempt>, AuthFailure> {
        self.store
            .read_json(LOGIN_ATTEMPTS_FILE)
            .map_err(AuthFailure::Internal)
            .map(Option::unwrap_or_default)
    }

    fn persist_attempts(
        &self,
        attempts: &HashMap<String, LoginAttempt>,
    ) -> Result<(), AuthFailure> {
        self.store
            .write_json(LOGIN_ATTEMPTS_FILE, attempts)
            .map_err(AuthFailure::Internal)
    }

    fn checked_wall_now(&self) -> Result<u64, AuthFailure> {
        self.require_trusted_clock()?;
        Ok(self.clock.wall_now())
    }

    fn require_trusted_clock(&self) -> Result<(), AuthFailure> {
        match self.clock_trust.status() {
            ClockTrustStatus::Trusted => Ok(()),
            ClockTrustStatus::WaitingForSync => Err(AuthFailure::ClockNotSynchronized),
        }
    }

    fn checked_monotonic_now(&self) -> Result<u64, AuthFailure> {
        self.clock.monotonic_now().map_err(AuthFailure::Internal)
    }

    fn audit(&self, event: &str, outcome: &str, client_ip: Option<&str>) {
        let result = (|| -> Result<(), String> {
            let _audit_lock = self.store.lock_exclusive(AUDIT_LOCK_FILE)?;
            let mut audit = self
                .store
                .read_json::<Vec<AuditEvent>>(AUDIT_FILE)?
                .unwrap_or_default();
            audit.push(AuditEvent {
                timestamp: self.clock.wall_now(),
                clock_trusted: Some(self.clock_trust.status() == ClockTrustStatus::Trusted),
                event: event.to_owned(),
                outcome: outcome.to_owned(),
                client: client_ip.map(|_| "redacted".into()),
            });
            if audit.len() > MAX_AUDIT_EVENTS {
                let drain = audit.len() - MAX_AUDIT_EVENTS;
                audit.drain(0..drain);
            }
            self.store.write_json(AUDIT_FILE, &audit)
        })();
        if let Err(error) = result {
            eprintln!(
                "[audit] persistence degraded: {error}; event={event}; outcome={outcome}; client={}",
                if client_ip.is_some() { "redacted" } else { "none" }
            );
        }
    }
}

fn argon2id() -> Result<Argon2<'static>, AuthFailure> {
    let params = Params::new(
        ARGON_MEMORY_KIB,
        ARGON_ITERATIONS,
        ARGON_LANES,
        Some(ARGON_OUTPUT_LEN),
    )
    .map_err(|error| AuthFailure::Internal(format!("Argon2 parameters: {error}")))?;
    Ok(Argon2::new(Algorithm::Argon2id, Version::V0x13, params))
}

fn validate_password_record(record: &PasswordRecord) -> Result<(), String> {
    let parsed = PasswordHash::new(&record.argon2id_phc)
        .map_err(|error| format!("password verifier: {error}"))?;
    if parsed.algorithm.as_str() != "argon2id" {
        return Err("password verifier is not Argon2id".into());
    }
    if parsed.version != Some(19)
        || parsed.params.get_decimal("m") != Some(ARGON_MEMORY_KIB)
        || parsed.params.get_decimal("t") != Some(ARGON_ITERATIONS)
        || parsed.params.get_decimal("p") != Some(ARGON_LANES)
        || parsed.hash.as_ref().map(|hash| hash.as_bytes().len()) != Some(ARGON_OUTPUT_LEN)
    {
        return Err("password verifier has unexpected Argon2id parameters".into());
    }
    let generation = URL_SAFE_NO_PAD
        .decode(&record.generation)
        .map_err(|_| "password generation is invalid")?;
    if generation.len() != 16 {
        return Err("password generation is invalid".into());
    }
    Ok(())
}

fn validate_label(label: &str) -> Result<&str, AuthFailure> {
    let label = label.trim();
    let count = label.chars().count();
    if !(1..=64).contains(&count) || label.chars().any(char::is_control) {
        return Err(AuthFailure::InvalidInput(
            "label must be 1-64 non-control characters",
        ));
    }
    Ok(label)
}

fn validate_spki(encoded: &str) -> Result<VerifyingKey, AuthFailure> {
    let der = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| AuthFailure::InvalidInput("public_key_spki must be base64url DER"))?;
    VerifyingKey::from_public_key_der(&der)
        .map_err(|_| AuthFailure::InvalidInput("public_key_spki is not a P-256 SPKI key"))
}

fn verify_signature_candidates(encoded: &[u8], mut verify: impl FnMut(&Signature) -> bool) -> bool {
    if let Ok(raw) = Signature::from_slice(encoded) {
        if verify(&raw) {
            return true;
        }
    }
    Signature::from_der(encoded).is_ok_and(|der| verify(&der))
}

fn challenge_message(credential_id: &str, challenge_id: &str, nonce: &[u8; 32]) -> Vec<u8> {
    let mut message = Vec::with_capacity(
        CHALLENGE_DOMAIN.len() + credential_id.len() + challenge_id.len() + nonce.len() + 4,
    );
    message.extend_from_slice(CHALLENGE_DOMAIN);
    message.extend_from_slice(&(credential_id.len() as u16).to_be_bytes());
    message.extend_from_slice(credential_id.as_bytes());
    message.extend_from_slice(&(challenge_id.len() as u16).to_be_bytes());
    message.extend_from_slice(challenge_id.as_bytes());
    message.extend_from_slice(nonce);
    message
}

fn session_expired(session: &SessionRecord, now: u64) -> bool {
    now >= session
        .issued_monotonic
        .saturating_add(session.absolute_seconds)
        || now
            >= session
                .last_seen_monotonic
                .saturating_add(session.idle_seconds)
}

fn progressive_delay(failures: u32) -> u64 {
    match failures {
        0..=2 => 0,
        3 => 5,
        4 => 15,
        5 => 60,
        _ => 300,
    }
}

fn normalize_attempts(attempts: &mut HashMap<String, LoginAttempt>, now: u64) {
    attempts.retain(|key, attempt| {
        valid_client_key(key)
            && (now < attempt.last_failure
                || now < attempt.locked_until
                || now.saturating_sub(attempt.last_failure) < FAILURE_TTL_SECS)
    });
    if attempts.len() > MAX_LOGIN_CLIENTS {
        let mut newest = attempts
            .iter()
            .map(|(key, attempt)| (key.clone(), attempt.last_failure))
            .collect::<Vec<_>>();
        newest.sort_unstable_by_key(|(_, last_failure)| std::cmp::Reverse(*last_failure));
        let keep = newest
            .into_iter()
            .take(MAX_LOGIN_CLIENTS)
            .map(|(key, _)| key)
            .collect::<BTreeSet<_>>();
        attempts.retain(|key, _| keep.contains(key));
    }
}

fn client_key(client_ip: &str) -> String {
    let mut input = Vec::with_capacity(CHALLENGE_DOMAIN.len() + client_ip.len());
    input.extend_from_slice(CHALLENGE_DOMAIN);
    input.extend_from_slice(client_ip.as_bytes());
    URL_SAFE_NO_PAD.encode(sha256(&input))
}

fn valid_client_key(key: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(key)
        .is_ok_and(|decoded| decoded.len() == 32)
}

fn sha256(input: &[u8]) -> [u8; 32] {
    Sha256::digest(input).into()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Barrier;

    use p256::ecdsa::signature::Signer;
    use p256::ecdsa::{Signature, SigningKey};
    use p256::pkcs8::EncodePublicKey;

    use super::*;

    const PASSWORD: &str = "correct horse battery staple";
    const IP: &str = "192.168.0.42";

    struct TestClock {
        wall: AtomicU64,
        monotonic: AtomicU64,
        clock_trust_boottime: AtomicU64,
        boot_id: Mutex<Option<String>>,
    }

    impl TestClock {
        fn new(now: u64) -> Self {
            Self {
                wall: AtomicU64::new(now),
                monotonic: AtomicU64::new(now),
                clock_trust_boottime: AtomicU64::new(now),
                boot_id: Mutex::new(Some("11111111-1111-1111-1111-111111111111".into())),
            }
        }

        fn advance(&self, seconds: u64) {
            self.wall.fetch_add(seconds, Ordering::SeqCst);
            self.monotonic.fetch_add(seconds, Ordering::SeqCst);
            self.clock_trust_boottime
                .fetch_add(seconds, Ordering::SeqCst);
        }

        fn advance_monotonic(&self, seconds: u64) {
            self.monotonic.fetch_add(seconds, Ordering::SeqCst);
        }

        fn set_wall(&self, value: u64) {
            self.wall.store(value, Ordering::SeqCst);
        }

        fn set_monotonic(&self, value: u64) {
            self.monotonic.store(value, Ordering::SeqCst);
        }

        fn set_boot_id(&self, value: Option<&str>) {
            *self.boot_id.safe_lock() = value.map(str::to_owned);
        }
    }

    impl Clock for TestClock {
        fn wall_now(&self) -> u64 {
            self.wall.load(Ordering::SeqCst)
        }

        fn monotonic_now(&self) -> Result<u64, String> {
            Ok(self.monotonic.load(Ordering::SeqCst))
        }

        fn boot_id(&self) -> Result<String, String> {
            self.boot_id
                .safe_lock()
                .clone()
                .ok_or_else(|| "boot identity unavailable".into())
        }

        fn clock_trust_boottime_now(&self) -> Result<u64, String> {
            Ok(self.clock_trust_boottime.load(Ordering::SeqCst))
        }
    }

    fn service() -> (tempfile::TempDir, Arc<TestClock>, AuthService) {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let clock = Arc::new(TestClock::new(1_000_000));
        let service = AuthService::open_with_clock(store, clock.clone()).unwrap();
        service.set_password(PASSWORD).unwrap();
        (temp, clock, service)
    }

    fn paired(service: &AuthService) -> (SigningKey, RegisteredCredential) {
        let signing = SigningKey::random(&mut OsRng);
        let der = signing.verifying_key().to_public_key_der().unwrap();
        let pairing = service.open_pairing_window().unwrap();
        let credential = service
            .register_credential(
                &pairing.pairing_nonce,
                "Owner iPhone",
                &URL_SAFE_NO_PAD.encode(der.as_bytes()),
                IP,
            )
            .unwrap();
        (signing, credential)
    }

    #[test]
    fn password_verifier_is_argon2id_with_explicit_parameters() {
        let (temp, _, _) = service();
        let record: PasswordRecord = StateStore::open(temp.path().join("state"))
            .unwrap()
            .read_json(PASSWORD_FILE)
            .unwrap()
            .unwrap();
        assert!(record
            .argon2id_phc
            .starts_with("$argon2id$v=19$m=19456,t=2,p=1$"));
        assert!(!record.argon2id_phc.contains(PASSWORD));
    }

    #[test]
    fn persisted_password_verifier_with_weaker_parameters_is_rejected() {
        let (temp, _clock, _service) = service();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let mut record: PasswordRecord = store.read_json(PASSWORD_FILE).unwrap().unwrap();
        record.argon2id_phc = record.argon2id_phc.replace("m=19456", "m=8");
        store.write_json(PASSWORD_FILE, &record).unwrap();
        assert!(AuthService::open(store).is_err());
    }

    #[test]
    fn lockout_progresses_per_client() {
        let (_temp, clock, service) = service();
        for _ in 0..3 {
            assert_eq!(
                service.password_session("wrong password value", IP),
                Err(AuthFailure::Unauthorized)
            );
        }
        assert_eq!(
            service.password_session(PASSWORD, IP),
            Err(AuthFailure::Locked {
                retry_after_seconds: 5
            })
        );
        assert!(service.password_session(PASSWORD, "192.168.0.99").is_ok());
        clock.advance(5);
        assert!(service.password_session(PASSWORD, IP).is_ok());
    }

    #[test]
    fn lockout_survives_service_restart_and_clock_rollback() {
        let (temp, clock, service) = service();
        for _ in 0..3 {
            assert_eq!(
                service.password_session("wrong password value", IP),
                Err(AuthFailure::Unauthorized)
            );
        }
        drop(service);
        clock.set_wall(999_900);
        let restarted = AuthService::open_with_clock(
            StateStore::open(temp.path().join("state")).unwrap(),
            clock,
        )
        .unwrap();
        assert_eq!(
            restarted.password_session(PASSWORD, IP),
            Err(AuthFailure::Locked {
                retry_after_seconds: 300
            })
        );
        let persisted =
            std::fs::read_to_string(temp.path().join("state/login-attempts.json")).unwrap();
        assert!(!persisted.contains(IP));
    }

    #[test]
    fn unseen_wall_clock_rollback_and_rebound_cannot_extend_volatile_deadlines() {
        let (_temp, clock, service) = service();
        let session = service.password_session(PASSWORD, IP).unwrap();
        let (signing, credential) = paired(&service);
        let challenge = service.create_challenge(&credential.id, IP).unwrap();
        let message = URL_SAFE_NO_PAD.decode(&challenge.message).unwrap();
        let signature: Signature = signing.sign(&message);
        let signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());

        // No request observes the rollback. Wall time rebounds above the prior
        // high-water mark, while the authoritative monotonic clock advances.
        clock.set_wall(900_000);
        clock.advance_monotonic(NORMAL_ABSOLUTE_SECS);
        clock.set_wall(1_000_001);

        assert_eq!(
            service.validate_token(&session.token, Scope::Read),
            Err(AuthFailure::Unauthorized)
        );
        assert_eq!(
            service.verify_challenge(&credential.id, &challenge.challenge_id, &signature, IP),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn clock_rollback_pauses_password_and_pairing_but_preserves_key_login() {
        let (_temp, clock, service) = service();
        let (signing, credential) = paired(&service);
        clock.set_wall(900_000);

        assert_eq!(
            service.password_session(PASSWORD, IP),
            Err(AuthFailure::ClockNotSynchronized)
        );
        assert_eq!(
            service.open_pairing_window(),
            Err(AuthFailure::ClockNotSynchronized)
        );

        let challenge = service.create_challenge(&credential.id, IP).unwrap();
        let message = URL_SAFE_NO_PAD.decode(&challenge.message).unwrap();
        let signature: Signature = signing.sign(&message);
        let session = service
            .verify_challenge(
                &credential.id,
                &challenge.challenge_id,
                &URL_SAFE_NO_PAD.encode(signature.to_bytes()),
                IP,
            )
            .unwrap();
        assert!(service.validate_token(&session.token, Scope::Read).is_ok());
        let audit = service
            .store
            .read_json::<Vec<AuditEvent>>(AUDIT_FILE)
            .unwrap()
            .unwrap();
        assert!(audit.iter().any(|event| event.clock_trusted == Some(false)));

        clock.set_wall(1_000_001);
        assert!(service.password_session(PASSWORD, IP).is_ok());
    }

    #[test]
    fn normal_token_slides_but_never_exceeds_absolute_expiry() {
        let (_temp, clock, service) = service();
        let session = service.password_session(PASSWORD, IP).unwrap();
        clock.advance(NORMAL_IDLE_SECS - 1);
        assert!(service.validate_token(&session.token, Scope::Read).is_ok());
        clock.advance(NORMAL_IDLE_SECS - 1);
        assert!(service.validate_token(&session.token, Scope::Read).is_ok());
        clock.advance(NORMAL_ABSOLUTE_SECS);
        assert_eq!(
            service.validate_token(&session.token, Scope::Read),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn advanced_token_is_five_minutes_and_non_sliding() {
        let (_temp, clock, service) = service();
        let session = service.advanced_session(PASSWORD, IP).unwrap();
        clock.advance(200);
        assert!(service
            .validate_token(&session.token, Scope::Advanced)
            .is_ok());
        clock.advance(100);
        assert_eq!(
            service.validate_token(&session.token, Scope::Advanced),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn key_session_cannot_use_admin_scope() {
        let (_temp, _clock, service) = service();
        let (signing, credential) = paired(&service);
        let challenge = service.create_challenge(&credential.id, IP).unwrap();
        let message = URL_SAFE_NO_PAD.decode(challenge.message).unwrap();
        let signature: Signature = signing.sign(&message);
        let session = service
            .verify_challenge(
                &credential.id,
                &challenge.challenge_id,
                &URL_SAFE_NO_PAD.encode(signature.to_bytes()),
                IP,
            )
            .unwrap();
        assert_eq!(
            service.validate_token(&session.token, Scope::Admin),
            Err(AuthFailure::Forbidden)
        );
    }

    #[test]
    fn challenge_accepts_raw_and_der_signatures_and_rejects_replay() {
        let (_temp, _clock, service) = service();
        let (signing, credential) = paired(&service);

        for der in [false, true] {
            let challenge = service.create_challenge(&credential.id, IP).unwrap();
            let message = URL_SAFE_NO_PAD.decode(&challenge.message).unwrap();
            let signature: Signature = signing.sign(&message);
            let encoded = if der {
                URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes())
            } else {
                URL_SAFE_NO_PAD.encode(signature.to_bytes())
            };
            assert!(service
                .verify_challenge(&credential.id, &challenge.challenge_id, &encoded, IP)
                .is_ok());
            assert_eq!(
                service.verify_challenge(&credential.id, &challenge.challenge_id, &encoded, IP),
                Err(AuthFailure::Unauthorized)
            );
        }
    }

    #[test]
    fn exact_64_byte_der_is_not_misclassified_as_raw_only() {
        let mut encoded = vec![0x30, 62, 0x02, 29];
        encoded.extend([0x01; 29]);
        encoded.extend([0x02, 29]);
        encoded.extend([0x02; 29]);
        assert_eq!(encoded.len(), 64);

        let raw = Signature::from_slice(&encoded).unwrap().to_bytes().to_vec();
        let der = Signature::from_der(&encoded).unwrap().to_bytes().to_vec();
        assert_ne!(raw, der);

        let mut attempted = Vec::new();
        let accepted = verify_signature_candidates(&encoded, |candidate| {
            let candidate = candidate.to_bytes().to_vec();
            attempted.push(candidate.clone());
            candidate == der
        });
        assert!(accepted);
        assert_eq!(attempted, [raw, der]);
    }

    #[test]
    fn expired_challenge_is_consumed() {
        let (_temp, clock, service) = service();
        let (signing, credential) = paired(&service);
        let challenge = service.create_challenge(&credential.id, IP).unwrap();
        let message = URL_SAFE_NO_PAD.decode(&challenge.message).unwrap();
        let signature: Signature = signing.sign(&message);
        let signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
        clock.advance(CHALLENGE_SECS);
        assert_eq!(
            service.verify_challenge(&credential.id, &challenge.challenge_id, &signature, IP),
            Err(AuthFailure::Unauthorized)
        );
        assert_eq!(
            service.verify_challenge(&credential.id, &challenge.challenge_id, &signature, IP),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn a_new_challenge_replaces_the_previous_one_for_that_credential() {
        let (_temp, _clock, service) = service();
        let (_signing, credential) = paired(&service);
        let first = service.create_challenge(&credential.id, IP).unwrap();
        let second = service.create_challenge(&credential.id, IP).unwrap();
        assert_ne!(first.challenge_id, second.challenge_id);
        assert_eq!(
            service.verify_challenge(&credential.id, &first.challenge_id, "invalid", IP),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn pairing_expires_replays_and_invalid_payloads_fail_closed() {
        let (_temp, clock, service) = service();
        let signing = SigningKey::random(&mut OsRng);
        let der = signing.verifying_key().to_public_key_der().unwrap();
        let spki = URL_SAFE_NO_PAD.encode(der.as_bytes());

        let pairing = service.open_pairing_window().unwrap();
        clock.advance(PAIRING_SECS);
        assert_eq!(
            service.register_credential(&pairing.pairing_nonce, "Phone", &spki, IP),
            Err(AuthFailure::Unauthorized)
        );

        let pairing = service.open_pairing_window().unwrap();
        assert!(matches!(
            service.register_credential(&pairing.pairing_nonce, "", &spki, IP),
            Err(AuthFailure::InvalidInput(_))
        ));
        assert_eq!(
            service.register_credential(&pairing.pairing_nonce, "Phone", &spki, IP),
            Err(AuthFailure::Unauthorized)
        );

        let pairing = service.open_pairing_window().unwrap();
        assert!(matches!(
            service.register_credential(&pairing.pairing_nonce, "Phone", "not-spki", IP),
            Err(AuthFailure::InvalidInput(_))
        ));
    }

    #[test]
    fn credential_created_at_remains_unix_wall_time() {
        let (_temp, clock, service) = service();
        clock.set_monotonic(42);
        let (_signing, credential) = paired(&service);
        let summary = service
            .list_credentials()
            .into_iter()
            .find(|item| item.id == credential.id)
            .unwrap();
        assert_eq!(summary.created_at, 1_000_000);
    }

    #[test]
    fn pairing_window_is_consumed_if_monotonic_clock_moves_before_its_issue_time() {
        let (_temp, clock, service) = service();
        let signing = SigningKey::random(&mut OsRng);
        let der = signing.verifying_key().to_public_key_der().unwrap();
        let pairing = service.open_pairing_window().unwrap();
        clock.set_monotonic(999_999);
        assert_eq!(
            service.register_credential(
                &pairing.pairing_nonce,
                "Phone",
                &URL_SAFE_NO_PAD.encode(der.as_bytes()),
                IP
            ),
            Err(AuthFailure::Unauthorized)
        );
        assert_eq!(
            service.register_credential(
                &pairing.pairing_nonce,
                "Phone",
                &URL_SAFE_NO_PAD.encode(der.as_bytes()),
                IP
            ),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn pairing_window_fails_closed_on_boot_mismatch_and_pauses_when_identity_is_missing() {
        let (_temp, clock, service) = service();
        let signing = SigningKey::random(&mut OsRng);
        let spki = URL_SAFE_NO_PAD.encode(
            signing
                .verifying_key()
                .to_public_key_der()
                .unwrap()
                .as_bytes(),
        );

        let mismatched = service.open_pairing_window().unwrap();
        clock.set_boot_id(Some("22222222-2222-2222-2222-222222222222"));
        assert_eq!(
            service.register_credential(&mismatched.pairing_nonce, "Phone", &spki, IP),
            Err(AuthFailure::Unauthorized)
        );
        assert_eq!(
            service.register_credential(&mismatched.pairing_nonce, "Phone", &spki, IP),
            Err(AuthFailure::Unauthorized)
        );

        let missing = service.open_pairing_window().unwrap();
        clock.set_boot_id(None);
        assert_eq!(
            service.register_credential(&missing.pairing_nonce, "Phone", &spki, IP),
            Err(AuthFailure::ClockNotSynchronized)
        );
        clock.set_boot_id(Some("22222222-2222-2222-2222-222222222222"));
        assert_eq!(
            service
                .register_credential(&missing.pairing_nonce, "Phone", &spki, IP)
                .unwrap()
                .label,
            "Phone"
        );
    }

    #[test]
    fn password_rotation_in_another_process_invalidates_existing_sessions() {
        let (temp, clock, service) = service();
        let session = service.password_session(PASSWORD, IP).unwrap();
        let second = AuthService::open_with_clock(
            StateStore::open(temp.path().join("state")).unwrap(),
            clock,
        )
        .unwrap();
        second
            .set_password("a newly rotated management password")
            .unwrap();

        assert_eq!(
            service.validate_token(&session.token, Scope::Read),
            Err(AuthFailure::Unauthorized)
        );
        assert!(service
            .password_session("a newly rotated management password", "192.168.0.77")
            .is_ok());
    }

    #[test]
    fn cli_style_revoke_invalidates_a_live_key_session() {
        let (temp, _clock, service) = service();
        let (signing, credential) = paired(&service);
        let challenge = service.create_challenge(&credential.id, IP).unwrap();
        let message = URL_SAFE_NO_PAD.decode(&challenge.message).unwrap();
        let signature: Signature = signing.sign(&message);
        let session = service
            .verify_challenge(
                &credential.id,
                &challenge.challenge_id,
                &URL_SAFE_NO_PAD.encode(signature.to_bytes()),
                IP,
            )
            .unwrap();
        let maintenance =
            AuthService::open(StateStore::open(temp.path().join("state")).unwrap()).unwrap();
        assert!(maintenance.revoke_credential(&credential.id).unwrap());

        assert_eq!(
            service.validate_token(&session.token, Scope::Read),
            Err(AuthFailure::Unauthorized)
        );
        assert_eq!(
            service.create_challenge(&credential.id, IP),
            Err(AuthFailure::Unauthorized)
        );
    }

    #[test]
    fn concurrent_registration_and_cli_revoke_preserve_both_updates() {
        let (temp, clock, service) = service();
        let server = Arc::new(service);
        let (_old_signing, old) = paired(&server);
        let maintenance = Arc::new(
            AuthService::open_with_clock(
                StateStore::open(temp.path().join("state")).unwrap(),
                clock.clone(),
            )
            .unwrap(),
        );
        let new_signing = SigningKey::random(&mut OsRng);
        let new_spki = URL_SAFE_NO_PAD.encode(
            new_signing
                .verifying_key()
                .to_public_key_der()
                .unwrap()
                .as_bytes(),
        );
        let pairing = server.open_pairing_window().unwrap();
        let barrier = Arc::new(Barrier::new(3));

        let register = {
            let server = Arc::clone(&server);
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                server
                    .register_credential(&pairing.pairing_nonce, "New browser", &new_spki, IP)
                    .unwrap()
            })
        };
        let revoke = {
            let maintenance = Arc::clone(&maintenance);
            let barrier = Arc::clone(&barrier);
            let old_id = old.id.clone();
            std::thread::spawn(move || {
                barrier.wait();
                assert!(maintenance.revoke_credential(&old_id).unwrap());
            })
        };
        barrier.wait();
        let new = register.join().unwrap();
        revoke.join().unwrap();

        let reopened = AuthService::open_with_clock(
            StateStore::open(temp.path().join("state")).unwrap(),
            clock,
        )
        .unwrap();
        let credentials = reopened.list_credentials();
        assert!(credentials
            .iter()
            .any(|credential| credential.id == old.id && credential.revoked));
        assert!(credentials
            .iter()
            .any(|credential| credential.id == new.id && !credential.revoked));
    }

    #[test]
    fn replacing_pair_window_cannot_be_consumed_by_the_previous_nonce() {
        let (temp, clock, service) = service();
        let server = Arc::new(service);
        let maintenance = Arc::new(
            AuthService::open_with_clock(
                StateStore::open(temp.path().join("state")).unwrap(),
                clock,
            )
            .unwrap(),
        );
        let old = server.open_pairing_window().unwrap();
        let signing = SigningKey::random(&mut OsRng);
        let spki = URL_SAFE_NO_PAD.encode(
            signing
                .verifying_key()
                .to_public_key_der()
                .unwrap()
                .as_bytes(),
        );
        let barrier = Arc::new(Barrier::new(3));
        let replace = {
            let maintenance = Arc::clone(&maintenance);
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                maintenance.open_pairing_window().unwrap()
            })
        };
        let use_old = {
            let server = Arc::clone(&server);
            let barrier = Arc::clone(&barrier);
            let old_spki = spki.clone();
            std::thread::spawn(move || {
                barrier.wait();
                server.register_credential(&old.pairing_nonce, "Old window", &old_spki, IP)
            })
        };
        barrier.wait();
        let replacement = replace.join().unwrap();
        let _old_outcome = use_old.join().unwrap();
        assert!(server
            .register_credential(&replacement.pairing_nonce, "Replacement window", &spki, IP)
            .is_ok());
    }

    #[test]
    fn committed_mutations_succeed_when_audit_persistence_is_degraded() {
        let (temp, _clock, service) = service();
        let audit_path = temp.path().join("state/audit.json");
        std::fs::remove_file(&audit_path).unwrap();
        std::fs::create_dir(&audit_path).unwrap();

        let new_password = "password committed despite audit outage";
        service.set_password(new_password).unwrap();
        assert!(service
            .password_session(new_password, "192.168.0.88")
            .is_ok());
        let signing = SigningKey::random(&mut OsRng);
        let spki = URL_SAFE_NO_PAD.encode(
            signing
                .verifying_key()
                .to_public_key_der()
                .unwrap()
                .as_bytes(),
        );
        let pairing = service.open_pairing_window().unwrap();
        let credential = service
            .register_credential(&pairing.pairing_nonce, "Audit outage key", &spki, IP)
            .unwrap();
        assert!(service.revoke_credential(&credential.id).unwrap());
        assert!(service
            .list_credentials()
            .iter()
            .any(|item| item.id == credential.id && item.revoked));
    }

    #[test]
    fn persisted_lockout_state_is_cleaned_and_bounded_on_open() {
        let (temp, clock, service) = service();
        drop(service);
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let attempts = (0..(MAX_LOGIN_CLIENTS + 20))
            .map(|index| {
                (
                    client_key(&format!("192.0.2.{index}")),
                    LoginAttempt {
                        failures: 3,
                        locked_until: 1_000_005,
                        last_failure: 1_000_000 + index as u64,
                    },
                )
            })
            .collect::<HashMap<_, _>>();
        store.write_json(LOGIN_ATTEMPTS_FILE, &attempts).unwrap();
        let _reopened = AuthService::open_with_clock(store.clone(), clock).unwrap();
        let normalized: HashMap<String, LoginAttempt> =
            store.read_json(LOGIN_ATTEMPTS_FILE).unwrap().unwrap();
        assert_eq!(normalized.len(), MAX_LOGIN_CLIENTS);
    }

    #[test]
    fn audit_is_redacted_and_token_state_stores_hashes_only() {
        let (temp, _, service) = service();
        let session = service.password_session(PASSWORD, IP).unwrap();
        let audit = std::fs::read_to_string(temp.path().join("state/audit.json")).unwrap();
        assert!(!audit.contains(IP));
        assert!(audit.contains("redacted"));
        assert!(!audit.contains(PASSWORD));
        assert!(!audit.contains(&session.token));

        let sessions = service.sessions.safe_lock();
        assert_eq!(sessions[0].token_hash.len(), 32);
    }

    #[test]
    fn legacy_audit_clock_trust_remains_unknown() {
        let event: AuditEvent = serde_json::from_value(serde_json::json!({
            "timestamp": 1,
            "event": "legacy",
            "outcome": "success"
        }))
        .unwrap();
        assert_eq!(event.clock_trusted, None);
        let serialized = serde_json::to_value(event).unwrap();
        assert!(serialized.get("clock_trusted").is_none());
    }
}
