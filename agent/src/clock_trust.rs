use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::state_store::StateStore;

const CLOCK_STATE_FILE: &str = "clock-trust.json";
const CLOCK_LOCK_FILE: &str = "clock-trust.lock";
const BOOT_STATE_FILE: &str = "boot-clock-anchor.json";
const BOOT_LOCK_FILE: &str = "boot-clock-anchor.lock";
const BOOT_STATE_ROOT: &str = "/tmp/u60-clock-trust-v1";
const ROLLBACK_TOLERANCE_SECONDS: u64 = 5 * 60;
const PERSIST_INTERVAL_SECONDS: u64 = 24 * 60 * 60;

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClockTrustStatus {
    Trusted,
    WaitingForSync,
}

pub trait WallClock: Send + Sync {
    fn now(&self) -> u64;
    fn boottime(&self) -> Result<u64, String>;
    fn boot_id(&self) -> Result<String, String>;
}

struct SystemWallClock;

impl WallClock for SystemWallClock {
    fn now(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or_default()
    }

    fn boottime(&self) -> Result<u64, String> {
        let mut value = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        #[cfg(target_os = "linux")]
        let clock_id = libc::CLOCK_BOOTTIME;
        #[cfg(not(target_os = "linux"))]
        let clock_id = libc::CLOCK_MONOTONIC;
        if unsafe { libc::clock_gettime(clock_id, &mut value) } != 0 {
            return Err(format!(
                "read boot clock: {}",
                std::io::Error::last_os_error()
            ));
        }
        u64::try_from(value.tv_sec).map_err(|_| "boot clock returned a negative value".into())
    }

