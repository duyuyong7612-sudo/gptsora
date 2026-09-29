# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-3f2cdcc5462448df9d424633be14504652046d87da5bc100ef0916f9ee3da388"
# Source-SHA256: "8f10fcb7f3f39ecb259f3c036c5e4945720c1ad0dad685b01a21c9ead686ef9d"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""adu_orchestrator — minimal multi-tool dispatcher (code / browser / desktop).

V1 wires the local tools we already have (adu_code_agent, local-agent :4317).
Codex CLI, Claude Code, browser-use are adapter stubs — see README.md.
"""
__version__ = "0.1.0"

from . import dispatcher  # noqa: F401

__all__ = ["dispatcher", "__version__"]
