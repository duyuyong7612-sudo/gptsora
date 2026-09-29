# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-c77102be6686cc58ccc0e24f8962ec47f9b25894bc5122e3d16d52305e6bb4a7"
# Source-SHA256: "03af5164478a6ddd2f562497f80064d28d8f1b7b9df9aad046acefebbd683d57"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""File system tools: list_files, read_file, write_file, patch_file, search_text.

All writes are dry-run by default; pass allow_write=True to actually apply.
Every textual output is secret-masked before returning.
"""
from __future__ import annotations

import difflib
import fnmatch
import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import config, safety


def _now_ts() -> str:
    return time.strftime("%Y%m%d_%H%M%S")


def _excluded(name: str, excludes: List[str]) -> bool:
    for pat in excludes:
        if fnmatch.fnmatch(name, pat):
            return True
    return False


_TEXT_BYTES = (
    {7, 8, 9, 10, 12, 13, 27}
    | set(range(0x20, 0x7f))
    | set(range(0x80, 0x100))
)


def _is_binary(path: Path, sample_bytes: int = 4096) -> bool:
    try:
        with open(path, "rb") as f:
            chunk = f.read(sample_bytes)
    except Exception:
        return False
    if b"\x00" in chunk:
        return True
    nontext = sum(1 for b in chunk if b not in _TEXT_BYTES)
    return (nontext / max(len(chunk), 1)) > 0.30


# ---- list_files -----------------------------------------------------------

def list_files(root_dir: str,
               include_patterns: Optional[List[str]] = None,
               exclude_patterns: Optional[List[str]] = None,
               max_depth: int = 8) -> Dict[str, Any]:
    """Walk a directory tree, applying include/exclude patterns and max_depth."""
    root = safety.canonical(root_dir)
    ok, why = safety.check_read_allowed(root)
    if not ok:
        return {"ok": False, "error": why}
    if not root.exists():
        return {"ok": False, "error": f"not_found: {root}"}
    if not root.is_dir():
        return {"ok": False, "error": f"not_a_dir: {root}"}

    incl = include_patterns or []
    excl = list(config.DEFAULT_EXCLUDES) + (exclude_patterns or [])

    out: List[Dict[str, Any]] = []
    root_depth = len(root.parts)
    truncated = False

    for dirpath, dirnames, filenames in os.walk(root):
        d = Path(dirpath)
        cur_depth = len(d.parts) - root_depth
        if cur_depth >= max_depth:
            dirnames[:] = []
        # filter dirs in-place so os.walk doesn't descend
        dirnames[:] = [x for x in dirnames if not _excluded(x, excl)]
        for fname in filenames:
            if _excluded(fname, excl):
                continue
            if incl and not any(fnmatch.fnmatch(fname, p) for p in incl):
                continue
            fp = d / fname
            try:
                st = fp.stat()
            except OSError:
                continue
            out.append({
                "path": str(fp),
                "rel_path": str(fp.relative_to(root)),
                "size": st.st_size,
                "mtime": st.st_mtime,
            })
            if len(out) >= config.MAX_FILES_LIST:
                truncated = True
                break
        if truncated:
            break

    return {
        "ok": True,
        "root": str(root),
        "count": len(out),
        "truncated": truncated,
        "files": out,
    }


# ---- read_file ------------------------------------------------------------

def read_file(path: str,
              start_line: int = 1,
              end_line: Optional[int] = None,
              max_lines: int = config.MAX_READ_LINES_DEFAULT) -> Dict[str, Any]:
    """Read text file lines [start_line, end_line] (1-indexed inclusive)."""
    p = safety.canonical(path)
    ok, why = safety.check_read_allowed(p)
    if not ok:
        return {"ok": False, "error": why}
    if not p.exists():
        return {"ok": False, "error": f"not_found: {p}"}
    if not p.is_file():
        return {"ok": False, "error": f"not_a_file: {p}"}
    if _is_binary(p):
        return {"ok": False, "error": f"binary_file_refused: {p}"}

    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        return {"ok": False, "error": f"read_failed: {type(e).__name__}: {e}"}

    total = len(lines)
    s = max(1, int(start_line or 1))
    e = total if end_line is None else min(total, int(end_line))
    if s > total:
        return {
            "ok": True, "path": str(p), "total_lines": total,
            "start_line": s, "end_line": s - 1, "content": "",
            "truncated": False,
        }

    hard_max = min(int(max_lines), config.MAX_READ_LINES_HARD)
    truncated = False
    if e - s + 1 > hard_max:
        e = s + hard_max - 1
        truncated = True

    chunk = "".join(lines[s - 1:e])
    chunk = safety.mask_secrets(chunk)
    if len(chunk) > config.MAX_OUTPUT_BYTES:
        chunk = chunk[:config.MAX_OUTPUT_BYTES] + "\n…[output truncated]"
        truncated = True

    return {
        "ok": True,
        "path": str(p),
        "total_lines": total,
        "start_line": s,
        "end_line": e,
        "truncated": truncated,
        "content": chunk,
    }


# ---- diff + backup helpers -----------------------------------------------

def _make_diff(old: str, new: str, path_label: str) -> str:
    old_lines = old.splitlines(keepends=True)
    new_lines = new.splitlines(keepends=True)
    diff_iter = difflib.unified_diff(
        old_lines, new_lines,
        fromfile=f"a/{path_label}", tofile=f"b/{path_label}",
    )
    return safety.mask_secrets("".join(diff_iter))


def _backup_root_for(p: Path) -> Path:
    """Pick the deepest enclosing ALLOW_PATH and put backups under
    <root>/.adu_backups/. Fallback: file's own parent."""
    p = safety.canonical(p)
    best = None
    for ap in config.ALLOW_PATHS:
        try:
            p.relative_to(ap)
            if best is None or len(ap.parts) > len(best.parts):
                best = ap
        except ValueError:
            continue
    return (best or p.parent) / config.BACKUP_DIR_NAME


