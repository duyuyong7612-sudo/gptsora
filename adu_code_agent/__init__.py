# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-44c2d8205aeb6326fabbf188f8161d4a4e8e4c14256b701c15e729143b8a49c2"
# Source-SHA256: "bb1367fac5edc75952da2a9166ea32ba02b0baad3f95b958a471f0ee70e60822"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""adu_code_agent — local safe code-engineering agent toolkit.

Self-contained Python package providing:
  - file system tools (list / read / write / patch / search) with dry-run + diff
  - shell tools (run / check_port / kill_process) with command blocklist
  - secret masking on all output
  - allow-paths enforcement on writes
  - AgentLoop scaffold for scripted task execution
  - FastAPI router + standalone server for HTTP usage
  - CLI for direct terminal use

See README.md for usage.
"""
__version__ = "0.1.0"

from . import config, safety, fs_tools, shell_tools, loop  # noqa: F401

__all__ = ["config", "safety", "fs_tools", "shell_tools", "loop", "__version__"]
