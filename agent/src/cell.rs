//! Radio selection: network mode, band locking and cell locking.
//! All of it is driven by the dashboard's Signal → Mode & Locking tab.

use serde_json::{json, Value};

use crate::handlers::AppState;
use crate::ubus;
use crate::validate::validate_ubus_input;

pub fn cell_lock_nr(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    if let Err(e) = validate_ubus_input(&parsed) {
        return (400, json!({"ok": false, "error": e}));
    }
    match ubus::call(
        "zte_nwinfo_api",
        "nwinfo_lock_nr_cell",
        Some(&parsed.to_string()),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn cell_lock_lte(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    if let Err(e) = validate_ubus_input(&parsed) {
        return (400, json!({"ok": false, "error": e}));
    }
    match ubus::call(
        "zte_nwinfo_api",
        "nwinfo_lock_lte_cell",
        Some(&parsed.to_string()),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn cell_lock_reset(_state: &AppState) -> (u16, Value) {
    match ubus::call(
        "zte_nwinfo_api",
        "nwinfo_reset_band_cell_setting",
        Some("{}"),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

pub fn cell_band_nr(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    if let Err(e) = validate_ubus_input(&parsed) {
        return (400, json!({"ok": false, "error": e}));
    }
    let params = parsed.to_string();
    eprintln!("[INFO] [band_nr] ubus call zte_nwinfo_api nwinfo_set_nrbandlock '{params}'");
    match ubus::call("zte_nwinfo_api", "nwinfo_set_nrbandlock", Some(&params)) {
        Ok(data) => {
            eprintln!("[INFO] [band_nr] success: {data}");
            (200, json!({"ok": true, "data": data}))
        }
        Err(e) => {
            eprintln!("[WARN] [band_nr] error: {e}");
            (503, json!({"ok": false, "error": e}))
        }
    }
}

pub fn cell_band_lte(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    if let Err(e) = validate_ubus_input(&parsed) {
        return (400, json!({"ok": false, "error": e}));
    }
    let params = parsed.to_string();
    eprintln!("[INFO] [band_lte] ubus call zte_nwinfo_api nwinfo_set_gwl_bandlock '{params}'");
    match ubus::call("zte_nwinfo_api", "nwinfo_set_gwl_bandlock", Some(&params)) {
        Ok(data) => {
            eprintln!("[INFO] [band_lte] success: {data}");
            (200, json!({"ok": true, "data": data}))
        }
        Err(e) => {
            eprintln!("[WARN] [band_lte] error: {e}");
            (503, json!({"ok": false, "error": e}))
        }
    }
}

pub fn cell_band_reset(_state: &AppState) -> (u16, Value) {
    match ubus::call("zte_nwinfo_api", "nwinfo_rest_band_rat", Some("{}")) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}

/// PUT /api/modem/network-mode — preferred RAT (5G SA/NSA, LTE-only, …).
pub fn modem_network_mode_set(_state: &AppState, body: &[u8]) -> (u16, Value) {
    let parsed: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (400, json!({"ok": false, "error": "invalid JSON"})),
    };
    if let Err(e) = validate_ubus_input(&parsed) {
        return (400, json!({"ok": false, "error": e}));
    }
    match ubus::call(
        "zte_nwinfo_api",
        "nwinfo_set_netselect",
        Some(&parsed.to_string()),
    ) {
        Ok(data) => (200, json!({"ok": true, "data": data})),
        Err(e) => (503, json!({"ok": false, "error": e})),
    }
}