def _backup(p: Path) -> Optional[Path]:
    if not p.exists() or not p.is_file():
        return None
    root = _backup_root_for(p)
    try:
        root.mkdir(parents=True, exist_ok=True)
        target = root / f"{_now_ts()}__{p.name}"
        with open(p, "rb") as src, open(target, "wb") as dst:
            dst.write(src.read())
        return target
    except Exception:
        return None


# ---- write_file -----------------------------------------------------------

def write_file(path: str, content: str, allow_write: bool = False) -> Dict[str, Any]:
    """Write content to file. Dry-run by default; pass allow_write=True to apply.
    Returns {ok, applied, diff, backup_path, error?}."""
    p = safety.canonical(path)
    ok, why = safety.check_write_allowed(p)
    if not ok:
        return {"ok": False, "applied": False, "error": why}
    if isinstance(content, bytes):
        return {"ok": False, "applied": False, "error": "binary_content_not_supported"}
    content = str(content or "")

    old = ""
    if p.exists() and p.is_file():
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                old = f.read()
        except Exception as e:
            return {"ok": False, "applied": False, "error": f"read_existing_failed: {e}"}

    diff = _make_diff(old, content, str(p))

    if not allow_write:
        return {
            "ok": True, "applied": False, "dry_run": True,
            "path": str(p), "diff": diff,
            "would_apply": old != content,
        }

    backup = _backup(p)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(content)
    except Exception as e:
        return {
            "ok": False, "applied": False,
            "error": f"write_failed: {e}",
            "backup_path": str(backup) if backup else None,
            "diff": diff,
        }
    return {
        "ok": True, "applied": True, "path": str(p),
        "backup_path": str(backup) if backup else None,
        "diff": diff,
        "bytes_written": len(content),
    }


# ---- patch_file -----------------------------------------------------------

