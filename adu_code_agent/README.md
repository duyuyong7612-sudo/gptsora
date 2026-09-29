# adu_code_agent — local safe code-engineering agent toolkit

A self-contained Python package giving ChatAGI 阿杜 the kind of project
read/write/run/fix capability that Claude Code or Continue use, but on the
local box, with hard safety rails.

Pure stdlib runtime (no third-party deps). FastAPI is optional and only
needed if you want the HTTP API.

## Where it lives

```
~/Desktop/backend/adu_code_agent/
├── __init__.py
├── config.py        constants, ALLOW_PATHS, blocklist defaults
├── safety.py        path safety, secret masking, dangerous-command detection
├── fs_tools.py      list_files / read_file / write_file / patch_file / search_text
├── shell_tools.py   run_command / check_port / kill_process
├── loop.py          AgentLoop (scripted multi-step runner)
├── routes.py        FastAPI APIRouter (optional, for inclusion in main backend)
├── server.py        standalone FastAPI app on its own port
├── cli.py           CLI entry point (`python -m adu_code_agent.cli`)
├── tests.py         built-in self-test (sandboxed)
└── README.md
```

## Quick start

```bash
cd ~/Desktop/backend
python -m adu_code_agent.cli self-test
python -m adu_code_agent.cli info

python -m adu_code_agent.cli list   --root ~/Desktop/little-beijing-edge-box
python -m adu_code_agent.cli search --root ~/Desktop/little-beijing-edge-box --query "gpt-realtime-2"
python -m adu_code_agent.cli read   --path ~/Desktop/little-beijing-edge-box/frontend/js/realtime-web-call.js --start 1 --end 120

python -m adu_code_agent.cli run        --cmd "echo hello"
python -m adu_code_agent.cli check-port --port 3000

# default dry-run prints a diff but does not write:
python -m adu_code_agent.cli patch --path /tmp/foo.py --search "old" --replace "new"
# add --apply to actually write:
python -m adu_code_agent.cli patch --path /tmp/foo.py --search "old" --replace "new" --apply
```

## Safety rules (V1)

| What | Rule |
|---|---|
| **Writes** | Refused unless the canonical path is inside `ADU_AGENT_ALLOW_PATHS`. |
| **Default** | `write_file` / `patch_file` / `kill_process` are dry-run; pass `allow_write=true` / `allow_kill=true` or `--apply` to actually act. |
| **Backups** | Every accepted write copies the prior file to `<project_root>/.adu_backups/<ts>__<name>`. |
| **Secret masking** | `sk-…`, `sk-ant-…`, `ek_…`, `AKIA…`, `gh[pousr]_…`, and `*_KEY=value` style assignments are masked to `prefix***last4` in every output (read, diff, command stdout/stderr, log). |
| **Forbidden write targets** | `/`, `~`, `~/Desktop`, `~/Downloads`, `~/Documents`, `~/Library`, `/Users`, `/Applications`, `/System`, `/private`, `/tmp` (directly), and any path containing `.git` / `.venv` / `node_modules` / `__pycache__`. |
| **Dangerous commands** | Hard-blocked: `rm -rf /` or `~`, `sudo rm`, `mkfs`, `dd if=`, `chmod -R 777 /`, `chown -R`, `curl \| sh`, `wget \| sh`, `git push --force`, `npm publish`, `echo $OPENAI_API_KEY`. No "force allow". |
| **kill_process** | Same-user check enforced. Other users' processes are refused even with `--apply`. |
| **delete tool** | NOT implemented in V1 by design. |

## Default allow paths

```
~/Desktop/backend
~/Desktop/little-beijing-edge-box
~/Desktop/GPTsora
```

Override via environment:

```bash
export ADU_AGENT_ALLOW_PATHS="$HOME/Desktop/projA:$HOME/Desktop/projB"
```

## HTTP usage (optional)

### Option A — standalone server (does not touch live 8000 backend)

