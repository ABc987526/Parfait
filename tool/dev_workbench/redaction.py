"""Redaction helpers for telemetry, snapshots, and gateway request traces."""

from __future__ import annotations

import re
from typing import Any

REDACTED = "[REDACTED]"

_SENSITIVE_KEY_EXACT = frozenset({
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
    "x-parfait-workbench-token",
    "accesstoken",
    "access_token",
    "refreshtoken",
    "refresh_token",
    "apikey",
    "api_key",
    "secret",
    "password",
    "code_verifier",
    "transferenvelope",
    "transfer_envelope",
})

_BEARER_RE = re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]+", re.IGNORECASE)
_TRANSFER_ENVELOPE_B64_RE = re.compile(
    r"eyJ2ZXJzaW9uIjoyLCJwYXlsb2FkVHlwZSI6InBpeGl2LWFjY291bnQtdHJhbnNmZXIi[A-Za-z0-9+/=_-]+"
)
_COOKIE_HEADER_RE = re.compile(
    r"(?:^|(?<=[\s]))(set-cookie|cookie)\s*:\s*[^\r\n]+",
    re.IGNORECASE,
)
_AUTH_HEADER_RE = re.compile(
    r"""(?:^|(?<=[\s]))((?:proxy-)?authorization)\s*:\s*(?:(?:Bearer|Basic|Token|Digest)\s+)?[^\s\r\n"']+""",
    re.IGNORECASE,
)
_API_KEY_HEADER_RE = re.compile(
    r"""(?:^|(?<=[\s]))(x-parfait-workbench-token|x-api-key)\s*:\s*[^\s\r\n"']+""",
    re.IGNORECASE,
)
_PARAM_SECRET_RE = re.compile(
    r"""((?:[A-Za-z0-9_.-]*(?:access_?token|refresh_?token|id_?token|code_?verifier|phpsessid|api_?key|apikey|secret|password|token)|(?<![A-Za-z0-9_])(?:code|cookie))\s*=\s*["']?)([^"'\s&;,}]+)(["']?)""",
    re.IGNORECASE,
)
_JSON_SECRET_RE = re.compile(
    r'("[A-Za-z0-9_.-]*(?:access_?token|refresh_?token|id_?token|cookie|set-cookie|authorization|x-parfait-workbench-token|api_?key|secret|password|code_?verifier|transfer_?envelope)"\s*:\s*)"([^"\\]*(?:\\.[^"\\]*)*)"',
    re.IGNORECASE,
)


def _is_sensitive_key(key: str) -> bool:
    low = key.lower().replace("-", "").replace("_", "")
    return (
        key.lower() in _SENSITIVE_KEY_EXACT
        or "token" in low
        or "secret" in low
        or "cookie" in low
        or "password" in low
        or "authorization" in low
        or "apikey" in low
        or "credential" in low
        or "transferenvelope" in low
    )


def redact_text(text: str) -> str:
    if not text:
        return text
    out = _TRANSFER_ENVELOPE_B64_RE.sub(REDACTED, text)
    out = _BEARER_RE.sub(f"Bearer {REDACTED}", out)
    out = _COOKIE_HEADER_RE.sub(lambda m: f"{m.group(1)}: {REDACTED}", out)
    out = _AUTH_HEADER_RE.sub(lambda m: f"{m.group(1)}: {REDACTED}", out)
    out = _API_KEY_HEADER_RE.sub(lambda m: f"{m.group(1)}: {REDACTED}", out)
    out = _PARAM_SECRET_RE.sub(lambda m: f"{m.group(1)}{REDACTED}{m.group(3)}", out)
    out = _JSON_SECRET_RE.sub(lambda m: f'{m.group(1)}"{REDACTED}"', out)
    return out


def redact_value(value: Any, *, key: str | None = None) -> Any:
    if key is not None and _is_sensitive_key(key):
        return REDACTED
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [redact_value(item) for item in value]
    if isinstance(value, tuple):
        return [redact_value(item) for item in value]
    if isinstance(value, dict):
        return {
            str(k): redact_value(v, key=str(k))
            for k, v in value.items()
        }
    return value


def redact_headers(headers: dict[str, str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for k, v in headers.items():
        if _is_sensitive_key(k):
            out[k] = REDACTED
        else:
            out[k] = redact_text(v)
    return out