def patch_file(path: str,
               search: Optional[str] = None,
               replace: Optional[str] = None,
               patch: Optional[str] = None,
               allow_write: bool = False) -> Dict[str, Any]:
    """Apply a search/replace patch to a text file.

    V1 supports search/replace only (the search string must match EXACTLY ONCE
    to avoid ambiguous edits). Unified-diff `patch` argument is reserved.
    """
    if patch:
        return {"ok": False, "applied": False,
                "error": "unified_diff_patch_not_supported_in_v1; use search/replace"}
    if search is None or replace is None:
        return {"ok": False, "applied": False, "error": "missing_search_or_replace"}

    p = safety.canonical(path)
    ok, why = safety.check_write_allowed(p)
    if not ok:
        return {"ok": False, "applied": False, "error": why}
    if not p.exists() or not p.is_file():
        return {"ok": False, "applied": False, "error": f"not_a_file: {p}"}

    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            old = f.read()
    except Exception as e:
        return {"ok": False, "applied": False, "error": f"read_failed: {e}"}

    count = old.count(search)
    if count == 0:
        return {"ok": False, "applied": False,
                "error": "search_not_found", "occurrences": 0}
    if count > 1:
        return {"ok": False, "applied": False,
                "error": "search_not_unique", "occurrences": count,
                "hint": "search must match exactly once; widen the context"}

    new = old.replace(search, replace, 1)
    diff = _make_diff(old, new, str(p))

    if not allow_write:
        return {"ok": True, "applied": False, "dry_run": True,
                "path": str(p), "occurrences": count, "diff": diff}

    backup = _backup(p)
    try:
        with open(p, "w", encoding="utf-8") as f:
            f.write(new)
    except Exception as e:
        return {"ok": False, "applied": False, "error": f"write_failed: {e}",
                "backup_path": str(backup) if backup else None, "diff": diff}
    return {"ok": True, "applied": True, "path": str(p),
            "backup_path": str(backup) if backup else None,
            "occurrences": count, "diff": diff}


# ---- search_text ----------------------------------------------------------

def search_text(root_dir: str,
                query: str,
                include_patterns: Optional[List[str]] = None,
                exclude_patterns: Optional[List[str]] = None,
                case_sensitive: bool = False,
                max_results: int = 500,
                context_lines: int = 0,
                explicitly_allow_secrets: bool = False) -> Dict[str, Any]:
    """Grep-like search across files under root_dir."""
    if not query:
        return {"ok": False, "error": "empty_query"}
    root = safety.canonical(root_dir)
    ok, why = safety.check_read_allowed(root)
    if not ok:
        return {"ok": False, "error": why}

    if not explicitly_allow_secrets and any(p.search(query) for p in safety._TOKEN_PATS):
        return {"ok": False,
                "error": "query_looks_like_a_secret; "
                         "pass explicitly_allow_secrets=True only if you really need this"}

    incl = include_patterns or []
    excl = list(config.DEFAULT_EXCLUDES) + (exclude_patterns or [])
    needle = query if case_sensitive else query.lower()

    hits: List[Dict[str, Any]] = []
    files_scanned = 0
    truncated = False

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [x for x in dirnames if not _excluded(x, excl)]
        for fname in filenames:
            if _excluded(fname, excl):
                continue
            if incl and not any(fnmatch.fnmatch(fname, p) for p in incl):
                continue
            fp = Path(dirpath) / fname
            try:
                if _is_binary(fp):
                    continue
                with open(fp, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()
                files_scanned += 1
            except Exception:
                continue
            for i, line in enumerate(lines, 1):
                hay = line if case_sensitive else line.lower()
                if needle in hay:
                    cb = lines[max(0, i - 1 - context_lines):i - 1] if context_lines else []
                    ca = lines[i:i + context_lines] if context_lines else []
                    hits.append({
                        "path": str(fp),
                        "rel_path": str(fp.relative_to(root)),
                        "line": i,
                        "text": safety.mask_secrets(line.rstrip("\n")),
                        "context_before": [safety.mask_secrets(x.rstrip("\n")) for x in cb],
                        "context_after": [safety.mask_secrets(x.rstrip("\n")) for x in ca],
                    })
                    if len(hits) >= max_results:
                        truncated = True
                        break
            if truncated:
                break
        if truncated:
            break

    return {
        "ok": True,
        "root": str(root),
        "query": query,
        "case_sensitive": case_sensitive,
        "files_scanned": files_scanned,
        "match_count": len(hits),
        "truncated": truncated,
        "matches": hits,
    }
