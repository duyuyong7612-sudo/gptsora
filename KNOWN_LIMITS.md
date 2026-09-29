# Known limits of this source snapshot

> **Security notice (2026-09-29).** The source release published on
> 2026-09-25 exposed unauthenticated command-execution routes: `/agent/*`
> (including `/agent/exec`, `/agent/write` and `/agent/security/allow_root`),
> `/api/computer`, `/controller/run`, the screen-control channel, and the
> Codex / Claude executor routes could be called by anyone who could reach
> the server. **This release fixes that.** `agent_guard.py` now rejects every
> request that is not on the public allow-list unless it carries a matching
> `X-Agent-Token`. If you deployed the 2026-09-25 version, stop it and upgrade.
>
> Before any deployment you **must** set:
> - `AGENT_API_TOKEN` — required by protected routes (`X-Agent-Token` header);
> - `CHATAGI_JWT_SECRET` (or `JWT_SECRET`) — token signing and verification
>   now fail instead of falling back to a default secret;
> - `LOCAL_AGENT_TOKEN` if you run `local_agent_4317.py` — it refuses all
>   requests without one.
>
> Still open: `/memory/*` routes have **no per-user authorization** yet. Do
> not expose them to untrusted users.

This release publishes source and build inputs. It does not assert acceptance
of live model calls, microphone/desktop control, subscriptions, App Store
distribution, or production security. Build and restoration results apply to
the recorded environment and exact release, not to all optional integrations.

- Credentials are deliberately absent. Configure your own accounts and safe
  environment before enabling a provider. Never publish `.env` or runtime data.
- Authentication has no default JWT secret: without `CHATAGI_JWT_SECRET`
  (or `JWT_SECRET`) the backend refuses to sign or verify tokens. Importing the main
  backend also initializes local storage and probes the local agent, so use
  an isolated checkout and environment for inspection or testing.
- `openclaw_bridge_router.py` requires an explicit `OPENCLAW_BRIDGE_TOKEN`;
  an unset token rejects requests. `adu_screen_streamer.py` requires
  `ADU_USER_KEY` before starting screen capture. Its legacy MJPEG listener
  has no independent authentication; it now binds `127.0.0.1` by default
  (`ADU_SCREEN_STREAM_HOST` overrides). Do not expose it to the Internet.
- Every bundled server now listens on `127.0.0.1` by default (`HOST`,
  `APP_HOST`, `LOCAL_AGENT_HOST`, `ADU_CURSOR_HOST`, `ADU_CODE_AGENT_HOST`
  override it). Binding a public interface is an explicit operator choice.
- The restored Polar webhook integration currently marks an event as seen
  before its entitlement writer completes. A writer failure can therefore
  cause a subsequent retry to be treated as a duplicate. Resolve and test
  that payment-reliability issue before enabling production billing.
- The iOS app has historical, fixed backend configuration and existing
  signing/product identifiers. Replace those for your own installation.
  GoogleWebRTC 1.1.32000 requires the documented older simulator architecture.
- Python optional modules have platform-specific requirements. Core dependency
  restoration alone does not validate every legacy helper or provider.
- Existing user data, locally installed CLIs, external model weights and
  service subscriptions are not bundled. Product templates and source are
  included; operators supply external services under their own agreements.

Commercial deployment additionally requires the prior written permission in
[LICENSE](LICENSE), regardless of whether these technical issues are fixed.
