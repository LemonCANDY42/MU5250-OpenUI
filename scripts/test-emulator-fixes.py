#!/usr/bin/env python3
"""Guarded end-to-end checks for the fixes requested in the safety review.

The script refuses non-loopback targets, verifies the emulator-only WMS object,
and restores LAN, Wi-Fi, network mode, APN mode/profile and band-lock state.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


BASE = "http://127.0.0.1:9090"
PASSWORD = "emu-test-password"


class Api:
    def __init__(self) -> None:
        parsed = urllib.parse.urlparse(BASE)
        if parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise RuntimeError("refusing to test a non-loopback API")
        self.token = ""

    def request(self, method: str, path: str, body=None, headers=None):
        payload = None if body is None else json.dumps(body).encode()
        request_headers = dict(headers or {})
        if payload is not None:
            request_headers["Content-Type"] = "application/json"
        if self.token:
            request_headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            BASE + path, data=payload, method=method, headers=request_headers
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def login(self) -> None:
        status, response = self.request(
            "POST", "/api/auth/login", {"password": PASSWORD}
        )
        assert status == 200 and response["ok"]
        self.token = response["data"]["token"]

    def ok(self, method: str, path: str, body=None, headers=None):
        status, response = self.request(method, path, body, headers)
        assert status == 200 and response.get("ok") is True, (status, response)
        return response.get("data", {})


def test_emulator_guard(api: Api) -> None:
    capabilities = api.ok("GET", "/api/sms/capabilities")
    assert capabilities["object"] == "zte_agent_emu_wms", capabilities
    assert capabilities["available"] and capabilities["ready"]


def test_kill_bloat(api: Api) -> None:
    status, _ = api.request("POST", "/api/system/kill-bloat", {"pids": [1]})
    assert status == 400
    result = api.ok(
        "POST",
        "/api/system/kill-bloat",
        {"pids": [1]},
        {"X-Confirm": "true"},
    )
    assert result["killed"] == [], result
    assert result["skipped"] and result["skipped"][0]["pid"] == 1, result


def test_lan(api: Api) -> None:
    baseline = api.ok("GET", "/api/router/lan")
    assert baseline == {
        "ipaddr": "192.168.0.1",
        "netmask": "255.255.255.0",
        "dhcp_enabled": True,
        "dhcp_start": "192.168.0.2",
        "dhcp_end": "192.168.0.253",
        "lease_seconds": 86400,
    }, baseline
    status, _ = api.request("PUT", "/api/router/lan", {"lan_ipaddr": baseline["ipaddr"]})
    assert status == 400
    changed = {**baseline, "lease_seconds": 82800}
    try:
        api.ok("PUT", "/api/router/lan", changed)
        assert api.ok("GET", "/api/router/lan")["lease_seconds"] == 82800
        disabled = {**changed, "dhcp_enabled": False}
        api.ok("PUT", "/api/router/lan", disabled)
        assert api.ok("GET", "/api/router/lan")["dhcp_enabled"] is False
    finally:
        api.ok("PUT", "/api/router/lan", baseline)
    assert api.ok("GET", "/api/router/lan") == baseline


def test_modem_capabilities_and_locks(api: Api) -> None:
    capabilities = api.ok("GET", "/api/modem/capabilities")
    assert [mode["value"] for mode in capabilities["network_modes"]] == [
        "WL_AND_5G",
        "LTE_AND_5G",
        "Only_5G",
        "WCDMA_AND_LTE",
        "Only_LTE",
        "Only_WCDMA",
    ]
    assert capabilities["lte_bands"] == [
        1, 2, 3, 4, 5, 7, 8, 18, 19, 20, 26, 28, 29, 32, 34, 38, 39,
        40, 41, 42, 43, 48, 66, 71,
    ]
    assert capabilities["nr_sa_bands"][-3:] == [77, 78, 79]

    dashboard = api.ok("GET", "/api/dashboard")
    baseline_mode = dashboard["signal"].get("net_select", "WL_AND_5G")
    status, _ = api.request("PUT", "/api/modem/network-mode", {"net_select": "LTE_ONLY"})
    assert status == 400
    try:
        api.ok("PUT", "/api/modem/network-mode", {"net_select": "WCDMA_AND_LTE"})
    finally:
        api.ok("PUT", "/api/modem/network-mode", {"net_select": baseline_mode})

    lte_mask = str((1 << (1 - 1)) | (1 << (71 - 1)))
    api.ok("POST", "/api/cell/band/lte", {
        "is_lte_band": "1", "lte_band_mask": lte_mask,
        "is_gw_band": "0", "gw_band_mask": "0",
    })
    status, _ = api.request("POST", "/api/cell/band/lte", {
        "is_lte_band": "1", "lte_band_mask": str(1 << 11),
        "is_gw_band": "0", "gw_band_mask": "0",
    })
    assert status == 400
    api.ok("POST", "/api/cell/band/nr", {"nr5g_type": "SA", "nr5g_band": "1,78"})
    status, _ = api.request("POST", "/api/cell/band/nr", {"nr5g_type": "SA", "nr5g_band": "12"})
    assert status == 400
    api.ok("POST", "/api/cell/band/reset")


def test_wifi7(api: Api) -> None:
    baseline = api.ok("GET", "/api/wifi/status")
    assert baseline["htmode_2g"] == "EHT40"
    assert baseline["htmode_5g"] == "EHT160"
    assert baseline["bandwidth_options_2g"] == ["EHT20", "EHT40"]
    assert baseline["bandwidth_options_5g"] == ["EHT20", "EHT40", "EHT80", "EHT160"]
    assert baseline["wifi7_supported"] is True
    status, _ = api.request("PUT", "/api/wifi/settings", {"htmode_2g": "HT40"})
    assert status == 400
    try:
        api.ok("PUT", "/api/wifi/settings", {"htmode_2g": "EHT20"})
        assert api.ok("GET", "/api/wifi/status")["htmode_2g"] == "EHT20"
    finally:
        api.ok("PUT", "/api/wifi/settings", {"htmode_2g": baseline["htmode_2g"]})
    assert api.ok("GET", "/api/wifi/status")["htmode_2g"] == baseline["htmode_2g"]


def test_unavailable_hardware(api: Api) -> None:
    thermal = api.ok("GET", "/api/device/thermal/all")
    battery = api.ok("GET", "/api/device/battery/detail")
    bsp = api.ok("GET", "/api/device/battery-info")
    charge = api.ok("GET", "/api/device/charge-control")
    assert thermal == {"available": False}, thermal
    assert battery["available"] is False
    for key, value in battery.items():
        if key != "available":
            assert value is None, (key, value)
    assert bsp["available"] is False
    assert all(value is None for key, value in bsp.items() if key != "available")
    assert charge["capacity"] is None and charge["battery_available"] is False


def test_apn(api: Api) -> None:
    baseline_mode = api.ok("GET", "/api/router/apn/mode")["apn_mode"]
    baseline_profiles = api.ok("GET", "/api/router/apn/profiles")["apnListArray"]
    original_active = next((profile for profile in baseline_profiles if profile.get("isEnable")), None)
    name = f"CodexEmu{int(time.time()) % 100000}"
    created_id = None
    api.ok("POST", "/api/router/apn/profiles", {
        "profilename": name,
        "wanapn": "emulator.test",
        "username": "",
        "password": "",
        "pppAuthMode": 0,
        "pdpType": 3,
    })
    try:
        profiles = api.ok("GET", "/api/router/apn/profiles")["apnListArray"]
        created = next(profile for profile in profiles if profile.get("profilename") == name)
        created_id = str(created["profileId"])
        assert created["wanapn"] == "emulator.test" and int(created["pdpType"]) == 3
        api.ok("POST", "/api/router/apn/profiles/activate", {"profileId": created_id})
        profiles = api.ok("GET", "/api/router/apn/profiles")["apnListArray"]
        assert any(str(profile["profileId"]) == created_id and profile.get("isEnable") for profile in profiles)
        status, _ = api.request("POST", "/api/router/apn/profiles/delete", {"profileId": created_id})
        assert status == 409
    finally:
        if original_active:
            api.ok("POST", "/api/router/apn/profiles/activate", {"profileId": str(original_active["profileId"])})
        api.ok("PUT", "/api/router/apn/mode", {"apn_mode": int(baseline_mode)})
        if created_id:
            api.ok("POST", "/api/router/apn/profiles/delete", {"profileId": created_id})
    remaining = api.ok("GET", "/api/router/apn/profiles")["apnListArray"]
    assert not any(profile.get("profilename") == name for profile in remaining)


def test_sms(api: Api) -> None:
    messages = api.ok("POST", "/api/sms/list", {"page": 0, "per_page": 500})["messages"]
    unread = next(message for message in messages if int(message["tag"]) == 1)
    api.ok("POST", "/api/sms/read", {"ids": [int(unread["id"])]})
    after_read = api.ok("POST", "/api/sms/list", {"page": 0, "per_page": 500})["messages"]
    assert next(message for message in after_read if message["id"] == unread["id"])["tag"] == 0

    text = f"Emulator SMS {int(time.time())}"
    status, _ = api.request("POST", "/api/sms/send", {"to": "+61400000000", "text": text})
    assert status == 400
    api.ok("POST", "/api/sms/send", {"number": "+61400000000", "message": text})
    messages = api.ok("POST", "/api/sms/list", {"page": 0, "per_page": 500})["messages"]
    encoded = "".join(f"{ord(character):04X}" for character in text)
    sent = next(message for message in messages if message["content"] == encoded)
    assert sent["tag"] == 2 and sent["mem_store"] == 1
    api.ok("POST", "/api/sms/delete", {"ids": [int(sent["id"])]})
    messages = api.ok("POST", "/api/sms/list", {"page": 0, "per_page": 500})["messages"]
    assert not any(message["id"] == sent["id"] for message in messages)


def test_at_read_only(api: Api) -> None:
    result = api.ok("POST", "/api/at/send", {"command": "AT+CSQ", "timeout": 3})
    assert "OK" in result["response"]
    for command in ("AT+CSQ=1", "AT+FOO", "AT+CFUN=1"):
        status, _ = api.request("POST", "/api/at/send", {"command": command, "timeout": 3})
        assert status == 403, (command, status)


def main() -> int:
    api = Api()
    api.login()
    tests = [
        ("emulator guard + SMS capability", test_emulator_guard),
        ("kill-bloat confirmation and PID allowlist", test_kill_bloat),
        ("LAN/DHCP exact payload + restore", test_lan),
        ("network modes and LTE/NR bands", test_modem_capabilities_and_locks),
        ("Wi-Fi 7 EHT bandwidth + restore", test_wifi7),
        ("unavailable sensor semantics", test_unavailable_hardware),
        ("manual APN create/activate/delete + restore", test_apn),
        ("SMS list/read/send/delete", test_sms),
        ("read-only AT query", test_at_read_only),
    ]
    failures = []
    for name, function in tests:
        try:
            function(api)
            print(f"PASS  {name}")
        except Exception as error:  # continue so every restore/fix gets exercised
            failures.append((name, error))
            print(f"FAIL  {name}: {error}")
    if failures:
        print(f"\n{len(failures)} integration check(s) failed", file=sys.stderr)
        return 1
    print(f"\nPASS  all {len(tests)} guarded emulator checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
