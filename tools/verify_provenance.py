#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-92b48469914c9ffcc04023260de85e02b77819c4669fecd713f486313c09e3fe"
# Source-SHA256: "3bc9dda0e10beba24c980d255be94713830a1d952dbaaa4d388789c93bb80ce1"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Verify distributed file hashes against a trusted SOURCE_PROVENANCE.json."""
import hashlib
import json
import stat
import sys
from pathlib import Path, PurePosixPath


def verify(root, *, allow_incomplete=False):
    root = root.resolve(strict=True)
    marker = root / ".GPTSORA_INCOMPLETE"
    if not allow_incomplete and (marker.exists() or marker.is_symlink()):
        raise ValueError("incomplete release marker exists; do not publish")
    manifest = root / "SOURCE_PROVENANCE.json"
    if manifest.is_symlink():
        raise ValueError("manifest must be a regular file, not a symlink")
    report = json.loads(manifest.read_text(encoding="utf-8"))
    seen = set()
    for item in report["files"]:
        name = item["path"]
        parts = PurePosixPath(name).parts
        if not parts or name.startswith("/") or ".." in parts or "\\" in name:
            raise ValueError("unsafe path in manifest")
        if name in seen or name == "SOURCE_PROVENANCE.json":
            raise ValueError("duplicate or reserved manifest entry")
        seen.add(name)
        path = root
        for part in parts:
            path = path / part
            if path.is_symlink():
                raise ValueError("symlink is not allowed: " + name)
        mode = path.stat().st_mode
        if not stat.S_ISREG(mode):
            raise ValueError("not a regular file: " + name)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != item["output_sha256"]:
            raise ValueError("SHA-256 mismatch: " + name)
        if stat.S_IMODE(mode) & 0o111 != int(item["output_mode"], 8) & 0o111:
            raise ValueError("executable mode mismatch: " + name)
    return report


if __name__ == "__main__":
    try:
        data = verify(Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd())
        print("Verified", len(data["files"]), "listed files for", data["release_id"])
        print("Use a trusted commit: this checks listed files, not manifest authenticity or extra files.")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Verification failed:", error, file=sys.stderr)
        sys.exit(1)
