#!/usr/bin/env python3
"""Combine a stdin pair-open grant with a verified public device bundle."""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime as dt
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


COMPLETE = "u60-device-bundle-complete-v1"
NONCE = re.compile(r"^[A-Za-z0-9_-]{43}$")
PIN = re.compile(r"^sha256/[A-Za-z0-9+/]{43}=$")


def die(message: str) -> None:
    raise SystemExit(f"pairing payload: {message}")


parser = argparse.ArgumentParser()
parser.add_argument("bundle_dir", type=Path)
parser.add_argument(
    "base_url",
    choices=(
        "https://u60.local:9443",
        "https://u60.local:19443",
        "https://192.168.0.1:9443",
    ),
)
args = parser.parse_args()

bundle = args.bundle_dir.resolve(strict=True)
if not bundle.is_dir() or args.bundle_dir.is_symlink():
    die("bundle directory must be a real directory")
marker = bundle / "device-bundle.complete"
pin_file = bundle / "device-spki-pin.txt"
if marker.is_symlink() or pin_file.is_symlink():
    die("bundle files must not be symlinks")
if marker.read_text(encoding="ascii").strip() != COMPLETE:
    die("device bundle completion marker is invalid")
pin = pin_file.read_text(encoding="ascii").strip()
if not PIN.fullmatch(pin):
    die("SPKI pin format is invalid")
try:
    if len(base64.b64decode(pin.removeprefix("sha256/"), validate=True)) != 32:
        die("SPKI pin length is invalid")
except (ValueError, binascii.Error):
    die("SPKI pin encoding is invalid")

parsed_url = urlsplit(args.base_url)
if (
    parsed_url.scheme != "https"
    or parsed_url.hostname not in ("u60.local", "192.168.0.1")
    or parsed_url.port not in (9443, 19443)
    or (parsed_url.hostname == "192.168.0.1" and parsed_url.port != 9443)
):
    die("base URL is outside the fixed local HTTPS profile")

try:
    grant = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeDecodeError):
    die("stdin is not pair-open JSON")
if set(grant) != {"pairing_nonce", "expires_at", "registration_path"}:
    die("pair-open JSON fields do not match the expected contract")
nonce = grant["pairing_nonce"]
expires_at = grant["expires_at"]
if not isinstance(nonce, str) or not NONCE.fullmatch(nonce):
    die("pairing nonce format is invalid")
if grant["registration_path"] != "/v1/auth/pair":
    die("registration path is invalid")
if not isinstance(expires_at, int):
    die("pairing expiry is invalid")
now = int(dt.datetime.now(tz=dt.timezone.utc).timestamp())
if expires_at <= now or expires_at - now > 300:
    die("pairing window is expired or longer than five minutes")

payload = {
    "version": 1,
    "base_url": args.base_url,
    "spki_sha256": pin,
    "pairing_nonce": nonce,
    "expires_at": dt.datetime.fromtimestamp(expires_at, tz=dt.timezone.utc)
    .isoformat(timespec="seconds")
    .replace("+00:00", "Z"),
}
json.dump(payload, sys.stdout, separators=(",", ":"), ensure_ascii=True)
sys.stdout.write("\n")
