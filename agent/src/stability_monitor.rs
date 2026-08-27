use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::mem::MaybeUninit;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::state_store::StateStore;

const STATE_NAME: &str = "stability-monitor-v1.json";
const LOG_NAME: &str = "stability-monitor-v1.jsonl";
const SCHEMA_VERSION: u8 = 1;
const WINDOW_SECONDS: u64 = 7 * 24 * 60 * 60;
const SAMPLE_INTERVAL_SECONDS: u64 = 10 * 60;
const DEADLINE_CONFIRMATION_SECONDS: u64 = SAMPLE_INTERVAL_SECONDS;
const MAX_LOG_BYTES: u64 = 1024 * 1024;
const MAX_RECORD_BYTES: usize = 1024;
const EARLIEST_PLAUSIBLE_UNIX_SECONDS: u64 = 1_704_067_200; // 2024-01-01 UTC
const LATEST_PLAUSIBLE_UNIX_SECONDS: u64 = 4_102_444_800; // 2100-01-01 UTC

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum CompletionReason {
    WindowElapsed,
    StorageLimit,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct MonitorState {
    schema_version: u8,
    started_at_unix_seconds: u64,
    deadline_at_unix_seconds: u64,
    deadline_candidate_at_unix_seconds: Option<u64>,
    completed_at_unix_seconds: Option<u64>,
    completion_reason: Option<CompletionReason>,
    boot_fingerprint_sha256: Option<String>,
    device_reboot_count: u32,
}

impl MonitorState {
    fn new(now: u64, boot_fingerprint_sha256: Option<String>) -> Result<Self, String> {
        Ok(Self {
            schema_version: SCHEMA_VERSION,
            started_at_unix_seconds: now,
            deadline_at_unix_seconds: now
                .checked_add(WINDOW_SECONDS)
                .ok_or_else(|| "monitor deadline overflowed".to_string())?,
            deadline_candidate_at_unix_seconds: None,
            completed_at_unix_seconds: None,
            completion_reason: None,
            boot_fingerprint_sha256,
            device_reboot_count: 0,
        })
    }

    fn validate(&self) -> Result<(), String> {
        if self.schema_version != SCHEMA_VERSION
            || !plausible_wall_time(self.started_at_unix_seconds)
            || self.deadline_at_unix_seconds
                != self
                    .started_at_unix_seconds
                    .checked_add(WINDOW_SECONDS)
                    .ok_or_else(|| "monitor deadline overflowed".to_string())?
            || self.completed_at_unix_seconds.is_some() != self.completion_reason.is_some()
            || self
                .boot_fingerprint_sha256
                .as_ref()
                .is_some_and(|value| !valid_sha256(value))
        {
            return Err("monitor state failed its fixed schema".into());
        }
        if let Some(candidate) = self.deadline_candidate_at_unix_seconds {
            if candidate < self.deadline_at_unix_seconds || !plausible_wall_time(candidate) {
                return Err("monitor deadline confirmation is invalid".into());
            }
        }
        if let (Some(completed), Some(reason)) =
            (self.completed_at_unix_seconds, self.completion_reason)
        {
            let valid_boundary = match reason {
                CompletionReason::WindowElapsed => completed >= self.deadline_at_unix_seconds,
                CompletionReason::StorageLimit => completed >= self.started_at_unix_seconds,
            };
            if !valid_boundary
                || !plausible_wall_time(completed)
                || self.deadline_candidate_at_unix_seconds.is_some()
            {
                return Err("monitor completion time is invalid".into());
            }
        }
        Ok(())
    }

    fn is_completed(&self) -> bool {
        self.completed_at_unix_seconds.is_some()
    }
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum RecordKind {
    Sample,
    Completed,
}

#[derive(Debug, Serialize)]
struct MonitorRecord {
    schema_version: u8,
    kind: RecordKind,
    recorded_at_unix_seconds: u64,
    monitor_elapsed_seconds: u64,
    service_restarted: bool,
    device_rebooted: bool,
    device_reboot_count: u32,
    wall_clock_rollback_observed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    device_uptime_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_uptime_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_cpu_percent: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_rss_kib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_threads: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_total_mib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_available_mib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data_total_mib: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    data_available_mib: Option<u64>,
    monitor_log_bytes_before_record: u64,
}

#[derive(Debug, Clone, Default)]
struct ResourceSnapshot {
    boot_fingerprint_sha256: Option<String>,
    device_uptime_seconds: Option<u64>,
    agent_start_ticks: Option<u64>,
    agent_cpu_ticks: Option<u64>,
    clock_ticks_per_second: Option<u64>,
    agent_rss_kib: Option<u64>,
    agent_threads: Option<u64>,
    memory_total_mib: Option<u64>,
    memory_available_mib: Option<u64>,
    data_total_mib: Option<u64>,
    data_available_mib: Option<u64>,
}

impl ResourceSnapshot {
    fn capture() -> Self {
        let process = fs::read_to_string("/proc/self/stat")
            .ok()
            .and_then(|value| parse_process_stat(&value));
        let memory = fs::read_to_string("/proc/meminfo")
            .ok()
            .and_then(|value| parse_memory(&value));
        let data = read_data_storage();
        let clock_ticks_per_second = system_constant(libc::_SC_CLK_TCK);
        let device_uptime_seconds = fs::read_to_string("/proc/uptime")
            .ok()
            .and_then(|value| parse_uptime(&value));
        let agent_rss_kib = fs::read_to_string("/proc/self/statm")
            .ok()
            .and_then(|value| parse_rss_kib(&value));
        let agent_threads = fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|value| parse_threads(&value));
        Self {
            boot_fingerprint_sha256: read_boot_fingerprint(),
            device_uptime_seconds,
            agent_start_ticks: process.map(|value| value.start_ticks),
            agent_cpu_ticks: process.map(|value| value.cpu_ticks),
            clock_ticks_per_second,
            agent_rss_kib,
            agent_threads,
            memory_total_mib: memory.map(|value| value.0),
            memory_available_mib: memory.map(|value| value.1),
            data_total_mib: data.map(|value| value.0),
            data_available_mib: data.map(|value| value.1),
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct ProcessCounters {
    cpu_ticks: u64,
    device_uptime_seconds: u64,
    clock_ticks_per_second: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ProcessStat {
    cpu_ticks: u64,
    start_ticks: u64,
}

struct StabilityMonitor {
    store: StateStore,
    state: Option<MonitorState>,
    previous_counters: Option<ProcessCounters>,
    previous_wall_time: Option<u64>,
    first_checkpoint: bool,
    state_existed_at_start: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CheckpointOutcome {
    Continue,
    Completed,
}

impl StabilityMonitor {
    fn open(store: StateStore) -> Result<Self, String> {
        let state = store.read_json::<MonitorState>(STATE_NAME)?;
        if let Some(state) = &state {
            state.validate()?;
        } else {
            reject_orphaned_log(&store)?;
        }
        let state_existed_at_start = state.is_some();
        Ok(Self {
            store,
            state,
            previous_counters: None,
            previous_wall_time: None,
            first_checkpoint: true,
            state_existed_at_start,
        })
    }

    fn is_completed(&self) -> bool {
        self.state.as_ref().is_some_and(MonitorState::is_completed)
    }

    fn checkpoint(
        &mut self,
        now: u64,
        snapshot: ResourceSnapshot,
    ) -> Result<CheckpointOutcome, String> {
        if !plausible_wall_time(now) {
            return Err("wall clock is outside the accepted monitor range".into());
        }
        if self.is_completed() {
            return Ok(CheckpointOutcome::Completed);
        }
        if self.state.is_none() {
            let state = MonitorState::new(now, snapshot.boot_fingerprint_sha256.clone())?;
            self.store.write_json(STATE_NAME, &state)?;
            self.state = Some(state);
            self.state_existed_at_start = false;
        }

        let mut state = self.state.clone().expect("state initialized above");
        let mut state_changed = false;
        let device_rebooted = match (
            state.boot_fingerprint_sha256.as_deref(),
            snapshot.boot_fingerprint_sha256.as_deref(),
        ) {
            (Some(previous), Some(current)) if previous != current => {
                state.device_reboot_count = state.device_reboot_count.saturating_add(1);
                state.boot_fingerprint_sha256 = Some(current.to_owned());
                state_changed = true;
                true
            }
            (None, Some(current)) => {
                state.boot_fingerprint_sha256 = Some(current.to_owned());
                state_changed = true;
                false
            }
            _ => false,
        };

        let wall_clock_rollback_observed = self
            .previous_wall_time
            .is_some_and(|previous| now < previous)
            || now < state.started_at_unix_seconds;
        let completion_due = if now >= state.deadline_at_unix_seconds {
            match state.deadline_candidate_at_unix_seconds {
                Some(candidate)
                    if now >= candidate.saturating_add(DEADLINE_CONFIRMATION_SECONDS) =>
                {
                    true
                }
                Some(candidate) if now < candidate => {
                    state.deadline_candidate_at_unix_seconds = Some(now);
                    state_changed = true;
                    false
                }
                Some(_) => false,
                None => {
                    state.deadline_candidate_at_unix_seconds = Some(now);
                    state_changed = true;
                    false
                }
            }
        } else {
            if state.deadline_candidate_at_unix_seconds.take().is_some() {
                state_changed = true;
            }
            false
        };

        let current_counters = process_counters(&snapshot);
        let agent_cpu_percent = self
            .previous_counters
            .zip(current_counters)
            .and_then(|(previous, current)| process_cpu_percent(previous, current));
        let agent_uptime_seconds = agent_uptime_seconds(&snapshot);
        let log_bytes = monitor_log_bytes(&self.store)?;
        let record = MonitorRecord {
            schema_version: SCHEMA_VERSION,
            kind: if completion_due {
                RecordKind::Completed
            } else {
                RecordKind::Sample
            },
            recorded_at_unix_seconds: now,
            monitor_elapsed_seconds: now
                .saturating_sub(state.started_at_unix_seconds)
                .min(WINDOW_SECONDS),
            service_restarted: self.first_checkpoint && self.state_existed_at_start,
            device_rebooted,
            device_reboot_count: state.device_reboot_count,
            wall_clock_rollback_observed,
            device_uptime_seconds: snapshot.device_uptime_seconds,
            agent_uptime_seconds,
            agent_cpu_percent,
            agent_rss_kib: snapshot.agent_rss_kib,
            agent_threads: snapshot.agent_threads,
            memory_total_mib: snapshot.memory_total_mib,
            memory_available_mib: snapshot.memory_available_mib,
            data_total_mib: snapshot.data_total_mib,
            data_available_mib: snapshot.data_available_mib,
            monitor_log_bytes_before_record: log_bytes,
        };

        // Persist lifecycle facts before the best-effort sample append. A crash
        // may lose one sample, but it must not count the same reboot twice or
        // silently reopen a cleared deadline candidate on the next start.
        if state_changed {
            self.store.write_json(STATE_NAME, &state)?;
            self.state = Some(state.clone());
            state_changed = false;
        }

        match append_record(&self.store, &record) {
            Ok(()) => {}
            Err(AppendError::StorageLimit) => {
                state.completed_at_unix_seconds = Some(now);
                state.completion_reason = Some(CompletionReason::StorageLimit);
                state.deadline_candidate_at_unix_seconds = None;
                self.store.write_json(STATE_NAME, &state)?;
                self.state = Some(state);
                return Ok(CheckpointOutcome::Completed);
            }
            Err(AppendError::Other(error)) => return Err(error),
        }

        if completion_due {
            sync_log(&self.store)?;
            state.completed_at_unix_seconds = Some(now);
            state.completion_reason = Some(CompletionReason::WindowElapsed);
            state.deadline_candidate_at_unix_seconds = None;
            state_changed = true;
        }
        if state_changed {
            self.store.write_json(STATE_NAME, &state)?;
        }
        self.state = Some(state);
        self.previous_counters = current_counters;
        self.previous_wall_time = Some(now);
        self.first_checkpoint = false;
        Ok(if completion_due {
            CheckpointOutcome::Completed
        } else {
            CheckpointOutcome::Continue
        })
    }
}

pub fn start(store: StateStore) -> Result<bool, String> {
    let mut monitor = StabilityMonitor::open(store)?;
    if monitor.is_completed() {
        return Ok(false);
    }
    tokio::spawn(async move {
        loop {
            let now = current_unix_seconds();
            let outcome = match now {
                Some(now) => monitor.checkpoint(now, ResourceSnapshot::capture()),
                None => Err("wall clock is outside the accepted monitor range".into()),
            };
            match outcome {
                Ok(CheckpointOutcome::Completed) => break,
                Ok(CheckpointOutcome::Continue) => {}
                Err(error) => eprintln!("[stability-monitor] checkpoint skipped: {error}"),
            }
            tokio::time::sleep(Duration::from_secs(SAMPLE_INTERVAL_SECONDS)).await;
        }
    });
    Ok(true)
}

fn current_unix_seconds() -> Option<u64> {
    let value = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs();
    plausible_wall_time(value).then_some(value)
}

fn plausible_wall_time(value: u64) -> bool {
    (EARLIEST_PLAUSIBLE_UNIX_SECONDS..=LATEST_PLAUSIBLE_UNIX_SECONDS).contains(&value)
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn read_boot_fingerprint() -> Option<String> {
    let value = fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
    let value = value.trim();
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
    {
        return None;
    }
    Some(format!("{:x}", Sha256::digest(value.as_bytes())))
}

fn reject_orphaned_log(store: &StateStore) -> Result<(), String> {
    let path = store.root_path().join(LOG_NAME);
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err("monitor log is not a regular file".into())
        }
        Ok(metadata) if metadata.len() > 0 => {
            Err("monitor log exists without its authoritative state".into())
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("inspect monitor log: {error}")),
    }
}

enum AppendError {
    StorageLimit,
    Other(String),
}

fn append_record(store: &StateStore, record: &MonitorRecord) -> Result<(), AppendError> {
    let mut bytes = serde_json::to_vec(record)
        .map_err(|error| AppendError::Other(format!("serialize monitor record: {error}")))?;
    bytes.push(b'\n');
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(AppendError::Other(
            "monitor record exceeded its fixed bound".into(),
        ));
    }
    let path = store.root_path().join(LOG_NAME);
    let current_size = monitor_log_bytes(store).map_err(AppendError::Other)?;
    if current_size
        .checked_add(bytes.len() as u64)
        .is_none_or(|size| size > MAX_LOG_BYTES)
    {
        return Err(AppendError::StorageLimit);
    }
    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)
        .map_err(|error| AppendError::Other(format!("open monitor log: {error}")))?;
    let metadata = file
        .metadata()
        .map_err(|error| AppendError::Other(format!("inspect monitor log: {error}")))?;
    if !metadata.is_file() {
        return Err(AppendError::Other(
            "monitor log is not a regular file".into(),
        ));
    }
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|error| AppendError::Other(format!("protect monitor log: {error}")))?;
    file.write_all(&bytes)
        .map_err(|error| AppendError::Other(format!("append monitor record: {error}")))
}

fn monitor_log_bytes(store: &StateStore) -> Result<u64, String> {
    let path = store.root_path().join(LOG_NAME);
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err("monitor log is not a regular file".into())
        }
        Ok(metadata) => Ok(metadata.len()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(format!("inspect monitor log: {error}")),
    }
}

fn sync_log(store: &StateStore) -> Result<(), String> {
    let path = store.root_path().join(LOG_NAME);
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("open completed monitor log: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("sync completed monitor log: {error}"))
}

fn parse_uptime(value: &str) -> Option<u64> {
    let seconds = value.split_whitespace().next()?.parse::<f64>().ok()?;
    (seconds.is_finite() && seconds >= 0.0).then_some(seconds.floor() as u64)
}

fn parse_process_stat(value: &str) -> Option<ProcessStat> {
    let fields = value
        .get(value.rfind(')')? + 1..)?
        .split_whitespace()
        .collect::<Vec<_>>();
    let user_ticks = fields.get(11)?.parse::<u64>().ok()?;
    let system_ticks = fields.get(12)?.parse::<u64>().ok()?;
    let start_ticks = fields.get(19)?.parse::<u64>().ok()?;
    Some(ProcessStat {
        cpu_ticks: user_ticks.checked_add(system_ticks)?,
        start_ticks,
    })
}

fn parse_rss_kib(value: &str) -> Option<u64> {
    let resident_pages = value.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    let page_size = system_constant(libc::_SC_PAGESIZE)?;
    resident_pages.checked_mul(page_size)?.checked_div(1024)
}

fn parse_threads(value: &str) -> Option<u64> {
    let line = value.lines().find(|line| line.starts_with("Threads:"))?;
    let mut fields = line.split_whitespace();
    (fields.next()? == "Threads:").then_some(())?;
    let threads = fields.next()?.parse::<u64>().ok()?;
    (threads > 0 && fields.next().is_none()).then_some(threads)
}

fn parse_memory(value: &str) -> Option<(u64, u64)> {
    let mut total_kib = None;
    let mut available_kib = None;
    for line in value.lines() {
        let mut fields = line.split_whitespace();
        match fields.next()? {
            "MemTotal:" if total_kib.is_none() => {
                let value = fields.next()?.parse::<u64>().ok()?;
                (fields.next() == Some("kB") && fields.next().is_none()).then_some(())?;
                total_kib = Some(value);
            }
            "MemAvailable:" if available_kib.is_none() => {
                let value = fields.next()?.parse::<u64>().ok()?;
                (fields.next() == Some("kB") && fields.next().is_none()).then_some(())?;
                available_kib = Some(value);
            }
            _ => {}
        }
    }
    let total_kib = total_kib.filter(|value| *value > 0)?;
    let available_kib = available_kib.filter(|value| *value <= total_kib)?;
    Some((total_kib / 1024, available_kib / 1024))
}

fn read_data_storage() -> Option<(u64, u64)> {
    let path = CString::new("/data").ok()?;
    let mut value = MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `path` is a fixed NUL-terminated string and `value` points to
    // writable storage for one libc `statvfs` result.
    if unsafe { libc::statvfs(path.as_ptr(), value.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: libc returned success and initialized the output structure.
    let value = unsafe { value.assume_init() };
    let block_size = u128::from(if value.f_frsize > 0 {
        value.f_frsize
    } else {
        value.f_bsize
    });
    let total_bytes = u128::from(value.f_blocks).checked_mul(block_size)?;
    let available_bytes = u128::from(value.f_bavail).checked_mul(block_size)?;
    if total_bytes == 0 || available_bytes > total_bytes {
        return None;
    }
    let bytes_per_mib = 1_048_576_u128;
    Some((
        u64::try_from(total_bytes / bytes_per_mib).ok()?,
        u64::try_from(available_bytes / bytes_per_mib).ok()?,
    ))
}

fn system_constant(name: libc::c_int) -> Option<u64> {
    // SAFETY: `name` is one of the documented `_SC_*` constants and sysconf
    // has no pointer arguments.
    let value = unsafe { libc::sysconf(name) };
    (value > 0).then_some(value as u64)
}

fn process_counters(snapshot: &ResourceSnapshot) -> Option<ProcessCounters> {
    Some(ProcessCounters {
        cpu_ticks: snapshot.agent_cpu_ticks?,
        device_uptime_seconds: snapshot.device_uptime_seconds?,
        clock_ticks_per_second: snapshot.clock_ticks_per_second?,
    })
}

fn process_cpu_percent(previous: ProcessCounters, current: ProcessCounters) -> Option<f64> {
    if previous.clock_ticks_per_second != current.clock_ticks_per_second
        || current.cpu_ticks < previous.cpu_ticks
        || current.device_uptime_seconds <= previous.device_uptime_seconds
    {
        return None;
    }
    let cpu_seconds =
        (current.cpu_ticks - previous.cpu_ticks) as f64 / current.clock_ticks_per_second as f64;
    let elapsed_seconds = (current.device_uptime_seconds - previous.device_uptime_seconds) as f64;
    let percent = cpu_seconds * 100.0 / elapsed_seconds;
    percent
        .is_finite()
        .then_some(((percent.clamp(0.0, 100.0) * 1000.0).round()) / 1000.0)
}

fn agent_uptime_seconds(snapshot: &ResourceSnapshot) -> Option<u64> {
    let ticks = snapshot.agent_start_ticks?;
    let ticks_per_second = snapshot.clock_ticks_per_second?;
    let start_seconds = ticks.checked_div(ticks_per_second)?;
    snapshot.device_uptime_seconds?.checked_sub(start_seconds)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;

    fn store() -> (tempfile::TempDir, StateStore) {
        let temp = tempfile::tempdir().unwrap();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        (temp, store)
    }

    fn snapshot(boot: &str, uptime: u64, cpu_ticks: u64) -> ResourceSnapshot {
        ResourceSnapshot {
            boot_fingerprint_sha256: Some(boot.repeat(64)),
            device_uptime_seconds: Some(uptime),
            agent_start_ticks: Some(100),
            agent_cpu_ticks: Some(cpu_ticks),
            clock_ticks_per_second: Some(100),
            agent_rss_kib: Some(2_048),
            agent_threads: Some(1),
            memory_total_mib: Some(1_024),
            memory_available_mib: Some(512),
            data_total_mib: Some(4_096),
            data_available_mib: Some(3_072),
        }
    }

    #[test]
    fn monitor_is_private_bounded_and_computes_consecutive_cpu() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let mut monitor = StabilityMonitor::open(store.clone()).unwrap();
        assert_eq!(
            monitor
                .checkpoint(start, snapshot("a", 1_000, 100))
                .unwrap(),
            CheckpointOutcome::Continue
        );
        assert_eq!(
            monitor
                .checkpoint(start + SAMPLE_INTERVAL_SECONDS, snapshot("a", 1_600, 160))
                .unwrap(),
            CheckpointOutcome::Continue
        );

        let state = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(state.deadline_at_unix_seconds, start + WINDOW_SECONDS);
        assert!(!state.is_completed());
        let path = store.root_path().join(LOG_NAME);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(fs::metadata(path).unwrap().len() < MAX_LOG_BYTES);
        let lines = fs::read_to_string(store.root_path().join(LOG_NAME)).unwrap();
        let values = lines
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(values.len(), 2);
        assert_eq!(values[1]["agent_cpu_percent"], 0.1);
        assert_eq!(values[0]["service_restarted"], false);
        assert!(!lines.contains(&"a".repeat(64)));
    }

    #[test]
    fn restart_and_device_reboot_continue_the_original_window() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let mut first = StabilityMonitor::open(store.clone()).unwrap();
        first.checkpoint(start, snapshot("a", 4_000, 100)).unwrap();
        drop(first);

        let mut restarted = StabilityMonitor::open(store.clone()).unwrap();
        restarted
            .checkpoint(start + 3_600, snapshot("b", 120, 20))
            .unwrap();
        let state = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(state.started_at_unix_seconds, start);
        assert_eq!(state.device_reboot_count, 1);
        let last = fs::read_to_string(store.root_path().join(LOG_NAME))
            .unwrap()
            .lines()
            .last()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .unwrap();
        assert_eq!(last["service_restarted"], true);
        assert_eq!(last["device_rebooted"], true);
        assert!(last.get("agent_cpu_percent").is_none());
    }

    #[test]
    fn seven_day_deadline_requires_confirmation_then_stays_completed() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let deadline = start + WINDOW_SECONDS;
        let mut monitor = StabilityMonitor::open(store.clone()).unwrap();
        monitor.checkpoint(start, snapshot("a", 100, 10)).unwrap();
        assert_eq!(
            monitor
                .checkpoint(deadline, snapshot("a", 200, 20))
                .unwrap(),
            CheckpointOutcome::Continue
        );
        assert_eq!(
            monitor
                .checkpoint(
                    deadline + DEADLINE_CONFIRMATION_SECONDS,
                    snapshot("a", 800, 30)
                )
                .unwrap(),
            CheckpointOutcome::Completed
        );
        let state = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(
            state.completion_reason,
            Some(CompletionReason::WindowElapsed)
        );
        let size = fs::metadata(store.root_path().join(LOG_NAME))
            .unwrap()
            .len();
        let restarted = StabilityMonitor::open(store.clone()).unwrap();
        assert!(restarted.is_completed());
        assert_eq!(
            fs::metadata(store.root_path().join(LOG_NAME))
                .unwrap()
                .len(),
            size
        );
    }

    #[test]
    fn power_off_gap_counts_without_resetting_or_inventing_samples() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let deadline = start + WINDOW_SECONDS;
        let mut first_boot = StabilityMonitor::open(store.clone()).unwrap();
        first_boot
            .checkpoint(start, snapshot("a", 3_000, 10))
            .unwrap();
        drop(first_boot);

        let mut after_power_off = StabilityMonitor::open(store.clone()).unwrap();
        assert_eq!(
            after_power_off
                .checkpoint(deadline + 3_600, snapshot("b", 60, 5))
                .unwrap(),
            CheckpointOutcome::Continue
        );
        drop(after_power_off);

        let mut confirmed = StabilityMonitor::open(store.clone()).unwrap();
        assert_eq!(
            confirmed
                .checkpoint(
                    deadline + 3_600 + DEADLINE_CONFIRMATION_SECONDS,
                    snapshot("b", 660, 15),
                )
                .unwrap(),
            CheckpointOutcome::Completed
        );
        let records = fs::read_to_string(store.root_path().join(LOG_NAME)).unwrap();
        assert_eq!(records.lines().count(), 3);
        let state = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(state.started_at_unix_seconds, start);
        assert_eq!(state.device_reboot_count, 1);
    }

    #[test]
    fn clock_rollback_clears_a_premature_deadline_candidate() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let deadline = start + WINDOW_SECONDS;
        let mut monitor = StabilityMonitor::open(store.clone()).unwrap();
        monitor.checkpoint(start, snapshot("a", 100, 10)).unwrap();
        monitor
            .checkpoint(deadline, snapshot("a", 200, 20))
            .unwrap();
        monitor
            .checkpoint(deadline - 60, snapshot("a", 300, 30))
            .unwrap();
        let state = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(state.deadline_candidate_at_unix_seconds, None);
        assert!(!state.is_completed());
    }

    #[test]
    fn orphaned_log_and_malformed_state_fail_closed() {
        let (_temp, store) = store();
        fs::write(store.root_path().join(LOG_NAME), b"orphan\n").unwrap();
        assert!(StabilityMonitor::open(store.clone()).is_err());
        fs::remove_file(store.root_path().join(LOG_NAME)).unwrap();
        fs::write(store.root_path().join(STATE_NAME), b"{}").unwrap();
        assert!(StabilityMonitor::open(store).is_err());
    }

    #[test]
    fn storage_limit_completes_early_and_never_appends_again() {
        let (_temp, store) = store();
        let start = 1_800_000_000;
        let state = MonitorState::new(start, Some("a".repeat(64))).unwrap();
        store.write_json(STATE_NAME, &state).unwrap();
        fs::write(
            store.root_path().join(LOG_NAME),
            vec![b'x'; MAX_LOG_BYTES as usize],
        )
        .unwrap();

        let mut monitor = StabilityMonitor::open(store.clone()).unwrap();
        assert_eq!(
            monitor
                .checkpoint(start + SAMPLE_INTERVAL_SECONDS, snapshot("a", 1_000, 100))
                .unwrap(),
            CheckpointOutcome::Completed
        );
        let completed = store
            .read_json::<MonitorState>(STATE_NAME)
            .unwrap()
            .unwrap();
        assert_eq!(
            completed.completion_reason,
            Some(CompletionReason::StorageLimit)
        );
        assert_eq!(
            completed.completed_at_unix_seconds,
            Some(start + SAMPLE_INTERVAL_SECONDS)
        );
        completed.validate().unwrap();

        let size = fs::metadata(store.root_path().join(LOG_NAME))
            .unwrap()
            .len();
        assert!(StabilityMonitor::open(store.clone())
            .unwrap()
            .is_completed());
        assert_eq!(
            fs::metadata(store.root_path().join(LOG_NAME))
                .unwrap()
                .len(),
            size
        );
    }

    #[test]
    fn parsers_reject_invalid_kernel_values() {
        assert_eq!(parse_uptime("123.9 4.0"), Some(123));
        assert_eq!(parse_uptime("nan 4.0"), None);
        assert_eq!(parse_threads("Threads:\t2\n"), Some(2));
        assert_eq!(parse_threads("Threads:\t0\n"), None);
        assert_eq!(
            parse_memory("MemTotal: 1024 kB\nMemAvailable: 512 kB\n"),
            Some((1, 0))
        );
        assert_eq!(
            parse_memory("MemTotal: 512 kB\nMemAvailable: 1024 kB\n"),
            None
        );
        assert_eq!(
            parse_process_stat("1 (zte agent) S 0 0 0 0 0 0 0 0 0 0 5 6 0 0 0 0 1 0 100 0 0"),
            Some(ProcessStat {
                cpu_ticks: 11,
                start_ticks: 100,
            })
        );
    }
}
