# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-12fe1f85797175ff03c919816a5d92950b02df700afa01b8ee38bbd0a498a6d6"
# Source-SHA256: "9999f6cb077f5a70428c23e760dcd1507979e38857cd1a189bd780fe680a1b83"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""adu_code_agent.config — central knobs.

ALLOW_PATHS: roots where writes are allowed. Set via env var
ADU_AGENT_ALLOW_PATHS (colon-separated). Defaults to a small set
of Desktop project directories.

    export ADU_AGENT_ALLOW_PATHS="$HOME/Desktop/projA:$HOME/Desktop/projB"

Reads have a wider allowed set (ALLOW_PATHS + READ_ALSO_OK).
Writes are strictly limited to ALLOW_PATHS.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import List


def _expand(p: str) -> Path:
    return Path(p).expanduser().resolve()


_DEFAULT_ALLOW = [
    "~/Desktop/backend",
    "~/Desktop/little-beijing-edge-box",
    "~/Desktop/GPTsora",
]
_env = os.environ.get("ADU_AGENT_ALLOW_PATHS", "").strip()
if _env:
    ALLOW_PATHS: List[Path] = [_expand(p) for p in _env.split(":") if p.strip()]
else:
    ALLOW_PATHS = [_expand(p) for p in _DEFAULT_ALLOW]

# Read is broader: ALLOW_PATHS plus a few system-safe scratch dirs.
READ_ALSO_OK = [
    _expand("/tmp"),
    _expand("/private/tmp"),
]

# These exact paths can NEVER be the direct target of a write. Subdirs
# inside them that ARE inside ALLOW_PATHS are still writable.
HARD_FORBIDDEN_WRITE_TARGETS = [
    Path("/"),
    Path.home(),
    Path.home() / "Desktop",
    Path.home() / "Downloads",
    Path.home() / "Documents",
    Path.home() / "Library",
    Path("/Users"),
    Path("/Applications"),
    Path("/System"),
    Path("/private"),
    Path("/tmp"),
]

# These directory NAMES are never a legitimate write target wherever they appear.
FORBIDDEN_DIRNAMES = {".git", ".venv", "venv", "node_modules", "__pycache__"}

DEFAULT_EXCLUDES = [
    ".git", ".venv", "venv", "node_modules", "__pycache__",
    ".DS_Store", "dist", "build", "DerivedData", ".next", ".turbo",
    ".idea", ".vscode", ".pytest_cache", ".mypy_cache",
    "*.pyc", "*.log", "*.swp", "*.tmp",
]

MAX_READ_LINES_DEFAULT = 400
MAX_READ_LINES_HARD = 5000
MAX_OUTPUT_BYTES = 200_000          # cap on stdout / read output
MAX_FILES_LIST = 5000

DEFAULT_CMD_TIMEOUT = 60.0
MAX_CMD_TIMEOUT = 600.0

BACKUP_DIR_NAME = ".adu_backups"
