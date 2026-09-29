#!/usr/bin/env python3
# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-98872048f00d14c0774617ba42eaa5f1901017330e2ec6d20841bee3e393ee7d"
# Source-SHA256: "24847fcb0ea4bf13811c4c2f37cc6090b2b9e10dd4b86a51c2128f548a07bd3d"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""Prepare an explicit, reviewed GPTsora source list; never publish or phone home."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import tokenize
import unicodedata


PROVENANCE = "SOURCE_PROVENANCE.json"
INCOMPLETE = ".GPTSORA_INCOMPLETE"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
COOKIE = re.compile(br"^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def checked_absolute(value):
    path = Path(value).expanduser()
    if ".." in path.parts:
        raise ValueError("'..' is forbidden in input/output paths")
    return Path(os.path.abspath(path))


def open_directory(path, forbidden_identity=None):
    """Walk an absolute path without following symlinks, including ancestors."""
    fd = os.open(path.anchor, DIRECTORY_FLAGS)
    try:
        if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) == forbidden_identity:
            raise ValueError("output parent is inside source-root")
        for component in path.parts[1:]:
            next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            if (os.fstat(fd).st_dev, os.fstat(fd).st_ino) == forbidden_identity:
                raise ValueError("output parent is inside source-root")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_regular(root_fd, parts):
    fd = os.dup(root_fd)
    try:
        for component in parts[:-1]:
            next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                          dir_fd=fd)
        with os.fdopen(file_fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("listed inputs must be regular files")
            return stream.read(), stat.S_IMODE(info.st_mode)
    finally:
        os.close(fd)


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def path_key(value):
    # Conservatively reject collisions on case-insensitive/normalizing filesystems.
    return unicodedata.normalize("NFC", value).casefold()


def validate_manifest(data):
    document = json.loads(data.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
    if not isinstance(document, dict) or set(document) != {"files"}:
        raise ValueError("manifest must be an object containing only 'files'")
    entries = document["files"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("manifest 'files' must be a nonempty list")
    paths = {path_key(PROVENANCE), path_key(INCOMPLETE)}
    directories = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "expected_sha256", "first_party"}:
            raise ValueError("each entry needs only path, expected_sha256, first_party")
        name = entry["path"]
        if (not isinstance(name, str) or not name or "\\" in name or ":" in name
                or any(ord(c) < 32 or ord(c) == 127 for c in name)):
            raise ValueError("invalid relative path")
        name.encode("utf-8")  # Reject lone surrogates rather than inventing a filename.
        parts = name.split("/")
        if any(part in {"", ".", ".."} for part in parts):
            raise ValueError("paths must be plain relative POSIX paths without traversal")
        key = path_key(name)
        parents = {path_key("/".join(parts[:i])) for i in range(1, len(parts))}
        if key in paths or key in directories or parents & paths:
            raise ValueError("duplicate, reserved, or conflicting manifest paths")
        paths.add(key)
        directories.update(parents)
        digest = entry["expected_sha256"]
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise ValueError("expected_sha256 must have 64 hexadecimal characters")
        if type(entry["first_party"]) is not bool:
            raise ValueError("first_party must be a JSON boolean")
    return entries


def comment_value(value):
    # Quote metadata and neutralize C/Swift and HTML comment delimiters.
    return (json.dumps(value, ensure_ascii=True)
            .replace("/*", "\\u002f*").replace("*/", "*\\u002f")
            .replace("--", "\\u002d\\u002d"))


def watermark(data, name, fields):
    suffix = Path(name).suffix.lower()
    basename = Path(name).name
    if suffix in {".py", ".pyi", ".sh", ".bash", ".zsh", ".command", ".rb"} or basename in {"Podfile", "Gemfile", "Rakefile"}:
        style = "hash"
    elif suffix in {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts", ".swift"}:
        style = "slash"
    elif suffix == ".css":
        style = "css"
    elif suffix in {".html", ".htm"}:
        style = "html"
    else:
        return data, "manifest-only-format"
    if b"\x00" in data:
        return data, "manifest-only-binary"
    try:
        encoding = (tokenize.detect_encoding(io.BytesIO(data).readline)[0]
                    if suffix in {".py", ".pyi"} else "utf-8-sig")
        data.decode(encoding)
        encoding = "utf-8" if encoding == "utf-8-sig" else encoding
        sample = "# // /* */ <!-- --> GPTsora 0123456789\n"
        if sample.encode(encoding) != sample.encode("ascii"):
            return data, "manifest-only-encoding"
    except (UnicodeError, LookupError, SyntaxError):
        return data, "manifest-only-encoding"
    bom = b"\xef\xbb\xbf" if data.startswith(b"\xef\xbb\xbf") else b""
    body = data[len(bom):]
    lines = body.splitlines(keepends=True)
    keep = 0
    if lines and lines[0].startswith(b"#!"):
        keep = 1
    if style == "hash":
        # Keep Python cookies and Ruby magic comments in their original positions.
        while keep < len(lines) and (lines[keep].lstrip().startswith(b"#") or not lines[keep].strip()):
            keep += 1
        if suffix in {".py", ".pyi"}:
            for index, line in enumerate(lines[:2]):
                if COOKIE.match(line):
                    keep = max(keep, index + 1)
    elif style == "slash":
        # Swift's tools-version line and leading compiler/linter directives stay first.
        while keep < len(lines) and (lines[keep].lstrip().startswith(b"//") or not lines[keep].strip()):
            keep += 1
    offset = sum(len(line) for line in lines[:keep])
    if style == "css":
        charset = re.match(br'@charset "[^"\r\n]*";', body, flags=re.I)
        offset = charset.end() if charset else 0
    elif style == "html":
        declaration = re.match(br"(?:<\?xml\b[^?]*\?>\s*)?(?:<!DOCTYPE\b[^>]*>)?", body, flags=re.I)
        offset = declaration.end()
    match = re.search(br"\r\n|\n|\r", body)
    newline = match.group() if match else b"\n"
    text = ["GPTsora source provenance (metadata only; existing notices retained)"]
    text.extend(f"{key}: {comment_value(value)}" for key, value in fields.items())
    if style in {"hash", "slash"}:
        prefix = "# " if style == "hash" else "// "
        header = [prefix + line for line in text]
    elif style == "css":
        header = ["/*", *text, "*/"]
    else:
        header = ["<!--", *text, "-->"]
    before, after = body[:offset], body[offset:]
    separator = newline if before and not before.endswith((b"\n", b"\r")) else b""
    inserted = newline.join(line.encode("ascii") for line in header) + newline
    return bom + before + separator + inserted + after, "comment-" + style


def write_new(root_fd, parts, data, mode=0o644):
    fd = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            next_fd = os.open(part, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        file_fd = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                          0o600, dir_fd=fd)
        with os.fdopen(file_fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
    finally:
        os.close(fd)


def prepare(args):
    source = checked_absolute(args.source_root)
    output = checked_absolute(args.output)
    manifest = checked_absolute(args.manifest)
    if source == output or source in output.parents:
        raise ValueError("output must be outside source-root")
    for value in (args.owner, args.license_ref, args.release_id):
        if not value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("owner, license-ref and release-id must be nonempty single lines")
        if any(delimiter in value for delimiter in ("/*", "*/", "<!--", "-->")):
            raise ValueError("comment delimiters are forbidden in metadata")
    manifest_fd = open_directory(manifest.parent)
    try:
        manifest_bytes, _ = read_regular(manifest_fd, [manifest.name])
    finally:
        os.close(manifest_fd)
    entries = validate_manifest(manifest_bytes)
    source_fd = open_directory(source)
    source_info = os.fstat(source_fd)
    source_identity = (source_info.st_dev, source_info.st_ino)
    prepared, records = [], []
    try:
        for entry in entries:
            name = entry["path"]
            data, source_mode = read_regular(source_fd, name.split("/"))
            digest = sha256(data)
            if digest != entry["expected_sha256"].lower():
                raise ValueError("source SHA-256 mismatch: " + name)
            source_id = "gptsora-" + sha256(b"GPTsora\0" + name.encode("utf-8") + b"\0" + bytes.fromhex(digest))
            fields = {"Source-ID": source_id, "Source-SHA256": digest,
                      "Owner": args.owner, "License-Reference": args.license_ref,
                      "Release-ID": args.release_id}
            result, mode = (watermark(data, name, fields) if entry["first_party"]
                            else (data, "unchanged-third-party"))
            output_mode = 0o644 | (source_mode & 0o111)
            prepared.append((name.split("/"), result, output_mode))
            records.append({"path": name, "source_id": source_id,
                            "first_party": entry["first_party"], "source_sha256": digest,
                            "output_sha256": sha256(result), "watermark_mode": mode,
                            "source_mode": oct(source_mode), "output_mode": oct(output_mode)})
    finally:
        os.close(source_fd)
    report = {"schema_version": 1, "project": "GPTsora", "release_id": args.release_id,
              "first_party_owner": args.owner, "first_party_license_reference": args.license_ref,
              "input_manifest_sha256": sha256(manifest_bytes),
              "policy": "Metadata only; third-party notices/terms remain unchanged. No telemetry.",
              "files": records}
    report_bytes = (json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    # Preflight is complete. A failed write leaves a visibly incomplete new directory.
    parent_fd = open_directory(output.parent, forbidden_identity=source_identity)
    try:
        os.mkdir(output.name, mode=0o700, dir_fd=parent_fd)
        output_fd = os.open(output.name, DIRECTORY_FLAGS, dir_fd=parent_fd)
        try:
            write_new(output_fd, [INCOMPLETE], b"INCOMPLETE: do not publish this directory.\n")
            for parts, data, mode in prepared:
                write_new(output_fd, parts, data, mode)
            write_new(output_fd, [PROVENANCE], report_bytes)
            os.unlink(INCOMPLETE, dir_fd=output_fd)
        finally:
            os.close(output_fd)
    finally:
        os.close(parent_fd)
    print(f"Prepared {len(records)} explicit files. Review {output / PROVENANCE}; nothing was published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True, help="new directory; existing parent, outside source-root")
    parser.add_argument("--owner", required=True, help="confirmed owner of first-party files")
    parser.add_argument("--license-ref", required=True, help="explicit approved license reference; no default")
    parser.add_argument("--release-id", required=True)
    args = parser.parse_args()
    try:
        prepare(args)
    except (OSError, ValueError, UnicodeError) as error:
        parser.exit(1, f"Preparation refused: {error}\n")


if __name__ == "__main__":
    main()
