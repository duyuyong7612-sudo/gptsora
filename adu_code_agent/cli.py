# GPTsora source provenance (metadata only; existing notices retained)
# Source-ID: "gptsora-d5acf4a987b44c8e9eca442fab357a02b244084024cb7dbf51e6bf156c0c4dcf"
# Source-SHA256: "6ed353638ca5ab0feba8353d82b444a89b87e3137f2c12268c7ca2ab878f3056"
# Owner: "YUYONG DU"
# License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
# Release-ID: "gptsora-source-2026-09-25"
"""adu_code_agent CLI.

    cd ~/Desktop/backend

    python -m adu_code_agent.cli info
    python -m adu_code_agent.cli self-test

    python -m adu_code_agent.cli list   --root ~/Desktop/little-beijing-edge-box
    python -m adu_code_agent.cli search --root ~/Desktop/little-beijing-edge-box --query "gpt-realtime-2"
    python -m adu_code_agent.cli read   --path ~/Desktop/little-beijing-edge-box/frontend/js/realtime-web-call.js --start 1 --end 120

    python -m adu_code_agent.cli run    --cmd "echo hello"
    python -m adu_code_agent.cli check-port --port 3000
    python -m adu_code_agent.cli patch  --path /tmp/foo.py --search "old" --replace "new"          # dry-run
    python -m adu_code_agent.cli patch  --path /tmp/foo.py --search "old" --replace "new" --apply  # actually writes

    python -m adu_code_agent.cli loop   --goal "smoke" --script /tmp/actions.json
"""
from __future__ import annotations

import argparse
import json
import sys

from . import fs_tools, shell_tools, loop, config


def _print(obj) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False, default=str))


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="adu-code-agent")
    sub = p.add_subparsers(dest="subcommand", required=True)

    pi = sub.add_parser("info", help="show config (allow_paths etc.)")

    pl = sub.add_parser("list", help="list files under a root")
    pl.add_argument("--root", required=True)
    pl.add_argument("--include", action="append", default=None)
    pl.add_argument("--exclude", action="append", default=None)
    pl.add_argument("--max-depth", type=int, default=8)

    pr = sub.add_parser("read", help="read a text file by line range")
    pr.add_argument("--path", required=True)
    pr.add_argument("--start", type=int, default=1)
    pr.add_argument("--end", type=int, default=None)
    pr.add_argument("--max-lines", type=int, default=400)

    ps = sub.add_parser("search", help="grep-like search")
    ps.add_argument("--root", required=True)
    ps.add_argument("--query", required=True)
    ps.add_argument("--include", action="append", default=None)
    ps.add_argument("--exclude", action="append", default=None)
    ps.add_argument("--case-sensitive", action="store_true")
    ps.add_argument("--context", type=int, default=0)
    ps.add_argument("--max-results", type=int, default=500)
    ps.add_argument("--allow-secrets", action="store_true",
                    help="permit a query that looks like a literal secret")

    pw = sub.add_parser("write", help="write a file (default dry-run; --apply to write)")
    pw.add_argument("--path", required=True)
    pw.add_argument("--content-file", default=None,
                    help="read new content from a file (use '-' for stdin)")
    pw.add_argument("--content", default=None,
                    help="literal content (mutually exclusive with --content-file)")
    pw.add_argument("--apply", action="store_true",
                    help="actually write (default: dry-run)")

    pp = sub.add_parser("patch", help="search/replace inside a file")
    pp.add_argument("--path", required=True)
    pp.add_argument("--search", required=True)
    pp.add_argument("--replace", required=True)
    pp.add_argument("--apply", action="store_true")

    pc = sub.add_parser("run", help="run a shell command (with safety blocklist)")
    pc.add_argument("--cmd", required=True)
    pc.add_argument("--cwd", default=None)
    pc.add_argument("--timeout", type=float, default=60.0)

    pp2 = sub.add_parser("check-port", help="show what's listening on a port")
    pp2.add_argument("--port", type=int, required=True)

    pk = sub.add_parser("kill", help="signal a process (default dry-run)")
    pk.add_argument("--pid", type=int, default=None)
    pk.add_argument("--port", type=int, default=None)
    pk.add_argument("--signal", default="TERM")
    pk.add_argument("--apply", action="store_true")

    pl2 = sub.add_parser("loop", help="run a JSON list of actions")
    pl2.add_argument("--goal", required=True)
    pl2.add_argument("--script", required=True,
                     help="path to JSON file containing a list of action objects")
    pl2.add_argument("--apply", action="store_true",
                     help="propagate allow_write=true to write/patch actions")
    pl2.add_argument("--max-iter", type=int, default=5)

    sub.add_parser("self-test", help="run built-in self-tests in a /tmp sandbox")

    args = p.parse_args(argv)

    if args.subcommand == "info":
        _print({
            "allow_paths": [str(x) for x in config.ALLOW_PATHS],
            "read_also_ok": [str(x) for x in config.READ_ALSO_OK],
            "default_excludes": config.DEFAULT_EXCLUDES,
            "backup_dir_name": config.BACKUP_DIR_NAME,
        })
        return 0

    if args.subcommand == "list":
        _print(fs_tools.list_files(args.root, args.include, args.exclude, args.max_depth))
        return 0

    if args.subcommand == "read":
        _print(fs_tools.read_file(args.path, args.start, args.end, args.max_lines))
        return 0

    if args.subcommand == "search":
        _print(fs_tools.search_text(
            args.root, args.query, args.include, args.exclude,
            args.case_sensitive, args.max_results, args.context,
            args.allow_secrets,
        ))
        return 0

    if args.subcommand == "write":
        if args.content is None:
            if args.content_file == "-":
                content = sys.stdin.read()
            elif args.content_file:
                with open(args.content_file, "r", encoding="utf-8") as f:
                    content = f.read()
            else:
                p.error("write: provide --content or --content-file")
        else:
            content = args.content
        _print(fs_tools.write_file(args.path, content, allow_write=args.apply))
        return 0

    if args.subcommand == "patch":
        _print(fs_tools.patch_file(
            args.path, search=args.search, replace=args.replace,
            allow_write=args.apply,
        ))
        return 0

    if args.subcommand == "run":
        # args.cmd here is the `--cmd` flag value (the shell command), NOT the subcommand name.
        _print(shell_tools.run_command(args.cmd, cwd=args.cwd, timeout_seconds=args.timeout))
        return 0

    if args.subcommand == "check-port":
        _print(shell_tools.check_port(args.port))
        return 0

    if args.subcommand == "kill":
        _print(shell_tools.kill_process(
            pid=args.pid, port=args.port,
            allow_kill=args.apply, signal_name=args.signal,
        ))
        return 0

    if args.subcommand == "loop":
        with open(args.script, "r", encoding="utf-8") as f:
            actions = json.load(f)
        if not isinstance(actions, list):
            print("script must be a JSON list of action objects", file=sys.stderr)
            return 2
        L = loop.AgentLoop(
            args.goal,
            allow_write=args.apply,
            max_iterations=args.max_iter,
        )
        _print(L.run_script(actions))
        return 0

    if args.subcommand == "self-test":
        from .tests import run_self_test
        ok = run_self_test()
        return 0 if ok else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
