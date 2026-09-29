# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-16ef2ce7d65c1c2ee48aa0e2510018c9f0ee88f3fea3759e529797fbaf3a70e2"
# Source-SHA256: "c636ca281d7476e54ab4ec6aa5f7bd6b8f03bc7a5e1c90539b55dae391618222"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Path safety, secret masking, dangerous-command detection.

Every write goes through `check_write_allowed(path)` BEFORE diff/backup/apply.
Every read goes through `check_read_allowed(path)` BEFORE returning content.
All textual output goes through `mask_secrets(text)` before being returned/logged.
Every shell command goes through `is_dangerous_command(cmd)` BEFORE execution.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Tuple

from . import config


def canonical(p) -> Path:
    return Path(str(p)).expanduser().resolve()


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def check_read_allowed(path) -> Tuple[bool, str]:
    p = canonical(path)
    for ap in config.ALLOW_PATHS + config.READ_ALSO_OK:
        if p == ap or _is_within(p, ap):
            return True, ""
    return False, f"read_denied: {p} is not under ALLOW_PATHS / READ_ALSO_OK"


def check_write_allowed(path) -> Tuple[bool, str]:
    p = canonical(path)
    # 1) Hard-forbidden direct targets — can't write to these paths themselves.
    for f in config.HARD_FORBIDDEN_WRITE_TARGETS:
        if p == f:
            return False, f"write_denied: {p} is a protected root"
    # 2) Forbidden dir names anywhere in the path (e.g. .git, node_modules).
    for part in p.parts:
        if part in config.FORBIDDEN_DIRNAMES:
            return False, f"write_denied: path contains protected segment '{part}'"
    # 3) Must be inside some ALLOW_PATHS root.
    for ap in config.ALLOW_PATHS:
        if p == ap or _is_within(p, ap):
            return True, ""
    return False, (
        f"write_denied: {p} is outside ADU_AGENT_ALLOW_PATHS="
        f"{[str(x) for x in config.ALLOW_PATHS]}"
    )


# ---- secret masking ---------------------------------------------------

# Provider key prefixes — match a wide range of long token shapes.
_TOKEN_PATS = [
    re.compile(r'\bsk-ant-[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\bsk-proj-[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\bsk-[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\bek_[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\bek-[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\brt_[A-Za-z0-9_\-]{16,}'),
    re.compile(r'\bAKIA[0-9A-Z]{16}\b'),                  # AWS Access Key
    re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),          # GitHub PAT
]

# Env-style ASSIGNMENT: SOMETHING_KEY = <long secret>
_ENV_KEY_PAT = re.compile(
    r'(\b[A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASS|API)\b\s*[=:]\s*["\']?)'
    r'([A-Za-z0-9_\-+/=\.]{20,})'
)


def _mask_token(s: str) -> str:
    if len(s) <= 8:
        return "****"
    for prefix in ("sk-ant-", "sk-proj-", "sk-", "ek_", "ek-", "rt_", "AKIA",
                   "ghp_", "gho_", "ghu_", "ghs_", "ghr_"):
        if s.startswith(prefix):
            return f"{prefix}***{s[-4:]}"
    return f"{s[:3]}***{s[-4:]}"


def mask_secrets(text):
    """Mask secret-looking tokens in a string. Idempotent on already-masked text."""
    if not isinstance(text, str) or not text:
        return text
    out = text
    for pat in _TOKEN_PATS:
        out = pat.sub(lambda m: _mask_token(m.group(0)), out)
    out = _ENV_KEY_PAT.sub(lambda m: m.group(1) + _mask_token(m.group(2)), out)
    return out


# ---- dangerous shell commands ---------------------------------------

# These patterns are hard-blocked. There is no "force allow" — the request
# is refused before any subprocess starts.
_DANGER_REGEX = [
    re.compile(r'\brm\s+-rf?\s+/\s*($|[\s&;|])'),
    re.compile(r'\brm\s+-rf?\s+~\s*($|[\s&;|])'),
    re.compile(r'\brm\s+-rf?\s+\$HOME\b'),
    re.compile(r'\bsudo\b.*\brm\b'),
    re.compile(r'\bdiskutil\s+erase'),
    re.compile(r'\bmkfs(?:\.|\s)'),
    re.compile(r'\bdd\b.*\bif='),
    re.compile(r'\bchmod\s+-R\s+777\s+/'),
    re.compile(r'\bchown\s+-R\b'),
    re.compile(r'\bcurl\b[^|]*\|\s*\b(?:sh|bash|zsh)\b'),
    re.compile(r'\bwget\b[^|]*\|\s*\b(?:sh|bash|zsh)\b'),
    re.compile(r'\bnpm\s+publish\b'),
    re.compile(r'\bgit\s+push\b[^&;|]*--force\b'),
    re.compile(r'\bgit\s+push\b[^&;|]*\s-f(?:\s|$)'),
    # Don't allow leaking OPENAI_API_KEY value via echo/printf/env
    re.compile(r'(?:echo|printf|print)\b[^|;]*\$\{?OPENAI_API_KEY\}?'),
]

# If the literal command line CONTAINS an actual secret-looking token, refuse.
_TOKEN_IN_CMD_PAT = re.compile(r'\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}')


def is_dangerous_command(cmd) -> Tuple[bool, str]:
    if not isinstance(cmd, str) or not cmd.strip():
        return True, "empty_command"
    s = cmd.strip()
    for pat in _DANGER_REGEX:
        if pat.search(s):
            return True, f"blocked_by_pattern: {pat.pattern}"
    if _TOKEN_IN_CMD_PAT.search(s):
        return True, "blocked: command contains a literal secret-looking token"
    return False, ""


__all__ = [
    "canonical", "check_read_allowed", "check_write_allowed",
    "mask_secrets", "is_dangerous_command",
]
