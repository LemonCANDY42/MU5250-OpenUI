#!/usr/bin/env python3
"""Fail closed if the generated-contract iOS target regresses its safe boundary."""

from __future__ import annotations

import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "clients" / "ios" / "OpenU60"
SECURE_APP = IOS / "SecureApp"
PROJECT = IOS / "project.yml"
CANONICAL_OPENAPI = ROOT / "openapi" / "u60-v1.yaml"
IOS_OPENAPI = SECURE_APP / "openapi.yaml"
EXPECTED_APP_SOURCE_LINES = (
    "      - path: SecureApp",
    "      - path: SecureApp/openapi.yaml",
    "      - path: Core/Components/CardView.swift",
    "      - path: Resources",
    "        excludes:",
    "          - Info.plist",
)


class BoundaryError(ValueError):
    """Raised when the declarative iOS compile boundary is not exact."""


def fail(message: str) -> None:
    raise SystemExit(f"iOS boundary check failed: {message}")


def validate_app_sources(project_text: str) -> None:
    """Require the application target's source stanza to match one safe allowlist."""

    lines = project_text.splitlines()
    try:
        target_start = lines.index("  OpenU60:")
        sources_start = lines.index("    sources:", target_start + 1)
    except ValueError as error:
        raise BoundaryError("OpenU60 sources stanza is missing") from error

    if any(
        line and not line.startswith(" ")
        for line in lines[target_start + 1 : sources_start]
    ):
        raise BoundaryError("OpenU60 sources stanza escaped its target")

    source_lines: list[str] = []
    for line in lines[sources_start + 1 :]:
        if line and len(line) - len(line.lstrip(" ")) <= 4:
            break
        if line.strip():
            source_lines.append(line)
    if tuple(source_lines) != EXPECTED_APP_SOURCE_LINES:
        raise BoundaryError(
            "OpenU60 compiled sources must exactly match the approved allowlist"
        )


def run_parser_negative_checks(project_text: str) -> None:
    """Prove broad and individually selected legacy sources fail the parser."""

    marker = "      - path: SecureApp\n"
    if marker not in project_text:
        raise BoundaryError("cannot construct parser negative checks")
    for forbidden_line in (
        "      - path: Core\n",
        "      - path: Core/Networking/AgentClient.swift\n",
    ):
        candidate = project_text.replace(marker, forbidden_line + marker, 1)
        try:
            validate_app_sources(candidate)
        except BoundaryError:
            continue
        raise BoundaryError(
            f"source parser accepted negative fixture {forbidden_line.strip()!r}"
        )


if not IOS_OPENAPI.is_symlink():
    fail("SecureApp/openapi.yaml must be a symlink to the canonical contract")
if IOS_OPENAPI.resolve() != CANONICAL_OPENAPI.resolve():
    fail("iOS OpenAPI input does not resolve to openapi/u60-v1.yaml")

project = PROJECT.read_text(encoding="utf-8")
try:
    validate_app_sources(project)
    run_parser_negative_checks(project)
except BoundaryError as error:
    fail(str(error))
required_project_fragments = (
    "exactVersion: 1.13.0",
    "exactVersion: 1.12.0",
    "exactVersion: 1.3.1",
    "exactVersion: 1.6.0",
    "plugin: OpenAPIGenerator",
    "- path: SecureAppTests\n",
)
for fragment in required_project_fragments:
    if fragment not in project:
        fail(f"project.yml is missing {fragment.strip()!r}")

config = (SECURE_APP / "openapi-generator-config.yaml").read_text(encoding="utf-8")
if "  - types" not in config or "  - client" not in config:
    fail("Swift OpenAPI generation must include both types and client")

with (IOS / "Resources" / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
if "NSAppTransportSecurity" in info:
    fail("Info.plist must not weaken App Transport Security")

compiled_swift = sorted(SECURE_APP.rglob("*.swift")) + [
    IOS / "Core" / "Components" / "CardView.swift"
]
source = "\n".join(path.read_text(encoding="utf-8") for path in compiled_swift)
for forbidden in (
    "http://",
    ":9090",
    '"/api/',
    "router_password",
    "NSAllowsArbitraryLoads",
    "SecTrustSetAnchorCertificates",
    "UserDefaults",
    "@AppStorage",
    "Not exposed by the iOS public API",
    "updateWifiMaster",
    "setWifiMasterEnabled",
    "bandSteeringEnabled:",
    'Toggle("Wi-Fi master switch"',
    'Toggle("Multi-band integration"',
):
    if forbidden in source:
        fail(f"compiled source contains forbidden marker {forbidden!r}")

required_source_fragments = (
    "SecureEnclave.P256.Signing.PrivateKey",
    "#if targetEnvironment(simulator)",
    "SecTrustEvaluateWithError",
    "SPKIPinningDelegate",
    "URLSessionConfiguration.ephemeral",
    "willPerformHTTPRedirection",
    "completionHandler(nil)",
    "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
    "SessionVault",
    "client.getDashboardSnapshot()",
    "applyDashboard(snapshot, charging: snapshot.charging)",
)
for fragment in required_source_fragments:
    if fragment not in source:
        fail(f"compiled source is missing {fragment!r}")

print("iOS boundary check passed")
