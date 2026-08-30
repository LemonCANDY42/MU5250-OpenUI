use std::collections::BTreeMap;
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::b04_io::{B04Io, UbusRead, UbusWrite, WifiField};
use crate::state_store::StateStore;

const WIFI_TRANSACTION_FILE: &str = "wifi-transaction.json";
const WIFI_TRANSACTION_LOCK: &str = "wifi-transaction.lock";
const TRAFFIC_LOCK: &str = "traffic.lock";
const SMS_LOCK: &str = "sms.lock";
const DAILY_AUDIT_FILE: &str = "daily-audit.json";
const DAILY_AUDIT_LOCK: &str = "daily-audit.lock";
const WIFI_CONFIRM_SECONDS: u64 = 120;
const WIFI_ROLLBACK_REAPER_STACK_BYTES: usize = 256 * 1024;
const MAX_DAILY_AUDIT_EVENTS: usize = 128;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WriteResult {
    pub result: &'static str,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SmsSendRequest {
    pub recipient: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ChargingStatus {
    pub capacity_percent: u8,
    pub paused: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TrafficCycleRequest {
    pub reset_day: u8,
    pub enabled: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WifiMasterRequest {
    pub enabled: bool,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WifiTransactionRequest {
    pub transaction_id: String,
    #[serde(default)]
    pub ssid_2g: Option<String>,
    #[serde(default)]
    pub passphrase_2g: Option<String>,
    #[serde(default)]
    pub hidden_2g: Option<bool>,
    #[serde(default)]
    pub main_enabled_2g: Option<bool>,
    #[serde(default)]
    pub channel_2g: Option<String>,
    #[serde(default)]
    pub bandwidth_2g: Option<String>,
    #[serde(default)]
    pub transmit_power_2g: Option<u8>,
    #[serde(default)]
    pub ssid_5g: Option<String>,
    #[serde(default)]
    pub passphrase_5g: Option<String>,
    #[serde(default)]
    pub hidden_5g: Option<bool>,
    #[serde(default)]
    pub main_enabled_5g: Option<bool>,
    #[serde(default)]
    pub channel_5g: Option<String>,
    #[serde(default)]
    pub bandwidth_5g: Option<String>,
    #[serde(default)]
    pub transmit_power_5g: Option<u8>,
    #[serde(default)]
    pub guest_enabled_2g: Option<bool>,
    #[serde(default)]
    pub guest_enabled_5g: Option<bool>,
    #[serde(default)]
    pub guest_ssid: Option<String>,
    #[serde(default)]
    pub guest_passphrase: Option<String>,
    #[serde(default)]
    pub guest_hidden: Option<bool>,
    #[serde(default)]
    pub guest_isolation: Option<bool>,
    #[serde(default)]
    pub guest_active_time_minutes: Option<u16>,
    #[serde(default)]
    pub band_steering_enabled: Option<bool>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WifiConfirmRequest {
    pub transaction_id: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct WifiTransactionGrant {
    pub transaction_id: String,
    pub confirm_within_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct PendingWifiTransaction {
    id: String,
    expires_at: u64,
    old_values: BTreeMap<WifiField, String>,
    #[serde(default)]
    new_values: BTreeMap<WifiField, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct DailyAuditEvent {
    timestamp: u64,
    event: String,
    outcome: String,
}

pub struct DailyService {
    store: StateStore,
    io: Arc<dyn B04Io>,
    wifi_rollback: Arc<dyn WifiRollbackScheduler>,
}

trait WifiRollbackScheduler: Send + Sync {
    fn arm(&self, transaction_id: &str) -> Result<(), String>;
}

struct ProcessWifiRollbackScheduler;

impl WifiRollbackScheduler for ProcessWifiRollbackScheduler {
    fn arm(&self, transaction_id: &str) -> Result<(), String> {
        spawn_wifi_rollback(transaction_id)
    }
}

impl DailyService {
    pub fn open(store: StateStore) -> Result<Self, String> {
        Self::with_io(store, Arc::new(crate::b04_io::SystemB04Io::new()))
    }

    pub fn run_wifi_rollback_worker(
        store: StateStore,
        transaction_id: &str,
    ) -> Result<bool, String> {
        validate_transaction_id(transaction_id)?;
        let service = Self {
            store,
            io: Arc::new(crate::b04_io::SystemB04Io::new()),
            wifi_rollback: Arc::new(ProcessWifiRollbackScheduler),
        };
        service.rollback_pending_wifi(Some(transaction_id))
    }

    fn with_io(store: StateStore, io: Arc<dyn B04Io>) -> Result<Self, String> {
        Self::with_io_and_rollback(store, io, Arc::new(ProcessWifiRollbackScheduler))
    }

    fn with_io_and_rollback(
        store: StateStore,
        io: Arc<dyn B04Io>,
        wifi_rollback: Arc<dyn WifiRollbackScheduler>,
    ) -> Result<Self, String> {
        let service = Self {
            store,
            io,
            wifi_rollback,
        };
        // A reboot or service restart during an unconfirmed Wi-Fi transaction
        // must restore the saved values before the listener can start.
        service.rollback_pending_wifi(None)?;
        Ok(service)
    }

    pub fn sms_send(&self, request: SmsSendRequest) -> Result<WriteResult, String> {
        validate_recipient(&request.recipient)?;
        validate_message(&request.message)?;
        let _lock = self.store.lock_exclusive(SMS_LOCK)?;
        let timestamp = sms_timestamp()?;
        let encoding = sms_encoding(&request.message);
        self.io.ubus_write(UbusWrite::SmsSend {
            number: request.recipient,
            timestamp,
            encoded_message: encode_sms_message(&request.message),
            encoding,
        })?;
        for attempt in 0..20 {
            match sms_command_status(self.io.as_ref(), 4)? {
                3 => {
                    self.audit("sms_send", "success");
                    return Ok(WriteResult { result: "accepted" });
                }
                2 => {
                    self.audit("sms_send", "failed");
                    return Err("SMS send reached the failed state".into());
                }
                _ => {}
            }
            if attempt < 19 {
                thread::sleep(Duration::from_millis(500));
            }
        }
        self.audit("sms_send", "failed");
        Err("SMS send did not reach the completed state".into())
    }

    pub fn charging_status(&self) -> Result<ChargingStatus, String> {
        Ok(ChargingStatus {
            capacity_percent: self.io.battery_capacity()?,
            paused: charger_paused(self.io.as_ref())?,
        })
    }

    pub fn traffic_cycle_update(
        &self,
        request: TrafficCycleRequest,
    ) -> Result<WriteResult, String> {
        if !(1..=31).contains(&request.reset_day) {
            return Err("reset_day must be between 1 and 31".into());
        }
        let _lock = self.store.lock_exclusive(TRAFFIC_LOCK)?;
        let previous = traffic_cycle_state(self.io.as_ref())?;
        let write = self.io.ubus_write(UbusWrite::TrafficCycle {
            reset_day: request.reset_day,
            enabled: request.enabled,
        });
        let applied = write.and_then(|_| traffic_cycle_state(self.io.as_ref()));
        if applied.as_ref() != Ok(&(request.reset_day, request.enabled)) {
            let cause = applied.err().unwrap_or_else(|| {
                "traffic cycle readback did not match the requested state".into()
            });
            let recovery = self.restore_traffic_cycle(previous);
            return match recovery {
                Ok(()) => {
                    self.audit("traffic_cycle_update", "rolled_back");
                    Err(format!("traffic cycle update was rolled back: {cause}"))
                }
                Err(rollback_error) => {
                    self.audit("traffic_cycle_update", "rollback_failed");
                    Err(format!(
                        "traffic cycle update failed and recovery is still pending: {cause}; {rollback_error}"
                    ))
                }
            };
        }
        self.audit("traffic_cycle_update", "success");
        Ok(WriteResult { result: "applied" })
    }

    pub fn wifi_transaction_begin(
        &self,
        request: WifiTransactionRequest,
    ) -> Result<WifiTransactionGrant, String> {
        validate_transaction_id(&request.transaction_id)?;
        let transaction_id = request.transaction_id.clone();
        let mut values = wifi_values_from_request(request)?;
        if values.is_empty() {
            return Err("at least one Wi-Fi setting is required".into());
        }
        let _lock = self.store.lock_exclusive(WIFI_TRANSACTION_LOCK)?;
        if self
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)?
            .is_some()
        {
            return Err("another Wi-Fi transaction is awaiting confirmation".into());
        }
        resolve_multi_band_values(self.io.as_ref(), &mut values)?;
        validate_wifi_switch_state(self.io.as_ref(), &values)?;
        let old_values = self
            .io
            .wifi_values(&values.keys().copied().collect::<Vec<_>>())?;
        if old_values.len() != values.len() {
            return Err("one or more Wi-Fi settings are unavailable on this firmware".into());
        }
        let transaction = PendingWifiTransaction {
            id: transaction_id,
            expires_at: unix_now()?.saturating_add(WIFI_CONFIRM_SECONDS),
            old_values,
            new_values: values.clone(),
        };
        self.store.write_json(WIFI_TRANSACTION_FILE, &transaction)?;
        if let Err(error) = self.wifi_rollback.arm(&transaction.id) {
            self.store.remove(WIFI_TRANSACTION_FILE)?;
            self.audit("wifi_transaction_begin", "rollback_not_armed");
            return Err(error);
        }
        if let Err(apply_error) = self.io.apply_wifi_values(&values) {
            return self.rollback_after_failed_apply(&transaction, apply_error);
        }
        match self
            .io
            .wifi_values(&values.keys().copied().collect::<Vec<_>>())
        {
            Ok(applied) if applied == values => {}
            Ok(_) => {
                return self.rollback_after_failed_apply(
                    &transaction,
                    "Wi-Fi readback did not match the requested settings".into(),
                )
            }
            Err(error) => return self.rollback_after_failed_apply(&transaction, error),
        }
        self.audit("wifi_transaction_begin", "pending");
        Ok(WifiTransactionGrant {
            transaction_id: transaction.id,
            confirm_within_seconds: WIFI_CONFIRM_SECONDS,
        })
    }

    pub fn wifi_master_update(&self, request: WifiMasterRequest) -> Result<WriteResult, String> {
        let _lock = self.store.lock_exclusive(WIFI_TRANSACTION_LOCK)?;
        if self
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)?
            .is_some()
        {
            return Err("another Wi-Fi transaction is awaiting confirmation".into());
        }
        let previous = self.io.wifi_master_enabled()?;
        if previous == request.enabled {
            return Ok(WriteResult { result: "applied" });
        }
        if let Err(error) = self.io.set_wifi_master_enabled(request.enabled) {
            return self.restore_wifi_master(previous, error);
        }
        match self.io.wifi_master_enabled() {
            Ok(value) if value == request.enabled => {
                self.audit("wifi_master_update", "success");
                Ok(WriteResult { result: "applied" })
            }
            Ok(_) => self.restore_wifi_master(
                previous,
                "Wi-Fi master readback did not match the requested state".into(),
            ),
            Err(error) => self.restore_wifi_master(previous, error),
        }
    }

    pub fn wifi_transaction_confirm(&self, transaction_id: &str) -> Result<WriteResult, String> {
        validate_transaction_id(transaction_id)?;
        let _lock = self.store.lock_exclusive(WIFI_TRANSACTION_LOCK)?;
        let transaction = self
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)?
            .ok_or_else(|| "no Wi-Fi transaction is awaiting confirmation".to_string())?;
        if transaction.id != transaction_id {
            return Err("Wi-Fi transaction identifier did not match".into());
        }
        if unix_now()? > transaction.expires_at {
            self.io.apply_wifi_values(&transaction.old_values)?;
            self.store.remove(WIFI_TRANSACTION_FILE)?;
            self.audit("wifi_transaction_confirm", "expired_rolled_back");
            return Err("Wi-Fi confirmation deadline expired; old settings were restored".into());
        }
        if transaction.new_values.is_empty() {
            return Err(
                "Wi-Fi verification snapshot is unavailable; automatic rollback remains armed"
                    .into(),
            );
        }
        let applied = self
            .io
            .wifi_values(&transaction.new_values.keys().copied().collect::<Vec<_>>())?;
        if applied != transaction.new_values {
            return Err(
                "Wi-Fi settings do not match the requested values; automatic rollback remains armed"
                    .into(),
            );
        }
        self.store.remove(WIFI_TRANSACTION_FILE)?;
        self.audit("wifi_transaction_confirm", "success");
        Ok(WriteResult {
            result: "committed",
        })
    }

    pub fn rollback_pending_wifi(&self, expected_id: Option<&str>) -> Result<bool, String> {
        let _lock = self.store.lock_exclusive(WIFI_TRANSACTION_LOCK)?;
        let Some(transaction) = self
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)?
        else {
            return Ok(false);
        };
        if expected_id.is_some_and(|expected| expected != transaction.id) {
            return Ok(false);
        }
        self.io.apply_wifi_values(&transaction.old_values)?;
        self.store.remove(WIFI_TRANSACTION_FILE)?;
        self.audit("wifi_transaction_rollback", "success");
        Ok(true)
    }

    fn rollback_after_failed_apply<T>(
        &self,
        transaction: &PendingWifiTransaction,
        cause: String,
    ) -> Result<T, String> {
        match self.io.apply_wifi_values(&transaction.old_values) {
            Ok(()) => {
                self.store.remove(WIFI_TRANSACTION_FILE)?;
                self.audit("wifi_transaction_begin", "rolled_back");
                Err(format!("Wi-Fi transaction was rolled back: {cause}"))
            }
            Err(rollback_error) => {
                self.audit("wifi_transaction_begin", "rollback_failed");
                Err(format!(
                    "Wi-Fi apply failed and recovery is still pending: {cause}; {rollback_error}"
                ))
            }
        }
    }

    fn restore_traffic_cycle(&self, previous: (u8, bool)) -> Result<(), String> {
        self.io.ubus_write(UbusWrite::TrafficCycle {
            reset_day: previous.0,
            enabled: previous.1,
        })?;
        if traffic_cycle_state(self.io.as_ref())? != previous {
            return Err("traffic cycle rollback readback did not match".into());
        }
        Ok(())
    }

    fn restore_wifi_master<T>(&self, previous: bool, cause: String) -> Result<T, String> {
        match self.io.set_wifi_master_enabled(previous) {
            Ok(()) if self.io.wifi_master_enabled() == Ok(previous) => {
                self.audit("wifi_master_update", "rolled_back");
                Err(format!("Wi-Fi master update was rolled back: {cause}"))
            }
            Ok(()) => {
                self.audit("wifi_master_update", "rollback_failed");
                Err(format!(
                    "Wi-Fi master update failed and recovery readback did not match: {cause}"
                ))
            }
            Err(rollback_error) => {
                self.audit("wifi_master_update", "rollback_failed");
                Err(format!(
                    "Wi-Fi master update failed and recovery is still pending: {cause}; {rollback_error}"
                ))
            }
        }
    }

    fn audit(&self, event: &str, outcome: &str) {
        let result = (|| -> Result<(), String> {
            let _lock = self.store.lock_exclusive(DAILY_AUDIT_LOCK)?;
            let mut events = self
                .store
                .read_json::<Vec<DailyAuditEvent>>(DAILY_AUDIT_FILE)?
                .unwrap_or_default();
            events.push(DailyAuditEvent {
                timestamp: unix_now()?,
                event: event.to_owned(),
                outcome: outcome.to_owned(),
            });
            if events.len() > MAX_DAILY_AUDIT_EVENTS {
                events.drain(0..events.len() - MAX_DAILY_AUDIT_EVENTS);
            }
            self.store.write_json(DAILY_AUDIT_FILE, &events)
        })();
        if let Err(error) = result {
            eprintln!(
                "[daily-audit] persistence degraded: {error}; event={event}; outcome={outcome}"
            );
        }
    }
}

fn spawn_wifi_rollback(transaction_id: &str) -> Result<(), String> {
    validate_transaction_id(transaction_id)?;
    let mut command =
        Command::new(std::env::current_exe().map_err(|_| "cannot resolve agent executable")?);
    command
        .args([
            "wifi-rollback-after",
            transaction_id,
            &WIFI_CONFIRM_SECONDS.to_string(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    // Keep the independent rollback process so it can still restore Wi-Fi if
    // the listener exits, while a small parent-side thread waits for and reaps
    // it after the confirmation window. Creating the reaper before spawning
    // the child preserves the existing fail-closed launch behavior.
    let _completion = spawn_reaped_command(command)?;
    Ok(())
}

fn spawn_reaped_command(
    mut command: Command,
) -> Result<mpsc::Receiver<Result<(), String>>, String> {
    let (launch_sender, launch_receiver) = mpsc::sync_channel::<Result<(), String>>(1);
    let (completion_sender, completion_receiver) = mpsc::sync_channel::<Result<(), String>>(1);

    thread::Builder::new()
        .name("wifi-rollback-reaper".into())
        .stack_size(WIFI_ROLLBACK_REAPER_STACK_BYTES)
        .spawn(move || match command.spawn() {
            Ok(mut child) => {
                let _ = launch_sender.send(Ok(()));
                let result = child
                    .wait()
                    .map(|_| ())
                    .map_err(|_| "cannot reap the independent Wi-Fi rollback worker".into());
                let _ = completion_sender.send(result);
            }
            Err(_) => {
                let _ = launch_sender.send(Err(
                    "cannot start the independent Wi-Fi rollback worker".into(),
                ));
            }
        })
        .map_err(|_| "cannot start the Wi-Fi rollback reaper".to_string())?;

    launch_receiver
        .recv()
        .map_err(|_| "Wi-Fi rollback worker launch status was unavailable".to_string())??;
    Ok(completion_receiver)
}

fn wifi_values_from_request(
    request: WifiTransactionRequest,
) -> Result<BTreeMap<WifiField, String>, String> {
    let mut values = BTreeMap::new();
    for (field, value) in [
        (WifiField::Ssid2g, request.ssid_2g),
        (WifiField::Ssid5g, request.ssid_5g),
    ] {
        if let Some(value) = value {
            validate_ssid(&value)?;
            values.insert(field, value);
        }
    }
    for (field, value) in [
        (WifiField::Passphrase2g, request.passphrase_2g),
        (WifiField::Passphrase5g, request.passphrase_5g),
    ] {
        if let Some(value) = value {
            validate_passphrase(&value)?;
            values.insert(field, value);
        }
    }
    for (field, value) in [
        (WifiField::Hidden2g, request.hidden_2g),
        (WifiField::Hidden5g, request.hidden_5g),
    ] {
        if let Some(value) = value {
            values.insert(field, if value { "1" } else { "0" }.into());
        }
    }
    for (field, value) in [
        (WifiField::MainDisabled2g, request.main_enabled_2g),
        (WifiField::MainDisabled5g, request.main_enabled_5g),
    ] {
        if let Some(enabled) = value {
            values.insert(field, if enabled { "0" } else { "1" }.into());
        }
    }
    for (field, value, five_ghz) in [
        (WifiField::Channel2g, request.channel_2g, false),
        (WifiField::Channel5g, request.channel_5g, true),
    ] {
        if let Some(value) = value {
            values.insert(field, validate_channel(&value, five_ghz)?);
        }
    }
    for (field, value, five_ghz) in [
        (WifiField::Bandwidth2g, request.bandwidth_2g, false),
        (WifiField::Bandwidth5g, request.bandwidth_5g, true),
    ] {
        if let Some(value) = value {
            validate_bandwidth(&value, five_ghz)?;
            values.insert(field, value);
        }
    }
    for (field, value) in [
        (WifiField::TransmitPower2g, request.transmit_power_2g),
        (WifiField::TransmitPower5g, request.transmit_power_5g),
    ] {
        if let Some(value) = value {
            if !matches!(value, 10 | 20 | 30 | 40 | 50 | 60 | 70 | 80 | 90 | 100) {
                return Err("transmit power must be 10 to 100 percent in 10 percent steps".into());
            }
            values.insert(field, value.to_string());
        }
    }
    for (field, value) in [
        (WifiField::GuestDisabled2g, request.guest_enabled_2g),
        (WifiField::GuestDisabled5g, request.guest_enabled_5g),
    ] {
        if let Some(enabled) = value {
            values.insert(field, if enabled { "0" } else { "1" }.into());
        }
    }
    if let Some(value) = request.guest_ssid {
        validate_ssid(&value)?;
        values.insert(WifiField::GuestSsid2g, value.clone());
        values.insert(WifiField::GuestSsid5g, value);
    }
    if let Some(value) = request.guest_passphrase {
        validate_passphrase(&value)?;
        values.insert(WifiField::GuestPassphrase2g, value.clone());
        values.insert(WifiField::GuestPassphrase5g, value);
    }
    for (fields, value) in [
        (
            [WifiField::GuestHidden2g, WifiField::GuestHidden5g],
            request.guest_hidden,
        ),
        (
            [WifiField::GuestIsolation2g, WifiField::GuestIsolation5g],
            request.guest_isolation,
        ),
    ] {
        if let Some(value) = value {
            for field in fields {
                values.insert(field, if value { "1" } else { "0" }.into());
            }
        }
    }
    if let Some(value) = request.guest_active_time_minutes {
        if !matches!(value, 0 | 30 | 60 | 120 | 240 | 480 | 720 | 1440) {
            return Err("guest active time is not one of the supported durations".into());
        }
        for field in [WifiField::GuestActiveTime2g, WifiField::GuestActiveTime5g] {
            values.insert(field, value.to_string());
        }
    }
    if let Some(enabled) = request.band_steering_enabled {
        values.insert(
            WifiField::BandSteeringEnabled,
            if enabled { "1" } else { "0" }.into(),
        );
    }
    Ok(values)
}

fn validate_channel(value: &str, five_ghz: bool) -> Result<String, String> {
    let normalized = if value == "auto" { "0" } else { value };
    let valid = if five_ghz {
        matches!(
            normalized,
            "0" | "36"
                | "40"
                | "44"
                | "48"
                | "52"
                | "56"
                | "60"
                | "64"
                | "100"
                | "104"
                | "108"
                | "112"
                | "116"
                | "120"
                | "124"
                | "128"
                | "132"
                | "136"
                | "140"
                | "149"
                | "153"
                | "157"
                | "161"
                | "165"
        )
    } else {
        matches!(
            normalized,
            "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "10" | "11" | "12" | "13"
        )
    };
    valid
        .then(|| normalized.to_owned())
        .ok_or_else(|| "channel is not in the fixed B04 allowlist".into())
}

fn resolve_multi_band_values(
    io: &dyn B04Io,
    values: &mut BTreeMap<WifiField, String>,
) -> Result<(), String> {
    let requested_enabled = values
        .get(&WifiField::BandSteeringEnabled)
        .map(|value| parse_binary_value(value, "band steering"))
        .transpose()?;
    let touches_primary_state = [
        WifiField::MainDisabled2g,
        WifiField::MainDisabled5g,
        WifiField::Ssid2g,
        WifiField::Ssid5g,
        WifiField::Passphrase2g,
        WifiField::Passphrase5g,
        WifiField::Hidden2g,
        WifiField::Hidden5g,
    ]
    .iter()
    .any(|field| values.contains_key(field));
    if requested_enabled.is_none() && !touches_primary_state {
        return Ok(());
    }
    let fields = [
        WifiField::MainDisabled2g,
        WifiField::MainDisabled5g,
        WifiField::BandSteeringEnabled,
        WifiField::Ssid2g,
        WifiField::Ssid5g,
        WifiField::Passphrase2g,
        WifiField::Passphrase5g,
        WifiField::Encryption2g,
        WifiField::Encryption5g,
        WifiField::Hidden2g,
        WifiField::Hidden5g,
        WifiField::SettingsSync2g,
        WifiField::SettingsSync5g,
    ];
    let mut effective = io.wifi_values(&fields)?;
    if effective.len() != fields.len() {
        return Err("one or more multi-band settings are unavailable on this firmware".into());
    }
    effective.extend(values.clone());
    let enabled = requested_enabled.unwrap_or(parse_binary_value(
        &effective[&WifiField::BandSteeringEnabled],
        "band steering",
    )?);

    if enabled {
        if effective[&WifiField::MainDisabled2g] != "0"
            || effective[&WifiField::MainDisabled5g] != "0"
        {
            return Err("multi-band integration requires both primary Wi-Fi bands enabled".into());
        }
        for (source, destination) in [
            (WifiField::Ssid2g, WifiField::Ssid5g),
            (WifiField::Passphrase2g, WifiField::Passphrase5g),
            (WifiField::Encryption2g, WifiField::Encryption5g),
            (WifiField::Hidden2g, WifiField::Hidden5g),
        ] {
            values.insert(destination, effective[&source].clone());
        }
    } else if requested_enabled == Some(false)
        && effective[&WifiField::Ssid2g] == effective[&WifiField::Ssid5g]
    {
        values.insert(
            WifiField::Ssid5g,
            stock_split_5g_ssid(&effective[&WifiField::Ssid2g])?,
        );
    }

    if enabled || requested_enabled == Some(false) {
        let sync = if enabled { "1" } else { "0" }.to_string();
        values.insert(WifiField::SettingsSync2g, sync.clone());
        values.insert(WifiField::SettingsSync5g, sync);
    }
    Ok(())
}

fn stock_split_5g_ssid(ssid_2g: &str) -> Result<String, String> {
    const SUFFIX: &str = "_5G";
    if ssid_2g.len().saturating_add(SUFFIX.len()) > 32 {
        return Err(
            "5 GHz SSID cannot add the stock _5G suffix within the 32-byte limit; shorten the 2.4 GHz SSID first"
                .into(),
        );
    }
    Ok(format!("{ssid_2g}{SUFFIX}"))
}

fn validate_wifi_switch_state(
    io: &dyn B04Io,
    requested: &BTreeMap<WifiField, String>,
) -> Result<(), String> {
    let relevant = [
        WifiField::MainDisabled2g,
        WifiField::MainDisabled5g,
        WifiField::BandSteeringEnabled,
        WifiField::Ssid2g,
        WifiField::Ssid5g,
        WifiField::Passphrase2g,
        WifiField::Passphrase5g,
        WifiField::Encryption2g,
        WifiField::Encryption5g,
        WifiField::Hidden2g,
        WifiField::Hidden5g,
        WifiField::SettingsSync2g,
        WifiField::SettingsSync5g,
    ];
    if !relevant.iter().any(|field| requested.contains_key(field)) {
        return Ok(());
    }

    let fields = [
        WifiField::MainDisabled2g,
        WifiField::MainDisabled5g,
        WifiField::BandSteeringEnabled,
        WifiField::Ssid2g,
        WifiField::Ssid5g,
        WifiField::Passphrase2g,
        WifiField::Passphrase5g,
        WifiField::Encryption2g,
        WifiField::Encryption5g,
        WifiField::Hidden2g,
        WifiField::Hidden5g,
        WifiField::SettingsSync2g,
        WifiField::SettingsSync5g,
    ];
    let mut effective = io.wifi_values(&fields)?;
    if effective.len() != fields.len() {
        return Err("one or more Wi-Fi switch settings are unavailable on this firmware".into());
    }
    for field in relevant {
        if let Some(value) = requested.get(&field) {
            effective.insert(field, value.clone());
        }
    }

    let enabled_2g = effective[&WifiField::MainDisabled2g] == "0";
    let enabled_5g = effective[&WifiField::MainDisabled5g] == "0";
    if !enabled_2g && !enabled_5g {
        return Err(
            "at least one primary Wi-Fi band must remain enabled; use the Wi-Fi master switch to disable all Wi-Fi"
                .into(),
        );
    }
    let band_steering =
        parse_binary_value(&effective[&WifiField::BandSteeringEnabled], "band steering")?;
    let sync_2g = parse_binary_value(&effective[&WifiField::SettingsSync2g], "2.4 GHz sync")?;
    let sync_5g = parse_binary_value(&effective[&WifiField::SettingsSync5g], "5 GHz sync")?;
    if band_steering && (!enabled_2g || !enabled_5g) {
        return Err("multi-band integration requires both primary Wi-Fi bands enabled".into());
    }
    if band_steering && (!sync_2g || !sync_5g) {
        return Err("multi-band integration requires both stock settings-sync flags".into());
    }
    if band_steering
        && (effective[&WifiField::Ssid2g] != effective[&WifiField::Ssid5g]
            || effective[&WifiField::Passphrase2g] != effective[&WifiField::Passphrase5g]
            || effective[&WifiField::Encryption2g] != effective[&WifiField::Encryption5g]
            || effective[&WifiField::Hidden2g] != effective[&WifiField::Hidden5g])
    {
        return Err(
            "multi-band integration requires matching primary SSID, password and security settings"
                .into(),
        );
    }
    if !band_steering && (sync_2g || sync_5g) {
        return Err(
            "multi-band separation requires both stock settings-sync flags disabled".into(),
        );
    }
    if !band_steering && effective[&WifiField::Ssid2g] == effective[&WifiField::Ssid5g] {
        return Err("multi-band separation requires distinct 2.4 GHz and 5 GHz SSIDs".into());
    }
    Ok(())
}

fn parse_binary_value(value: &str, label: &str) -> Result<bool, String> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(format!("{label} setting was invalid")),
    }
}

fn validate_bandwidth(value: &str, five_ghz: bool) -> Result<(), String> {
    let valid = if five_ghz {
        matches!(value, "auto" | "EHT20" | "EHT40" | "EHT80" | "EHT160")
    } else {
        matches!(value, "auto" | "EHT20" | "EHT40" | "EHT20_40")
    };
    valid
        .then_some(())
        .ok_or_else(|| "bandwidth is not in the fixed B04 allowlist".into())
}

fn validate_ssid(value: &str) -> Result<(), String> {
    let len = value.len();
    if len == 0 || len > 32 || value.chars().any(char::is_control) {
        return Err("SSID must contain 1 to 32 UTF-8 bytes and no control characters".into());
    }
    Ok(())
}

fn validate_passphrase(value: &str) -> Result<(), String> {
    let valid_ascii = value.is_ascii() && !value.chars().any(char::is_control);
    let valid_length = (8..=63).contains(&value.len())
        || (value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()));
    if !valid_ascii || !valid_length {
        return Err(
            "Wi-Fi passphrase must be 8 to 63 printable ASCII characters or 64 hex digits".into(),
        );
    }
    Ok(())
}

fn validate_recipient(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 32
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'+' | b'*' | b'#'))
    {
        return Err(
            "recipient must use only digits, +, * or # and be at most 32 characters".into(),
        );
    }
    Ok(())
}

fn validate_message(value: &str) -> Result<(), String> {
    let count = value.chars().count();
    if count == 0 || count > 160 || value.contains('\0') {
        return Err("message must contain 1 to 160 characters".into());
    }
    Ok(())
}

fn encode_sms_message(value: &str) -> String {
    value
        .encode_utf16()
        .map(|code_unit| format!("{code_unit:04X}"))
        .collect()
}

fn sms_encoding(value: &str) -> &'static str {
    const GSM7: &str = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà^{}\\[~]|€";
    if value.chars().all(|character| GSM7.contains(character)) {
        "GSM7_default"
    } else {
        "UNICODE"
    }
}

fn sms_timestamp() -> Result<String, String> {
    let output = Command::new("date")
        .arg("+%y;%m;%d;%H;%M;%S;%z")
        .stdin(Stdio::null())
        .output()
        .map_err(|_| "cannot generate the SMS timestamp".to_string())?;
    if !output.status.success() {
        return Err("cannot generate the SMS timestamp".into());
    }
    let raw =
        String::from_utf8(output.stdout).map_err(|_| "SMS timestamp was not UTF-8".to_string())?;
    normalize_sms_timestamp(raw.trim())
}

fn normalize_sms_timestamp(raw: &str) -> Result<String, String> {
    let (prefix, zone) = raw
        .rsplit_once(';')
        .ok_or_else(|| "SMS timestamp had an invalid shape".to_string())?;
    if zone.len() != 5 || !matches!(&zone[..1], "+" | "-") {
        return Err("SMS timezone offset had an invalid shape".into());
    }
    let hours: u8 = zone[1..3]
        .parse()
        .map_err(|_| "SMS timezone hours were invalid".to_string())?;
    let minutes: u8 = zone[3..5]
        .parse()
        .map_err(|_| "SMS timezone minutes were invalid".to_string())?;
    if hours > 14 || minutes > 59 {
        return Err("SMS timezone offset was out of range".into());
    }
    let offset = f64::from(hours) + f64::from(minutes) / 60.0;
    let offset = if minutes == 0 {
        format!("{}{}", &zone[..1], hours)
    } else {
        format!("{}{offset}", &zone[..1])
    };
    Ok(format!("{prefix};{offset}"))
}

fn sms_command_status(io: &dyn B04Io, command: u8) -> Result<i64, String> {
    let value = io.ubus_read(UbusRead::SmsCommandStatus { command })?;
    value_i64(value.get("sms_cmd_status_result"))
        .ok_or_else(|| "SMS command status response was invalid".to_string())
}

fn charger_paused(io: &dyn B04Io) -> Result<bool, String> {
    let value = io.ubus_read(UbusRead::ChargerStatus)?;
    value
        .get("direct_power_supply_mode")
        .and_then(Value::as_str)
        .and_then(|value| match value {
            "enable" => Some(true),
            "disable" => Some(false),
            _ => None,
        })
        .ok_or_else(|| "charger status response was invalid".to_string())
}

fn traffic_cycle_state(io: &dyn B04Io) -> Result<(u8, bool), String> {
    let readback = io.ubus_read(UbusRead::DataCycle)?;
    let day = value_u8(readback.get("clearday"))
        .filter(|value| (1..=31).contains(value))
        .ok_or_else(|| "traffic cycle readback did not contain a valid day".to_string())?;
    let enabled = value_bool(readback.get("enable")).ok_or_else(|| {
        "traffic cycle readback did not contain a valid enabled state".to_string()
    })?;
    Ok((day, enabled))
}

fn value_i64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(value) => value.as_i64(),
        Value::String(value) => value.parse().ok(),
        _ => None,
    }
}

