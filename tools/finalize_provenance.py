#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d998d0d0bb0d626281b8a07da9e70009b86770f8285f355b1387d903748411f5"
# Source-SHA256: "d8e506b64763c8ad2bc43c25ad8c10eafd7aa65ec22ff5b7dad00ddcab18c37c"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Update CocoaPods' Podfile checksum after adding provenance comments."""
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

from verify_provenance import verify


def atomic_write(path, data):
    mode = stat.S_IMODE(path.stat().st_mode)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".gptsora-", delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def finalize(root):
    root = root.resolve(strict=True)
    report = verify(root)
    pod_name, lock_name = "GPTsora/Podfile", "GPTsora/Podfile.lock"
    records = {entry["path"]: entry for entry in report["files"]}
    pod, lock = records[pod_name], records[lock_name]
    for path in (root / lock_name, root / "SOURCE_PROVENANCE.json"):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("finalization requires unlinked regular output files")
    pod_bytes = (root / pod_name).read_bytes()
    lock_bytes = (root / lock_name).read_bytes()
    checksum = hashlib.sha1(pod_bytes).hexdigest()  # CocoaPods format, not a security hash.
    matches = re.findall(rb"(?m)^PODFILE CHECKSUM: ([a-f0-9]{40})$", lock_bytes)
    if len(matches) != 1:
        raise ValueError("expected exactly one CocoaPods Podfile checksum")
    old = matches[0].decode("ascii")
    if old == checksum:
        return
    result = re.sub(rb"(?m)^PODFILE CHECKSUM: [a-f0-9]{40}$",
                    b"PODFILE CHECKSUM: " + checksum.encode("ascii"), lock_bytes)
    lock.setdefault("transforms", []).append({
        "kind": "podfile-checksum", "algorithm": "sha1",
        "podfile_path": pod_name, "podfile_output_sha256": pod["output_sha256"],
        "checksum_before": old, "checksum_after": checksum,
        "input_output_sha256": lock["output_sha256"],
    })
    lock["output_sha256"] = hashlib.sha256(result).hexdigest()
    report["postprocess"] = {"tool": "tools/finalize_provenance.py", "version": 1}
    marker = root / ".GPTSORA_INCOMPLETE"
    with marker.open("x", encoding="utf-8") as handle:
        handle.write("Provenance finalization in progress. Do not publish.\n")
    atomic_write(root / lock_name, result)
    atomic_write(root / "SOURCE_PROVENANCE.json",
                 (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    verify(root, allow_incomplete=True)
    marker.unlink()


if __name__ == "__main__":
    try:
        finalize(Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd())
        print("CocoaPods checksum and provenance are consistent.")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Finalization failed:", error, file=sys.stderr)
        sys.exit(1)