    fn boot_id(&self) -> Result<String, String> {
        #[cfg(target_os = "linux")]
        {
            let value = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
            return validate_boot_id(&value);
        }
        #[cfg(not(target_os = "linux"))]
        {
            Ok("00000000-0000-0000-0000-000000000000".into())
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct ClockState {
    schema_version: u8,
    high_water_unix_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct BootClockAnchor {
    schema_version: u8,
    boot_id: String,
    wall_unix_seconds: u64,
    boottime_seconds: u64,
}

pub struct ClockTrust {
    store: StateStore,
    boot_store: StateStore,
    build_epoch: u64,
    clock: Arc<dyn WallClock>,
}

impl ClockTrust {
    pub fn open(store: StateStore) -> Result<Arc<Self>, String> {
        let boot_root = if cfg!(test) {
            store.root_path().join("clock-trust-boot-test")
        } else {
            PathBuf::from(BOOT_STATE_ROOT)
        };
        let boot_store = StateStore::open(boot_root)?;
        Self::open_with_components(
            store,
            boot_store,
            source_date_epoch()?,
            Arc::new(SystemWallClock),
        )
    }

    #[cfg(test)]
    pub(crate) fn open_with_clock(
        store: StateStore,
        build_epoch: u64,
        clock: Arc<dyn WallClock>,
    ) -> Result<Arc<Self>, String> {
        let boot_store = StateStore::open(store.root_path().join("clock-trust-boot-test"))?;
        Self::open_with_components(store, boot_store, build_epoch, clock)
    }

    fn open_with_components(
        store: StateStore,
        boot_store: StateStore,
        build_epoch: u64,
        clock: Arc<dyn WallClock>,
    ) -> Result<Arc<Self>, String> {
        Ok(Arc::new(Self {
            store,
            boot_store,
            build_epoch,
            clock,
        }))
    }

    pub fn status(&self) -> ClockTrustStatus {
        self.checked_status().unwrap_or_else(|error| {
            eprintln!("[clock-trust] waiting for synchronization: {error}");
            ClockTrustStatus::WaitingForSync
        })
    }

    fn checked_status(&self) -> Result<ClockTrustStatus, String> {
        // Every process takes the locks in this order and reloads both files.
        // The persistent lock makes the 24-hour write cap global, while the
        // boot-scoped tmpfs anchor carries the five-minute bound across Agent,
        // maintenance CLI and rollback-child process boundaries.
        let _persistent_lock = self.store.lock_exclusive(CLOCK_LOCK_FILE)?;
        let _boot_lock = self.boot_store.lock_exclusive(BOOT_LOCK_FILE)?;

        let persisted = match self.store.read_json::<ClockState>(CLOCK_STATE_FILE) {
            Ok(Some(state)) if state.schema_version == 1 => Some(state),
            Ok(None) => None,
            Ok(Some(_)) | Err(_) => return Ok(ClockTrustStatus::WaitingForSync),
        };
        let now = self.clock.now();
        let persisted_floor = persisted
            .as_ref()
            .map_or(0, |state| state.high_water_unix_seconds);
        let required_floor = self.build_epoch.max(persisted_floor);
        if now.saturating_add(ROLLBACK_TOLERANCE_SECONDS) < required_floor {
            return Ok(ClockTrustStatus::WaitingForSync);
        }

        let boot_id = validate_boot_id(&self.clock.boot_id()?)?;
        let boottime = self.clock.boottime()?;
        let anchor = match self
            .boot_store
            .read_json::<BootClockAnchor>(BOOT_STATE_FILE)
        {
            Ok(Some(anchor)) if anchor.schema_version == 1 => Some(anchor),
            Ok(None) => None,
            Ok(Some(_)) | Err(_) => return Ok(ClockTrustStatus::WaitingForSync),
        };

        let mut publish_anchor = anchor.is_none();
        if let Some(anchor) = anchor {
            validate_boot_id(&anchor.boot_id)?;
            if anchor.boot_id == boot_id {
                if boottime < anchor.boottime_seconds {
                    return Ok(ClockTrustStatus::WaitingForSync);
                }
                let expected_wall = anchor
                    .wall_unix_seconds
                    .saturating_add(boottime.saturating_sub(anchor.boottime_seconds));
                if now.saturating_add(ROLLBACK_TOLERANCE_SECONDS) < expected_wall {
                    return Ok(ClockTrustStatus::WaitingForSync);
                }
                // Never lower the anchor. Moving it forward when wall time is
                // ahead preserves the exact five-minute rollback bound without
                // any persistent flash write.
                publish_anchor = now > expected_wall;
            } else {
                // The volatile directory normally disappears on reboot. A boot
                // identity mismatch is nevertheless safe to replace after the
                // persistent/build floor has already passed.
                publish_anchor = true;
            }
        }
        if publish_anchor {
            self.boot_store.write_json(
                BOOT_STATE_FILE,
                &BootClockAnchor {
                    schema_version: 1,
                    boot_id,
                    wall_unix_seconds: now,
                    boottime_seconds: boottime,
                },
            )?;
        }

        let should_persist = match &persisted {
            None => true,
            Some(state) => {
                now >= state
                    .high_water_unix_seconds
                    .saturating_add(PERSIST_INTERVAL_SECONDS)
            }
        };
        if should_persist {
            self.store.write_json(
                CLOCK_STATE_FILE,
                &ClockState {
                    schema_version: 1,
                    high_water_unix_seconds: required_floor.max(now),
                },
            )?;
        }
        Ok(ClockTrustStatus::Trusted)
    }

    pub fn wall_now(&self) -> u64 {
        self.clock.now()
    }
}

fn validate_boot_id(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return Err("boot identity is invalid".into());
    }
    Ok(value.to_owned())
}

fn source_date_epoch() -> Result<u64, String> {
    match option_env!("SOURCE_DATE_EPOCH") {
        Some(value) => value
            .parse()
            .map_err(|_| "SOURCE_DATE_EPOCH must be an unsigned Unix timestamp".into()),
        None if cfg!(test) => Ok(0),
        None => Err("SOURCE_DATE_EPOCH is required for the service build".into()),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Mutex;

    use crate::util::MutexExt;

    use super::*;

    struct TestClock {
        wall: AtomicU64,
        boottime: AtomicU64,
        boot_id: Mutex<String>,
    }

    impl TestClock {
        fn new(now: u64) -> Arc<Self> {
            Arc::new(Self {
                wall: AtomicU64::new(now),
                boottime: AtomicU64::new(10_000),
                boot_id: Mutex::new("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into()),
            })
        }

        fn set_wall(&self, now: u64) {
            self.wall.store(now, Ordering::SeqCst);
        }

        fn advance(&self, seconds: u64) {
            self.wall.fetch_add(seconds, Ordering::SeqCst);
            self.boottime.fetch_add(seconds, Ordering::SeqCst);
        }
    }

    impl WallClock for TestClock {
        fn now(&self) -> u64 {
            self.wall.load(Ordering::SeqCst)
        }

        fn boottime(&self) -> Result<u64, String> {
            Ok(self.boottime.load(Ordering::SeqCst))
        }

        fn boot_id(&self) -> Result<String, String> {
            Ok(self.boot_id.safe_lock().clone())
        }
    }

    fn service(now: u64, build_epoch: u64) -> (tempfile::TempDir, Arc<TestClock>, Arc<ClockTrust>) {
        let temp = tempfile::tempdir().unwrap();
        let clock = TestClock::new(now);
        let trust = ClockTrust::open_with_clock(
            StateStore::open(temp.path().join("state")).unwrap(),
            build_epoch,
            clock.clone(),
        )
        .unwrap();
        (temp, clock, trust)
    }

    #[test]
    fn first_request_waits_until_wall_clock_reaches_the_build_floor() {
        let (temp, clock, trust) = service(1_700_000_000, 1_800_000_000);
        assert_eq!(trust.status(), ClockTrustStatus::WaitingForSync);
        assert!(!temp.path().join("state/clock-trust.json").exists());

        clock.set_wall(1_800_000_000);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
        assert!(temp.path().join("state/clock-trust.json").is_file());
        assert!(
            std::fs::metadata(temp.path().join("state/clock-trust.json"))
                .unwrap()
                .len()
                < 1_024
        );
    }

    #[test]
    fn observed_forward_progress_cannot_be_rolled_back_more_than_five_minutes() {
        let (_temp, clock, trust) = service(1_800_000_000, 1_800_000_000);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
        clock.advance(12 * 60 * 60);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
        clock.set_wall(1_800_000_000 + 60 * 60);
        assert_eq!(trust.status(), ClockTrustStatus::WaitingForSync);
    }

    #[test]
    fn five_minute_clock_adjustment_remains_trusted() {
        let (_temp, clock, trust) = service(1_800_000_000, 1_800_000_000);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
        clock.set_wall(1_800_000_000 - ROLLBACK_TOLERANCE_SECONDS);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
    }

    #[test]
    fn boot_anchor_is_shared_across_process_instances() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let clock = TestClock::new(1_800_000_000);
        let first =
            ClockTrust::open_with_clock(store.clone(), 1_800_000_000, clock.clone()).unwrap();
        let second = ClockTrust::open_with_clock(store, 1_800_000_000, clock.clone()).unwrap();
        assert_eq!(first.status(), ClockTrustStatus::Trusted);
        clock.advance(12 * 60 * 60);
        assert_eq!(first.status(), ClockTrustStatus::Trusted);
        clock.set_wall(1_800_000_000 + 60 * 60);
        assert_eq!(second.status(), ClockTrustStatus::WaitingForSync);
    }

    #[test]
    fn persistent_high_water_survives_restart() {
        let (temp, clock, trust) = service(1_800_000_000, 1_800_000_000);
        assert_eq!(trust.status(), ClockTrustStatus::Trusted);
        drop(trust);
        clock.set_wall(1_700_000_000);
        let reopened = ClockTrust::open_with_clock(
            StateStore::open(temp.path().join("state")).unwrap(),
            1_600_000_000,
            clock,
        )
        .unwrap();
        assert_eq!(reopened.status(), ClockTrustStatus::WaitingForSync);
    }

    #[test]
    fn corrupt_persistent_state_is_preserved_and_never_trusted() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        std::fs::write(temp.path().join("state/clock-trust.json"), b"not-json").unwrap();
        let trust = ClockTrust::open_with_clock(store, 1, TestClock::new(2)).unwrap();
        assert_eq!(trust.status(), ClockTrustStatus::WaitingForSync);
        assert_eq!(
            std::fs::read(temp.path().join("state/clock-trust.json")).unwrap(),
            b"not-json"
        );
    }

    #[test]
    fn corrupt_boot_anchor_is_preserved_and_never_trusted() {
        let (temp, _clock, trust) = service(1_800_000_000, 1_800_000_000);
        let path = temp
            .path()
            .join("state/clock-trust-boot-test/boot-clock-anchor.json");
        std::fs::write(&path, b"not-json").unwrap();
        assert_eq!(trust.status(), ClockTrustStatus::WaitingForSync);
        assert_eq!(std::fs::read(path).unwrap(), b"not-json");
    }

    #[test]
    fn persistent_high_water_is_written_at_most_once_per_day_globally() {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let clock = TestClock::new(1_800_000_000);
        let first =
            ClockTrust::open_with_clock(store.clone(), 1_800_000_000, clock.clone()).unwrap();
        let second = ClockTrust::open_with_clock(store, 1_800_000_000, clock.clone()).unwrap();
        assert_eq!(first.status(), ClockTrustStatus::Trusted);
        let path = temp.path().join("state/clock-trust.json");
        let initial = std::fs::read(&path).unwrap();
        clock.advance(PERSIST_INTERVAL_SECONDS - 1);
        assert_eq!(second.status(), ClockTrustStatus::Trusted);
        assert_eq!(std::fs::read(&path).unwrap(), initial);
        clock.advance(1);
        assert_eq!(first.status(), ClockTrustStatus::Trusted);
        let updated = std::fs::read(&path).unwrap();
        assert_ne!(updated, initial);
        assert_eq!(second.status(), ClockTrustStatus::Trusted);
        assert_eq!(std::fs::read(path).unwrap(), updated);
    }
}
