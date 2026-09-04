#!/usr/bin/env python3
"""Fail closed when the B04 agent drifts from its public contract.

Public behavior is owned by `openapi/u60-v1.yaml`; the agent and same-origin
dashboard may expose or consume only those versioned paths.

Run from anywhere: python3 scripts/check-api-contract.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER_RS = ROOT / "agent/src/server.rs"
OPENAPI = ROOT / "openapi/u60-v1.yaml"
WEB_SOURCES = tuple(
    sorted(path for path in (ROOT / "web-app/src").rglob("*") if path.is_file())
)

ROUTE_RE = re.compile(
    r'\.route\(\s*"(/(?:api|v1)/[^"]+)"\s*,\s*(get|post|put|delete|patch)\('
)
CHAINED_ROUTE_RE = re.compile(
    r'\.route\(\s*"(/(?:api|v1)/[^"]+)"\s*,\s*'
    r'(?:get|post|put|delete|patch)\([^)]*\)\s*\.\s*'
    r'(get|post|put|delete|patch)\('
)
OPENAPI_PATH_RE = re.compile(r"^  (/v1/[a-zA-Z0-9/_-]+):\s*$", re.MULTILINE)
OPENAPI_ANY_PATH_RE = re.compile(r"^  (/[a-zA-Z0-9/_-]+):\s*$", re.MULTILINE)
OPENAPI_METHOD_RE = re.compile(r"^    (get|post|put|delete|patch):\s*$")
OPENAPI_STATUS_RE = re.compile(r'^        "([1-5][0-9][0-9])":\s*$')
FORBIDDEN_PUBLIC_PATHS = {
    "/api/at/send",
    "/api/at/port",
    "/api/system/kill-bloat",
    "/v1/wifi/master",
}
EXPECTED_BOOTSTRAP_PATHS: set[str] = set()
REQUIRED_RESPONSE_CODES = {
    ("Get", "/v1/device"): {"200", "401", "403", "500"},
    ("Get", "/v1/capabilities"): {"200", "401", "403", "500"},
    ("Get", "/v1/status/dashboard"): {"200", "401", "403", "500"},
    ("Get", "/v1/status/system"): {"200", "401", "403", "500", "501", "503"},
    ("Get", "/v1/status/battery"): {"200", "401", "403", "500", "501", "503"},
    ("Get", "/v1/status/thermal"): {"200", "401", "403", "500", "501", "503"},
    ("Post", "/v1/auth/password/session"): {
        "200", "400", "401", "403", "413", "429", "500", "503"
    },
    ("Post", "/v1/auth/password/advanced"): {
        "200", "400", "401", "403", "413", "429", "500", "503"
    },
    ("Post", "/v1/auth/challenge"): {"200", "400", "401", "403", "413", "500"},
    ("Post", "/v1/auth/challenge/verify"): {
        "200", "400", "401", "403", "413", "500"
    },
    ("Post", "/v1/auth/pair"): {"200", "400", "401", "403", "413", "500"},
    ("Post", "/v1/device/reboot"): {
        "200", "400", "401", "403", "409", "413", "500", "503"
    },
    ("Post", "/v1/device/power-off"): {
        "200", "400", "401", "403", "409", "413", "500", "503"
    },
    ("Post", "/v1/sms/send"): {"200", "400", "401", "403", "413", "500", "503"},
    ("Get", "/v1/charging"): {"200", "401", "403", "500", "503"},
    ("Put", "/v1/traffic/cycle"): {"200", "400", "401", "403", "413", "500", "503"},
    ("Post", "/v1/wifi/transaction"): {"200", "400", "401", "403", "409", "413", "500", "503"},
    ("Post", "/v1/wifi/transaction/confirm"): {"200", "400", "401", "403", "409", "413", "500", "503"},
}


def read(path: Path) -> str:
    if not path.exists():
        sys.exit(f"missing file: {path.relative_to(ROOT)}")
    return path.read_text()


def report(title: str, items: set[str], hint: str) -> bool:
    if not items:
        return True
    print(f"\n  {title}")
    for item in sorted(items):
        print(f"    - {item}")
    print(f"    -> {hint}")
    return False


def openapi_operations(source: str) -> dict[tuple[str, str], set[str]]:
    """Parse the deliberately simple path/method/response skeleton.

    Full schema validity is checked by the pinned OpenAPI generator. This
    parser owns only the public route and status-code agreement invariant.
    """
    operations: dict[tuple[str, str], set[str]] = {}
    path: str | None = None
    operation: tuple[str, str] | None = None
    for line in source.splitlines():
        if line and not line.startswith(" "):
            path = None
            operation = None
        path_match = OPENAPI_PATH_RE.match(line)
        if path_match:
            path = path_match.group(1)
            operation = None
            continue
        method_match = OPENAPI_METHOD_RE.match(line)
        if path and method_match:
            method = method_match.group(1).capitalize()
            operation = (method, path)
            operations.setdefault(operation, set())
            continue
        status_match = OPENAPI_STATUS_RE.match(line)
        if operation and status_match:
            operations[operation].add(status_match.group(1))
    return operations


def openapi_schema_properties(source: str, schema: str) -> set[str]:
    """Return direct property names from one top-level component schema."""
    lines = source.splitlines()
    marker = f"    {schema}:"
    try:
        start = lines.index(marker)
    except ValueError:
        return set()
    properties: set[str] = set()
    in_properties = False
    for line in lines[start + 1 :]:
        if line.startswith("    ") and not line.startswith("      "):
            break
        if line == "      properties:":
            in_properties = True
            continue
        if in_properties:
            match = re.match(r"^        ([a-zA-Z0-9_]+):\s*$", line)
            if match:
                properties.add(match.group(1))
    return properties


def main() -> int:
    server_source = read(SERVER_RS)
    routes = {(method.capitalize(), path) for path, method in ROUTE_RE.findall(server_source)}
    routes |= {
        (method.capitalize(), path)
        for path, method in CHAINED_ROUTE_RE.findall(server_source)
    }
    server_paths = {path for _, path in routes}
    server_v1 = {path for path in server_paths if path.startswith("/v1/")}
    server_legacy = {path for path in server_paths if path.startswith("/api/")}
    openapi_source = read(OPENAPI)
    contract_v1 = set(OPENAPI_PATH_RE.findall(openapi_source))
    contract_legacy = {
        path
        for path in OPENAPI_ANY_PATH_RE.findall(openapi_source)
        if not path.startswith("/v1/")
    }
    contract_operations = openapi_operations(openapi_source)
    server_v1_operations = {route for route in routes if route[1].startswith("/v1/")}

    web_forbidden: set[str] = set()
    for source_path in WEB_SOURCES:
        source = read(source_path)
        web_forbidden |= {
            f"{source_path.relative_to(ROOT)}: {path}"
            for path in FORBIDDEN_PUBLIC_PATHS
            if path in source
        }

    print(
        f"agent routes {len(server_v1)} versioned paths and "
        f"{len(server_legacy)} legacy paths; "
        f"OpenAPI declares {len(contract_v1)} paths"
    )

    ok = True
    ok &= report(
        "Agent /v1 routes missing from OpenAPI:",
        server_v1 - contract_v1,
        "document the route before serving it",
    )
    ok &= report(
        "OpenAPI paths not routed by the agent:",
        contract_v1 - server_v1,
        "implement the route or remove the premature contract",
    )
    ok &= report(
        "Agent method/path operations missing from OpenAPI:",
        {f"{method} {path}" for method, path in server_v1_operations - contract_operations.keys()},
        "declare the exact HTTP operation before routing it",
    )
    ok &= report(
        "OpenAPI operations not routed by the agent:",
        {f"{method} {path}" for method, path in contract_operations.keys() - server_v1_operations},
        "remove premature operations or implement the exact route",
    )

    response_drift: set[str] = set()
    for operation, required in REQUIRED_RESPONSE_CODES.items():
        declared = contract_operations.get(operation, set())
        missing = required - declared
        if missing:
            response_drift.add(f"{operation[0]} {operation[1]} missing {','.join(sorted(missing))}")
    ok &= report(
        "OpenAPI operations omit runtime response statuses:",
        response_drift,
        "declare every typed success, auth, unsupported and degraded response",
    )
    ok &= report(
        "Unexpected legacy agent routes:",
        server_legacy - EXPECTED_BOOTSTRAP_PATHS,
        "new clients may only use /v1; remove the legacy route",
    )
    ok &= report(
        "Unexpected non-versioned OpenAPI paths:",
        contract_legacy,
        "the public contract is versioned under /v1 only",
    )
    ok &= report(
        "Forbidden public routes are still routed:",
        server_paths & FORBIDDEN_PUBLIC_PATHS,
        "raw AT and process-killing surfaces are permanently excluded",
    )
    ok &= report(
        "Forbidden public paths remain in dashboard or mock sources:",
        web_forbidden,
        "delete the dormant client or fixture binding",
    )

    forbidden_contract_terms = {
        term for term in ("/api/at", "kill-bloat", "command:", "shell") if term in openapi_source
    }
    ok &= report(
        "Forbidden command surfaces appear in OpenAPI:",
        forbidden_contract_terms,
        "the versioned domain contract must not expose generic execution",
    )

    retired_wifi_write_fields = {"band_steering_enabled"} & openapi_schema_properties(
        openapi_source, "WifiTransactionRequest"
    )
    ok &= report(
        "Retired Wi-Fi coordination writes remain in OpenAPI:",
        retired_wifi_write_fields,
        "keep multi-band state read-only and remove the transaction write field",
    )

    print("\nOK: B04 public surface matches OpenAPI." if ok else "\nFAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
