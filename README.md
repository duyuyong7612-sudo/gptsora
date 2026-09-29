# GPTsora

GPTsora source release: Python backend, React web frontend, and Swift iOS app.
The code also uses the historical names GPT Solara, ChatAGI, and Adu.

**Any commercial use requires prior written approval.** This project uses
the custom [GPTsora Noncommercial Source License 1.0](LICENSE), identifier
`LicenseRef-GPTsora-Noncommercial-1.0`. It is noncommercial source-available
software, not standard AGPL or an OSI-approved open-source project.
See [commercial authorization](COMMERCIAL.md) and
[third-party notices](THIRD_PARTY_NOTICES.md).

非商业用途可按许可使用、学习、修改及分发；任何商用都必须事先获得书面
批准。分发或通过网络向用户提供本项目时，须提供对应版本源码并保留版权、
许可和来源记录；修改部分遵循同一许可。第三方代码仍按其原许可执行。

## Source map

| Location | Contents |
| --- | --- |
| `server_session.py`, root Python modules | FastAPI backend, chat, voice, identity, memory and orchestration |
| `adu_orchestrator/`, `local_computer_agent/`, `routers/` | Code/desktop adapters, local agent and feature routes |
| `realtime_voice/`, `public_*voice.py` | Voice transport and provider adapters |
| `chatagi_adu_web_frontend/` | React / TypeScript / Vite web frontend and npm lock |
| `GPTsora/` | iOS source, Xcode project, tests, resources and dependency locks |
| `_media/realtime_native_poc.html` | Required static native-realtime client |
| `third_party/` | Notices and license texts for bundled upstream material |
| `SOURCE_PROVENANCE.json` | Exact source/output hashes and first-party license scope |

This is a development source snapshot. It preserves product source and
authorized demo resources, including optional and legacy helper modules.
It is not a production service or a signed application distribution. Real
credentials, user databases, chats, recordings, private device settings,
dependency caches, build output, unrelated experiments, and obsolete scratch
copies are not product source and are excluded.

## Backend

Use **Python 3.11**. Some audio helpers still use `audioop`; Python 3.13 and
later are not the supported baseline for this snapshot.

```sh
python3.11 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-core.lock
cp .env.example .env
# Fill in only the credentials for the features you want to use.
uvicorn server_session:app --host 127.0.0.1 --port 8000
```

`requirements.txt` lists direct core requirements. `requirements-core.lock`
records the versions restored for this release on CPython 3.11 / macOS arm64;
it is not a claim of testing every operating system or provider. All models,
accounts, billing products, API keys and service subscriptions are supplied
by the operator. This repository does not grant access to the original
operator's services.

Optional features need additional packages and setup:

| Feature | Additional dependencies / setup |
| --- | --- |
| PostgreSQL billing | `psycopg2-binary`, operator-managed database |
| PDF / Word extraction | `pdfplumber`, `pypdf`, `python-docx` |
| Audio numerical helpers / LiveKit worker | `numpy`, `livekit`; configured LiveKit service |
| Desktop capture and control | `mss`, `pyautogui`; local OS permissions and explicit operator action |
| macOS accessibility adapters | `pyobjc-framework-Cocoa`, `pyobjc-framework-Quartz`, `pyobjc-framework-ApplicationServices` |
| Optional browser / provider adapters | `playwright` and its browser installation, `beautifulsoup4`, `anthropic`, provider-specific configuration |

These optional paths are included as source; their live service, desktop,
microphone, and payment behavior was not accepted as production-ready by
publishing this repository. See [known limits](KNOWN_LIMITS.md).

## Web frontend

Use Node.js and npm with the committed lock file:

```sh
cd chatagi_adu_web_frontend
npm ci
npx tsc --noEmit
npm run build
```

The build writes `_media/chatagi_adu_app/index.html` relative to the repository
root. The backend serves it at `/chatagi-adu`. For an isolated build, run
`npm run build -- --outDir /absolute/path/to/a/new-output-directory`.
The frontend uses the current hostname on port 8000; see
`src/api/backendBase.ts` before configuring a different deployment topology.
`npm run dev` starts the Vite development server.

## iOS

Read [the iOS build instructions](GPTsora/README_IOS_BUILD.md). Restore
CocoaPods and Swift Package Manager dependencies, then open
`GPTsora/GPTsora.xcworkspace`. The application target is `GPT Solara`.
Configure your own signing team, bundle identifiers, backend and service
accounts. The existing backend address is selected by
`GPTsora/GPTsora/AppConfig.swift` (`fixedBaseURLString`); saved debug overrides
do not change that fixed selection in this snapshot.

GoogleWebRTC 1.1.32000 is an older binary dependency. Follow the documented
simulator architecture and SDK limitations; do not interpret a source release
as App Store, payment, device, or signed-release approval.

## Copyright and source watermarks

First-party comment-capable code carries project, owner, release and source
identifiers. Formats that cannot safely carry comments use the provenance
manifest. Third-party source is retained with its original bytes and license.
The manifest records both pre-watermark and distributed hashes, so a known
release can be checked. Preserve the attribution and mark your modifications.

These are attribution and integrity records. They do not secretly report
usage, identify every person who copies the code, or prevent someone from
removing a comment. For integrity verification, compare with a trusted Git
commit and the manifest from that commit.

Verify a clean release checkout with:

```sh
python3 tools/verify_provenance.py .
```

The release packaging tool adds code comments, then
`tools/finalize_provenance.py` refreshes the CocoaPods checksum and records
that transformation without changing the original source hashes.

See [contribution terms](CONTRIBUTING.md) before submitting changes.
