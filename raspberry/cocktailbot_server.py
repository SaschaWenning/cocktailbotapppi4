#!/usr/bin/env python3
"""CocktailBot Raspberry Pi GPIO controller and Flutter-Web host.

The REST API exposes the local contract used by the Flutter app:
  GET  /api/status
  POST /api/command
  GET  /api/payment/status
  POST /api/payment/config
  POST /api/payment/create-order
  GET  /api/payment/order-status
  POST /api/payment/mark-used

GPIO numbering is BCM. All pumps are forced off at startup, on stop, and on exit.
"""

from __future__ import annotations

import argparse
import atexit
import base64
import glob
import hashlib
import hmac
import ipaddress
import json
import os
import io
import re
import secrets
import signal
import socket
import sqlite3
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Any

import requests

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

try:
    from PIL import Image, ImageOps
except ImportError:  # installed by requirements; keep a clear runtime error
    Image = None  # type: ignore[assignment]
    ImageOps = None  # type: ignore[assignment]

from flask import Flask, jsonify, request, send_file, send_from_directory

try:
    import serial
except ImportError:  # LED controller is optional; pumps must remain usable
    serial = None  # type: ignore[assignment]

try:
    from gpiozero import Device, OutputDevice
    from gpiozero.pins.mock import MockFactory
except ImportError as exc:  # pragma: no cover - production dependency check
    raise SystemExit(
        "gpiozero fehlt. Installiere es mit: sudo apt install python3-gpiozero"
    ) from exc