fn value_u8(value: Option<&Value>) -> Option<u8> {
    value_i64(value).and_then(|value| u8::try_from(value).ok())
}

fn value_bool(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(value) => Some(*value),
        Value::Number(value) => value.as_u64().and_then(|value| match value {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }),
        Value::String(value) => match value.as_str() {
            "0" | "disable" | "disabled" => Some(false),
            "1" | "enable" | "enabled" => Some(true),
            _ => None,
        },
        _ => None,
    }
}

fn validate_transaction_id(value: &str) -> Result<(), String> {
    if value.len() != 24
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("invalid Wi-Fi transaction identifier".into());
    }
    Ok(())
}

fn unix_now() -> Result<u64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| "system clock is before the Unix epoch".into())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Mutex;

    use serde_json::json;

    use super::*;
    use crate::b04_io::{UbusRead, UbusWrite, WifiInterface};

    struct MockIo {
        wifi: Mutex<BTreeMap<WifiField, String>>,
        wifi_master: Mutex<bool>,
        rollback_armed: Arc<AtomicBool>,
        require_prearmed: AtomicBool,
        paused: Mutex<bool>,
        capacity: Mutex<u8>,
        cycle: Mutex<(u8, bool)>,
        fail_next_cycle_readback: AtomicBool,
        corrupt_cycle_readback: AtomicBool,
    }

    impl MockIo {
        fn new() -> Self {
            Self::with_rollback_flag(Arc::new(AtomicBool::new(false)))
        }

        fn with_rollback_flag(rollback_armed: Arc<AtomicBool>) -> Self {
            Self {
                wifi: Mutex::new(BTreeMap::from([
                    (WifiField::Ssid2g, "owner-wifi".into()),
                    (WifiField::Passphrase2g, "ownerpass88".into()),
                    (WifiField::Encryption2g, "sae-mixed".into()),
                    (WifiField::Hidden2g, "0".into()),
                    (WifiField::MainDisabled2g, "0".into()),
                    (WifiField::Channel2g, "0".into()),
                    (WifiField::Bandwidth2g, "EHT20_40".into()),
                    (WifiField::TransmitPower2g, "30".into()),
                    (WifiField::Ssid5g, "owner-wifi".into()),
                    (WifiField::Passphrase5g, "ownerpass88".into()),
                    (WifiField::Encryption5g, "sae-mixed".into()),
                    (WifiField::Hidden5g, "0".into()),
                    (WifiField::MainDisabled5g, "0".into()),
                    (WifiField::Channel5g, "0".into()),
                    (WifiField::Bandwidth5g, "EHT160".into()),
                    (WifiField::TransmitPower5g, "50".into()),
                    (WifiField::GuestDisabled2g, "1".into()),
                    (WifiField::GuestSsid2g, "guest".into()),
                    (WifiField::GuestPassphrase2g, "guestpass88".into()),
                    (WifiField::GuestHidden2g, "0".into()),
                    (WifiField::GuestIsolation2g, "0".into()),
                    (WifiField::GuestActiveTime2g, "0".into()),
                    (WifiField::GuestDisabled5g, "1".into()),
                    (WifiField::GuestSsid5g, "guest".into()),
                    (WifiField::GuestPassphrase5g, "guestpass88".into()),
                    (WifiField::GuestHidden5g, "0".into()),
                    (WifiField::GuestIsolation5g, "0".into()),
                    (WifiField::GuestActiveTime5g, "0".into()),
                    (WifiField::BandSteeringEnabled, "1".into()),
                    (WifiField::SettingsSync2g, "1".into()),
                    (WifiField::SettingsSync5g, "1".into()),
                ])),
                wifi_master: Mutex::new(true),
                rollback_armed,
                require_prearmed: AtomicBool::new(false),
                paused: Mutex::new(false),
                capacity: Mutex::new(80),
                cycle: Mutex::new((1, false)),
                fail_next_cycle_readback: AtomicBool::new(false),
                corrupt_cycle_readback: AtomicBool::new(false),
            }
        }
    }

    impl B04Io for MockIo {
        fn ubus_read(&self, operation: UbusRead) -> Result<Value, String> {
            match operation {
                UbusRead::SmsCommandStatus { .. } => Ok(json!({"sms_cmd_status_result": 3})),
                UbusRead::ChargerStatus => Ok(json!({
                    "direct_power_supply_mode": if *self.paused.lock().unwrap() { "enable" } else { "disable" }
                })),
                UbusRead::DataCycle => {
                    if self.corrupt_cycle_readback.swap(false, Ordering::SeqCst) {
                        return Ok(json!({"clearday": 0, "enable": 7}));
                    }
                    let (day, enabled) = *self.cycle.lock().unwrap();
                    Ok(json!({"clearday": day, "enable": u8::from(enabled)}))
                }
                _ => Err("unused read".into()),
            }
        }

        fn ubus_write(&self, operation: UbusWrite) -> Result<Value, String> {
            match operation {
                UbusWrite::SmsSend { .. } => Ok(json!({})),
                UbusWrite::TrafficCycle { reset_day, enabled } => {
                    *self.cycle.lock().unwrap() = (reset_day, enabled);
                    if self.fail_next_cycle_readback.swap(false, Ordering::SeqCst) {
                        self.corrupt_cycle_readback.store(true, Ordering::SeqCst);
                    }
                    Ok(json!({}))
                }
            }
        }

        fn wireless_config(&self) -> Result<BTreeMap<String, String>, String> {
            Err("unused".into())
        }

        fn wifi_capabilities(&self) -> Result<BTreeMap<String, String>, String> {
            Err("unused".into())
        }

        fn station_count(&self, _interface: WifiInterface) -> Result<u32, String> {
            Err("unused".into())
        }

        fn active_wifi_channel(&self, _interface: WifiInterface) -> Result<u16, String> {
            Err("unused".into())
        }

        fn wifi_values(&self, fields: &[WifiField]) -> Result<BTreeMap<WifiField, String>, String> {
            let wifi = self.wifi.lock().unwrap();
            Ok(fields
                .iter()
                .filter_map(|field| wifi.get(field).cloned().map(|value| (*field, value)))
                .collect())
        }

        fn apply_wifi_values(&self, values: &BTreeMap<WifiField, String>) -> Result<(), String> {
            if self.require_prearmed.load(Ordering::SeqCst)
                && !self.rollback_armed.load(Ordering::SeqCst)
            {
                return Err("rollback was not armed before Wi-Fi mutation".into());
            }
            self.wifi.lock().unwrap().extend(values.clone());
            Ok(())
        }

        fn wifi_master_enabled(&self) -> Result<bool, String> {
            Ok(*self.wifi_master.lock().unwrap())
        }

        fn set_wifi_master_enabled(&self, enabled: bool) -> Result<(), String> {
            *self.wifi_master.lock().unwrap() = enabled;
            Ok(())
        }

        fn battery_capacity(&self) -> Result<u8, String> {
            Ok(*self.capacity.lock().unwrap())
        }
    }

    fn service() -> (tempfile::TempDir, Arc<MockIo>, DailyService) {
        let temp = tempfile::tempdir().unwrap();
        let io = Arc::new(MockIo::new());
        let service = DailyService::with_io(
            StateStore::open(temp.path().join("state")).unwrap(),
            io.clone(),
        )
        .unwrap();
        (temp, io, service)
    }

    struct MockRollbackScheduler {
        armed: Arc<AtomicBool>,
    }

    impl WifiRollbackScheduler for MockRollbackScheduler {
        fn arm(&self, _transaction_id: &str) -> Result<(), String> {
            self.armed.store(true, Ordering::SeqCst);
            Ok(())
        }
    }

    fn service_with_rollback_tracking() -> (
        tempfile::TempDir,
        Arc<MockIo>,
        Arc<MockRollbackScheduler>,
        DailyService,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let armed = Arc::new(AtomicBool::new(false));
        let io = Arc::new(MockIo::with_rollback_flag(armed.clone()));
        let rollback = Arc::new(MockRollbackScheduler { armed });
        let service = DailyService::with_io_and_rollback(
            StateStore::open(temp.path().join("state")).unwrap(),
            io.clone(),
            rollback.clone(),
        )
        .unwrap();
        (temp, io, rollback, service)
    }

    #[test]
    fn validators_reject_command_and_configuration_injection() {
        assert!(validate_recipient("+61400000000").is_ok());
        assert!(validate_recipient("12; reboot").is_err());
        assert!(validate_ssid("Owner Wi-Fi").is_ok());
        assert!(validate_ssid("bad\nssid").is_err());
        assert!(validate_passphrase("safe passphrase").is_ok());
        assert!(validate_passphrase("short").is_err());
        assert_eq!(validate_channel("auto", false).unwrap(), "0");
        assert!(validate_channel("165", true).is_ok());
        assert!(validate_channel("14", false).is_err());
        assert!(validate_bandwidth("EHT160", true).is_ok());
        assert!(validate_bandwidth("EHT160", false).is_err());
    }

    #[test]
    fn wifi_transaction_identifier_is_known_before_network_mutation() {
        assert!(serde_json::from_str::<WifiTransactionRequest>(r#"{"ssid_2g":"test"}"#).is_err());
        let request = serde_json::from_str::<WifiTransactionRequest>(
            r#"{"transaction_id":"abcdefghijklmnopqrstuvwx","ssid_2g":"test"}"#,
        )
        .unwrap();
        assert_eq!(request.transaction_id, "abcdefghijklmnopqrstuvwx");
        assert!(validate_transaction_id(&request.transaction_id).is_ok());
        assert!(validate_transaction_id("too-short").is_err());
    }

    #[test]
    fn wifi_master_switch_preserves_independent_access_point_state() {
        let (_temp, io, service) = service();
        io.wifi
            .lock()
            .unwrap()
            .insert(WifiField::MainDisabled5g, "1".into());

        service
            .wifi_master_update(WifiMasterRequest { enabled: false })
            .unwrap();
        assert!(!io.wifi_master_enabled().unwrap());
        assert_eq!(
            io.wifi_values(&[WifiField::MainDisabled2g, WifiField::MainDisabled5g])
                .unwrap(),
            BTreeMap::from([
                (WifiField::MainDisabled2g, "0".into()),
                (WifiField::MainDisabled5g, "1".into()),
            ])
        );

        service
            .wifi_master_update(WifiMasterRequest { enabled: true })
            .unwrap();
        assert!(io.wifi_master_enabled().unwrap());
        assert_eq!(
            io.wifi_values(&[WifiField::MainDisabled2g, WifiField::MainDisabled5g])
                .unwrap(),
            BTreeMap::from([
                (WifiField::MainDisabled2g, "0".into()),
                (WifiField::MainDisabled5g, "1".into()),
            ])
        );
    }

    #[test]
    fn wifi_master_switch_cannot_interleave_with_pending_wifi_transaction() {
        let (_temp, io, _rollback, service) = service_with_rollback_tracking();
        service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                hidden_2g: Some(true),
                ..Default::default()
            })
            .unwrap();

        let error = service
            .wifi_master_update(WifiMasterRequest { enabled: false })
            .unwrap_err();

        assert!(error.contains("awaiting confirmation"));
        assert!(io.wifi_master_enabled().unwrap());
    }

    #[test]
    fn rollback_child_is_waited_for_by_the_reaper() {
        let command = Command::new("true");
        let completion = spawn_reaped_command(command).unwrap();
        assert_eq!(
            completion.recv_timeout(Duration::from_secs(2)).unwrap(),
            Ok(())
        );
    }

    #[test]
    fn rollback_child_launch_failure_is_reported_synchronously() {
        let command = Command::new("/definitely/missing/zte-agent-test-command");
        assert!(spawn_reaped_command(command).is_err());
    }

    #[test]
    fn extended_wifi_fields_are_strict_and_transactional() {
        let values = wifi_values_from_request(WifiTransactionRequest {
            channel_2g: Some("auto".into()),
            bandwidth_2g: Some("EHT20_40".into()),
            transmit_power_5g: Some(50),
            guest_enabled_2g: Some(true),
            guest_ssid: Some("Owner Guest".into()),
            guest_isolation: Some(true),
            guest_active_time_minutes: Some(120),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(values[&WifiField::Channel2g], "0");
        assert_eq!(values[&WifiField::Bandwidth2g], "EHT20_40");
        assert_eq!(values[&WifiField::TransmitPower5g], "50");
        assert_eq!(values[&WifiField::GuestDisabled2g], "0");
        assert_eq!(values[&WifiField::GuestSsid5g], "Owner Guest");
        assert_eq!(values[&WifiField::GuestIsolation5g], "1");
        assert_eq!(values[&WifiField::GuestActiveTime2g], "120");

        assert!(wifi_values_from_request(WifiTransactionRequest {
            bandwidth_2g: Some("EHT160".into()),
            ..Default::default()
        })
        .is_err());
        assert!(wifi_values_from_request(WifiTransactionRequest {
            transmit_power_5g: Some(55),
            ..Default::default()
        })
        .is_err());
        assert!(wifi_values_from_request(WifiTransactionRequest {
            guest_active_time_minutes: Some(90),
            ..Default::default()
        })
        .is_err());
    }

    #[test]
    fn independent_main_band_and_steering_switches_use_fixed_transaction_fields() {
        let values = wifi_values_from_request(WifiTransactionRequest {
            main_enabled_2g: Some(false),
            main_enabled_5g: Some(true),
            band_steering_enabled: Some(false),
            ..Default::default()
        })
        .unwrap();

        assert_eq!(values[&WifiField::MainDisabled2g], "1");
        assert_eq!(values[&WifiField::MainDisabled5g], "0");
        assert_eq!(values[&WifiField::BandSteeringEnabled], "0");
    }

    #[test]
    fn disabling_multi_band_uses_the_stock_split_ssid_and_sync_state() {
        let (_temp, io, _rollback, service) = service_with_rollback_tracking();

        service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                band_steering_enabled: Some(false),
                ..Default::default()
            })
            .unwrap();

        let applied = io
            .wifi_values(&[
                WifiField::Ssid2g,
                WifiField::Ssid5g,
                WifiField::BandSteeringEnabled,
                WifiField::SettingsSync2g,
                WifiField::SettingsSync5g,
            ])
            .unwrap();
        assert_eq!(applied[&WifiField::Ssid2g], "owner-wifi");
        assert_eq!(applied[&WifiField::Ssid5g], "owner-wifi_5G");
        assert_eq!(applied[&WifiField::BandSteeringEnabled], "0");
        assert_eq!(applied[&WifiField::SettingsSync2g], "0");
        assert_eq!(applied[&WifiField::SettingsSync5g], "0");

        assert!(service
            .rollback_pending_wifi(Some("abcdefghijklmnopqrstuvwx"))
            .unwrap());
        let restored = io
            .wifi_values(&[
                WifiField::Ssid5g,
                WifiField::BandSteeringEnabled,
                WifiField::SettingsSync2g,
                WifiField::SettingsSync5g,
            ])
            .unwrap();
        assert_eq!(restored[&WifiField::Ssid5g], "owner-wifi");
        assert_eq!(restored[&WifiField::BandSteeringEnabled], "1");
        assert_eq!(restored[&WifiField::SettingsSync2g], "1");
        assert_eq!(restored[&WifiField::SettingsSync5g], "1");
    }

    #[test]
    fn enabling_multi_band_copies_the_primary_identity_and_syncs_both_bands() {
        let (_temp, io, _rollback, service) = service_with_rollback_tracking();
        io.wifi.lock().unwrap().extend(BTreeMap::from([
            (WifiField::Ssid5g, "owner-wifi_5G".into()),
            (WifiField::Passphrase5g, "different-passphrase".into()),
            (WifiField::Encryption5g, "psk2".into()),
            (WifiField::Hidden5g, "1".into()),
            (WifiField::BandSteeringEnabled, "0".into()),
            (WifiField::SettingsSync2g, "0".into()),
            (WifiField::SettingsSync5g, "0".into()),
        ]));

        service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                band_steering_enabled: Some(true),
                ..Default::default()
            })
            .unwrap();

        let applied = io
            .wifi_values(&[
                WifiField::Ssid2g,
                WifiField::Ssid5g,
                WifiField::Passphrase2g,
                WifiField::Passphrase5g,
                WifiField::Encryption2g,
                WifiField::Encryption5g,
                WifiField::Hidden2g,
                WifiField::Hidden5g,
                WifiField::BandSteeringEnabled,
                WifiField::SettingsSync2g,
                WifiField::SettingsSync5g,
            ])
            .unwrap();
        assert_eq!(applied[&WifiField::Ssid5g], applied[&WifiField::Ssid2g]);
        assert_eq!(
            applied[&WifiField::Passphrase5g],
            applied[&WifiField::Passphrase2g]
        );
        assert_eq!(
            applied[&WifiField::Encryption5g],
            applied[&WifiField::Encryption2g]
        );
        assert_eq!(applied[&WifiField::Hidden5g], applied[&WifiField::Hidden2g]);
        assert_eq!(applied[&WifiField::BandSteeringEnabled], "1");
        assert_eq!(applied[&WifiField::SettingsSync2g], "1");
        assert_eq!(applied[&WifiField::SettingsSync5g], "1");
    }

    #[test]
    fn disabling_multi_band_rejects_an_equal_ssid_that_cannot_fit_the_stock_suffix() {
        let (_temp, io, rollback, service) = service_with_rollback_tracking();
        let long_ssid = "123456789012345678901234567890";
        io.wifi.lock().unwrap().extend(BTreeMap::from([
            (WifiField::Ssid2g, long_ssid.into()),
            (WifiField::Ssid5g, long_ssid.into()),
        ]));

        let error = service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                band_steering_enabled: Some(false),
                ..Default::default()
            })
            .unwrap_err();

        assert!(error.contains("5 GHz SSID"));
        assert!(!rollback.armed.load(Ordering::SeqCst));
    }

    #[test]
    fn disconnecting_wifi_transaction_arms_rollback_before_mutation() {
        let (_temp, io, rollback, service) = service_with_rollback_tracking();
        io.require_prearmed.store(true, Ordering::SeqCst);

        let grant = service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                main_enabled_2g: Some(false),
                main_enabled_5g: Some(true),
                band_steering_enabled: Some(false),
                ..Default::default()
            })
            .unwrap();

        assert_eq!(grant.transaction_id, "abcdefghijklmnopqrstuvwx");
        assert!(rollback.armed.load(Ordering::SeqCst));
        assert_eq!(
            io.wifi_values(&[WifiField::MainDisabled2g]).unwrap()[&WifiField::MainDisabled2g],
            "1"
        );
    }

    #[test]
    fn main_band_switches_cannot_remove_the_last_reachable_primary_ap() {
        let (_temp, io, rollback, service) = service_with_rollback_tracking();
        io.wifi
            .lock()
            .unwrap()
            .insert(WifiField::MainDisabled5g, "1".into());

        let error = service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                main_enabled_2g: Some(false),
                band_steering_enabled: Some(false),
                ..Default::default()
            })
            .unwrap_err();

        assert!(error.contains("at least one primary Wi-Fi band"));
        assert!(!rollback.armed.load(Ordering::SeqCst));
        assert_eq!(
            io.wifi_values(&[WifiField::MainDisabled2g]).unwrap()[&WifiField::MainDisabled2g],
            "0"
        );
    }

    #[test]
    fn multi_band_integration_requires_both_primary_aps() {
        let (_temp, _io, rollback, service) = service_with_rollback_tracking();
        let error = service
            .wifi_transaction_begin(WifiTransactionRequest {
                transaction_id: "abcdefghijklmnopqrstuvwx".into(),
                main_enabled_2g: Some(false),
                main_enabled_5g: Some(true),
                band_steering_enabled: Some(true),
                ..Default::default()
            })
            .unwrap_err();

        assert!(error.contains("multi-band integration requires both"));
        assert!(!rollback.armed.load(Ordering::SeqCst));
    }

    #[test]
    fn charging_is_read_only_and_traffic_writes_require_readback() {
        let (_temp, io, service) = service();
        let status = service.charging_status().unwrap();
        assert_eq!(status.capacity_percent, 80);
        assert!(!status.paused);
        service
            .traffic_cycle_update(TrafficCycleRequest {
                reset_day: 15,
                enabled: true,
            })
            .unwrap();
        assert_eq!(*io.cycle.lock().unwrap(), (15, true));
    }

    #[test]
    fn traffic_restores_previous_state_after_bad_readback() {
        let (_temp, io, service) = service();
        io.fail_next_cycle_readback.store(true, Ordering::SeqCst);
        let cycle_error = service
            .traffic_cycle_update(TrafficCycleRequest {
                reset_day: 15,
                enabled: true,
            })
            .unwrap_err();
        assert!(cycle_error.contains("rolled back"));
        assert_eq!(*io.cycle.lock().unwrap(), (1, false));
    }

    #[test]
    fn wifi_confirmation_requires_matching_device_readback() {
        let (_temp, io, service) = service();
        let transaction = PendingWifiTransaction {
            id: "abcdefghijklmnopqrstuvwx".into(),
            expires_at: unix_now().unwrap() + 120,
            old_values: BTreeMap::from([(WifiField::TransmitPower2g, "30".into())]),
            new_values: BTreeMap::from([(WifiField::TransmitPower2g, "40".into())]),
        };
        service
            .store
            .write_json(WIFI_TRANSACTION_FILE, &transaction)
            .unwrap();

        let error = service
            .wifi_transaction_confirm(&transaction.id)
            .unwrap_err();
        assert!(error.contains("automatic rollback remains armed"));
        assert!(service
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)
            .unwrap()
            .is_some());

        io.apply_wifi_values(&transaction.new_values).unwrap();
        assert_eq!(
            service
                .wifi_transaction_confirm(&transaction.id)
                .unwrap()
                .result,
            "committed"
        );
        assert!(service
            .store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)
            .unwrap()
            .is_none());
    }

    #[test]
    fn wifi_pending_record_restores_on_service_restart() {
        let (temp, io, service) = service();
        let store = StateStore::open(temp.path().join("state")).unwrap();
        let old = io
            .wifi_values(&[WifiField::Ssid2g])
            .unwrap()
            .remove(&WifiField::Ssid2g)
            .unwrap();
        let pending = PendingWifiTransaction {
            id: "zyxwvutsrqponmlkjihgfedc".into(),
            expires_at: unix_now().unwrap() + 120,
            old_values: BTreeMap::from([(WifiField::Ssid2g, old.clone())]),
            new_values: BTreeMap::from([(WifiField::Ssid2g, "new-ssid".into())]),
        };
        store.write_json(WIFI_TRANSACTION_FILE, &pending).unwrap();
        io.apply_wifi_values(&BTreeMap::from([(WifiField::Ssid2g, "new-ssid".into())]))
            .unwrap();
        drop(service);
        DailyService::with_io(store.clone(), io.clone()).unwrap();
        assert_eq!(
            io.wifi_values(&[WifiField::Ssid2g]).unwrap()[&WifiField::Ssid2g],
            old
        );
        assert!(store
            .read_json::<PendingWifiTransaction>(WIFI_TRANSACTION_FILE)
            .unwrap()
            .is_none());
    }

    #[test]
    fn timestamp_and_sms_encoding_match_stock_shapes() {
        assert_eq!(
            normalize_sms_timestamp("26;08;16;12;34;56;+0530").unwrap(),
            "26;08;16;12;34;56;+5.5"
        );
        assert_eq!(encode_sms_message("Hi"), "00480069");
        assert_eq!(encode_sms_message("😀"), "D83DDE00");
        assert_eq!(sms_encoding("Hello"), "GSM7_default");
        assert_eq!(sms_encoding("你好"), "UNICODE");
    }
}