```bash
cd ~/Desktop/backend
python -m adu_code_agent.server --port 4380
curl http://127.0.0.1:4380/health
curl http://127.0.0.1:4380/api/code-agent/info
```

### Option B — wire into the existing ChatAGI FastAPI backend

In `~/Desktop/backend/server_session.py` (or wherever the FastAPI app lives):

```python
from adu_code_agent.routes import router as code_agent_router
app.include_router(code_agent_router, prefix="/api")
```

Endpoints (all POST except `/info`):

```
GET  /api/code-agent/info
POST /api/code-agent/list_files
POST /api/code-agent/read_file
POST /api/code-agent/search_text
POST /api/code-agent/write_file        # body.allow_write=true to apply
POST /api/code-agent/patch_file        # body.allow_write=true to apply
POST /api/code-agent/run_command
POST /api/code-agent/check_port
POST /api/code-agent/kill_process      # body.allow_kill=true to apply
POST /api/code-agent/loop              # scripted multi-step run
```

## AgentLoop — scripted run

```python
from adu_code_agent.loop import AgentLoop

L = AgentLoop("find and fix gpt-realtime-2 refs", allow_write=False)
out = L.run_script([
    {"type": "search", "root": "~/Desktop/little-beijing-edge-box",
     "query": "gpt-realtime-2"},
    {"type": "read", "path": "~/Desktop/little-beijing-edge-box/.env",
     "start": 1, "end": 50},
])
print(out["completed"], out["step_count"])
for a in out["attempts"]:
    print(a)
```

For the LLM-driven scenario, the LLM emits a list of action dicts and posts
them to `POST /api/code-agent/loop`; the backend executes the steps in order
and returns the structured summary (attempts, completed, details).

## Continuing the Little Beijing fix with this agent

Example task: "search `gpt-realtime-2`, produce a patch that makes the
backend `.env` the single source of truth, and run a smoke check."

Step 1 — find all references:
```bash
python -m adu_code_agent.cli search \
    --root ~/Desktop/little-beijing-edge-box \
    --query "gpt-realtime-2"
```

Step 2 — read each hit:
```bash
python -m adu_code_agent.cli read \
    --path ~/Desktop/little-beijing-edge-box/frontend/js/realtime-web-call.js \
    --start 1 --end 200
```

Step 3 — dry-run patch (note: the search string MUST match exactly once):
```bash
python -m adu_code_agent.cli patch \
    --path ~/Desktop/little-beijing-edge-box/frontend/js/realtime-web-call.js \
    --search 'this.model = options.model || "gpt-realtime-2";' \
    --replace 'this.model = options.model || "";'
# inspect the printed diff; when satisfied re-run with --apply
```

Step 4 — smoke check the backend boots:
```bash
python -m adu_code_agent.cli run \
    --cwd ~/Desktop/little-beijing-edge-box \
    --cmd "python3 -m py_compile backend/routes/realtime_routes.py && echo OK"
```

Or write a JSON action script and feed it to the loop:

```bash
cat > /tmp/lb_fix.json <<'JSON'
[
  {"type": "search", "root": "~/Desktop/little-beijing-edge-box", "query": "gpt-realtime-2"},
  {"type": "read",   "path": "~/Desktop/little-beijing-edge-box/.env", "start": 1, "end": 20},
  {"type": "run",    "cmd": "python3 -m py_compile ~/Desktop/little-beijing-edge-box/backend/routes/realtime_routes.py && echo OK"}
]
JSON
python -m adu_code_agent.cli loop \
    --goal "scan Little Beijing for gpt-realtime-2 and verify backend compiles" \
    --script /tmp/lb_fix.json
```

## What V1 deliberately does NOT do

- No `delete` tool — blast radius too large.
- No unified-diff patch parser — V1 only does single-occurrence search/replace.
- No LLM planner — `AgentLoop` is a structured runner; an external LLM
  (or you) drives it via action lists.
- No remote network calls, no cloud uploads.
- No automatic writes — every write requires explicit `allow_write=true` / `--apply`.