def _detect_rp1_gpio_chip() -> tuple[int | None, str]:
    """Resolve the RP1 gpiochip used by the Pi 5 40-pin header.

    Raspberry Pi kernel updates may renumber the RP1 gpiochip.  Old gpiozero
    releases assume gpiochip0/gpiochip4 and can therefore fail with
    ``lgpio.error: can not open gpiochip``.  We intentionally resolve the
    kernel label ``pinctrl-rp1`` instead of relying on a fixed number.
    """
    configured = os.getenv("COCKTAILBOT_GPIO_CHIP", "auto").strip().lower()
    if configured and configured != "auto":
        if not configured.isdigit():
            raise RuntimeError(
                "COCKTAILBOT_GPIO_CHIP muss 'auto' oder eine ganze Zahl sein"
            )
        chip = int(configured)
        if not Path(f"/dev/gpiochip{chip}").exists():
            raise RuntimeError(f"/dev/gpiochip{chip} existiert nicht")
        return chip, "konfiguriert"

    try:
        result = subprocess.run(
            ["gpiodetect"],
            check=False,
            capture_output=True,
            text=True,
            timeout=3,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return None, "gpiozero-standard"

    if result.returncode != 0:
        return None, "gpiozero-standard"

    for line in result.stdout.splitlines():
        if "[pinctrl-rp1]" not in line:
            continue
        match = re.match(r"^gpiochip(\d+)\s", line.strip())
        if match:
            chip = int(match.group(1))
            if Path(f"/dev/gpiochip{chip}").exists():
                return chip, "pinctrl-rp1"
    return None, "gpiozero-standard"


def _configure_gpiozero_lgpio_factory() -> tuple[int | None, str]:
    """Patch gpiozero's LGPIOFactory only when an RP1 chip is resolved.

    This keeps non-Pi-5 systems on gpiozero's native behaviour while making
    Pi 5 installations independent of the current gpiochip number.
    """
    if os.getenv("COCKTAILBOT_GPIO_MOCK", "0") in {"1", "true", "True"}:
        return None, "mock"

    chip, source = _detect_rp1_gpio_chip()
    if chip is None:
        return None, source

    try:
        import lgpio
        import gpiozero.pins.lgpio as gpiozero_lgpio
    except ImportError as exc:
        raise RuntimeError(
            "lgpio fehlt; installiere python3-lgpio für die Pumpensteuerung"
        ) from exc

    base_init = gpiozero_lgpio.LGPIOFactory.__bases__[0].__init__

    def cocktailbot_init(self, _chip=None):  # type: ignore[no-untyped-def]
        base_init(self)
        self._handle = lgpio.gpiochip_open(chip)
        self._chip = chip
        self.pin_class = gpiozero_lgpio.LGPIOPin

    gpiozero_lgpio.LGPIOFactory.__init__ = cocktailbot_init
    return chip, source


GPIOZERO_LGPIO_CHIP, GPIOZERO_LGPIO_CHIP_SOURCE = _configure_gpiozero_lgpio_factory()


PUMP_PINS: tuple[int, ...] = (
    17, 18, 27, 22, 23, 24, 25, 4, 5,
    6, 13, 19, 26, 16, 20, 21, 12, 15,
)
PUMP_COUNT = len(PUMP_PINS)
MAX_PUMP_DURATION_MS = 120_000
MAX_JOB_DURATION_MS = 600_000
DEFAULT_START_SPACING_MS = 100
MAX_START_SPACING_MS = 2_000

USB_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
USB_IMAGE_MAX_COUNT = 240
USB_IMAGE_MAX_BYTES = 25 * 1024 * 1024
USB_IMAGE_SCAN_DEPTH = 4

ACTIVE_HIGH = os.getenv("COCKTAILBOT_ACTIVE_HIGH", "0") not in {"0", "false", "False"}
MOCK_GPIO = os.getenv("COCKTAILBOT_GPIO_MOCK", "0") in {"1", "true", "True"}
STATE_FILE = Path(
    os.getenv("COCKTAILBOT_STATE_FILE", "/var/lib/cocktailbot/machine_state.json")
)
PICO_PORT = os.getenv("COCKTAILBOT_PICO_PORT", "auto").strip() or "auto"
PICO_BAUD = int(os.getenv("COCKTAILBOT_PICO_BAUD", "115200"))
PAYPAL_MODE = os.getenv("COCKTAILBOT_PAYPAL_MODE", "sandbox").strip().lower() or "sandbox"
PAYPAL_CLIENT_ID = os.getenv("COCKTAILBOT_PAYPAL_CLIENT_ID", "").strip()
PAYPAL_CLIENT_SECRET = os.getenv("COCKTAILBOT_PAYPAL_CLIENT_SECRET", "").strip()
PAYPAL_DB_FILE = Path(
    os.getenv("COCKTAILBOT_PAYMENT_DB", "/var/lib/cocktailbot/payments.db")
)
PAYPAL_BRAND_NAME = os.getenv("COCKTAILBOT_PAYPAL_BRAND_NAME", "CocktailBot").strip() or "CocktailBot"
PAYPAL_RETURN_URL = os.getenv("COCKTAILBOT_PAYPAL_RETURN_URL", "").strip()
PAYPAL_CANCEL_URL = os.getenv("COCKTAILBOT_PAYPAL_CANCEL_URL", "").strip()
PAYPAL_TIMEOUT_SECONDS = float(os.getenv("COCKTAILBOT_PAYPAL_TIMEOUT_SECONDS", "15"))
KIOSK_STOP_FILE = Path(
    os.getenv("COCKTAILBOT_KIOSK_STOP_FILE", "/var/lib/cocktailbot/kiosk.stop")
)
NETWORK_ACCESS_FILE = Path(
    os.getenv(
        "COCKTAILBOT_NETWORK_ACCESS_FILE",
        "/var/lib/cocktailbot/network_access.json",
    )
)
APP_STATE_FILE = Path(
    os.getenv(
        "COCKTAILBOT_APP_STATE_FILE",
        "/var/lib/cocktailbot/app_state.json",
    )
)
NETWORK_ADMIN_TOKEN_TTL_SECONDS = 30 * 60
LICENSE_FILE = Path(
    os.getenv("COCKTAILBOT_LICENSE_FILE", "/var/lib/cocktailbot/license.json")
)
LICENSE_PUBLIC_KEY_FILE = Path(
    os.getenv(
        "COCKTAILBOT_LICENSE_PUBLIC_KEY",
        "/etc/cocktailbot/license_public_key.pem",
    )
)
LICENSE_PREFIX = "CBL1-"
LICENSE_TYPE = "COMMERCIAL"
LICENSE_PROTOCOL_VERSION = 1



class NetworkAccessManager:
    """Persist LAN access securely without storing the admin PIN in plaintext."""

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._tokens: dict[str, float] = {}
        self.lan_enabled = False
        self.pin_salt = ""
        self.pin_hash = ""
        self._load()

    def _load(self) -> None:
        try:
            data = json.loads(NETWORK_ACCESS_FILE.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        self.lan_enabled = data.get("lanEnabled") is True
        self.pin_salt = str(data.get("pinSalt", ""))
        self.pin_hash = str(data.get("pinHash", ""))
        # Never expose LAN access without a configured PIN.
        if self.lan_enabled and not self.has_pin:
            self.lan_enabled = False

    @property
    def has_pin(self) -> bool:
        return bool(self.pin_salt and self.pin_hash)

    @staticmethod
    def _validate_pin_format(pin: str) -> str:
        cleaned = pin.strip()
        if not re.fullmatch(r"\d{4,8}", cleaned):
            raise ValidationError("Admin-PIN muss aus 4 bis 8 Ziffern bestehen")
        return cleaned

    @staticmethod
    def _derive_pin_hash(pin: str, salt_hex: str) -> str:
        salt = bytes.fromhex(salt_hex)
        return hashlib.pbkdf2_hmac(
            "sha256",
            pin.encode("utf-8"),
            salt,
            180_000,
        ).hex()

    def _save(self) -> None:
        NETWORK_ACCESS_FILE.parent.mkdir(parents=True, exist_ok=True)
        temp = NETWORK_ACCESS_FILE.with_suffix(".tmp")
        temp.write_text(
            json.dumps(
                {
                    "lanEnabled": self.lan_enabled,
                    "pinSalt": self.pin_salt,
                    "pinHash": self.pin_hash,
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        os.chmod(temp, 0o600)
        temp.replace(NETWORK_ACCESS_FILE)
        os.chmod(NETWORK_ACCESS_FILE, 0o600)

    def configure(self, *, lan_enabled: bool, admin_pin: str = "") -> None:
        with self._lock:
            cleaned = admin_pin.strip()
            if cleaned:
                cleaned = self._validate_pin_format(cleaned)
                self.pin_salt = secrets.token_hex(16)
                self.pin_hash = self._derive_pin_hash(cleaned, self.pin_salt)
                self._tokens.clear()
            if lan_enabled and not self.has_pin:
                raise ValidationError(
                    "Für den Netzwerkzugriff muss zuerst ein Admin-PIN festgelegt werden"
                )
            self.lan_enabled = bool(lan_enabled)
            self._save()

    def verify_pin(self, pin: str) -> bool:
        with self._lock:
            if not self.has_pin:
                return False
            try:
                cleaned = self._validate_pin_format(pin)
                candidate = self._derive_pin_hash(cleaned, self.pin_salt)
            except (ValidationError, ValueError):
                return False
            return hmac.compare_digest(candidate, self.pin_hash)

    def create_token(self, pin: str) -> str | None:
        if not self.verify_pin(pin):
            return None
        token = secrets.token_urlsafe(32)
        with self._lock:
            now = time.monotonic()
            self._tokens = {
                key: expires
                for key, expires in self._tokens.items()
                if expires > now
            }
            self._tokens[token] = now + NETWORK_ADMIN_TOKEN_TTL_SECONDS
        return token

    def valid_token(self, token: str) -> bool:
        if not token:
            return False
        with self._lock:
            expires = self._tokens.get(token)
            if expires is None:
                return False
            if expires <= time.monotonic():
                self._tokens.pop(token, None)
                return False
            return True

    def revoke_token(self, token: str) -> None:
        with self._lock:
            self._tokens.pop(token, None)

    @staticmethod
    def local_ipv4_addresses() -> list[str]:
        addresses: set[str] = set()
        try:
            result = subprocess.run(
                ["hostname", "-I"],
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0:
                for item in result.stdout.split():
                    try:
                        address = ipaddress.ip_address(item.split("%", 1)[0])
                    except ValueError:
                        continue
                    if (
                        address.version == 4
                        and not address.is_loopback
                        and (address.is_private or address.is_link_local)
                    ):
                        addresses.add(str(address))
        except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
            pass

        if not addresses:
            try:
                for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                    item = info[4][0]
                    address = ipaddress.ip_address(item)
                    if (
                        not address.is_loopback
                        and (address.is_private or address.is_link_local)
                    ):
                        addresses.add(str(address))
            except (OSError, ValueError):
                pass
        return sorted(addresses)

    def public_status(self, *, client_is_local: bool, port: int) -> dict[str, Any]:
        addresses = self.local_ipv4_addresses()
        return {
            "ok": True,
            "lanEnabled": self.lan_enabled,
            "adminPinConfigured": self.has_pin,
            "clientIsLocal": client_is_local,
            "adminTokenTtlSeconds": NETWORK_ADMIN_TOKEN_TTL_SECONDS,
            "addresses": addresses,
            "urls": [f"http://{address}:{port}" for address in addresses],
        }


def _request_address() -> ipaddress._BaseAddress | None:
    raw = (request.remote_addr or "").split("%", 1)[0].strip()
    if not raw:
        return None
    try:
        return ipaddress.ip_address(raw)
    except ValueError:
        return None


def _request_is_local() -> bool:
    address = _request_address()
    return bool(address and address.is_loopback)


def _request_is_private_lan() -> bool:
    address = _request_address()
    return bool(address and (address.is_private or address.is_link_local))


def desktop_environment() -> dict[str, str]:
    """Environment for programs that must appear in the local X11 session."""
    env = os.environ.copy()
    uid = os.getuid()
    home = str(Path.home())
    env.setdefault("HOME", home)
    env.setdefault("USER", os.getenv("USER", "pi"))
    env["DISPLAY"] = os.getenv("COCKTAILBOT_DISPLAY", ":0")
    env["XAUTHORITY"] = os.getenv(
        "COCKTAILBOT_XAUTHORITY", str(Path(home) / ".Xauthority")
    )
    session_bus = Path(f"/run/user/{uid}/bus")
    if session_bus.exists():
        env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={session_bus}"
    return env


def onboard_running() -> bool:
    try:
        result = subprocess.run(
            ["pgrep", "-u", str(os.getuid()), "-x", "onboard"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0
    except OSError:
        return False


def onboard_dbus(method: str) -> bool:
    env = desktop_environment()
    try:
        result = subprocess.run(
            [
                "dbus-send",
                "--session",
                "--type=method_call",
                "--dest=org.onboard.Onboard",
                "/org/onboard/Onboard/Keyboard",
                f"org.onboard.Onboard.Keyboard.{method}",
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def show_onboard_keyboard() -> bool:
    env = desktop_environment()
    if not onboard_running():
        try:
            subprocess.Popen(
                ["onboard"],
                env=env,
                cwd=env.get("HOME") or None,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            return False
        # Onboard needs a short moment to register its D-Bus service.
        for _ in range(8):
            time.sleep(0.12)
            if onboard_running() and onboard_dbus("Show"):
                return True
        return onboard_running()

    # Launching Onboard again is also a supported way of bringing an existing
    # keyboard to the foreground; D-Bus is preferred because it is immediate.
    if onboard_dbus("Show"):
        return True
    try:
        subprocess.Popen(
            ["onboard"],
            env=env,
            cwd=env.get("HOME") or None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except OSError:
        return False


def hide_onboard_keyboard() -> bool:
    if not onboard_running():
        return True
    return onboard_dbus("Hide")

if MOCK_GPIO:
    Device.pin_factory = MockFactory()


@dataclass(frozen=True)
class PumpStep:
    pump: int
    start_offset_ms: int
    duration_ms: int


@dataclass(frozen=True)
class PumpJob:
    action: str
    mode: str
    steps: tuple[PumpStep, ...]
    total_duration_ms: int


class ValidationError(ValueError):
    pass


class PaymentError(RuntimeError):
    def __init__(self, message: str, status_code: int = 502) -> None:
        super().__init__(message)
        self.status_code = status_code


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_iso(value: datetime | None = None) -> str:
    return (value or utc_now()).isoformat()


def parse_money(value: Any, field: str = "price", *, allow_zero: bool = False) -> int:
    try:
        amount = Decimal(str(value).replace(",", ".")).quantize(
            Decimal("0.01"), rounding=ROUND_HALF_UP
        )
    except (InvalidOperation, ValueError, TypeError) as exc:
        raise ValidationError(f"Ungültiger Geldbetrag: {field}") from exc
    minimum = Decimal("0.00") if allow_zero else Decimal("0.01")
    if amount < minimum or amount > Decimal("9999.00"):
        raise ValidationError(f"Ungültiger Geldbetrag: {field}")
    return int(amount * 100)


def cents_text(cents: int) -> str:
    return f"{Decimal(cents) / Decimal(100):.2f}"


class PaypalPaymentBackend:
    """Local PayPal Orders-v2 backend with SQLite one-time-use protection."""

    def __init__(self) -> None:
        if PAYPAL_MODE not in {"sandbox", "live"}:
            raise SystemExit("COCKTAILBOT_PAYPAL_MODE muss sandbox oder live sein")
        self.mode = PAYPAL_MODE
        self.client_id = PAYPAL_CLIENT_ID
        self.client_secret = PAYPAL_CLIENT_SECRET
        self.api_base = (
            "https://api-m.paypal.com"
            if self.mode == "live"
            else "https://api-m.sandbox.paypal.com"
        )
        default_return = (
            "https://www.paypal.com/" if self.mode == "live"
            else "https://www.sandbox.paypal.com/"
        )
        self.return_url = PAYPAL_RETURN_URL or default_return
        self.cancel_url = PAYPAL_CANCEL_URL or self.return_url
        self.brand_name = PAYPAL_BRAND_NAME[:127]
        self.timeout = max(3.0, min(60.0, PAYPAL_TIMEOUT_SECONDS))
        self.db_file = PAYPAL_DB_FILE
        self._token_lock = threading.RLock()
        self._access_token = ""
        self._access_token_until = 0.0
        self._init_db()

    @property
    def configured(self) -> bool:
        return bool(self.client_id and self.client_secret)

    def _db(self) -> sqlite3.Connection:
        self.db_file.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(self.db_file, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    def _init_db(self) -> None:
        with self._db() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS payment_config (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    machine_id TEXT NOT NULL,
                    currency TEXT NOT NULL,
                    cocktail_cents INTEGER NOT NULL,
                    mocktail_cents INTEGER NOT NULL,
                    shot_cents INTEGER NOT NULL,
                    recipe_prices_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS payment_orders (
                    order_id TEXT PRIMARY KEY,
                    machine_id TEXT NOT NULL,
                    recipe_id TEXT NOT NULL,
                    recipe_name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    size_ml INTEGER NOT NULL,
                    amount_cents INTEGER NOT NULL,
                    currency TEXT NOT NULL,
                    approval_url TEXT NOT NULL,
                    paypal_status TEXT NOT NULL,
                    paid INTEGER NOT NULL DEFAULT 0,
                    used INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    expires_at TEXT,
                    paid_at TEXT,
                    used_at TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_payment_orders_created
                    ON payment_orders(created_at);
                """
            )

    def save_price_config(self, payload: dict[str, Any]) -> dict[str, Any]:
        machine_id = str(payload.get("machineId", "")).strip()
        if not machine_id or len(machine_id) > 80:
            raise ValidationError("Ungültige Maschinen-ID")
        currency = str(payload.get("currency", "EUR")).strip().upper()
        if currency != "EUR":
            raise ValidationError("Aktuell wird nur EUR unterstützt")

        defaults = payload.get("defaultPrices")
        if not isinstance(defaults, dict):
            raise ValidationError("Standardpreise fehlen")
        cocktail_cents = parse_money(defaults.get("cocktail"), "cocktail", allow_zero=True)
        mocktail_cents = parse_money(defaults.get("mocktail"), "mocktail", allow_zero=True)
        shot_cents = parse_money(defaults.get("shot"), "shot", allow_zero=True)

        def parse_price_map(raw: Any, label: str) -> dict[str, int]:
            if raw is None:
                return {}
            if not isinstance(raw, dict):
                raise ValidationError(f"{label} sind ungültig")
            result: dict[str, int] = {}
            for raw_key, value in raw.items():
                key = str(raw_key).strip()
                if not key or len(key) > 160:
                    raise ValidationError(f"Ungültiger Schlüssel in {label}")
                result[key] = parse_money(value, f"{label}:{key}", allow_zero=True)
            return result

        recipe_prices = parse_price_map(payload.get("recipePrices", {}), "Rezeptpreise")
        default_size_prices = parse_price_map(
            payload.get("defaultSizePrices", {}),
            "Standardpreise nach Größe",
        )
        recipe_size_prices = parse_price_map(
            payload.get("recipeSizePrices", {}),
            "Rezeptpreise nach Größe",
        )
        price_config_json = {
            "recipePrices": recipe_prices,
            "defaultSizePrices": default_size_prices,
            "recipeSizePrices": recipe_size_prices,
        }

        with self._db() as db:
            db.execute(
                """
                INSERT INTO payment_config (
                    id, machine_id, currency, cocktail_cents, mocktail_cents,
                    shot_cents, recipe_prices_json, updated_at
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    machine_id=excluded.machine_id,
                    currency=excluded.currency,
                    cocktail_cents=excluded.cocktail_cents,
                    mocktail_cents=excluded.mocktail_cents,
                    shot_cents=excluded.shot_cents,
                    recipe_prices_json=excluded.recipe_prices_json,
                    updated_at=excluded.updated_at
                """,
                (
                    machine_id,
                    currency,
                    cocktail_cents,
                    mocktail_cents,
                    shot_cents,
                    json.dumps(price_config_json, separators=(",", ":")),
                    utc_iso(),
                ),
            )
        return {
            "ok": True,
            "machineId": machine_id,
            "currency": currency,
            "recipePriceCount": len(recipe_prices),
            "defaultSizePriceCount": len(default_size_prices),
            "recipeSizePriceCount": len(recipe_size_prices),
        }

    def _price_config(self) -> sqlite3.Row:
        with self._db() as db:
            row = db.execute("SELECT * FROM payment_config WHERE id=1").fetchone()
        if row is None:
            raise PaymentError(
                "Zahlungspreise sind noch nicht mit dem Raspberry synchronisiert",
                409,
            )
        return row

    def _server_price(
        self,
        machine_id: str,
        recipe_id: str,
        category: str,
        size_ml: int,
    ) -> tuple[int, str]:
        config = self._price_config()
        if machine_id != config["machine_id"]:
            raise PaymentError("Maschinen-ID stimmt nicht mit der lokalen Konfiguration überein", 409)
        try:
            stored = json.loads(config["recipe_prices_json"] or "{}")
        except json.JSONDecodeError:
            stored = {}

        # Ab V28 werden größenabhängige Preise gemeinsam in diesem JSON-Feld
        # gespeichert. Alte Daten bestanden direkt aus {recipeId: cents}; diese
        # Form wird weiterhin vollständig unterstützt.
        if isinstance(stored, dict) and any(
            key in stored
            for key in ("recipePrices", "defaultSizePrices", "recipeSizePrices")
        ):
            legacy_recipe_prices = stored.get("recipePrices", {})
            default_size_prices = stored.get("defaultSizePrices", {})
            recipe_size_prices = stored.get("recipeSizePrices", {})
        else:
            legacy_recipe_prices = stored if isinstance(stored, dict) else {}
            default_size_prices = {}
            recipe_size_prices = {}

        recipe_size_key = f"{recipe_id}|{size_ml}"
        custom_size = recipe_size_prices.get(recipe_size_key)
        if custom_size is not None:
            return int(custom_size), str(config["currency"])

        legacy_custom = legacy_recipe_prices.get(recipe_id)
        if legacy_custom is not None:
            return int(legacy_custom), str(config["currency"])

        category_size_key = f"{category}|{size_ml}"
        default_size = default_size_prices.get(category_size_key)
        if default_size is not None:
            return int(default_size), str(config["currency"])

        column = {
            "cocktail": "cocktail_cents",
            "mocktail": "mocktail_cents",
            "shot": "shot_cents",
        }.get(category)
        if column is None:
            raise ValidationError("Unbekannte Getränkekategorie")
        return int(config[column]), str(config["currency"])

    def _access_token_value(self) -> str:
        if not self.configured:
            raise PaymentError(
                "PayPal ist auf dem Raspberry noch nicht konfiguriert. "
                "Führe 'sudo cocktailbot-paypal-config' aus.",
                503,
            )
        with self._token_lock:
            now = time.monotonic()
            if self._access_token and now < self._access_token_until:
                return self._access_token
            try:
                response = requests.post(
                    f"{self.api_base}/v1/oauth2/token",
                    auth=(self.client_id, self.client_secret),
                    data={"grant_type": "client_credentials"},
                    headers={"Accept": "application/json"},
                    timeout=self.timeout,
                )
            except requests.RequestException as exc:
                raise PaymentError(f"PayPal OAuth nicht erreichbar: {exc}") from exc
            if response.status_code < 200 or response.status_code >= 300:
                raise PaymentError(
                    f"PayPal OAuth HTTP {response.status_code}: {response.text[:500]}",
                    502,
                )
            try:
                data = response.json()
            except ValueError as exc:
                raise PaymentError("PayPal OAuth lieferte ungültiges JSON") from exc
            token = str(data.get("access_token", ""))
            expires_in = int(data.get("expires_in", 300))
            if not token:
                raise PaymentError("PayPal OAuth lieferte keinen Access-Token")
            self._access_token = token
            self._access_token_until = now + max(30, expires_in - 60)
            return token

    def _request_json(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        request_id: str | None = None,
    ) -> dict[str, Any]:
        headers = {
            "Authorization": f"Bearer {self._access_token_value()}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Prefer": "return=representation",
        }
        if request_id:
            headers["PayPal-Request-Id"] = request_id[:108]
        try:
            response = requests.request(
                method,
                f"{self.api_base}{path}",
                headers=headers,
                json=body,
                timeout=self.timeout,
            )
        except requests.RequestException as exc:
            raise PaymentError(f"PayPal API nicht erreichbar: {exc}") from exc
        if response.status_code < 200 or response.status_code >= 300:
            raise PaymentError(
                f"PayPal HTTP {response.status_code}: {response.text[:1000]}",
                502,
            )
        try:
            data = response.json()
        except ValueError as exc:
            raise PaymentError("PayPal API lieferte ungültiges JSON") from exc
        if not isinstance(data, dict):
            raise PaymentError("PayPal API lieferte eine ungültige Antwort")
        return data

    @staticmethod
    def _approval_url(data: dict[str, Any]) -> str:
        for link in data.get("links", []):
            if not isinstance(link, dict):
                continue
            if link.get("rel") in {"payer-action", "approve"}:
                return str(link.get("href", ""))
        return ""

    def create_order(self, payload: dict[str, Any]) -> dict[str, Any]:
        machine_id = str(payload.get("machineId", "")).strip()
        recipe_id = str(payload.get("recipeId", "")).strip()
        recipe_name = str(payload.get("recipeName", "")).strip()
        category = str(payload.get("category", "")).strip()
        try:
            size_ml = int(payload.get("sizeMl", 0))
        except (TypeError, ValueError) as exc:
            raise ValidationError("Ungültige Cocktailgröße") from exc
        if not machine_id or not recipe_id or not recipe_name:
            raise ValidationError("Bestelldaten sind unvollständig")
        if size_ml < 1 or size_ml > 5000:
            raise ValidationError("Ungültige Cocktailgröße")

        amount_cents, currency = self._server_price(
            machine_id, recipe_id, category, size_ml
        )
        if amount_cents < 1:
            raise PaymentError("Für diesen Cocktail ist kein Verkaufspreis gesetzt", 409)
        local_request_id = uuid.uuid4().hex
        description = f"{recipe_name} {size_ml} ml"[:127]
        custom_id = f"{machine_id}:{recipe_id}:{size_ml}"[:127]
        order_payload = {
            "intent": "CAPTURE",
            "purchase_units": [
                {
                    "reference_id": local_request_id[:64],
                    "custom_id": custom_id,
                    "description": description,
                    "amount": {
                        "currency_code": currency,
                        "value": cents_text(amount_cents),
                    },
                }
            ],
            "payment_source": {
                "paypal": {
                    "experience_context": {
                        "brand_name": self.brand_name,
                        "shipping_preference": "NO_SHIPPING",
                        "user_action": "PAY_NOW",
                        "return_url": self.return_url,
                        "cancel_url": self.cancel_url,
                    }
                }
            },
        }
        data = self._request_json(
            "POST",
            "/v2/checkout/orders",
            body=order_payload,
            request_id=f"create-{local_request_id}",
        )
        order_id = str(data.get("id", ""))
        approval_url = self._approval_url(data)
        if not order_id or not approval_url:
            raise PaymentError("PayPal hat keine gültige Freigabe-URL geliefert")
        expires_at = utc_now() + timedelta(hours=6)
        paypal_status = str(data.get("status", "CREATED"))

        with self._db() as db:
            db.execute(
                """
                INSERT INTO payment_orders (
                    order_id, machine_id, recipe_id, recipe_name, category,
                    size_ml, amount_cents, currency, approval_url, paypal_status,
                    created_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    order_id,
                    machine_id,
                    recipe_id,
                    recipe_name,
                    category,
                    size_ml,
                    amount_cents,
                    currency,
                    approval_url,
                    paypal_status,
                    utc_iso(),
                    utc_iso(expires_at),
                ),
            )
        return {
            "ok": True,
            "orderId": order_id,
            "approvalUrl": approval_url,
            "expiresAt": utc_iso(expires_at),
            "amount": cents_text(amount_cents),
            "currency": currency,
            "status": paypal_status,
        }

    def _local_order(self, order_id: str) -> sqlite3.Row:
        with self._db() as db:
            row = db.execute(
                "SELECT * FROM payment_orders WHERE order_id=?", (order_id,)
            ).fetchone()
        if row is None:
            raise PaymentError("Unbekannte PayPal-Order", 404)
        return row

    @staticmethod
    def _remote_amount(data: dict[str, Any]) -> tuple[str, str] | None:
        units = data.get("purchase_units")
        if not isinstance(units, list) or not units or not isinstance(units[0], dict):
            return None
        amount = units[0].get("amount")
        if not isinstance(amount, dict):
            return None
        return str(amount.get("value", "")), str(amount.get("currency_code", ""))

    def _validate_remote_amount(self, local: sqlite3.Row, data: dict[str, Any]) -> None:
        remote = self._remote_amount(data)
        if remote is None:
            raise PaymentError("PayPal-Antwort enthält keinen prüfbaren Betrag")
        value, currency = remote
        if value != cents_text(int(local["amount_cents"])) or currency != local["currency"]:
            raise PaymentError("PayPal-Betrag stimmt nicht mit der lokalen Bestellung überein")

    def order_status(self, order_id: str) -> dict[str, Any]:
        order_id = order_id.strip()
        if not order_id or len(order_id) > 80:
            raise ValidationError("Ungültige Order-ID")
        local = self._local_order(order_id)
        if bool(local["paid"]):
            return {
                "ok": True,
                "orderId": order_id,
                "paid": True,
                "used": bool(local["used"]),
                "status": local["paypal_status"],
            }

        remote = self._request_json("GET", f"/v2/checkout/orders/{order_id}")
        self._validate_remote_amount(local, remote)
        status = str(remote.get("status", "UNKNOWN"))

        if status == "APPROVED":
            try:
                remote = self._request_json(
                    "POST",
                    f"/v2/checkout/orders/{order_id}/capture",
                    body={},
                    request_id=f"capture-{order_id}",
                )
            except PaymentError:
                # Ein unterbrochener Capture-Request kann serverseitig trotzdem
                # erfolgreich gewesen sein. Ein erneutes GET ist idempotent und
                # verhindert Doppel-Captures.
                remote = self._request_json("GET", f"/v2/checkout/orders/{order_id}")
            self._validate_remote_amount(local, remote)
            status = str(remote.get("status", "UNKNOWN"))

        paid = status == "COMPLETED"
        now = utc_iso()
        with self._db() as db:
            db.execute(
                """
                UPDATE payment_orders
                SET paypal_status=?, paid=?, paid_at=CASE WHEN ?=1 THEN COALESCE(paid_at, ?) ELSE paid_at END
                WHERE order_id=?
                """,
                (status, 1 if paid else 0, 1 if paid else 0, now, order_id),
            )
            updated = db.execute(
                "SELECT used FROM payment_orders WHERE order_id=?", (order_id,)
            ).fetchone()
        return {
            "ok": True,
            "orderId": order_id,
            "paid": paid,
            "used": bool(updated["used"]) if updated is not None else False,
            "status": status,
        }

    def mark_used(self, order_id: str, machine_id: str) -> dict[str, Any]:
        order_id = order_id.strip()
        machine_id = machine_id.strip()
        if not order_id or not machine_id:
            raise ValidationError("Order-ID oder Maschinen-ID fehlt")
        now = utc_iso()
        with self._db() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT paid, used, machine_id FROM payment_orders WHERE order_id=?",
                (order_id,),
            ).fetchone()
            if row is None:
                raise PaymentError("Unbekannte PayPal-Order", 404)
            if row["machine_id"] != machine_id:
                raise PaymentError("Maschinen-ID stimmt nicht", 409)
            if not bool(row["paid"]):
                raise PaymentError("Zahlung ist noch nicht abgeschlossen", 409)
            if bool(row["used"]):
                raise PaymentError("Diese Zahlung wurde bereits verwendet", 409)
            db.execute(
                "UPDATE payment_orders SET used=1, used_at=? WHERE order_id=?",
                (now, order_id),
            )
        return {"ok": True, "orderId": order_id, "used": True, "usedAt": now}

    def test_connection(self) -> dict[str, Any]:
        self._access_token_value()
        return {
            "ok": True,
            "configured": self.configured,
            "connected": True,
            "mode": self.mode,
        }

    def status(self) -> dict[str, Any]:
        with self._db() as db:
            config = db.execute("SELECT machine_id, updated_at FROM payment_config WHERE id=1").fetchone()
            counts = db.execute(
                """
                SELECT
                    COUNT(*) AS total,
                    SUM(CASE WHEN paid=1 THEN 1 ELSE 0 END) AS paid,
                    SUM(CASE WHEN used=1 THEN 1 ELSE 0 END) AS used
                FROM payment_orders
                """
            ).fetchone()
        return {
            "ok": True,
            "backend": "raspberry-local",
            "configured": self.configured,
            "mode": self.mode,
            "priceConfigured": config is not None,
            "machineId": config["machine_id"] if config is not None else None,
            "priceUpdatedAt": config["updated_at"] if config is not None else None,
            "orders": {
                "total": int(counts["total"] or 0),
                "paid": int(counts["paid"] or 0),
                "used": int(counts["used"] or 0),
            },
        }

class PicoLedController:
    """USB-Serial bridge to the Pico 2 MicroPython LED controller.

    The Pico is deliberately optional: a disconnected LED controller must never
    prevent pump operation. The connection is reopened automatically whenever a
    later command is sent.
    """

    def __init__(self, configured_port: str = PICO_PORT, baud: int = PICO_BAUD) -> None:
        self.configured_port = configured_port
        self.baud = baud
        self._lock = threading.RLock()
        self._serial: Any | None = None
        self.port: str | None = None
        self.last_command = ""
        self.last_response = ""
        self.last_error = ""

    def _candidates(self) -> list[str]:
        if self.configured_port.lower() != "auto":
            return [self.configured_port]
        candidates: list[str] = []
        for pattern in (
            "/dev/serial/by-id/*MicroPython*",
            "/dev/serial/by-id/*Pico*",
            "/dev/ttyACM*",
        ):
            for candidate in sorted(glob.glob(pattern)):
                if candidate not in candidates:
                    candidates.append(candidate)
        return candidates

    def _close_locked(self) -> None:
        if self._serial is not None:
            try:
                self._serial.close()
            except Exception:
                pass
        self._serial = None
        self.port = None

    def _connect_locked(self) -> bool:
        if self._serial is not None and getattr(self._serial, "is_open", False):
            return True
        self._close_locked()
        if serial is None:
            self.last_error = "pyserial ist nicht installiert"
            return False

        for candidate in self._candidates():
            try:
                connection = serial.Serial(
                    candidate,
                    self.baud,
                    timeout=0.15,
                    write_timeout=0.5,
                )
                # Give MicroPython USB-CDC a brief moment after opening.
                time.sleep(0.15)
                self._serial = connection
                self.port = candidate
                self.last_error = ""
                return True
            except Exception as exc:
                self.last_error = f"{candidate}: {exc}"
        return False

    def send(self, command: str) -> bool:
        command = command.strip()
        if not command:
            return False
        with self._lock:
            if not self._connect_locked():
                return False
            assert self._serial is not None
            try:
                self._serial.write((command + "\n").encode("utf-8"))
                self._serial.flush()
                self.last_command = command
                # Firmware responses are diagnostic only; do not block on them.
                time.sleep(0.02)
                response = b""
                while getattr(self._serial, "in_waiting", 0):
                    response = self._serial.readline().strip() or response
                if response:
                    self.last_response = response.decode("utf-8", errors="replace")
                self.last_error = ""
                return True
            except Exception as exc:
                self.last_error = str(exc)
                self._close_locked()
                return False

    def apply_idle(self, settings: dict[str, Any]) -> bool:
        brightness = max(0, min(255, int(settings.get("brightness", 89))))
        r = max(0, min(255, int(settings.get("r", 22))))
        g = max(0, min(255, int(settings.get("g", 217))))
        b = max(0, min(255, int(settings.get("b", 204))))
        mode = str(settings.get("mode", "solid"))
        bright_ok = self.send(f"BRIGHT {brightness}")
        command = {
            "solid": f"COLOR {r} {g} {b}",
            "rainbow": "RAINBOW",
            "breathe": f"PULSE {r} {g} {b}",
            "blink": f"BLINK {r} {g} {b}",
            # Backward compatibility for installations that saved the former
            # app value 'chase'. The current Pico firmware has no CHASE command.
            "chase": f"BLINK {r} {g} {b}",
            "off": "OFF",
        }.get(mode, f"COLOR {r} {g} {b}")
        return self.send(command) and bright_ok

    @property
    def connected(self) -> bool:
        with self._lock:
            return bool(self._serial is not None and getattr(self._serial, "is_open", False))

    def close(self) -> None:
        with self._lock:
            try:
                if self._serial is not None and getattr(self._serial, "is_open", False):
                    self._serial.write(b"OFF\n")
                    self._serial.flush()
            except Exception:
                pass
            self._close_locked()



def _read_device_tree_text(path: Path) -> str:
    try:
        raw = path.read_bytes().replace(b"\x00", b"").strip()
        return raw.decode("ascii", errors="ignore").strip()
    except OSError:
        return ""


def hardware_identity_source() -> tuple[str, str]:
    """Return a stable Raspberry hardware identity and the source used.

    rpi-machine-id is preferred because Raspberry Pi documents it as a stable
    128-bit machine identifier. Older firmware may not expose it, so the
    hardware serial is the fallback. /etc/machine-id is only a final fallback
    for non-standard/test systems and is not expected on production Pi images.
    """
    candidates = (
        (Path("/proc/device-tree/chosen/rpi-machine-id"), "rpi-machine-id"),
        (Path("/sys/firmware/devicetree/base/chosen/rpi-machine-id"), "rpi-machine-id"),
        (Path("/proc/device-tree/serial-number"), "serial-number"),
        (Path("/sys/firmware/devicetree/base/serial-number"), "serial-number"),
    )
    for path, source in candidates:
        value = _read_device_tree_text(path)
        if value:
            return value.lower(), source

    try:
        value = Path("/etc/machine-id").read_text(encoding="ascii").strip()
        if value:
            return value.lower(), "os-machine-id-fallback"
    except OSError:
        pass
    return "unknown-cocktailbot-device", "unavailable"


def cocktailbot_device_id() -> tuple[str, str]:
    raw, source = hardware_identity_source()
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest().upper()[:16]
    grouped = "-".join(digest[i : i + 4] for i in range(0, 16, 4))
    return f"CB-{grouped}", source


def license_signing_message(device_id: str) -> bytes:
    return (
        f"COCKTAILBOT-LICENSE|{LICENSE_PROTOCOL_VERSION}|{LICENSE_TYPE}|{device_id}"
    ).encode("ascii")


class LicenseManager:
    """Offline, device-bound CocktailBot commercial license verifier."""

    def __init__(self) -> None:
        self.device_id, self.device_source = cocktailbot_device_id()
        self.public_key: Ed25519PublicKey | None = None
        self.public_key_error = ""
        self._load_public_key()

    def _load_public_key(self) -> None:
        try:
            loaded = serialization.load_pem_public_key(
                LICENSE_PUBLIC_KEY_FILE.read_bytes()
            )
            if not isinstance(loaded, Ed25519PublicKey):
                raise TypeError("Lizenzschlüssel ist kein Ed25519 Public Key")
            self.public_key = loaded
        except Exception as exc:  # configuration problem; status stays available
            self.public_key = None
            self.public_key_error = str(exc)

    @staticmethod
    def _decode_signature(code: str) -> bytes:
        normalized = "".join(code.strip().split())
        if not normalized.startswith(LICENSE_PREFIX):
            raise ValueError("Lizenzcode hat ein ungültiges Format")
        encoded = normalized[len(LICENSE_PREFIX) :]
        if not encoded:
            raise ValueError("Lizenzcode ist leer")
        padding = "=" * ((4 - len(encoded) % 4) % 4)
        try:
            signature = base64.urlsafe_b64decode((encoded + padding).encode("ascii"))
        except Exception as exc:
            raise ValueError("Lizenzcode kann nicht gelesen werden") from exc
        if len(signature) != 64:
            raise ValueError("Lizenzcode hat eine ungültige Länge")
        return signature

    def verify_code(self, code: str) -> tuple[bool, str]:
        if self.public_key is None:
            return False, "Öffentlicher Lizenzschlüssel ist nicht installiert"
        try:
            signature = self._decode_signature(code)
            self.public_key.verify(signature, license_signing_message(self.device_id))
            return True, "Lizenz gültig"
        except (InvalidSignature, ValueError):
            return False, "Lizenzcode ist für dieses Gerät ungültig"
        except Exception as exc:
            return False, f"Lizenzprüfung fehlgeschlagen: {exc}"

    def _read_local_license(self) -> dict[str, Any] | None:
        try:
            data = json.loads(LICENSE_FILE.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else None
        except (OSError, json.JSONDecodeError):
            return None

    def status(self) -> dict[str, Any]:
        stored = self._read_local_license()
        active = False
        message = "Privatmodus"
        activated_at: str | None = None

        if stored:
            stored_device = str(stored.get("deviceId", ""))
            code = str(stored.get("code", ""))
            activated_at = str(stored.get("activatedAt", "")) or None
            if stored_device != self.device_id:
                message = "Gespeicherte Lizenz gehört zu einem anderen Gerät"
            else:
                active, message = self.verify_code(code)

        return {
            "ok": True,
            "active": active,
            "mode": "commercial" if active else "private",
            "licenseType": LICENSE_TYPE if active else "PRIVATE",
            "deviceId": self.device_id,
            "deviceSource": self.device_source,
            "activatedAt": activated_at if active else None,
            "message": message,
            "publicKeyInstalled": self.public_key is not None,
            "publicKeyError": self.public_key_error if self.public_key is None else None,
        }

    def activate(self, code: str) -> dict[str, Any]:
        normalized = "".join(code.strip().split())
        valid, message = self.verify_code(normalized)
        if not valid:
            raise ValidationError(message)

        LICENSE_FILE.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": LICENSE_PROTOCOL_VERSION,
            "licenseType": LICENSE_TYPE,
            "deviceId": self.device_id,
            "code": normalized,
            "activatedAt": datetime.now(timezone.utc).isoformat(),
        }
        temp = LICENSE_FILE.with_suffix(".tmp")
        temp.write_text(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        os.chmod(temp, 0o600)
        temp.replace(LICENSE_FILE)
        os.chmod(LICENSE_FILE, 0o600)
        result = self.status()
        result["message"] = "Gewerbelizenz wurde aktiviert"
        return result

    def deactivate(self) -> dict[str, Any]:
        try:
            LICENSE_FILE.unlink(missing_ok=True)
        except OSError as exc:
            raise ValidationError(f"Lizenzdatei konnte nicht entfernt werden: {exc}") from exc
        result = self.status()
        result["message"] = "Gewerbelizenz wurde deaktiviert"
        return result


class PumpController:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._devices = {
            number: OutputDevice(
                pin,
                active_high=ACTIVE_HIGH,
                initial_value=False,
            )
            for number, pin in enumerate(PUMP_PINS, start=1)
        }
        self._active_pumps: set[int] = set()
        self._job: PumpJob | None = None
        self._job_started_at = 0.0
        self._completed_steps = 0
        self._generation = 0
        self._closed = False
        self.machine_state: dict[str, Any] = self._load_machine_state()
        self.led_settings: dict[str, Any] = {
            "mode": "solid",
            "r": 22,
            "g": 217,
            "b": 204,
            "brightness": 89,
        }
        self.pico = PicoLedController()
        self.all_off()
        self.pico.apply_idle(self.led_settings)

    @staticmethod
    def pin_for_pump(pump: int) -> int:
        if pump < 1 or pump > PUMP_COUNT:
            raise ValidationError("Ungültige Pumpennummer")
        return PUMP_PINS[pump - 1]

    def _load_machine_state(self) -> dict[str, Any]:
        try:
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    def save_machine_state(self, state: dict[str, Any]) -> None:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        temporary = STATE_FILE.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(state, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        temporary.replace(STATE_FILE)
        with self._lock:
            self.machine_state = state

    def _set_pump_locked(self, pump: int, enabled: bool) -> None:
        device = self._devices[pump]
        if enabled:
            device.on()
            self._active_pumps.add(pump)
        else:
            device.off()
            self._active_pumps.discard(pump)

    def all_off(self) -> None:
        with self._lock:
            for pump in self._devices:
                self._set_pump_locked(pump, False)

    def stop(self, reason: str = "Not-Aus") -> None:
        del reason
        with self._lock:
            self._generation += 1
            self.all_off()
            self._job = None
            self._job_started_at = 0.0
            self._completed_steps = 0
            closed = self._closed
        if not closed:
            self.pico.apply_idle(self.led_settings)

    def apply_led_settings(self, settings: dict[str, Any]) -> bool:
        with self._lock:
            self.led_settings = dict(settings)
            idle_now = self._job is None
        if idle_now:
            return self.pico.apply_idle(self.led_settings)
        return True

    def _restore_idle_after(self, generation: int, delay_seconds: float) -> None:
        def worker() -> None:
            time.sleep(delay_seconds)
            with self._lock:
                if self._closed or generation != self._generation or self._job is not None:
                    return
                settings = dict(self.led_settings)
            self.pico.apply_idle(settings)

        threading.Thread(
            target=worker,
            name="cocktailbot-led-restore",
            daemon=True,
        ).start()

    def _show_ready_then_idle(self, generation: int) -> None:
        self.pico.send("READY")
        self._restore_idle_after(generation, 5.0)

    def _show_error_then_idle(self, generation: int) -> None:
        self.pico.send("ERROR")
        self._restore_idle_after(generation, 5.0)

    def start(self, job: PumpJob) -> bool:
        with self._lock:
            if self._job is not None or self._closed:
                return False
            self._generation += 1
            generation = self._generation
            self.all_off()
            self._job = job
            self._job_started_at = time.monotonic()
            self._completed_steps = 0

        # Die App beschreibt den Zubereitungszustand als rot blinkend.
        self.pico.send("BLINK 255 0 0")

        thread = threading.Thread(
            target=self._run_job,
            args=(job, generation),
            name=f"cocktailbot-{job.action}",
            daemon=True,
        )
        thread.start()
        return True

    def _run_job(self, job: PumpJob, generation: int) -> None:
        started: set[int] = set()
        finished: set[int] = set()
        success = False
        failed = False

        try:
            while True:
                with self._lock:
                    if self._closed or generation != self._generation:
                        return
                    elapsed_ms = int((time.monotonic() - self._job_started_at) * 1000)

                    for index, step in enumerate(job.steps):
                        if index not in started and elapsed_ms >= step.start_offset_ms:
                            self._set_pump_locked(step.pump, True)
                            started.add(index)

                        if (
                            index in started
                            and index not in finished
                            and elapsed_ms >= step.start_offset_ms + step.duration_ms
                        ):
                            self._set_pump_locked(step.pump, False)
                            finished.add(index)
                            self._completed_steps = len(finished)

                    if len(finished) >= len(job.steps):
                        self.all_off()
                        self._job = None
                        self._job_started_at = 0.0
                        self._completed_steps = 0
                        success = True
                        break

                time.sleep(0.01)
        except Exception:
            failed = True
            raise
        finally:
            with self._lock:
                # A superseded thread must never leave an output active.
                if generation == self._generation:
                    self.all_off()
                    self._job = None
                    self._job_started_at = 0.0
                    self._completed_steps = 0

            if success:
                self._show_ready_then_idle(generation)
            elif failed and generation == self._generation:
                self._show_error_then_idle(generation)

    def status(self) -> dict[str, Any]:
        with self._lock:
            job = self._job
            active = sorted(self._active_pumps)
            if job is None or job.total_duration_ms <= 0:
                progress = 0.0
            else:
                elapsed_ms = int((time.monotonic() - self._job_started_at) * 1000)
                progress = min(1.0, elapsed_ms / job.total_duration_ms)

            return {
                "ok": True,
                "device": "CocktailBot-RaspberryPi",
                "gpioNumbering": "BCM",
                "busy": job is not None,
                "action": job.action if job else "idle",
                "currentPump": active[0] if active else 0,
                "runningPumpCount": len(active),
                "completedSteps": self._completed_steps if job else 0,
                "stepCount": len(job.steps) if job else 0,
                "progress": progress,
                "activePumps": active,
                "pumpPins": {
                    str(number): pin
                    for number, pin in enumerate(PUMP_PINS, start=1)
                },
                "machineState": self.machine_state,
                "ledState": "idle" if job is None else "preparing",
                "ledIdleMode": self.led_settings["mode"],
                "ledBrightness": self.led_settings["brightness"],
                "ledColor": {
                    "r": self.led_settings["r"],
                    "g": self.led_settings["g"],
                    "b": self.led_settings["b"],
                },
                "ledController": "Pico2-USB-Serial",
                "picoConnected": self.pico.connected,
                "picoPort": self.pico.port,
                "picoLastCommand": self.pico.last_command,
                "picoLastResponse": self.pico.last_response,
                "picoLastError": self.pico.last_error,
            }

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._generation += 1
            self.all_off()
            for device in self._devices.values():
                device.close()
        self.pico.close()


def as_int(value: Any, field: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValidationError(f"Ungültiges Feld: {field}") from exc


def validate_step(pump: Any, duration_ms: Any, start_offset_ms: int) -> PumpStep:
    pump_number = as_int(pump, "pump")
    duration = as_int(duration_ms, "durationMs")
    if pump_number < 1 or pump_number > PUMP_COUNT:
        raise ValidationError("Ungültige Pumpennummer")
    if duration < 1 or duration > MAX_PUMP_DURATION_MS:
        raise ValidationError("Ungültige Pumpenlaufzeit")
    if start_offset_ms + duration > MAX_JOB_DURATION_MS:
        raise ValidationError("Gesamtlaufzeit zu lang")
    return PumpStep(pump_number, start_offset_ms, duration)


def reject_duplicate_pumps(steps: list[PumpStep]) -> None:
    pumps = [step.pump for step in steps]
    if len(pumps) != len(set(pumps)):
        raise ValidationError("Eine Pumpe darf pro Auftrag nur einmal vorkommen")


def build_sequential_job(payload: dict[str, Any], action: str) -> PumpJob:
    items = payload.get("pumps")
    if not isinstance(items, list) or not items:
        raise ValidationError("Pumpenliste fehlt oder ist leer")

    steps: list[PumpStep] = []
    offset = 0
    for item in items:
        if not isinstance(item, dict):
            raise ValidationError("Ungültiger Pumpeneintrag")
        step = validate_step(item.get("pump"), item.get("durationMs"), offset)
        steps.append(step)
        offset += step.duration_ms

    reject_duplicate_pumps(steps)
    return PumpJob(action, "sequential", tuple(steps), offset)


def build_recipe_job(payload: dict[str, Any]) -> PumpJob:
    items = payload.get("pumps")
    if not isinstance(items, list) or not items:
        raise ValidationError("Pumpenliste fehlt oder ist leer")

    spacing = as_int(payload.get("startSpacingMs", DEFAULT_START_SPACING_MS), "startSpacingMs")
    if spacing < 0 or spacing > MAX_START_SPACING_MS:
        raise ValidationError("Ungültiger Startabstand")

    normal_items = [item for item in items if isinstance(item, dict) and not bool(item.get("delayed", False))]
    delayed_items = [item for item in items if isinstance(item, dict) and bool(item.get("delayed", False))]
    if len(normal_items) + len(delayed_items) != len(items):
        raise ValidationError("Ungültiger Pumpeneintrag")

    steps: list[PumpStep] = []
    normal_end = 0
    for index, item in enumerate(normal_items):
        offset = index * spacing
        step = validate_step(item.get("pump"), item.get("durationMs"), offset)
        steps.append(step)
        normal_end = max(normal_end, offset + step.duration_ms)

    for index, item in enumerate(delayed_items):
        offset = normal_end + index * spacing
        steps.append(validate_step(item.get("pump"), item.get("durationMs"), offset))

    reject_duplicate_pumps(steps)
    total = max(step.start_offset_ms + step.duration_ms for step in steps)
    return PumpJob("prepare_recipe", "overlapping", tuple(steps), total)



def load_app_state() -> dict[str, Any]:
    try:
        data = json.loads(APP_STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def save_app_state(state: dict[str, Any]) -> None:
    APP_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = APP_STATE_FILE.with_suffix(".tmp")
    temp.write_text(
        json.dumps(state, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    os.chmod(temp, 0o600)
    temp.replace(APP_STATE_FILE)
    os.chmod(APP_STATE_FILE, 0o600)


def create_app(controller: PumpController, web_root: Path) -> Flask:
    app = Flask(__name__, static_folder=None)
    payment = PaypalPaymentBackend()
    licensing = LicenseManager()
    network_access = NetworkAccessManager()
    usb_image_cache: dict[str, Path] = {}

    def usb_scan_roots() -> list[Path]:
        user_name = os.getenv("USER", "pi").strip() or "pi"
        configured = os.getenv("COCKTAILBOT_USB_ROOTS", "").strip()
        candidates: list[Path] = []
        if configured:
            candidates.extend(Path(item.strip()) for item in configured.split(":") if item.strip())
        candidates.extend([
            Path("/media") / user_name,
            Path("/run/media") / user_name,
            Path("/media/pi"),
            Path("/run/media/pi"),
            Path("/mnt/usb"),
        ])

        roots: list[Path] = []
        seen: set[str] = set()
        for candidate in candidates:
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            key = str(resolved)
            if key in seen or not resolved.is_dir():
                continue
            seen.add(key)
            roots.append(resolved)
        return roots

    def scan_usb_images() -> list[dict[str, Any]]:
        usb_image_cache.clear()
        results: list[dict[str, Any]] = []

        for root in usb_scan_roots():
            root_parts = len(root.parts)
            try:
                walker = os.walk(root, followlinks=False)
                for dir_path, dir_names, file_names in walker:
                    current = Path(dir_path)
                    depth = len(current.parts) - root_parts
                    if depth >= USB_IMAGE_SCAN_DEPTH:
                        dir_names[:] = []

                    # Hidden/system folders are not useful in the touch picker.
                    dir_names[:] = [name for name in dir_names if not name.startswith(".")]

                    for file_name in sorted(file_names, key=str.casefold):
                        if len(results) >= USB_IMAGE_MAX_COUNT:
                            return results
                        if file_name.startswith("."):
                            continue
                        path = current / file_name
                        if path.suffix.lower() not in USB_IMAGE_EXTENSIONS:
                            continue
                        try:
                            if not path.is_file():
                                continue
                            size = path.stat().st_size
                        except OSError:
                            continue
                        if size <= 0 or size > USB_IMAGE_MAX_BYTES:
                            continue

                        try:
                            relative = path.relative_to(root)
                        except ValueError:
                            continue
                        token = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:32]
                        usb_image_cache[token] = path
                        source = relative.parts[0] if len(relative.parts) > 1 else root.name
                        results.append({
                            "id": token,
                            "name": file_name,
                            "source": source or "USB",
                            "sizeBytes": size,
                        })
            except OSError:
                continue

        return results

    def usb_image_bytes(path: Path, *, thumbnail: bool) -> io.BytesIO:
        if Image is None or ImageOps is None:
            raise RuntimeError("Pillow ist nicht installiert")

        max_size = (360, 260) if thumbnail else (1200, 1200)
        quality = 72 if thumbnail else 80
        output = io.BytesIO()
        with Image.open(path) as source:
            image = ImageOps.exif_transpose(source)
            image.thumbnail(max_size)
            if image.mode in {"RGBA", "LA"}:
                rgba = image.convert("RGBA")
                background = Image.new("RGB", rgba.size, (11, 16, 21))
                background.paste(rgba, mask=rgba.getchannel("A"))
                image = background
            elif image.mode != "RGB":
                image = image.convert("RGB")
            image.save(output, format="JPEG", quality=quality, optimize=True)
        output.seek(0)
        return output

    def require_commercial_license():
        status = licensing.status()
        if not status.get("active"):
            return jsonify(
                ok=False,
                error="Aktive CocktailBot Gewerbelizenz erforderlich",
                license=status,
            ), 403
        return None

    def remote_admin_authorized() -> bool:
        if _request_is_local():
            return True
        token = request.headers.get("X-CocktailBot-Admin-Token", "").strip()
        if not token:
            token = request.cookies.get("cocktailbot_admin", "").strip()
        return network_access.valid_token(token)

    def network_blocked(message: str, *, disabled: bool = False):
        if request.path.startswith("/api/"):
            return jsonify(
                ok=False,
                error=message,
                networkAccessDisabled=disabled,
            ), 403
        detail = (
            "Öffne CocktailBot direkt am Raspberry und aktiviere unter "
            "Einstellungen → Netzwerk & Tablet den Zugriff im lokalen Netzwerk."
            if disabled
            else "CocktailBot akzeptiert nur Verbindungen aus einem privaten lokalen Netzwerk."
        )
        return (
            "<!doctype html><html lang='de'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>CocktailBot – Netzwerkzugriff</title></head>"
            "<body style='margin:0;background:#080808;color:#f4f4f4;font-family:sans-serif;"
            "display:grid;place-items:center;min-height:100vh'>"
            "<main style='max-width:620px;padding:28px;border:1px solid #3a3a3a;"
            "border-radius:18px;background:#151515'>"
            "<h1 style='margin-top:0;color:#b7ff00'>CocktailBot</h1>"
            f"<h2>{message}</h2><p style='line-height:1.5'>{detail}</p>"
            "</main></body></html>",
            403,
            {"Content-Type": "text/html; charset=utf-8"},
        )

    @app.before_request
    def enforce_lan_access():  # type: ignore[no-untyped-def]
        if request.method == "OPTIONS":
            return None
        if _request_is_local():
            return None
        # Never accept requests forwarded directly from a public Internet IP.
        if not _request_is_private_lan():
            return network_blocked("CocktailBot ist nur im lokalen Netzwerk erreichbar")
        if not network_access.lan_enabled:
            return network_blocked(
                "Netzwerkzugriff ist am CocktailBot deaktiviert",
                disabled=True,
            )

        path = request.path
        protected_exact = {
            "/api/network/access",
            "/api/network/admin-logout",
            "/api/license/activate",
            "/api/license/deactivate",
            "/api/payment/test",
            "/api/payment/config",
            "/api/kiosk/exit",
        }
        protected_prefixes = (
            "/api/images/",
            "/api/keyboard/",
        )
        needs_admin = path in protected_exact or any(
            path.startswith(prefix) for prefix in protected_prefixes
        )

        if path == "/api/app-state" and request.method == "POST":
            needs_admin = True

        if path == "/api/command" and request.method == "POST":
            payload = request.get_json(silent=True)
            action = str(payload.get("action", "")) if isinstance(payload, dict) else ""
            if action in {
                "set_led",
                "save_machine_state",
                "run_pump",
                "prime",
                "clean",
            }:
                needs_admin = True

        # Login and read-only network status must stay reachable before login.
        if path == "/api/network/admin-login" or (
            path == "/api/network/access" and request.method == "GET"
        ):
            needs_admin = False

        if needs_admin and not remote_admin_authorized():
            return jsonify(
                ok=False,
                error="Admin-PIN erforderlich",
                adminPinRequired=True,
            ), 401
        return None

    @app.after_request
    def add_cors_headers(response):  # type: ignore[no-untyped-def]
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-CocktailBot-Admin-Token"
        # Lokaler Kiosk: keine alten Flutter-/500-Seiten nach einem Update cachen.
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
        return response

    @app.get("/api/app-state")
    def api_app_state_get():
        return jsonify(ok=True, state=load_app_state())

    @app.route("/api/app-state", methods=["POST", "OPTIONS"])
    def api_app_state_update():
        if request.method == "OPTIONS":
            return ("", 204)
        # Local kiosk writes are always allowed. Remote writes reach this
        # endpoint only after successful Admin-PIN authentication.
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        state = payload.get("state")
        if not isinstance(state, dict):
            return jsonify(ok=False, error="state fehlt oder ist ungültig"), 400
        state = dict(state)
        existing = load_app_state()
        internal_usage_ids = existing.get("_lanUsageEventIds") if isinstance(existing, dict) else None
        if isinstance(internal_usage_ids, list):
            state["_lanUsageEventIds"] = internal_usage_ids[-1000:]
        save_app_state(state)
        return jsonify(ok=True, bytes=len(json.dumps(state, ensure_ascii=False)))

    @app.route("/api/usage/record", methods=["POST", "OPTIONS"])
    def api_usage_record():
        if request.method == "OPTIONS":
            return ("", 204)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        record = payload.get("record")
        if not isinstance(record, dict):
            return jsonify(ok=False, error="record fehlt oder ist ungültig"), 400

        recipe_id = str(record.get("recipeId", "")).strip()
        if not recipe_id:
            return jsonify(ok=False, error="recipeId fehlt"), 400
        try:
            size_ml = float(record.get("sizeMl", 0))
        except (TypeError, ValueError):
            return jsonify(ok=False, error="sizeMl ist ungültig"), 400
        if size_ml <= 0 or size_ml > 5000:
            return jsonify(ok=False, error="sizeMl ist außerhalb des gültigen Bereichs"), 400

        raw_amounts = record.get("ingredientAmountsMl")
        if not isinstance(raw_amounts, dict):
            return jsonify(ok=False, error="ingredientAmountsMl fehlt"), 400
        amounts: dict[str, float] = {}
        try:
            for key, value in raw_amounts.items():
                ingredient_id = str(key).strip()
                amount = float(value)
                if not ingredient_id or amount < 0 or amount > 5000:
                    raise ValueError
                amounts[ingredient_id] = amount
        except (TypeError, ValueError):
            return jsonify(ok=False, error="Ungültige Zutatenmenge"), 400

        canonical = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        event_id = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        state = load_app_state()
        if not state:
            return jsonify(ok=False, error="CocktailBot-App-Status ist noch nicht initialisiert"), 409

        seen = state.get("_lanUsageEventIds")
        if not isinstance(seen, list):
            seen = []
        seen_ids = [str(item) for item in seen]
        if event_id in seen_ids:
            return jsonify(ok=True, duplicate=True, eventId=event_id)

        recipe_counts = state.get("recipeDrinkCounts")
        if not isinstance(recipe_counts, dict):
            recipe_counts = {}
        recipe_counts[recipe_id] = int(recipe_counts.get(recipe_id, 0) or 0) + 1
        state["recipeDrinkCounts"] = recipe_counts

        size_key = f"{round(size_ml)} ml"
        size_counts = state.get("servingSizeCounts")
        if not isinstance(size_counts, dict):
            size_counts = {}
        size_counts[size_key] = int(size_counts.get(size_key, 0) or 0) + 1
        state["servingSizeCounts"] = size_counts

        usage = state.get("ingredientUsageMl")
        if not isinstance(usage, dict):
            usage = {}
        for ingredient_id, amount in amounts.items():
            try:
                current = float(usage.get(ingredient_id, 0) or 0)
            except (TypeError, ValueError):
                current = 0.0
            usage[ingredient_id] = current + amount
        state["ingredientUsageMl"] = usage

        inventory = state.get("shoppingInventoryMl")
        if isinstance(inventory, dict):
            for ingredient_id, amount in amounts.items():
                if ingredient_id not in inventory:
                    continue
                try:
                    current = float(inventory.get(ingredient_id, 0) or 0)
                except (TypeError, ValueError):
                    current = 0.0
                inventory[ingredient_id] = max(0.0, current - amount)
            state["shoppingInventoryMl"] = inventory

        party_session_id = str(record.get("partySessionId") or "").strip()
        sessions = state.get("partySessions")
        if party_session_id and isinstance(sessions, list):
            for session in sessions:
                if not isinstance(session, dict) or str(session.get("id", "")) != party_session_id:
                    continue
                drink_counts = session.get("drinkCounts")
                if not isinstance(drink_counts, dict):
                    drink_counts = {}
                drink_counts[recipe_id] = int(drink_counts.get(recipe_id, 0) or 0) + 1
                session["drinkCounts"] = drink_counts
                party_size_counts = session.get("sizeCounts")
                if not isinstance(party_size_counts, dict):
                    party_size_counts = {}
                party_size_counts[size_key] = int(party_size_counts.get(size_key, 0) or 0) + 1
                session["sizeCounts"] = party_size_counts
                break
            state["partySessions"] = sessions

        history = state.get("consumptionHistory")
        if not isinstance(history, list):
            history = []
        history.append(record)
        if len(history) > 5000:
            history = history[-5000:]
        state["consumptionHistory"] = history

        seen_ids.append(event_id)
        state["_lanUsageEventIds"] = seen_ids[-1000:]
        state["sharedAt"] = datetime.now(timezone.utc).isoformat()
        save_app_state(state)
        return jsonify(ok=True, duplicate=False, eventId=event_id)

    @app.get("/api/network/access")
    def api_network_access():
        try:
            port = int(request.environ.get("SERVER_PORT", 8080))
        except (TypeError, ValueError):
            port = 8080
        return jsonify(
            network_access.public_status(
                client_is_local=_request_is_local(),
                port=port,
            )
        )

    @app.route("/api/network/access", methods=["POST", "OPTIONS"])
    def api_network_access_update():
        if request.method == "OPTIONS":
            return ("", 204)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        try:
            network_access.configure(
                lan_enabled=payload.get("lanEnabled") is True,
                admin_pin=str(payload.get("adminPin", "")),
            )
            port = int(request.environ.get("SERVER_PORT", 8080))
            return jsonify(
                network_access.public_status(
                    client_is_local=_request_is_local(),
                    port=port,
                )
            )
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400

    @app.route("/api/network/admin-login", methods=["POST", "OPTIONS"])
    def api_network_admin_login():
        if request.method == "OPTIONS":
            return ("", 204)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        token = network_access.create_token(str(payload.get("pin", "")))
        if token is None:
            return jsonify(ok=False, error="Falscher Admin-PIN"), 401
        response = jsonify(
            ok=True,
            token=token,
            expiresInSeconds=NETWORK_ADMIN_TOKEN_TTL_SECONDS,
        )
        response.set_cookie(
            "cocktailbot_admin",
            token,
            max_age=NETWORK_ADMIN_TOKEN_TTL_SECONDS,
            httponly=True,
            samesite="Strict",
            secure=False,
        )
        return response

    @app.route("/api/network/admin-logout", methods=["POST", "OPTIONS"])
    def api_network_admin_logout():
        if request.method == "OPTIONS":
            return ("", 204)
        token = request.headers.get("X-CocktailBot-Admin-Token", "").strip()
        if not token:
            token = request.cookies.get("cocktailbot_admin", "").strip()
        network_access.revoke_token(token)
        response = jsonify(ok=True)
        response.delete_cookie("cocktailbot_admin")
        return response

    @app.get("/api/status")
    def api_status():
        return jsonify(controller.status())

    @app.post("/api/images/optimize")
    def api_optimize_uploaded_image():
        """Optimize an image selected with Chromium's native file chooser.

        The browser cannot expose an arbitrary Linux path to Flutter Web, so
        the selected file is posted as raw bytes. Keep this endpoint local and
        deliberately small: it accepts images only, limits payload size and
        returns an EXIF-corrected, resized JPEG.
        """
        raw = request.get_data(cache=False, as_text=False)
        if not raw:
            return jsonify(ok=False, error="Leere Bilddatei"), 400
        if len(raw) > 25 * 1024 * 1024:
            return jsonify(ok=False, error="Bild ist größer als 25 MB"), 413
        try:
            image = Image.open(io.BytesIO(raw))
            image = ImageOps.exif_transpose(image)
            if image.mode not in ("RGB", "L"):
                background = Image.new("RGB", image.size, (10, 10, 10))
                if "A" in image.getbands():
                    background.paste(image.convert("RGBA"), mask=image.getchannel("A"))
                    image = background
                else:
                    image = image.convert("RGB")
            elif image.mode == "L":
                image = image.convert("RGB")
            image.thumbnail((1200, 1200), Image.Resampling.LANCZOS)
            out = io.BytesIO()
            image.save(out, format="JPEG", quality=88, optimize=True)
            out.seek(0)
            return send_file(
                out,
                mimetype="image/jpeg",
                download_name="cocktail-image.jpg",
                max_age=0,
            )
        except Exception as exc:
            return jsonify(ok=False, error=f"Bild konnte nicht verarbeitet werden: {exc}"), 400

    @app.get("/api/images/usb")
    def api_usb_images():
        images = scan_usb_images()
        return jsonify(
            ok=True,
            images=images,
            count=len(images),
            roots=[str(root) for root in usb_scan_roots()],
        )

    @app.get("/api/images/usb/file")
    def api_usb_image_file():
        token = request.args.get("id", "").strip()
        thumbnail = request.args.get("thumb", "0") in {"1", "true", "True"}
        path = usb_image_cache.get(token)
        if path is None:
            # The server may have restarted after the list was displayed.
            scan_usb_images()
            path = usb_image_cache.get(token)
        if path is None:
            return jsonify(ok=False, error="USB-Bild nicht gefunden"), 404
        try:
            payload = usb_image_bytes(path, thumbnail=thumbnail)
        except (OSError, ValueError, RuntimeError) as exc:
            return jsonify(ok=False, error=f"Bild konnte nicht gelesen werden: {exc}"), 400
        return send_file(
            payload,
            mimetype="image/jpeg",
            download_name="cocktail.jpg",
            max_age=0,
        )

    @app.get("/api/license/status")
    def api_license_status():
        return jsonify(licensing.status())

    @app.route("/api/license/activate", methods=["POST", "OPTIONS"])
    def api_license_activate():
        if request.method == "OPTIONS":
            return ("", 204)
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        try:
            code = str(payload.get("code", ""))
            return jsonify(licensing.activate(code))
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc), **licensing.status()), 400

    @app.route("/api/license/deactivate", methods=["POST", "OPTIONS"])
    def api_license_deactivate():
        if request.method == "OPTIONS":
            return ("", 204)
        try:
            return jsonify(licensing.deactivate())
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400

    @app.route("/api/keyboard/show", methods=["POST", "OPTIONS"])
    def api_keyboard_show():
        if request.method == "OPTIONS":
            return ("", 204)
        shown = show_onboard_keyboard()
        return jsonify(ok=shown, keyboard="onboard", visible=shown), (200 if shown else 503)

    @app.route("/api/keyboard/hide", methods=["POST", "OPTIONS"])
    def api_keyboard_hide():
        if request.method == "OPTIONS":
            return ("", 204)
        hidden = hide_onboard_keyboard()
        return jsonify(ok=hidden, keyboard="onboard", visible=False), (200 if hidden else 503)

    @app.route("/api/kiosk/exit", methods=["POST", "OPTIONS"])
    def api_kiosk_exit():
        if request.method == "OPTIONS":
            return ("", 204)

        controller.stop("Kiosk wird beendet")
        try:
            KIOSK_STOP_FILE.parent.mkdir(parents=True, exist_ok=True)
            KIOSK_STOP_FILE.write_text(str(time.time()), encoding="utf-8")
        except OSError as exc:
            return jsonify(ok=False, error=f"Kiosk-Stopdatei: {exc}"), 500

        hide_onboard_keyboard()

        def stop_browser() -> None:
            time.sleep(0.35)
            subprocess.run(
                [
                    "pkill",
                    "-u",
                    str(os.getuid()),
                    "-f",
                    "chromium.*cocktailbot-chromium",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

        threading.Thread(target=stop_browser, daemon=True).start()
        return jsonify(ok=True, message="CocktailBot-Kiosk wird geschlossen")

    @app.route("/api/command", methods=["POST", "OPTIONS"])
    def api_command():
        if request.method == "OPTIONS":
            return ("", 204)

        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400

        action = str(payload.get("action", "")).strip()
        if not action:
            return jsonify(ok=False, error="Feld action fehlt"), 400

        try:
            if action == "set_led":
                mode = str(payload.get("mode", "solid"))
                if mode not in {"solid", "rainbow", "breathe", "blink", "chase", "off"}:
                    raise ValidationError("Unbekannter LED-Modus")
                values = {
                    key: as_int(payload.get(key, controller.led_settings[key]), key)
                    for key in ("r", "g", "b", "brightness")
                }
                if any(value < 0 or value > 255 for value in values.values()):
                    raise ValidationError("Ungültige LED-Farbwerte")
                settings = {"mode": mode, **values}
                transmitted = controller.apply_led_settings(settings)
                return jsonify(
                    ok=True,
                    action=action,
                    mode=mode,
                    picoConnected=controller.pico.connected,
                    transmitted=transmitted,
                )

            if action == "save_machine_state":
                state = payload.get("machineState")
                if not isinstance(state, dict):
                    raise ValidationError("machineState fehlt oder ist ungültig")
                controller.save_machine_state(state)
                return jsonify(ok=True, action=action, bytes=len(json.dumps(state)))

            if action == "save_fill_state":
                pump_updates = payload.get("pumps")
                if not isinstance(pump_updates, list):
                    raise ValidationError("pumps fehlt oder ist ungültig")
                with controller._lock:
                    state = dict(controller.machine_state)
                current_pumps = state.get("pumps")
                if not isinstance(current_pumps, list):
                    current_pumps = []
                by_number: dict[int, dict[str, Any]] = {}
                for item in current_pumps:
                    if not isinstance(item, dict):
                        continue
                    try:
                        number = int(item.get("number", 0))
                    except (TypeError, ValueError):
                        continue
                    if 1 <= number <= PUMP_COUNT:
                        by_number[number] = dict(item)
                for update in pump_updates:
                    if not isinstance(update, dict):
                        continue
                    number = as_int(update.get("number"), "number")
                    if number < 1 or number > PUMP_COUNT:
                        raise ValidationError("Ungültige Pumpennummer")
                    try:
                        remaining = float(update.get("remainingMl", 0))
                    except (TypeError, ValueError) as exc:
                        raise ValidationError("remainingMl ist ungültig") from exc
                    remaining = max(0.0, min(100000.0, remaining))
                    item = by_number.get(number, {"number": number})
                    item["remainingMl"] = remaining
                    by_number[number] = item
                state["pumps"] = [by_number[n] for n in sorted(by_number)]
                controller.save_machine_state(state)

                # Keep the read-only LAN snapshot's fill levels in step as well.
                shared = load_app_state()
                shared_pumps = shared.get("pumps") if isinstance(shared, dict) else None
                if isinstance(shared_pumps, list):
                    shared_by_number: dict[int, dict[str, Any]] = {}
                    for item in shared_pumps:
                        if not isinstance(item, dict):
                            continue
                        try:
                            number = int(item.get("number", 0))
                        except (TypeError, ValueError):
                            continue
                        if 1 <= number <= PUMP_COUNT:
                            shared_by_number[number] = dict(item)
                    for number, item in by_number.items():
                        target = shared_by_number.get(number)
                        if target is not None and "remainingMl" in item:
                            target["remainingMl"] = item["remainingMl"]
                    shared["pumps"] = [
                        shared_by_number[n] for n in sorted(shared_by_number)
                    ]
                    save_app_state(shared)
                return jsonify(ok=True, action=action, pumpCount=len(by_number))

            if action in {"stop", "all_off"}:
                controller.stop("Not-Aus")
                return jsonify(ok=True, action="stop", message="Alle Pumpen ausgeschaltet")

            if controller.status()["busy"]:
                return jsonify(ok=False, error="Maschine ist bereits beschäftigt"), 409

            if action == "run_pump":
                step = validate_step(payload.get("pump"), payload.get("durationMs"), 0)
                job = PumpJob("run_pump", "sequential", (step,), step.duration_ms)
            elif action == "prepare_recipe":
                job = build_recipe_job(payload)
            elif action in {"prime", "clean"}:
                job = build_sequential_job(payload, action)
            else:
                raise ValidationError(f"Unbekannte action: {action}")

            if not controller.start(job):
                return jsonify(ok=False, error="Auftrag konnte nicht gestartet werden"), 409

            return (
                jsonify(
                    ok=True,
                    accepted=True,
                    action=job.action,
                    stepCount=len(job.steps),
                    totalDurationMs=job.total_duration_ms,
                    mode=job.mode,
                ),
                202,
            )
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400
        except OSError as exc:
            controller.stop("GPIO-Fehler")
            return jsonify(ok=False, error=f"GPIO-/Dateifehler: {exc}"), 500

    @app.get("/api/payment/status")
    def api_payment_status():
        return jsonify(payment.status())

    @app.route("/api/payment/test", methods=["POST", "OPTIONS"])
    def api_payment_test():
        if request.method == "OPTIONS":
            return ("", 204)
        blocked = require_commercial_license()
        if blocked is not None:
            return blocked
        try:
            return jsonify(payment.test_connection())
        except PaymentError as exc:
            return jsonify(ok=False, error=str(exc)), exc.status_code

    @app.route("/api/payment/config", methods=["POST", "OPTIONS"])
    def api_payment_config():
        if request.method == "OPTIONS":
            return ("", 204)
        blocked = require_commercial_license()
        if blocked is not None:
            return blocked
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        try:
            return jsonify(payment.save_price_config(payload))
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400
        except PaymentError as exc:
            return jsonify(ok=False, error=str(exc)), exc.status_code

    @app.route("/api/payment/create-order", methods=["POST", "OPTIONS"])
    def api_payment_create_order():
        if request.method == "OPTIONS":
            return ("", 204)
        blocked = require_commercial_license()
        if blocked is not None:
            return blocked
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        try:
            return jsonify(payment.create_order(payload)), 201
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400
        except PaymentError as exc:
            return jsonify(ok=False, error=str(exc)), exc.status_code

    @app.get("/api/payment/order-status")
    def api_payment_order_status():
        try:
            return jsonify(payment.order_status(request.args.get("orderId", "")))
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400
        except PaymentError as exc:
            return jsonify(ok=False, error=str(exc)), exc.status_code

    @app.route("/api/payment/mark-used", methods=["POST", "OPTIONS"])
    def api_payment_mark_used():
        if request.method == "OPTIONS":
            return ("", 204)
        blocked = require_commercial_license()
        if blocked is not None:
            return blocked
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Ungültiges JSON"), 400
        try:
            return jsonify(
                payment.mark_used(
                    str(payload.get("orderId", "")),
                    str(payload.get("machineId", "")),
                )
            )
        except ValidationError as exc:
            return jsonify(ok=False, error=str(exc)), 400
        except PaymentError as exc:
            return jsonify(ok=False, error=str(exc)), exc.status_code

    @app.get("/payment/return")
    def payment_return_page():
        return (
            "<!doctype html><meta name='viewport' content='width=device-width'>"
            "<title>CocktailBot</title><body style='font-family:sans-serif;text-align:center;padding:3rem'>"
            "<h1>Zahlung freigegeben</h1><p>Du kannst dieses Fenster schließen. "
            "Die Cocktailmaschine prüft die Zahlung automatisch.</p></body>"
        )

    @app.get("/payment/cancel")
    def payment_cancel_page():
        return (
            "<!doctype html><meta name='viewport' content='width=device-width'>"
            "<title>CocktailBot</title><body style='font-family:sans-serif;text-align:center;padding:3rem'>"
            "<h1>Zahlung abgebrochen</h1><p>Es wurde kein Cocktail freigegeben.</p></body>"
        )

    @app.get("/")
    def root():
        index = web_root / "index.html"
        if index.is_file():
            return send_from_directory(web_root, "index.html")
        return jsonify(
            device="CocktailBot-RaspberryPi",
            statusEndpoint="/api/status",
            commandEndpoint="/api/command",
            paymentEndpoint="/api/payment/status",
            licenseEndpoint="/api/license/status",
            message="Flutter-Web-Build fehlt im konfigurierten web-root",
        )

    @app.get("/<path:resource>")
    def static_or_spa(resource: str):
        candidate = web_root / resource
        if candidate.is_file():
            return send_from_directory(web_root, resource)
        index = web_root / "index.html"
        if index.is_file():
            return send_from_directory(web_root, "index.html")
        return jsonify(ok=False, error="Datei nicht gefunden"), 404

    return app


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--web-root", type=Path, default=Path("/opt/cocktailbot/web"))
    args = parser.parse_args()

    controller = PumpController()
    atexit.register(controller.close)

    def shutdown_handler(signum: int, _frame: Any) -> None:
        controller.stop(f"Signal {signum}")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print("CocktailBot Raspberry Pi")
    print(f"GPIO-Modus: BCM | active_high={ACTIVE_HIGH} | mock={MOCK_GPIO}")
    if GPIOZERO_LGPIO_CHIP is not None:
        print(
            f"GPIO-Chip: gpiochip{GPIOZERO_LGPIO_CHIP} "
            f"| Quelle={GPIOZERO_LGPIO_CHIP_SOURCE}"
        )
    else:
        print(f"GPIO-Chip: gpiozero-standard | Quelle={GPIOZERO_LGPIO_CHIP_SOURCE}")
    print("Pumpen:", ", ".join(f"{i}=GPIO{pin}" for i, pin in enumerate(PUMP_PINS, 1)))
    print(f"Web/API: http://{args.host}:{args.port}")
    print(f"PayPal: mode={PAYPAL_MODE} | configured={bool(PAYPAL_CLIENT_ID and PAYPAL_CLIENT_SECRET)}")
    device_id, device_source = cocktailbot_device_id()
    print(f"Lizenz-Geräte-ID: {device_id} | Quelle={device_source}")

    app = create_app(controller, args.web_root.resolve())
    app.run(host=args.host, port=args.port, threaded=True, use_reloader=False)


if __name__ == "__main__":
    main()
