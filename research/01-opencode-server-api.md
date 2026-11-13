# opencode client–server protocol reference (for a native iOS/iPadOS client)

*Written on 2026-10-15 from the opencode source (`github.com/sst/opencode`, now `anomalyco/opencode`), default branch `dev`, commit `d0732ea` (2026-10-15, package version **2.0.29**; its `packages/protocol/openapi.json` is byte-identical to the released v2.0.30), and updated where later releases changed behaviour the app relies on. Other sources: the V1 OpenAPI spec and source files at tag `v1.18.23`, V2 specs at tags v2.0.0–v2.0.30, npm registry metadata, GitHub release metadata, and the swift-openapi-generator/runtime sources on `main`. All code citations are `path:line` relative to the repository root at `d0732ea` unless marked V1.*

Companion file: `research/opencode-openapi.json` (copy of `packages/protocol/openapi.json` at `d0732ea`).

## 1. Summary and the V1/V2 split

**The most important fact: "opencode" currently means two incompatible server APIs.**

* **V1** (`opencode-ai` on npm, versions 1.x; the installed **v1.18.23** belongs to this line; latest v1.19.1) serves the classic API (`/session/{id}/message`, `/event`, `/global/event`, `/global/health`, `x-opencode-directory`, optional Basic auth, opt-in mDNS). Its API has been frozen since 1.18.0, and its last releases point users to `opencode upgrade --major`.
* **V2** (`@opencode/cli`, versions 2.0.x, released 2026-09-11; 31 releases by 2026-10-15) is the default branch and what this document is mainly about. It is a rewrite: every route lives under `/api/*`, auth is mandatory, the transcript model and the event stream are new, and there is no V1 compatibility layer over HTTP. The first-party V2 desktop app marks V1 servers as incompatible ("Upgrade it to OpenCode V2 to continue", `packages/app/src/runtime/i18n/en.ts:400-401`).

**Recommendation:** build the iOS client against **V2 ≥ 2.0.10** (contract stable and additive since then; ≥ 2.0.25 for pairing). Detect V1 servers and tell the user to upgrade them (§12.4). Supporting V1 as well would mean a second, completely different protocol implementation (§11).

V2 in brief:

| Topic | V2 behaviour | Section |
|---|---|---|
| Transport | Plain HTTP/1.1 + JSON; SSE for events; WebSocket for terminals. No TLS in the server (remote access via the built-in OpenTunnel relay, a reverse proxy, SSH, or LAN HTTP) | §2 |
| Startup | One per-user background service (`opencode serve --service`) on `127.0.0.1:49374` by default; `opencode serve` (port 4096+) for foreground use; no `web`/`attach` commands, no mDNS | §2.2-2.3, §2.8 |
| Auth | HTTP Basic, username fixed to `opencode`, password = server password **or** a 30-day pairing token from `GET /auth/connect/{code}`; also `?auth_token=` and a same-origin cookie | §2.5, §2.7 |
| Health/version | `GET /api/info` → `{version, pid, urls, paths, capabilities?}`; 503 + `Retry-After` while starting | §2.9 |
| Scoping | `location[directory]=<abs>` query or `x-opencode-directory` header; session routes derive it from the session; one global event stream | §3 |
| Sending input | `POST /api/session/{id}/prompt {id?, text, files[{uri}], agents, skills, delivery: steer\|queue}` → durable inbox item; results arrive as events; model/agent set with separate calls | §5.3 |
| Transcript | Typed message rows (`user`, `assistant`, `shell`, `compaction`, `idle`, …); assistant rows hold `content: (text \| reasoning \| tool)[]`; tool state `streaming → running → completed \| error` | §6.3 |
| Events | `GET /api/event` (SSE, `data:` lines only, 15 s `: heartbeat`, first event `server.connected`, no replay, stream fails on overflow); 94 event types; durable events carry `{aggregateID, seq, version}` | §7 |
| Sync | Mirror `packages/client/src/solid/connection.ts` + `data.ts`: resync on every `server.connected`, invalidate on disconnect, optimistic writes keyed by client-minted IDs | §7.7-7.8 |
| Terminals | REST create/resize/delete + WebSocket with text output frames, one binary `0x00`+JSON `{cursor}` control frame, UTF-16 cursor resume | §8 |
| Codegen | OpenAPI 3.1, 142 ops / 285 schemas; usable only after preprocessing (strict `additionalProperties:false`, `anyOf` unions without discriminators, opaque event payloads); hand-write core models | §10 |

Section map: 2 Transport/startup/auth · 3 Scoping · 4 Wire conventions · 5 Endpoint catalog · 6 Data model · 7 Events and sync · 8 Terminals · 9 Tools · 10 OpenAPI/codegen · 11 V1 and V1→V2 diff · 12 Stability/versioning · 13 Gotchas · Appendix A (all 142 V2 operations) · Appendix B (all 94 V2 event payloads) · Appendix C (all 188 V1 operations).

## 2. Transport, startup, discovery and authentication (V2)

### 2.1 Process model

* There is one HTTP server process (Node `http.createServer`, plain HTTP, `packages/server/src/process.ts:14, 142-165`). It serves the JSON API under `/api/*`, the pairing route `/auth/connect/:code`, `/openapi.json`, WebSocket upgrades for terminals, and the **embedded web app on every other path** (`packages/cli/src/server-process.ts:92`; `packages/cli/src/services/web-ui.ts:15-31`).
* The CLI never embeds the server in-process: TUI, `run`, `mini` and the desktop app all talk HTTP to a server process. `createEmbeddedRoutes` (no password) is used only by the `@opencode/sdk` package (`packages/server/src/routes.ts:100-106`; `packages/sdk/src/internal/host.ts:30-60`).
* By default every client shares **one managed background service per user and release channel** ("the service"), elected through a fixed port plus a registration file. Clients can instead use a private child server (`--standalone`) or an explicit URL (`--server`).

### 2.2 CLI commands and flags (V2 at HEAD)

| Command | Purpose and flags | Source |
|---|---|---|
| `opencode [directory]` | TUI. `-c/--continue`, `-s/--session ID`, `--prompt`, `--auto`, `--server <url>`, `--standalone`, hidden `--yolo`/`--dangerously-skip-permissions`. The directory is applied with `chdir`; the TUI then resolves its location over HTTP. | `packages/cli/src/commands/commands.ts:15-24, 38-58`; `commands/handlers/default.ts:21-46` |
| `opencode serve` | Start a server. Flags: `--hostname`, `--port <int>`, `--cors <origin>` (repeatable), `--service`, `--stdio` (mutually exclusive). **No `--password`, `--mdns`, TLS or `web` flags in V2.** | `commands.ts:550-563`; `commands/handlers/serve.ts:8-16` |
| `opencode service start\|stop\|restart\|status` | Manage the background service (`status` prints its URL or `stopped`). | `commands.ts:471-512`; `commands/handlers/service/*.ts` |
| `opencode service get [key]` / `set <key> <value>` / `unset <key>` | Keys: `disabled, remote, hostname, port, password, cors, env`. `get password` prints (and if needed creates) the stored password. Changes stop the service until the next `start` or ensure. | `packages/cli/src/services/service-config.ts:101-113, 177-186, 208-355` |
| `opencode pair [--url URL] [--remote] [--yes]` | Print pairing links and a QR code for another device (§2.7). | `commands.ts:519-549`; `commands/handlers/pair.ts` |
| `opencode run`, `mini`, `api`, `models`, `stats`, `session …`, `auth …`, `reload`, `acp` | Clients of the service; most accept `--server` / `--standalone`; `acp` always uses a private server. | `commands.ts`; `commands/handlers/acp.ts:26-37` |
| `opencode upgrade [target] [--method …]` (alias `update`) | Self-update. (The V1 line's `opencode upgrade --major` is how 1.x users move to 2.x; there is no `--major` in V2.) | `commands.ts:60-74`; `packages/cli/src/services/updater.ts:14` |

V2 has **no `web` and no `attach` command** (both exist in V1, as shown by `opencode --help` on the installed 1.18.23). The web UI is served by every `serve` mode, and "attach" is `opencode --server <url>` with `OPENCODE_PASSWORD` set. The npm package installs `opencode` and a legacy alias `opencode2` (`packages/cli/package.json:7-9`; `install:337-366`).

### 2.3 Hosts, ports, serve modes

| Mode | Host | Port | Password | Notes |
|---|---|---|---|---|
| `serve --service` (the managed service) | config `hostname`, else `127.0.0.1` | config `port`, else **49374 (`0xC0DE`)** for channels latest/dev/beta/next, 49375 for `local`, otherwise derived from a hash of the channel; on Windows 0xC0DE becomes 0xB0DE (45278) | config `password`, else random 32 bytes base64url, persisted | cwd = `$HOME` (so the default location is `$HOME`); exits if a compatible service already answers; writes the registration file (`server-process.ts:61-73, 84-90`; `service-config.ts:46-59`) |
| `serve` (foreground) | `--hostname` or `127.0.0.1` | `--port`, else **first free port from 4096 upward** (`packages/server/src/process.ts:142-149`) | `OPENCODE_PASSWORD` / `OPENCODE_SERVER_PASSWORD`, else random (printed as `server password …`) | prints `server listening on <url>` (`server-process.ts:199-201`) |
| `serve --stdio` (private/standalone) | `127.0.0.1` | `--port 0` (ephemeral) | `OPENCODE_PASSWORD` provided by the parent | prints one JSON line `{"url": …}`; exits when stdin closes (`packages/cli/src/services/standalone.ts:17-59`) |

A server always requires a password ("Missing server password" otherwise, `packages/server/src/process.ts:53-54`). Binding `0.0.0.0` or `::` makes `/api/info.urls` list the loopback URL plus one URL per non-internal interface (`packages/server/src/server-info.ts:18-39`).

### 2.4 Local discovery: the service registration file

On the server machine, a client finds the managed service by reading `${XDG_STATE_HOME:-~/.local/state}/opencode/service.json` (or `service-<channel>.json` for other channels; the XDG layout is used on macOS too). Contents: `{"id","version","url","pid","password"}`, mode 0600 ("That file is the complete discovery contract", `packages/client/src/effect/service.ts:12-20`; `packages/client/src/service-probe.ts:36-41`; `packages/cli/src/services/service-registration.ts:22-39`). The probe calls `GET <url>/api/info` with that password, requires `pid` to match, and maps `200` → ready, `500` → failed, other statuses → waiting, `404` → incompatible protocol (`service-probe.ts:49-90`). An iOS app cannot read this file; it is how desktop, TUI and SSH tooling find the server.

### 2.5 Authentication

Single shared secret, HTTP Basic, fixed username:

* **Username is always `opencode`** (`packages/server/src/auth.ts:18-21`). The V1 `OPENCODE_SERVER_USERNAME` variable is not read in V2.
* **Password**: the server password (§2.3), **or a pairing session token** (§2.7); both are accepted wherever a password is (`auth.ts:32-37`).
* Accepted credential carriers (`packages/server/src/middleware/authorization.ts:12-71`):
  1. `Authorization: Basic base64("opencode:<password-or-token>")` (case-insensitive scheme). **`Bearer` is not accepted.**
  2. Query `?auth_token=<base64("opencode:<password-or-token>")>`, the same encoding as Basic, not the raw password. It takes precedence over the header. Useful where headers cannot be set (the web app reads it once from the page URL, `packages/app/src/entry.tsx:44-50, 81-96`).
  3. Cookie `opencode_session_<port>` (or `opencode_session` when the Host has no port) holding a session token; honoured only for same-origin requests (no `Origin`, or `Origin` host = `Host`).
* Unauthenticated routes: `GET /auth/connect/:code`, and the PTY connect routes when a valid `ticket` is supplied (`authorization.ts:82-91`; `process.ts:192-197`). The web app shell (static files) is also served without auth (`web-ui.ts:19-29`). **`/api/info` and `/openapi.json` require auth.**
* Failure: `401 {"_tag":"UnauthorizedError","message":"Authentication required"}`, plus `WWW-Authenticate: Basic realm="Secure Area"` unless the request is a browser `fetch` (`Sec-Fetch-Mode` present and not `navigate`) (`authorization.ts:41-56`). Send credentials preemptively on every request, including the SSE request and WebSocket upgrades.
* There are no scopes, roles or per-user accounts: any valid credential has full control, including reading stored provider secrets (`GET /api/credential`).

### 2.6 CORS

`HttpMiddleware.cors` with `maxAge 86400` (`packages/server/src/process.ts:74`). Allowed origins (`packages/server/src/cors.ts:3-20`): no `Origin` header (native clients), `http://localhost:*`, `http://127.0.0.1:*`, `oc://renderer` (desktop), `tauri://localhost`, `http(s)://tauri.localhost`, `https://*.opencode.ai`, and anything passed with `--cors` or `service set cors`. PTY routes additionally accept same-host origins (`cors.ts:22-26`). A native iOS client is unaffected by CORS. A WKWebView-hosted UI would need its origin allowed.

### 2.7 Remote access, TLS and pairing

* **No native TLS**: the server listens on plain HTTP and has no certificate options (`packages/server/src/options.ts:6-47`; `packages/gui-extensions/src/pairing/remote.ts:1-7`).
* Ways to reach it from a phone:
  1. **LAN:** `opencode service set hostname 0.0.0.0` (hint printed by `pair`, `commands/handlers/pair.ts:56-68`), then `http://<lan-ip>:49374`. Plain HTTP, so iOS needs an App Transport Security exception (`NSAllowsLocalNetworking` / per-domain) and the Local Network permission.
  2. **OpenTunnel** (built-in relay): `opencode pair --remote`, `opencode service set remote true`, or desktop Settings → Pairing. The service publishes `https://<16-hex route>.<tunnel host>` (for example `https://cbf8424f2044b16d.vcybm3xt4hhu.opentunnel.xyz` in a test fixture) in `/api/info.urls` (`packages/cli/src/services/remote-tunnel.ts:20-63`; `server-process.ts:182-198`; `packages/gui-extensions/src/pairing/remote.test.ts:11`). The comments claim traffic is end-to-end encrypted with a wildcard certificate, and access still requires the server password or a pairing token (`remote-tunnel.ts:7-10`).
  3. **SSH port forwarding** or a **reverse proxy** with `opencode pair --url https://…`.
* **Pairing flow** (how a phone should onboard):
  1. On the computer: `opencode pair` (or desktop Settings → Pairing) calls `POST /api/pair` → `{code, expires_in: 300}` (single-use, kept in memory, lost on restart; `packages/server/src/pairing.ts:7-33`).
  2. It prints links `<base>/auth/connect/<code>` for every URL in `/api/info.urls` (or `--url`, or the tunnel), and a **QR code whose payload is JSON `{"code": "...", "urls": ["http://192.168.1.5:49374", "https://…opentunnel…"]}`** with non-loopback URLs only (`pair.ts:29-50, 118-151`). The desktop QR contains `{code, urls: [tunnelOrigin]}` (`packages/gui-extensions/src/pairing/page.tsx:224-266`).
  3. On the phone: parse the link or QR JSON (code must match `[A-Za-z0-9_-]+`, URLs must be http(s) without credentials/query/fragment, as the app's parser enforces, `packages/app/src/servers/connect/pairing.ts:6-51`). Try the URLs in parallel, call `GET <url>/auth/connect/<code>` with `Accept: application/json` → `200 {"token": "<expiry>.<sig>"}`. Expired or used: `401 UnauthorizedError "Pairing link expired or already used"` (`packages/server/src/handlers/server.ts:30-53`).
  4. Store `{url, token}` in the Keychain and use `Authorization: Basic base64("opencode:<token>")`. Tokens are HMAC-signed, valid **30 days**, and all are revoked when the server password changes (`auth.ts:16, 39-66`). There is no refresh endpoint: re-pair when you get a 401.
  The first-party app tries every URL with a 5 s timeout and prefers the first one if it answers within 1 s (`packages/app/src/servers/connect/pairing.ts:85-132`).
* Manual alternative: user enters URL + password (from `opencode service get password`), validated with `GET /api/info` (`packages/app/src/servers/connect/dialog.tsx:334-402`).

### 2.8 mDNS / Bonjour

**Not present in V2.** No mDNS code, dependency or flag exists at HEAD; a V1 `server.mdns` config block is ignored with a warning (`packages/core/src/config/normalize.ts:45, 68`). V1 had `--mdns` / `--mdns-domain` (default `opencode.local`, and with mDNS the hostname defaulted to `0.0.0.0`), as the installed 1.18.23's `opencode --help` shows; see §11 for V1. For V2 an iOS client must get the address out of band (pairing link/QR, manual entry), or implement its own LAN scan for port 49374 followed by an authenticated `GET /api/info`.

### 2.9 Health, version and readiness

* `GET /api/info` is the only health/version endpoint. Ready: `200 {version, pid, urls[], paths{tmp}, capabilities?{persistentPty?}}`. Starting/stopping: `503` + `Retry-After: 1` (same body without capabilities). Boot failed: `500` (`packages/server/src/process.ts:188-217`; `handlers/server.ts:17-28`). Any other route before ready: `503 {"code":"service_starting"|"service_stopping"}` with `Retry-After: 1`, or `503 {"code":"service_failed", message, action}` (`process.ts:219-233`).
* No version header exists on responses. `/openapi.json` `info.version` is a constant `0.0.1`.
* The first-party app polls `/api/info` every 10 s for each saved server (30 s timeout, 2 retries on transport errors) and marks a server "unauthorized" on 401 (`packages/app/src/runtime/server/health.ts:23-29, 94-140`).

### 2.10 How the first-party clients connect

* **TUI / CLI:** resolve a server with `ServerConnection.resolve`: `--server URL` (Basic auth from `OPENCODE_PASSWORD`, `/api/info` check with a 5 s timeout, a version mismatch only warns), or a private `serve --stdio --port 0` child, or the managed service via `Service.ensure` (spawn `opencode serve --service` if needed; poll every 25 ms for up to 120 s; replace a service whose version differs for the TUI) (`packages/cli/src/services/server-connection.ts:21-98`; `packages/client/src/effect/service.ts:49-197`; `packages/client/src/service-timing.ts:16-24`). The TUI pushes its terminal environment with `PUT /api/session/{id}/environment` (`commands/handlers/default.ts:143`) and selects its location with `location[directory]` query parameters.
* **Desktop (Electron):** no private sidecar; it ensures the same managed service (`[bundledCli, "serve", "--service"]`, version pinned to the bundled CLI), and the main process injects `Authorization: Basic …` into renderer requests to the loopback origin, so the password never reaches the renderer (`packages/desktop/src/main/service/background-service.ts:32-92`; `packages/desktop/src/main/windows/security.ts:37-63`). Renderer origin `oc://renderer`.
* **Web UI** (served by the server itself): uses `location.origin`; authenticates with the pairing cookie or `?auth_token=`, else shows a sign-in form (`packages/app/src/entry.tsx:44-96`).
* **Remote servers in the app:** stored as `{type:"http", http:{url, password}}` (password = server password or pairing token) (`packages/app/src/runtime/server/persistence.ts:6-14`).
* **WSL / SSH extensions:** WSL runs `opencode serve --hostname 0.0.0.0 --port <free>` with `OPENCODE_SERVER_PASSWORD`; SSH runs `opencode service status|start` remotely and forwards the port with `ssh -L` (`packages/gui-extensions/src/wsl/sidecar.ts:34-101`; `packages/gui-extensions/src/ssh/bootstrap.ts:8-74`).

### 2.11 Environment variables

| Variable | Effect | Source |
|---|---|---|
| `OPENCODE_PASSWORD` (alias `OPENCODE_SERVER_PASSWORD`) | Password for foreground/stdio servers; credential sent by `--server` clients; ignored by `--service`; stripped from tool environments | `packages/cli/src/env.ts:7-22`; `server-process.ts:77-90` |
| `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_CONTENT`, `OPENCODE_CLI_CONFIG_CONTENT` | Config root / explicit file / inline JSON | `server-process.ts:35-41, 125-126`; `packages/core/src/config.ts:233-244` |
| `OPENCODE_DISABLE_PROJECT_CONFIG` (`OPENCODE_CONFIG_PROJECT_DISABLE`) | Ignore project config | `server-process.ts:117-119` |
| `OPENCODE_DB`, `OPENCODE_DISABLE_CHANNEL_DB` | Database path (`<data>/opencode/opencode.db` by default) | `packages/cli/src/database-path.ts:4-12` |
| `XDG_STATE_HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` | Root directories (also on macOS) | `packages/util/src/global-roots.ts:4-19` |
| `OPENCODE_CLIENT` | Client name reported by the server (`cli`, `desktop`, `acp`) | `server-process.ts:97` |
| `OPENCODE_MODELS_URL`, `OPENCODE_MODELS_PATH`, `OPENCODE_DISABLE_MODELS_FETCH` | Model catalog source | `server-process.ts:110-114` |
| `OPENCODE_DISABLE_AUTOUPDATE` | Disable update checks | `packages/cli/src/services/updater.ts:534` |
| `OPENCODE_DISABLE_FILEWATCHER` (`OPENCODE_FILEWATCHER_DISABLE`), `OPENCODE_DISABLE_FFF` | Disable file watcher / fast file finder | `server-process.ts:132-136` |
| `OPENCODE_DISABLE_CLAUDE_CODE(_SKILLS)` | Skip Claude Code compatibility discovery | `server-process.ts:121-124` |
| `OPENCODE_LOG_LEVEL`, `OPENCODE_PRINT_LOGS` | Logging | `packages/util/src/observability/logging.ts:159-173` |
| `OTEL_EXPORTER_OTLP_ENDPOINT/HEADERS` | Tracing | `packages/cli/src/index.ts:130-131` |
| Set by the server for child processes: `OPENCODE_TERMINAL=1` (PTYs), `OPENCODE_SESSION_ID` (shell tool), `OPENCODE_WORKTREE_BASE/PATH` | | `packages/core/src/pty.ts:175`; `tool/plugin/shell.ts:216`; `worktree.ts:244-245` |

No environment variable sets the server username, host or port in V2 (only Vite build-time `VITE_OPENCODE_SERVER_*` for the web app).

## 3. Scoping: locations, projects, sessions

### 3.1 The "location" concept

V2 has no per-request "instance" in the V1 sense. Everything that depends on a working directory (config, agents, models, tools, files, VCS, PTYs, shells, MCP servers) runs inside a **location**, identified by an absolute directory:

```ts
Location.Ref       = { directory: AbsolutePath, workspaceID?: "wrk_…" }   // packages/schema/src/location.ts:8-12
Location.PublicRef = { directory: AbsolutePath }                         // :14-16 (what the HTTP API exposes)
Location.PublicInfo = { directory, project: { id, directory, canonical } } // :19-32
```

The server lazily boots one set of location services per directory and caches it (`LocationServiceMap`, used in `packages/server/src/location.ts:89-100`). `workspaceID` exists internally but is not part of the V2 HTTP contract (V2_HTTP_API_AUDIT.md, "Workspace selectors and response fields removed until workspace support ships").

### 3.2 How a request selects its location

`requestRef()` in `packages/server/src/location.ts:71-79` resolves the location for every location-scoped route, in this order:

1. Query parameter `location[directory]=<absolute path>` (OpenAPI declares the `location` query parameter as `style: deepObject, explode: true`, `packages/protocol/src/groups/location.ts:14-27`).
2. Header `x-opencode-directory: <percent-encoded absolute path>`; the server applies `decodeURIComponent` and falls back to the raw value if decoding fails (`location.ts:75, 81-87`). The official clients always percent-encode it (`packages/client/src/solid/data.ts:165-172`, `packages/tui/src/mini/runtime.ts:154`).
3. Otherwise the **server process's current working directory** (`process.cwd()`).

A directory that does not exist yields `404 { "_tag": "LocationNotFoundError", "location": { "directory": … }, "message": … }` (`location.ts:20-34`, `packages/protocol/src/errors.ts:5-9`).

Location-scoped responses are wrapped as `{ "location": { "directory": <canonical directory> }, "data": … }` (`packages/schema/src/location.ts:34-36`, `packages/server/src/location.ts:49-60`). The returned directory is the server's canonical form; the official data layer stores results under that canonical key and, for models and providers, also under the requested key (`packages/client/src/solid/data.ts:1343-1366`). An iOS cache should do the same.

### 3.3 Three kinds of routes

| Kind | How the location is chosen | Routes |
|---|---|---|
| **Location-scoped** | `location[directory]` query, `x-opencode-directory` header, or server cwd | `GET /api/location`; agent, plugin, model, provider, integration, MCP, command, skill, RPC, shell, reference, VCS, web-search and config groups; `fs.*`; `pty.list/create/get/update/remove/connect-token` (and `pty.connect`, which re-derives it itself); `form.list`; `permission.request.list` (`packages/protocol/src/api.ts:159-189`, `groups/pty.ts:119`, `groups/permission.ts:61`, `groups/form.ts:25`) |
| **Session-scoped** | Derived from the session's stored location; any `location` you send is ignored | Every route that applies `sessionLocationMiddleware`: `session.fork`, `switchAgent`, `switchModel`, `update`, `prompt`, `command`, `experimental…/skill`, `synthetic`, `shell`, `compact`, `…/wait`, `revert.*`, `…/instructions/entries*`, `generate`, `interrupt`, `background`, `session.permission.create/get/reply` (`packages/protocol/src/groups/session.ts`, `packages/server/src/middleware/session-location.ts:16-30`). `session.permission.list` resolves the session's location inside its handler (`packages/server/src/handlers/permission.ts:60-68`). Session form routes use a variant that also accepts the undocumented `sessionID = "global"` sentinel for MCP elicitations, in which case the request location applies (`packages/server/src/middleware/form-location.ts:24-38`). |
| **Global** | No location | `server.*` (`/api/info`, `/api/pair`, `/auth/connect/:code`), `location.reload`, `session.list/create/get/remove/active`, `session.message.list/get`, `session.context/diff/inbox*/environment/view/move`, `experimental.session.stats/import/export/log`, `credential.*`, `project.update`, `worktree.*`, `debug.location.*`, `experimental.migration.v1.status`, `experimental.generate.text` (runs in the global config location, `packages/server/src/handlers/generate.ts:14-16`), persistent-PTY routes, `permission.saved.*`, `/api/event` |

Notes:

* `POST /api/session` without `parentID` and without `location` creates the session in the **server's cwd** (`packages/server/src/handlers/session.ts:137-139`). Always send `location: { directory }`. With `parentID`, the child inherits the parent's location.
* `project.list` is technically behind the location middleware (`api.ts:172`), so calling it without a location boots the server-cwd location; its result is still the global project list.
* Session events are routed internally by the session's owning location; on the wire an event may or may not carry `location` (see §7.2).

### 3.4 Projects and multi-project discovery

There is no "recent directories" endpoint in V2. Discovery works through projects, locations, worktrees and sessions:

| Need | Call | Notes |
|---|---|---|
| All known projects | `GET /api/project[?archived=true]` → `Project[]` | `Project = { id, canonical, vcs?, name?, icon?{url?,override?,color?}, commands?{start?}, time{created,updated,active,archived?}, sandboxes: string[] }` (`packages/schema/src/project.ts:40-49`). Archived projects are hidden unless `archived=true` (`groups/project.ts:17-26`). The official client also sorts by `time.active` descending and hides archived ones (`packages/client/src/solid/data.ts:1866-1871`). `Project.ID` is an opaque string; the literal `"global"` exists as a built-in value (`packages/schema/src/project-id.ts:4-8`). |
| Resolve a directory to its project | `GET /api/location?location[directory]=…` → `Location.PublicInfo` | Gives `project.id`, the project's root `directory` and `canonical` path. |
| Rename / re-icon / set worktree start script / move canonical root | `PATCH /api/project/{projectID}` body `{canonical?, name?, icon?, commands?}` → `Project` | `project.updated` event follows. |
| Worktrees of a project | `GET /api/worktree?projectID=…` → `[{directory, strategy?}]`; `POST /api/worktree` `{projectID, from?, branch?, directory?, name?}` → `{directory}`; `DELETE /api/worktree` **with JSON body** `{projectID, directory, force}`; `POST /api/worktree/refresh` `{projectID}` | `packages/protocol/src/groups/worktree.ts:21-77`; errors use the odd shape `{ _tag: "WorktreeError", name: "WorktreeError", data: { message, forceRequired? } }` (`:9-19`). Events `worktree.updated`, `worktree.resolved`. |
| Sessions of a directory | `GET /api/session?directory=<abs>` | Exact match on the session's location directory (`packages/core/src/session/store.ts:103`). |
| Sessions of a project (optionally a subfolder) | `GET /api/session?project=<id>[&subpath=<rel>]` | `subpath` is an exact match on the session's relative path (`store.ts:105-108`). |
| All sessions | `GET /api/session` | Plus `search=<substring of title>` (SQL `LIKE %…%`), `parentID=<id>` for children or `parentID=null` (the literal string) for roots (`store.ts:109-113`). From 2.1.0, `archived=true` returns only archived sessions and `archived=false` leaves them out; omitted returns both, and cursors keep the filter. 2.0.x ignores the parameter. 2.2.6 answers any other value, such as `1` or `TRUE`, with 400. |
| Which locations are booted | `GET /api/debug/location` → `Location.PublicRef[]`; `DELETE /api/debug/location?location[directory]=…` evicts one | Debug only. |
| Recently active | No endpoint. Use `Project.time.active` and `Session.Info.time.updated`. | |

Projects are created implicitly: resolving any location runs `Project.resolve`, which upserts a project row (`packages/core/src/project.ts:117, 354-397`). The project ID comes from the Git remote, a cached ID, or the root commit; Mercurial uses the hg root; a plain directory gets a hash of its path; a Git repository with no remote and no commits falls back to `"global"`. So "open a folder" in an iOS client is simply: pick an absolute path on the server machine, call `GET /api/location` with it, and use the returned `project.id`. `GET /api/project` is already ordered by `time.active` descending (`project.ts:221-230`), `time.active` is bumped at most once a minute while a project is used (`project.ts:60, 258-271`), and an hourly sweep archives idle projects whose canonical directory has disappeared (`project.ts:61, 399-420`).

## 4. Wire conventions (apply to every V2 route)

### 4.1 Encoding

* JSON request and response bodies (`application/json`), except `GET /api/fs/read/*` (raw bytes), `POST /api/experimental/fs/write` (raw `application/octet-stream` body), and the two SSE streams.
* The Node server wraps every response in `HttpMiddleware.compression()` (`packages/server/src/process.ts:73`); `URLSession` decompresses transparently.
* Timestamps are **epoch milliseconds** as JSON numbers (`DateTimeUtcFromMillis`, `packages/schema/src/schema.ts:36-41`). Some IDs embed time but must be treated as opaque.
* Money is a plain number in USD (`Money.USD`); model prices are USD per million tokens (`packages/schema/src/money.ts:6-17`).
* Query parameters are strings: numbers use `NumberFromString` (`limit=50`) and booleans use the literal strings `"true"` / `"false"` (`packages/protocol/src/groups/session.ts:161-166`). Nested query objects use bracket notation, so `location[directory]=/abs/path`, matching the generated client's `appendQuery` (`packages/client/src/promise/generated/client.ts:2256-2271`). `null` is sent as the string `"null"` (used by `session.list?parentID=null`).
* Path parameters are percent-encoded per segment. `fs.read` takes the **file path after the route prefix**: `GET /api/fs/read/src/app.ts` reads `src/app.ts` relative to the location (`packages/server/src/handlers/fs.ts:60-66` strips the first 13 characters and applies `decodeURIComponent` to the rest).
* Optional properties: Effect encodes `Schema.optional` as "key absent". The OpenAPI document renders many optionals as `anyOf: [T, {type: "null"}]` (226 of the 368 `anyOf`s). **Send absent keys, never `null`**, and decode `null` as absent to be safe.
* A few `Schema.Number` fields may encode non-finite values as the strings `"NaN"`, `"Infinity"` or `"-Infinity"`; the spec shows them as `number | "Infinity"|"-Infinity"|"NaN"` (for example `Integration.AttemptStatus.time.*`, `Session.Message.Shell.exit`, `Form.Value`). Real servers send finite numbers, but a strict decoder should accept both.

### 4.2 Response envelopes

| Shape | Used by |
|---|---|
| `{ "data": T }` | Most session routes (`session.get/create/fork/prompt/compact/synthetic/...`), message routes, permission routes under `/api/session/...`, credential list/create, persistent PTY |
| `{ "data": T[], "cursor": { "previous"?: string, "next"?: string } }` | `GET /api/session`, `GET /api/session/{id}/message` |
| `{ "location": { "directory" }, "data": T }` | Every location-scoped catalog or read (agents, models, providers, integrations, MCP, commands, skills, references, VCS, shells, PTYs, fs, form.list, permission.request.list, websearch) |
| Bare object or array | `GET /api/info` (`ServerInfo`), `GET /api/project` (`Project[]`), `PATCH /api/project/{id}` (`Project`), `GET /api/config` (`Config.Entry[]`), `GET /api/config/shell`, `GET /api/worktree`, `POST /api/worktree`, `GET /api/debug/location`, `GET /api/experimental/migration/v1`, `POST /api/session/{id}/interrupt` (`{interrupted}`), `POST /api/rpc/...` (`{output?}`) |
| `204 No Content` | All mutations that return nothing (switchAgent/switchModel/update/command/shell/revert clear+commit/inbox cancel+update/permission reply/form reply+cancel/environment/view/background/pty.remove/...) |

### 4.3 Errors

Every declared error is a JSON object tagged with `_tag`, served with the HTTP status from `packages/protocol/src/errors.ts`. The generated TypeScript client turns any declared status into an `Error` whose fields are copied from the body (`packages/client/src/promise/generated/client.ts:343-350, 2294-2305`).

| `_tag` | Status | Extra fields |
|---|---|---|
| `InvalidRequestError` | 400 | `message`, `kind?`, `field?`. Also produced for **any request that fails schema decoding**; the decoder's message is truncated to 1024 characters (`packages/server/src/middleware/schema-error.ts:7-20`) |
| `InvalidCursorError` | 400 | `message` |
| `RpcError` | 400 | `type`, `message`, `data?` |
| `FormInvalidAnswerError` | 400 | `id`, `message` |
| `UnauthorizedError` | 401 | `message` ("Authentication required") |
| `ForbiddenError` | 403 | `message` |
| `LocationNotFoundError` | 404 | `location{directory}`, `message` |
| `SessionNotFoundError` | 404 | `sessionID`, `message` |
| `MessageNotFoundError` | 404 | `sessionID`, `messageID`, `message` |
| `ProviderNotFoundError`, `IntegrationNotFoundError`, `IntegrationAttemptNotFoundError`, `IntegrationMethodNotFoundError`, `ProjectNotFoundError`, `FileNotFoundError`, `AgentNotFoundError`, `SkillNotFoundError`, `McpServerNotFoundError`, `CommandNotFoundError`, `PermissionNotFoundError`, `FormNotFoundError`, `PtyNotFoundError`, `ShellNotFoundError` | 404 | the relevant ID field plus `message` |
| `ConflictError` | 409 | `message`, `resource?` (for example a message ID reused in another session) |
| `SessionBusyError` | 409 | `sessionID`, `message` (revert while running) |
| `FormAlreadySettledError` | 409 | `id`, `message` |
| `InstructionEntryValueTooLargeError` | 413 | `actualBytes`, `maxBytes`, `message` |
| `UnknownError`, `CommandExecutionError`, `RpcInternalError` | 500 | `message`, plus `ref?` / `command` / `type` |
| `VcsInitNotSupportedError` | 501 | `providerID`, `message` |
| `ServiceUnavailableError` | 503 | `message`, `service?` |
| `WorktreeError` (worktree routes only) | 400 | different shape: `{ _tag, name: "WorktreeError", data: { message, forceRequired? } }` (`packages/protocol/src/groups/worktree.ts:9-19`) |

Errors raised **before** the API layer use other shapes:

* Missing or wrong credentials: `401 {"_tag":"UnauthorizedError","message":"Authentication required"}`, plus `WWW-Authenticate: Basic realm="Secure Area"` only when the request has no `Sec-Fetch-Mode` header or it is `navigate` (`packages/server/src/middleware/authorization.ts:41-56`). Native clients get the challenge header; this is harmless.
* Service not ready: `503 {"code":"service_starting"}` or `{"code":"service_stopping"}` with `Retry-After: 1`, or `503 {"code":"service_failed","message":…,"action":…}` (`packages/server/src/process.ts:219-233`).

### 4.4 Identifiers

All generated IDs are `"<prefix>_" + 12 hex characters + 14 base62 characters` (`packages/schema/src/identifier.ts:16-32`). The 12 hex characters are the low 48 bits of `timestamp_ms * 4096 + counter` (a per-millisecond counter). **Ascending** IDs sort by creation time; **descending** IDs store the bitwise NOT so the newest sorts first.

| Entity | Prefix | Order | Source | Client may mint? |
|---|---|---|---|---|
| Session | `ses_` | descending | `packages/schema/src/session-id.ts:5-15` | yes (`POST /api/session {id}`; reusing an existing ID adopts that session, `AGENTS.md`, Session Core) |
| Message / inbox item | `msg_` | ascending | `packages/schema/src/session-message.ts:23-30` | yes (`prompt`, `synthetic`, `compact`, `shell` accept `id`; idempotent per ID) |
| Event | `evt_` | ascending | `packages/schema/src/event.ts:9-13` | no |
| Permission request | `per_` | ascending | `packages/schema/src/permission.ts:10-14` | yes (`session.permission.create`) |
| Saved permission | `psv_` | ascending | `packages/schema/src/permission-saved.ts:8-12` | no |
| Form | `frm_` | ascending | `packages/schema/src/form.ts:8-15` | yes (`session.form.create`) |
| PTY | `pty_` | ascending | `packages/schema/src/pty.ts:9-22` | no |
| Shell | `sh_` | ascending | `packages/schema/src/shell.ts:9-22` | no |
| Credential | `cred_` | ascending | `packages/schema/src/credential.ts:14` | yes (`credential.create`) |
| Integration attempt | `con_` | ascending | `packages/schema/src/integration.ts:83-87` | no |
| Workspace (internal) | `wrk_` | ascending | `packages/schema/src/workspace-id.ts:5-19` | n/a |

Two derived-ID rules matter for clients:

* Messages created **from an event** reuse the event's ID with `evt_` replaced by `msg_` (`SessionMessage.ID.fromEvent`, `session-message.ts:28`). The official data layer relies on this to insert projected rows such as `agent-switched`, `model-switched`, `location-switched`, `synthetic`, `system`, `shell`, `idle` and `compaction` locally, with exactly the ID the server will later return (`packages/client/src/solid/data.ts:83, 692-716, 1077-1089`).
* Message IDs are ascending and lexicographically comparable. The client relies on that: it hides messages with `id >= session.revert.messageID` (`packages/tui/src/routes/session/rows.ts:52-66`) and truncates at `id >= to` on `session.revert.committed` (`data.ts:1121-1137`).

To mint IDs in Swift, reproduce `Identifier.create(false)`: lowercase hex of the low 6 bytes of `UInt64(ms) * 4096 + counter` (counter restarts at 1 each millisecond), followed by 14 random characters from `0-9A-Za-z`. For session IDs (descending) hex-encode the low 6 bytes of the bitwise NOT of that value.

### 4.5 Pagination

* **Sessions** (`GET /api/session`): default limit 50 (`packages/server/src/handlers/session.ts:29`), sorted by `time.updated` then `id` in the requested `order` (default `desc`). The response carries opaque `cursor.previous` / `cursor.next` (base64url JSON of the original filters plus an anchor; `packages/protocol/src/groups/session.ts:84-121`). Pass only `cursor` (plus optionally `limit`) on follow-up pages; the cursor re-applies the original filters.
* **Messages** (`GET /api/session/{id}/message`): default limit 50, maximum 200, default order `desc` (newest first) (`packages/server/src/handlers/message.ts:9, 41-46`; `packages/protocol/src/groups/message.ts:8-40`). Cursor = base64url `{id, order, direction}`; **do not combine `cursor` with `order`** (`InvalidCursorError`, `message.ts:35-36`). Repeat the same `type` filter on every page. `cursor.next` continues in the same order; `cursor.previous` walks back.
* **Shell output** (`GET /api/shell/{id}/output?cursor=&limit=`): byte cursor; `cursor == size` means fully caught up (`packages/schema/src/shell.ts:71-85`).
* **PTY output**: absolute cursor in UTF-16 code units on the WebSocket (see §8).

## 5. Endpoint catalog (V2, HEAD d0732ea)

The spec has **118 paths / 142 operations**. They are grouped below by domain, with semantics taken from the handlers. Appendix A lists all 142 operations with their exact parameters, bodies, responses and errors as generated from `packages/protocol/openapi.json`. Abbreviations: **L** = location-scoped (send `location[directory]` or `x-opencode-directory`), **S** = location derived from the session, **G** = global. "exp." = path under `/api/experimental/…`, outside the stable API commitment (V2_HTTP_API_AUDIT.md). For **L** routes the success body is wrapped as `{location: {directory}, data}` (§4.2); where a table shows only a type, it is the `data` part.

### 5.1 Server, health, pairing, locations

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `GET /api/info` | G | → `ServerInfo { version, pid, hostname? /* 2.2.0+ */, urls[], paths{tmp}, capabilities?{persistentPty?} }` | Identity + readiness. Answered even while the service boots: `503` + `Retry-After: 1` while starting/stopping, `500` if boot failed, `200` when ready (`packages/server/src/process.ts:188-217`). Still requires auth. `urls` are the reachable base URLs (for `0.0.0.0`/`::` binds, one per non-internal interface, `packages/server/src/server-info.ts:18-39`), plus tunnel URLs if any. `capabilities` is optional at every level "so clients still decode servers that predate a capability" (`packages/protocol/src/groups/server.ts:13-18`). |
| `POST /api/pair` | G | → `{ code, expires_in }` | Issues a single-use pairing code valid for 5 minutes (16 random bytes, base64url; `packages/server/src/pairing.ts:7, 24-28`). |
| `GET /auth/connect/{code}` | G (no auth needed) | → `{ token }` | Redeems a pairing code. With `Accept: text/html` it sets the `opencode_session_<port>` cookie and redirects to `/`; otherwise it returns a session token to use **as the Basic-auth password** (`packages/server/src/handlers/server.ts:30-53`). Expired/used code: `401 UnauthorizedError` (or a plain-text 401 page for browsers). See §2.7. |
| `GET /openapi.json` | G | → OpenAPI 3.1 document | Served by the running server (`HttpApiBuilder.layer(Api, { openapiPath: "/openapi.json" })`, `packages/server/src/routes.ts:178`). Behind auth like everything else. Useful for capability probing. |
| `GET /api/location` | L | → `Location.PublicInfo { directory, project{id, directory, canonical} }` | Resolves (and boots) a location. |
| `POST /api/location/reload` | G | → 204 | Shuts down and rebuilds **every** loaded location: pending permissions and forms are cancelled, running sessions continue at the next step boundary, and `location.shutdown` is emitted (`packages/protocol/src/groups/location.ts:50-61`). |
| `GET /api/debug/location`, `DELETE /api/debug/location` | G / L | list `Location.PublicRef[]` / 204 | Debug: list or evict booted locations. |
| `GET /api/experimental/migration/v1` | G | → `{status:"required"\|"completed"} \| {status:"running", progress{label, numerator?, denominator?}} \| {status:"error", error}` | Progress of the V1→V2 history migration (V1 sessions are imported into the V2 database by `V1Migration.layer`, `packages/server/src/routes.ts:190`). |

### 5.2 Sessions: lifecycle

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `GET /api/session` | G | query `limit, order, search, parentID, directory \| (project[, subpath]), cursor` → `{ data: Session.Info[], cursor{previous?, next?} }` | See §3.4 and §4.5. Children of a session: `parentID=<id>`; roots only: `parentID=null`. The official client pages children with `limit=200` (`packages/client/src/solid/data.ts:229, 526-534`). |
| `POST /api/session` | G | `{ id?, parentID?, title?, agent?, model?: Model.Ref, location?: {directory}, metadata?, permissions?: Rule[] }` → `{data: Session.Info}` | Creates a session. Without `parentID` and `location` it uses the server cwd. With `parentID` it creates a child at the parent's location and inherits its metadata. Client-minted `id` is allowed (the official client mints it to render optimistically, `data.ts:1514-1562`). Emits `session.created`. |
| `GET /api/session/{id}` | G | → `{data: Session.Info}` | 404 `SessionNotFoundError`. |
| `PATCH /api/session/{id}` | S | `{ title?, metadata?, permissions?, archived? /* 2.1.0+ */ }` → 204 | `title: ""` (empty string) **asks the server to generate a title** (`packages/server/src/handlers/session.ts:262-270`); a non-empty title renames (`session.renamed`); `metadata` replaces host metadata (`session.metadata.updated`); `permissions` replaces the session ruleset (`session.permissions`). |
| `DELETE /api/session/{id}` | G | → 204 | Deletes the session **and its child sessions** (`session.deleted`). |
| `GET /api/session/active` | G | → `{ data: { [sessionID]: {type:"running"} } }` | Sessions whose agent loop is currently running in this process; absent = idle. Used after every (re)connect to seed busy/idle state (`data.ts:635-655`). |
| `POST /api/session/{id}/fork` | S | `{ before?: msg_ }` → `{data: Session.Info}` | Creates a new **top-level** session (`parentID` unset) whose `fork = { sessionID: <source>, boundary: {type:"before"\|"through", messageID} }`, copying history before `before`, or through the newest message when omitted. It inherits location, agent, model, metadata and permissions, and gets a derived title (`packages/core/src/session.ts:319-358`, `session/projector.ts:114-175`). Empty source → `400 InvalidRequestError kind:"empty_session"` (`handlers/session.ts:225-238`). Emits only `session.forked` (no `session.created`), and the official data layer has no handler for it, so take the new session from the HTTP response or fetch it on that event. |
| `POST /api/session/{id}/agent` | S | `{ agent }` → 204 | Agent for subsequent steps; emits `session.agent.selected` (projected as an `agent-switched` message). |
| `POST /api/session/{id}/model` | S | `{ model: {providerID, id, variant?} }` → 204 | Model (and variant = reasoning-effort preset) for subsequent steps; emits `session.model.selected` (projected as `model-switched`). **There is no model or agent field on the prompt itself**: the TUI calls `/agent` and `/model` right before each prompt (`packages/tui/src/component/prompt/index.tsx:1273-1293, 1352-1369`). The server treats an unchanged selection as a no-op. |
| `POST /api/session/{id}/move` | G | `{ directory, delivery?: "steer"\|"queue" }` → 204 | Moves the session to another directory at a delivery boundary (enqueues a `move` inbox item; `session.moved` when applied). 400 if the directory is missing, not a directory, or unavailable (`handlers/session.ts:283-305`). |
| `PUT /api/session/{id}/environment` | G | `{ variables: {K:V} }` → 204 | Replaces the process environment used by this session's local shell commands (process-local, not persisted). |
| `POST /api/session/{id}/view` | G | `{ idle: <epoch ms> }` → 204 | Marks the idle transition the viewer saw as viewed (`session.viewed`); the server never marks a newer idle transition viewed. Pair with `Session.Info.time.idle` / `time.viewed` / `outcome` to drive "unread" badges. |
| `GET /api/experimental/session/stats` | G | `from?, to?` (epoch ms strings), `project?`, `timezone?` (IANA, default UTC), `tools?: none\|summary\|detail` → `{data: SessionStats.Info}` | Usage analytics (sessions, prompts, steps, tokens, cost, tool reliability, activity days, models). The response is wrapped in `data`; `tools=detail` adds a per-tool `usage[]` list. An unknown `timezone` answers 400 (2.2.2). |
| `POST /api/experimental/session/import`, `GET /api/experimental/session/{id}/export?sanitize=` | G | `SessionTransfer.Data {info, messages[]}` | Transcript import/export (V2 replacement for V1 `opencode export/import`). Export answers `{data: {info, messages}}`, wrapped in `data`, and 404 for a missing session (2.2.2). |

### 5.3 Sessions: sending input and controlling execution

V2 has **no synchronous "send and wait for the reply" call**. All inputs are durably *admitted* into a per-session inbox and delivered by the agent loop; results arrive as events (§7). Delivery vocabulary (AGENTS.md, Session Core; `packages/schema/src/session-inbox.ts:11`):

* `delivery: "steer"` (default): injected at the next safe step boundary of a running execution, or starts one when idle.
* `delivery: "queue"`: waits until every steer has drained, then exactly one queued item is delivered per continuation decision.
* `resume: false`: admit only, without scheduling execution.
* Pending items can be cancelled or switched between steer and queue until they are delivered.

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `POST /api/session/{id}/prompt` | S | `{ id?: msg_, text, files?: [{uri, name?, description?, mention?}], agents?: [{name, mention?}], skills?: [{id, mention?}], metadata?, delivery?, resume? }` → `{data: Session.Inbox.User}` | Admits one user message. **Idempotent per `id`**: retrying with the same ID in the same session returns the first admission, even if the content differs, because `packages/core/src/session/inbox.ts` reconciles by ID, session and type without comparing payloads; reusing the ID in another session or for another type → `409 ConflictError` (`handlers/session.ts:307-343`; corrected 2026-10-21 from the M3b live contract, which verified both cases against 2.0.32). Attachments: `uri` must be a `data:` URL (base64 must be canonical) or a `file://` URL **on the server machine** (optional `?start=&end=` line range for text; a directory yields a listing); 20 MiB limit; images are normalized/resized; other schemes → `400 InvalidRequestError field:"files"` (`packages/core/src/session/prompt.ts:93-231`). Unknown skill → 400 `field:"skills"`. Emits `session.inbox.enqueued`, later `session.inbox.delivered` and the execution events. |
| `POST /api/session/{id}/command` | S | `{ name, text, files?, agents?, skills?, delivery? }` → 204 | Runs a server-side slash command (`name` without the slash, `text` = arguments). Built-ins: `init` (guided AGENTS.md) and `review` (`packages/core/src/plugin/command.ts:28-53`), MCP prompts as `<server>:<prompt>` (`:54-78, 101-103`), plus config commands. Commands usually enqueue a prompt. 404 `CommandNotFoundError`, 500 `CommandExecutionError`. |
| `POST /api/session/{id}/shell` | S | `{ id?: msg_, command }` → 204 | Runs one shell command (the TUI's `!` mode) in the session directory; emits `session.shell.started`, then `session.shell.ended` with merged output (`packages/protocol/src/groups/session.ts:479-498`). Projected as a `shell` message. |
| `POST /api/session/{id}/synthetic` | S | `{ id?, text, description?, metadata?, delivery?, resume? }` → `{data: Session.Inbox.Synthetic}` | Hidden/system-authored input (the TUI sends editor context this way with `resume:false`, `prompt/index.tsx:1338-1351`). |
| `POST /api/session/{id}/compact` | S | `{ id?, delivery? }` → `{data: Session.Inbox.Compaction}` | Requests compaction (V1 "summarize"). Steers by default; the server may **coalesce** onto an already-pending compaction with a different ID (`data.ts:1563-1605`). |
| `POST /api/experimental/session/{id}/skill` | S | `{ id: skillID, resume? }` → 204 | Activates a skill directly (appends a `skill` message). |
| `POST /api/session/{id}/interrupt?resume=true\|false` | S | → `{ interrupted: boolean }` | V1 "abort". `true` if an active execution owned by this process was interrupted, `false` for the idle no-op. With `resume=true`, execution resumes pending steering input and next-in-line control items, while queued prompts stay parked (`groups/session.ts:745-765`). |
| `POST /api/session/{id}/background` | S | → 204 | Moves the session's active blocking jobs (the shell and subagent tools run as jobs) into background observation and tells the model, through a synthetic note, to carry on without waiting; no-op when nothing is blocking (`packages/core/src/session.ts:442-456`). |
| `POST /api/experimental/session/{id}/wait` | S | → 204 | Blocks until the session is idle (race-free barrier). With `prompt` this gives "synchronous" behaviour: prompt → wait → `GET …/message`. |
| `POST /api/session/{id}/generate` | S | `{ prompt }` → `{data:{text}}` | Transient generation using the session context; does not change history. |
| `GET /api/session/{id}/inbox` | G | → `{data: Session.Inbox.Info[]}` | Undelivered items (user, synthetic, compaction, move) in enqueue order. |
| `DELETE /api/session/{id}/inbox/{inboxID}` | G | → 204 | Cancels an undelivered item (idempotent; `session.inbox.cancelled`). |
| `PATCH /api/session/{id}/inbox/{inboxID}` | G | `{ delivery: "steer"\|"queue" }` → 204 | Switches delivery mode (`session.inbox.delivery.changed`); steering wakes execution; 409 if no longer pending. |

### 5.4 Messages and history

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `GET /api/session/{id}/message` | G | `limit? (1-200, default 50), order? (default desc), cursor?, type?` → `{data: Session.Message.Info[], cursor}` | Projected transcript (§6.3). `type` filters before pagination (`agent-switched, model-switched, location-switched, user, synthetic, system, skill, shell, assistant, compaction`; `idle` rows cannot be filtered for). |
| `GET /api/session/{id}/message/{messageID}` | G | → `{data: Session.Message.Info}` | One projected message. |
| `GET /api/session/{id}/context` | G | → `{data: Session.Message.Info[]}` | The active model context: messages after the last compaction. |
| `GET /api/session/{id}/diff?from=&to=&context=` | G | → `{data: FileDiff.Info[]}` | Per-file diffs of what a **turn** changed. `from` = user message whose turn to diff (default newest), `to` extends through a later turn, `context` = unchanged lines per hunk (omit for full-file patches). A turn runs from the first prompt after idle to the next idle marker. A running step compares against the working copy (`groups/session.ts:581-605`). |
| `POST /api/session/{id}/revert/stage` | S | `{ messageID, files?: boolean }` → `{data: Session.Revert}` | Stages a revert boundary at `messageID`: unless `files:false`, restores the files changed after it from snapshots and returns the resulting diffs. Restaging moves the boundary (`packages/core/src/session/revert.ts:21-56`). 409 `SessionBusyError` while running. Emits `session.revert.staged`. Clients hide messages with `id >= revert.messageID`. |
| `DELETE /api/session/{id}/revert` | S | → 204 | V1 "unrevert": restores the files and clears the boundary (`session.revert.cleared`). |
| `POST /api/session/{id}/revert/commit` | S | → 204 | Makes the revert permanent: deletes messages (and pending inbox items) at or after the boundary (`session.revert.committed {to}`). The TUI commits automatically before sending a new prompt while a revert is staged (`prompt/index.tsx:1328-1337`). |
| `GET/PUT/DELETE /api/experimental/session/{id}/instructions/entries[/{key}]` | S | PUT `{ value: <JSON> }` | API-managed durable context entries (key regex `^[a-z0-9][a-z0-9._-]*$`); changes are announced to the model at the next step boundary; `413` when too large. |
| `GET /api/experimental/session/{id}/log?after=<seq>&follow=true` | G | SSE of `Session.Event.Durable \| {type:"log.synced", aggregateID, seq?}` | Experimental durable replay of one session's event log after an exclusive sequence number, switching to live events with `follow=true`. Only the TUI devtools use it (`packages/tui/src/component/devtools-bar.tsx:165`). |

### 5.5 Permissions

Pending permission requests are **in-memory and per location** (`packages/core/src/permission.ts:265-330`); a server restart or `location.reload` cancels them.

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `GET /api/permission/request` | L | → `{location, data: Permission.Request[]}` | All pending requests in a location. |
| `GET /api/session/{id}/permission` | S (resolved in the handler) | → `{data: Permission.Request[]}` | Pending requests owned by the session (`packages/server/src/handlers/permission.ts:60-68`); the official client uses it to (re)hydrate (`data.ts:1801-1805`). |
| `GET /api/session/{id}/permission/{requestID}` | S | → `{data: Permission.Request}` | |
| `POST /api/session/{id}/permission/{requestID}/reply` | S | `{ decision: "once"\|"always"\|"reject", message? }` → 204 | `once` approves this request. `always` also stores `{projectID, action, resources: request.save}` as a saved permission when `save` is non-empty, and auto-approves other pending requests that now evaluate to allow. `reject` fails the tool (with `message` passed back to the model as corrective feedback) **and rejects every other pending request of the same session** (`permission.ts:264-321`). Each resolution emits `permission.replied`. 404 when already settled; the official client treats that as success (`data.ts:1809-1816`). |
| `POST /api/session/{id}/permission` | S | `{ id?, action, resources[], save?, metadata?, source?, agent? }` → `{data:{id, effect:"allow"\|"deny"\|"ask"}}` | For hosts and plugins: evaluate the rules and, if needed, create a pending request. |
| `GET /api/permission/saved?projectID=`, `DELETE /api/permission/saved/{id}` | G | `PermissionSaved.Info { id, projectID, action, resource, time{created,updated} }` | Manage "always allow" rules. |

### 5.6 Forms (V2 replacement for V1 "question" requests)

| Method & path | Scope | Request → response | Semantics |
|---|---|---|---|
| `GET /api/form` | L | → `{location, data: Form.Info[]}` | Pending forms in a location, including MCP elicitations owned by the `"global"` sentinel. |
| `GET /api/session/{id}/form` | S* | → `{data: Form.Info[]}` | Pending forms for a session. |
| `POST /api/session/{id}/form` | S* | `{ id?, title, metadata?, fields }` → `{data: Form.Info}` | Hosts/plugins can ask the user something. |
| `GET /api/session/{id}/form/{formID}` | S* | → `{data: Form.Detail}` (definition + `state`) | `state: pending \| answered{answer} \| cancelled{message?}`. |
| `POST /api/session/{id}/form/{formID}/reply` | S* | `{ answer: { [fieldKey]: string \| number \| boolean \| string[] } }` → 204 | One-shot; `400 FormInvalidAnswerError` if validation fails, `409 FormAlreadySettledError` if already settled. Emits `form.replied`. |
| `DELETE /api/session/{id}/form/{formID}?message=` | S* | → 204 | Declines, optionally telling the asker why (`form.cancelled`). |

`S*` = session form middleware: `sessionID` may be the literal `"global"` (MCP elicitations), in which case send the location header (`packages/client/src/solid/data.ts:165-172`).

### 5.7 Agents, commands, skills, references, plugins

| Method & path | Scope | Response | Notes |
|---|---|---|---|
| `GET /api/agent`, `GET /api/agent/{agentID}` | L | `Agent.Info[]` / `Agent.Info` | `mode: primary \| subagent \| all`, `hidden`, `color`, `steps`, `model?`, `permissions` (§6.5). Show `mode != subagent && !hidden` in the agent picker. Event `agent.updated`. |
| `GET /api/command` | L | `Command.Info[] {name, description?}` | Server-executable slash commands. Event `command.updated`. |
| `GET /api/skill` | L | `Skill.Info[] {id, name, description?, autoinvoke?, path, content}` | Event `skill.updated`. |
| `GET /api/reference` | L | `Reference.Info[] {name, path, description?, hidden?, source}` | Project references (local or git) that can be @-mentioned. Event `reference.updated`. |
| `GET /api/plugin`, `POST /api/plugin/check {target?}`, `POST /api/plugin/update {targets[]}` | L | `Plugin.Info[] {id?, source, features{server?,tui?,rpc?}, state}` | Plugin inventory and updates. Event `plugin.updated`. |

### 5.8 Models, providers, integrations (provider auth), credentials, web search, generation

| Method & path | Scope | Request → response | Notes |
|---|---|---|---|
| `GET /api/model` | L | → `Model.Info[]` | Snapshot of available models ordered by release date; may precede plugin settlement (refresh on `model.updated`). |
| `GET /api/model/default` | L | → `Model.Info \| null` | Model used when a session has no explicit selection. |
| `GET /api/provider`, `GET /api/provider/{providerID}` | L | → `Provider.Info[]` / `Provider.Info` | Active providers. Event `provider.updated`. |
| `GET /api/integration`, `GET /api/integration/{id}` | L | → `Integration.Info[]` / `Integration.Info` | **Provider and MCP authentication lives here.** Each integration lists `methods` (oauth / command / key / external / env) and current `connections` (credentials or env vars, each with optional `status: needs_auth`). Events `integration.updated`, `credential.*`. |
| `POST /api/integration/{id}/connect/key` | L | `{ key, answer?, label? }` → 204 | API-key method; `answer` = answers to the method's `form` fields. |
| `POST /api/integration/{id}/connect/external` | L | `{ methodID, answer?, label? }` → 204 | Stores a reference to credentials managed outside opencode. |
| `POST /api/integration/{id}/connect/oauth` | L | `{ methodID, answer?, label? }` → `{location, data: {attemptID, url, instructions, mode:"auto"\|"code", time{created, expires}}}` | Starts OAuth. Show `url` + `instructions`. `mode:"auto"`: the server-side plugin completes the flow by itself (a loopback callback server or device-code polling running **on the server machine**), so poll status. `mode:"code"`: the user pastes a code, then call `complete` with it (`packages/core/src/integration.ts:60-73, 590-640, 813-840`). |
| `GET /api/integration/{id}/connect/oauth/{attemptID}` | L | → `{status: pending\|complete\|failed{message}\|expired, time}` | Poll until terminal. |
| `POST /api/integration/{id}/connect/oauth/{attemptID}/complete` | L | `{ code? }` → 204 | Required for `code` mode. |
| `DELETE /api/integration/{id}/connect/oauth/{attemptID}` | L | → 204 | Idempotent cancel. |
| `POST /api/integration/{id}/connect/command`, `GET …/command/{attemptID}`, `DELETE …/command/{attemptID}` | L | `{ methodID, label? }` → `{attemptID, time}`; status `{status: pending{message?}\|complete\|failed\|expired}` | Runs a CLI login command **on the server** (method has `command: string[]`); poll status; `message` carries command output/instructions. |
| `POST /api/experimental/integration/wellknown` | L | `{ url }` → 204 | Adds a `.well-known` integration source. |
| `GET /api/credential` | G | → `{data: Credential.Entry[]}` | **Returns secret values** (API keys, OAuth access/refresh tokens; `packages/protocol/src/groups/credential.ts:13-14`). Avoid caching on the device. |
| `POST /api/credential` | G | `Credential.CreateInput {id?, integrationID, label?, value, activate?}` → `{data: Credential.Entry}` | Becomes active unless `activate:false` and one already exists; 409 if `id` exists. |
| `PATCH /api/credential/{id} {label}`, `POST /api/credential/{id}/activate`, `DELETE /api/credential/{id}` | G | → 204 | Multi-account management (`credential.updated`, `credential.switched`). |
| `GET /api/websearch/provider`, `POST /api/websearch {query, providerID?}` | L | → `WebSearch.Provider[]` / `{providerID, results[{url, title?, content?, time{published?}}]}` | Web search through the configured provider. |
| `POST /api/experimental/generate` | G | `{ prompt, model? }` → `{data:{text}}` | Stateless one-shot generation with the global config's default model. |

Gotcha for mobile: most built-in OAuth integrations use `mode: "auto"` with a **loopback redirect on the server machine**, for example `http://localhost:<port>/auth/callback` for OpenAI/ChatGPT and DigitalOcean, `http://127.0.0.1:<port>/callback` for Poe and Snowflake (`packages/core/src/plugin/provider/openai.ts:98-100`, `chatgpt.ts:149-151`, `digitalocean.ts:89-91`, `poe.ts:78-80`, `snowflake-cortex.ts:143-145`). Opening `url` in Safari on an iPhone that is not the server machine would redirect to the phone's own localhost and fail. Device-code style flows (for example GitHub Copilot, `github-copilot.ts:151`) work remotely. An iOS client should show the URL with a "complete this on the computer running opencode" hint, or offer API-key methods.

### 5.9 MCP servers

| Method & path | Scope | Notes |
|---|---|---|
| `GET /api/mcp` → `Mcp.Server[] { name, status: connected \| pending \| disabled \| failed{error} \| needs_auth{error}, integrationID? }` | L | Status of configured servers. `integrationID` is set for remote servers registered as OAuth integrations, so **MCP OAuth = the integration OAuth flow in §5.8** (`packages/schema/src/mcp.ts:90-97`). Event `mcp.status.changed {server}` (one per server as it settles; the official client debounces refetches by 150 ms, `data.ts:86, 1329-1335`). |
| `GET /api/mcp/resource` → `{resources[], templates[]}` | L | Resources from connected servers (for @-mentions). Event `mcp.resources.changed`. |
| exp. `PUT /api/experimental/mcp/{server} {config: local\|remote}`, `DELETE …/{server}`, `POST …/{server}/connect`, `POST …/{server}/disconnect` | L | **Runtime-only** overrides; not persisted to config. |

### 5.10 Files and search

| Method & path | Scope | Notes |
|---|---|---|
| `GET /api/fs/read/<relative path>` | L | Raw bytes with `Content-Type` = detected MIME, `ETag`, `Last-Modified`, `Cache-Control: no-cache, no-transform`, single-range `Range` support (206/416), and `304` on `If-None-Match`/`If-Modified-Since` (`packages/server/src/handlers/fs.ts:68-141`). Path is relative to the location; 404 `FileNotFoundError`. The OpenAPI path is the literal `/api/fs/read/*` (no path parameter), so build this URL by hand. |
| `GET /api/fs/list?path=` | L | Direct children (`{path: relative, type: file\|directory}`); `path` may be absolute or relative and may point outside the location; entry paths stay relative to the requested location. |
| `GET /api/fs/find?query=&type=file\|directory&limit=` | L | Ranked fuzzy file/directory search (V1 `find/file`). |
| exp. `POST /api/experimental/fs/write?path=` (raw body) | L | Writes bytes, creating parent directories; **not confined to the location**. |
| `filesystem.changed {file, event: add\|change\|unlink}` event | | File watcher notifications. |

Not present in V2: text search (`find.text`/grep), symbol search, `file.status` (use `GET /api/vcs/status`), and the V1 `/file/content` JSON reader (use `fs.read`).

### 5.11 VCS and worktrees

| Method & path | Scope | Notes |
|---|---|---|
| `GET /api/vcs` → `{provider?, branch{current?, default?}}` | L | Event `vcs.branch.updated {branch?}`. |
| `GET /api/vcs/status` → `[{file, additions, deletions, status: added\|deleted\|modified}]` | L | Uncommitted changes (V1 `file.status`). |
| `GET /api/vcs/diff?mode=working\|branch\|committed&base=&context=` → `FileDiff.Info[]` | L | `working` = HEAD→working copy; `branch` = merge-base(base)→working copy; `committed` = merge-base→HEAD (`packages/protocol/src/groups/vcs.ts:109-124`). |
| `GET /api/vcs/base` → `{name, ref, source: reflog\|default} \| null` | L | Inferred review base. |
| `GET /api/vcs/branch?search=&limit=` → `string[]` | L | Local and remote branches. |
| `POST /api/vcs/init?provider=git\|hg` | L | Initializes a repository in a markerless project (409 / 501 cases in the spec). |
| Worktrees | G | See §3.4. |

### 5.12 Shell commands (non-interactive, background)

`GET /api/shell` (running only) · `POST /api/shell {command, cwd?, timeout? (ms, default 0 = none), metadata?}` → `Shell.Info` · `GET /api/shell/{id}` · `DELETE /api/shell/{id}` (idempotent; kills and removes) · `GET /api/shell/{id}/output?cursor=&limit=` → `{output, cursor, size, truncated}`. All are L. Events: `shell.created {info}`, `shell.exited {id, exit?, status}`, `shell.deleted {id}`. The agent's own shell tool runs through this service and tags `metadata.sessionID` (`packages/schema/src/shell.ts:36-39`; the official client groups shells by it, `data.ts:1902-1906`).

### 5.13 Terminals

`GET/POST /api/pty`, `GET/PUT/DELETE /api/pty/{id}`, `POST /api/pty/{id}/connect-token`, WebSocket `GET /api/pty/{id}/connect`: see §8. Experimental session-bound persistent terminals live under `/api/experimental/session/{id}/terminal` and `/api/experimental/persistent-pty/*` (§8.5).

### 5.14 Configuration

| Method & path | Scope | Notes |
|---|---|---|
| `GET /api/config` → `Config.Entry[]` | L | Configuration **documents** and discovery directories for the location, lowest to highest priority: `{type:"document", path?, info: Config}` or `{type:"directory", path}`. Top-level config keys: `$schema, agents, commands, compaction, default_agent, enterprise, experimental, formatter, instructions, lsp, mcp, media, model, permissions, plugins, policies, providers, references, share, shell, skills, snapshots, tool_output, update, username, warming, watcher, websearch, worktree`. Event `config.updated`. |
| `GET /api/config/shell` → `[{path, name, acceptable}]` | (L in spec) | Shells available for terminals/agent execution. |
| exp. `PATCH /api/experimental/config {shell: string\|null}` | (L in spec) | The only config mutation exposed: it patches the `shell` field of the highest-precedence **global** config document. V1's `PATCH /config` has no V2 equivalent. |

### 5.15 Plugin RPC

`POST /api/rpc/{rpcID}/{method}?location[directory]=` with `{input?}` → `{output?}`; errors `RpcError` (400) / `RpcInternalError` (500). Plugin-defined events arrive on the event stream as `type: "rpc.<…>"` with a mandatory `location` and free-form `data` (`packages/protocol/src/groups/event.ts:14-21`). An iOS client can ignore RPC unless it hosts plugin UI.

### 5.16 V1 features with no V2 HTTP equivalent

Checked against the 142 operations at HEAD: session **share/unshare** (sharing was discontinued, v1.19.1 release notes), session **todo** lists, **LSP and formatter status**, **TUI-control routes** (`/tui/*`; the `tui.*` event types still exist in the manifest, but no server code at HEAD publishes them), text and symbol **find**, `file.status`, V1 **question** routes (replaced by forms), V1 provider-auth routes (replaced by integrations), `session.children` (use `parentID` filter), `session.init` (use the `init` command), message/part deletion and part update, `/global/*`, `/instance/dispose`, `/path`, `/log`, `/sync/*`, `/experimental/workspace*`, `PATCH /config`, and the `/mcp` add/auth routes (runtime MCP is experimental; auth goes through integrations).

## 6. Data model (V2)

Notation: TypeScript-like, `?` = optional key (absent, never `null` on output), times are epoch ms. Source of truth is `packages/schema/src/*.ts`; the shapes below match the OpenAPI components of the same name.

### 6.1 Session

```ts
Session.Info = {                          // packages/schema/src/session.ts:31-59 (public form: location is {directory})
  id: "ses_…"
  parentID?: "ses_…"                      // set for subagent/child sessions
  fork?: { sessionID: "ses_…", boundary: { type: "before"|"through", messageID: "msg_…" } }
  projectID: string
  agent?: string                          // current agent selection
  model?: Model.Ref                       // current model selection (with variant)
  cost: number                            // USD, this session only (not children)
  tokens: TokenUsage                      // cumulative
  outcome?: "succeeded"|"failed"|"interrupted"   // of the last finished execution, recorded at time.idle
  time: { created, updated, busy? /* start of the running turn, 2.2.2+ */, idle?, viewed?, archived? }
  title?: string
  location: { directory }
  subpath?: string                        // path relative to the project root
  metadata?: { [k]: JSON }                // host annotations; children/forks inherit
  permissions?: Permission.Rule[]         // evaluated after the agent's rules; last match wins
  revert?: { messageID, partID?, snapshot?, files?: FileDiff[] }   // staged revert (session-revert.ts:7-14)
}
TokenUsage = { input, output, reasoning, cache: { read, write } }   // token-usage.ts:5-14
```

Family cost: the official client sums `cost` over the root and every descendant it has loaded (`packages/client/src/solid/data.ts:1414-1422`), paging children with `GET /api/session?parentID=…&limit=200`. "Unread" = `time.idle > (time.viewed ?? 0)`; mark it with `POST /api/session/{id}/view {idle: time.idle}`.

### 6.2 Inputs: prompts, attachments, inbox items

```ts
PromptInput (request) = {                               // prompt-input.ts:22-34
  text: string
  files?:  [{ uri: "data:<mime>;base64,<b64>" | "file:///abs/path[?start=N&end=M]", name?, description?, mention?: {start, end, text} }]
  agents?: [{ name, mention? }]                         // @agent mentions (subagent hints)
  skills?: [{ id, mention? }]
}
Prompt (stored, on user messages / inbox payloads) = {  // prompt.ts:64-71
  text, files?: [{ data: base64, mime, source: {type:"inline"} | {type:"uri", uri}, name?, description?, mention? }],
  agents?: [{ name, mention? }], skills?: [{ id, name, text?, mention? }]
}
Session.Inbox.Info =                                     // session-inbox.ts:52-78
  | { id: "msg_…", sessionID, time{created}, type: "user",       delivery: "steer"|"queue", payload: Prompt & { metadata? } }
  | { …,                                    type: "synthetic",  delivery, payload: { text, description?, metadata? } }
  | { …,                                    type: "compaction", delivery, payload: {} }
  | { …,                                    type: "move",       delivery, payload: { location{directory}, projectID, subpath? } }
```

`mention = {start, end, text}` records where an @-mention sits in the prompt text (`prompt.ts:6-11`); the UIs use it to render pills.

### 6.3 Messages (`Session.Message.Info`)

V2 messages are **not** V1's `{info, parts[]}` pairs. A session transcript is one ordered list of typed rows (`packages/schema/src/session-message.ts:297-322`). Every row has `id: "msg_…"`, `type`, `time.created` and optional `metadata`.

| `type` | Extra fields | Meaning |
|---|---|---|
| `user` | `text, files?, agents?, skills?` | A delivered user prompt (same ID as its inbox item). |
| `synthetic` | `text, description?` | Host/system-injected input (usually hidden or collapsed). |
| `system` | `text, description?` | Instruction updates announced to the model (`session.instructions.updated`). |
| `skill` | `skill (id), name, text` | A skill activation. |
| `shell` | `shellID, command, status: running\|exited\|timeout\|killed, exit?, output?: {output, cursor, size, truncated}, time{created, completed?}` | A user `!command` run through `POST …/shell`. |
| `assistant` | see below | One **step** (one LLM call) of the agent loop. A turn usually has several. |
| `compaction` | `status: running\|completed\|failed`, `reason: auto\|manual`, running: `summary, recent`; completed: `+ model?, providerState?, providerContext?, cost?, tokens?`; failed: `error, cost?, tokens?` | Context compaction (V1 "summarize"). |
| `agent-switched` | `agent, previous?` | Projected from `session.agent.selected`. |
| `model-switched` | `model: Model.Ref, previous?` | Projected from `session.model.selected`. |
| `location-switched` | `location, projectID?, subpath?, previous?{location, projectID?, subpath?}` | Projected from `session.moved`. |
| `idle` | `outcome: succeeded\|failed\|interrupted, error?` | Turn boundary: the session went idle. Everything since the previous `idle` row is one turn, including prompts steered in mid-run. Not recorded for shutdown interruptions. |

```ts
Session.Message.Assistant = {                     // session-message.ts:212-237
  id, type: "assistant", agent, model: Model.Ref,
  content: AssistantContent[],                     // ordered: text, reasoning, tool items interleaved as streamed
  snapshot?: { start?: SnapshotID, end?: SnapshotID, files?: string[] },   // files changed by this step
  finish?: "stop"|"length"|"tool-calls"|"content-filter"|"error"|"unknown", rawFinish?: string,
  providerState?: object, cost?: number, tokens?: TokenUsage,             // this step only
  error?: StructuredError, retry?: { attempt, at, error },               // retry = scheduled provider retry
  time: { created /* request dispatch */, streamed? /* response body ended */, completed? }
}
AssistantContent =                                 // session-message.ts:161-198
  | { type: "text", text, state?: object }
  | { type: "reasoning", text, state?: object, time?: { created, completed? } }
  | { type: "tool", id /* provider call id */, name, executed?: boolean,
      providerState?: object, providerResultState?: object,
      state: ToolState, time: { created, ran?, completed? } }
ToolState =                                        // session-message.ts:126-159
  | { status: "streaming", input: string }                                   // raw JSON text being streamed
  | { status: "running",   input: object, metadata: { [k]: JSON } }          // metadata = live progress
  | { status: "completed", input: object, content: [Tool.Content, …] (non-empty), metadata? }
  | { status: "error",     input: object, error: StructuredError, content?: [Tool.Content, …], metadata? }
Tool.Content = { type: "text", text } | { type: "file", uri, mime, name? }   // tool.ts:67-84
StructuredError = { type: string, message: string, status?: 100..599, response?: { body } }   // session-error.ts:7-12
```

* `executed: false` means the call was not run locally (for example a provider-executed tool).
* `content` is the exact model-facing result; `metadata` is UI-only data (diffs, exit codes, child session IDs and so on; see §9).
* Per-step `cost`/`tokens` live on assistant rows; session totals live on `Session.Info` (pushed live by `session.usage.updated`). Context-window usage = the last assistant step with tokens (the Solid client exports `lastAssistantWithUsage`, CHANGELOG v2.0.29).
* There are no message-level "parts" IDs: content items are addressed by position (text/reasoning) or by tool `id`.

### 6.4 Model, provider, variants

```ts
Model.Ref  = { providerID, id, variant? }          // string form "provider/model#variant" (model.ts:19-43)
Model.Info = {                                     // model.ts:100-124
  id, modelID, providerID, canonical?, family?, name, package?, compatibility?,
  settings?, headers?, body?,                      // request overlays
  capabilities: { tools: boolean, input: string[], output: string[] },   // modalities: "text"|"audio"|"image"|"video"|"pdf" (core/src/models-dev.ts:29)
  variants: [{ id, settings?, headers?, body? }],  // named presets, e.g. reasoning effort
  time: { released }, cost: [{ tier?: {type:"context", size}, input, output, cache{read, write} }],  // USD / 1M tokens
  status: "alpha"|"beta"|"deprecated"|"active", enabled: boolean,
  limit: { context, input?, output }
}
Provider.Info = { id, canonical?, integrationID?, name, activation: "auto"|"enabled"|"disabled", package, compatibility?, settings?, headers?, body? }   // provider.ts
```

V2 has no separate "reasoning effort" field. Effort levels are **model variants**: pick one of `Model.Info.variants[].id` and send it as `model.variant` in `POST /api/session/{id}/model`. Variant overlays merge `settings`/`headers`/`body` into the provider request. Image input support = `"image" ∈ capabilities.input`. `cost` is an array because of context-size price tiers.

### 6.5 Agent, command, skill, reference

```ts
Agent.Info   = { id, name, model?: Model.Ref, request: {settings, headers, body}, system?, description?,
                 mode: "subagent"|"primary"|"all", hidden: boolean, color?, steps?, permissions: Rule[] }   // agent.ts:22-35
Command.Info = { name, description? }                                  // command.ts:9-13
Skill.Info   = { id, name, description?, autoinvoke?, path, content }
Reference.Info = { name, path, description?, hidden?, source: {type:"local",…} | {type:"git",…} }
```

The default agent ruleset (`agent.ts:39-52`) is "allow everything, ask before reading `*.env` / `*.env.*`, allow `*.env.example`".

### 6.6 Permissions

```ts
Permission.Request = { id: "per_…", sessionID, action: string, resources: string[], save?: string[],
                       metadata?: object, source?: { type: "tool", messageID, id /* tool call id */ }, message? }   // permission.ts:17-40
Permission.Reply   = "once" | "always" | "reject"      // body: { decision, message? }
Permission.Rule    = { action, resource, effect: "allow"|"deny"|"ask" }   // wildcard patterns; last match wins
PermissionSaved.Info = { id: "psv_…", projectID, action, resource, time{created, updated} }
```

`source` ties a request to the tool call that raised it (`messageID` = assistant message, `id` = tool call id), so the UI can render the prompt inline on the tool row. `resources` are what is being accessed (paths, commands, URLs); `save` are the generalized patterns stored when the user picks "always". V1's `once/always/reject` vocabulary survives, but the reply body field is now `decision` (V1 used `reply`, and its deprecated per-session route used `response`; V2_HTTP_API_AUDIT.md item 100).

### 6.7 Forms (questions)

```ts
Form.Info   = { id: "frm_…", sessionID: string /* or "global" */, title, metadata?, fields: Field[] (≥1) }   // form.ts:125-140
Form.Field  = StringField | NumberField | IntegerField | BooleanField | MultiselectField | ExternalField
  common: { key, title?, description?, required?, hidden?, when?: [{ key, op: "eq"|"neq", value }] }
  string:      { type:"string", format?: email|uri|date|date-time, minLength?, maxLength?, pattern?, placeholder?, default?, options?: Option[], custom? }
  number|integer: { minimum?, maximum?, default? }
  boolean:     { default? }
  multiselect: { options: Option[], minItems?, maxItems?, custom?, default?: string[] }
  external:    { type:"external", key, url, title?, description? }      // "open this URL" step
  Option = { value, label, description? }
Form.Answer = { [key]: string | number | boolean | string[] }
Form.State  = { status:"pending" } | { status:"answered", answer } | { status:"cancelled", message? }
```

`when` conditions are AND-ed; they reference earlier fields; against a multiselect, `eq` means "includes"; an unanswered referenced field makes the condition false; inactive fields are neither required nor answerable (`form.ts:28-41`). The model-facing `question` tool asks `{question, header, options[{label, description}], multiple?}` (`packages/schema/src/question.ts:6-21`) and is surfaced to clients as a form (§9).

### 6.8 Diffs, snapshots, VCS, files

```ts
FileDiff.Info = { file, patch /* unified diff */, additions, deletions, status: "added"|"deleted"|"modified" }   // file-diff.ts:6-12
Vcs.Info = { provider?, branch: { current?, default? } }
Vcs.FileStatus = { file, additions, deletions, status }
FileSystem.Entry = { path /* relative */, type: "file"|"directory" }
```

Snapshots are opaque IDs (`Snapshot.ID`, `snapshot.ts`) recorded on assistant steps (`snapshot.start/end/files`) and staged reverts; the server compares them for `session.diff` and revert. Clients never resolve snapshot IDs themselves.

### 6.9 Project and location

See §3.1 and §3.4. `Project.icon.url` is discovered (for example a favicon), `override` is user-set, `color` is a theme color; `commands.start` is the worktree setup script.

### 6.10 Shells, PTYs

```ts
Shell.Info = { id: "sh_…", status: "running"|"exited"|"timeout"|"killed", command, cwd, shell, file /* output capture path */,
               pid?, exit?, signal?, metadata: object, time: { started, completed? } }   // shell.ts:41-55
Pty        = { id: "pty_…", title, command, args[], cwd, status: "running"|"exited", pid, exitCode? }   // pty.ts:25-34
PersistentPty.Info = Pty & { sessionID, foregroundProcess: string|null, size{cols, rows}, output{head, tail} }   // persistent-pty.ts:9-15
```

### 6.11 Integrations, credentials, MCP

```ts
Integration.Info = { id, name, metadata?, methods: Method[], connections: Connection[] }   // integration.ts:74-80
Method = { type:"oauth", id, label, form? } | { type:"command", id, label, command: string[] }
       | { type:"key", label?, form? } | { type:"external", id, label, form? } | { type:"env", names: string[] }
Connection = { type:"credential", id, label, method: "key"|"oauth"|"external", status?: {status:"needs_auth", message, url?} }
           | { type:"env", name, status? }
Credential.Entry = { id: "cred_…", integrationID, label, active, value: OAuth{type,methodID,refresh,access,expires,metadata?} | Key{type,key,metadata?,configuration?} | External{type,methodID,metadata?} }
Mcp.Server = { name, status: {status:"connected"|"pending"|"disabled"} | {status:"failed"|"needs_auth", error}, integrationID? }
```

### 6.12 Config

`GET /api/config` returns raw configuration **documents** (`Config.Entry[]`), not a merged config: the client must merge by precedence if it needs effective values (`packages/protocol/src/groups/config.ts:12-24`). The V2 config schema is `packages/schema/src/config.ts` / `packages/core/src/config`; keys are listed in §5.14.

### 6.13 V1 entities with no V2 counterpart

* **Todo lists**: V1 had `Todo {content, status, priority}` with `GET /session/{id}/todo` and `todo.updated`; V2 removed the todo tool and API (`packages/core/src/database/v1-migration.bun.ts:901`).
* **Message parts with IDs** (`prt_…`), `step-start`/`step-finish`/`snapshot`/`patch`/`subtask`/`retry` parts: replaced by assistant rows (one per step) whose `content` holds text/reasoning/tool items, plus step/finish/cost fields on the row itself.
* **Session share** (`share.url`), `summary`, `slug`, `version` on sessions: not in V2 `Session.Info` (the `slug` and `version` survive only inside the `session.created` event).
* **Question requests** (`que_…`): replaced by forms (§6.7).

## 7. Real-time events and client synchronization

### 7.1 Transport

* **One global stream per server:** `GET /api/event` (`event.subscribe`). It carries events from **every** location and session ("native events and plugin RPC events across all server locations", `packages/protocol/src/groups/event.ts:44-53`). There are no per-directory or per-session streams; the official app opens one stream per server and demultiplexes by `event.location?.directory` and `data.sessionID` (`packages/app/src/runtime/server/client.tsx:24-58`).
* Plain **SSE over HTTP/1.1 chunked** with the same Basic auth as every other request. Response headers: `Content-Type: text/event-stream`, `Cache-Control: no-cache, no-transform`, `X-Accel-Buffering: no`, `X-Content-Type-Options: nosniff` (`packages/server/src/handlers/event.ts:22-31`).
* **Framing:** each event is exactly `data: <one-line JSON>\n\n` (`packages/server/src/event-feed.ts:29-31`). There are **no `event:` or `id:` lines and no `Last-Event-ID` support**. (The OpenAPI document describes a generic Effect SSE envelope `{id?, event, data: string}` with `event` required, `packages/protocol/openapi.json` path `/api/event`; the raw handler does not emit that, so ignore it.)
* **Keep-alive:** an SSE comment `: heartbeat\n\n` every 15 s (`handlers/event.ts:21`).
* **First frame:** always `{"id":"evt_…","type":"server.connected","data":{}}`. Note that it has **no `created` field** (`handlers/event.ts:13-19`; the protocol schema for it omits `created`, `groups/event.ts:27-35`). The reference client treats a stream that does not start with `server.connected` as a failure (`packages/client/src/solid/connection.ts:97-107`).
* **Volatile, no replay:** events published while you are disconnected are lost (`groups/event.ts:51`). Every reconnect must be followed by a resync (§7.8).
* **Backpressure:** each subscriber has a dropping queue of 4096 frames; when it overflows the server **fails that subscriber's stream** (the connection closes) instead of silently dropping events (`event-feed.ts:8, 64-68`). An event that cannot be encoded fails every subscriber (`event-feed.ts:41-62`). A disconnect therefore always means "possible gap, resync".
* The TypeScript client refuses single events larger than 16 MiB (`packages/client/src/promise/generated/client.ts:300, 389`).

### 7.2 Event envelope

```ts
{
  id: "evt_…",               // ascending; unique
  created: number,           // epoch ms (absent only on server.connected)
  type: string,              // discriminator
  data: { … },               // per type, see 7.3
  location?: { directory, workspaceID? },   // where it happened; absent for global events
  metadata?: { [k]: unknown },
  durable?: { aggregateID: string, seq: number, version: number }   // only for durable event types
}
```

Defined in `packages/schema/src/event.ts:67-78, 90-150`. `durable.aggregateID` is the session ID for session events (`session-event.ts:42-47`) and the project ID for `worktree.resolved`. `seq` is a 0-based, strictly increasing position in that aggregate's durable log (`packages/core/src/bus.ts:322-371, 583-598`). `version` is the schema version of that event type (for example `session.tool.success` is version 2). The `location` comes from the publisher's ambient location (`bus.ts:505-528`); session events normally carry their session's location.

Durability matters for clients: **durable** events are committed to SQLite together with their projection *before* they are broadcast (`bus.ts:449-484`), so an HTTP read issued after you receive a durable event already reflects it. **Ephemeral** events (all `*.delta`, `session.tool.progress`, `session.usage.updated`, `permission.*`, `form.*`, PTY/shell/catalog notifications) are never stored or replayed.

`seq` gaps are **not** a reliable loss signal: internal durable events such as `session.usage.recorded` and `session.message.content.updated` consume sequence numbers but are filtered out of the public stream (`packages/schema/src/session-event.ts:704-709`; `packages/schema/src/event-manifest.ts:71-84`; `packages/server/src/event-feed.ts:48-50`).

### 7.3 Event catalog

All 94 public event types (the `V2Event` union in `packages/client/src/promise/generated/types.ts:2545-2639`, built from `EventManifest.ServerDefinitions`, `packages/schema/src/event-manifest.ts:71-84`, plus `server.connected` and `rpc.*`). "D" = durable (with version), "E" = ephemeral. The "Client action" column paraphrases the reference handler `handleEvent()` in `packages/client/src/solid/data.ts:633-1341`.

**Connection and server**

| type | D/E | data | Fires when | Client action |
|---|---|---|---|---|
| `server.connected` | E | `{}` | First frame of every stream | Treat as (re)connected; resync (§7.8) |
| `installation.updated` | E | `{version}` | Server finished self-update | Offer reconnect/reload |
| `installation.update-available` | E | `{version}` | Newer release found (`packages/server/src/process.ts:118-120`) | Optional notice |
| `location.shutdown` | E | `{}` | A location's services were shut down (`location.reload`, eviction) | Invalidate every cached read for that location (`packages/schema/src/location-event.ts:5-6`) |
| `models-dev.refreshed` | E | `{}` | Model catalog refreshed | Refetch models |
| `rpc.<…>` | E | free-form object, `location` required | Plugin RPC events | Ignore unless hosting plugin UI |

**Catalog invalidations** (all E, `data` is `{}` unless stated; refetch the matching `GET` for `event.location`)

| type | Refetch |
|---|---|
| `provider.updated` | `GET /api/provider` |
| `model.updated` | `GET /api/model` |
| `agent.updated` | `GET /api/agent` |
| `command.updated` | `GET /api/command` |
| `skill.updated` | `GET /api/skill` |
| `reference.updated` | `GET /api/reference` |
| `plugin.updated` | `GET /api/plugin` |
| `config.updated` | `GET /api/config` (+ web-search providers) |
| `websearch.updated` | `GET /api/websearch/provider` |
| `artifact.updated` (2.2.4+) | `GET /api/experimental/artifacts` |
| `integration.updated` | integrations + models + providers |
| `credential.updated` | integrations, for every known location |
| `credential.switched` `{integrationID, credentialID\|null}` | reorder connections; refetch models + providers |
| `mcp.status.changed` `{server}` | `GET /api/mcp` (debounce, one event per server) |
| `mcp.resources.changed` `{server}` | `GET /api/mcp/resource` |
| `vcs.branch.updated` `{branch?}` | update `vcs.branch.current` in place |
| `project.updated` (data = full `Project`) | replace project |
| `worktree.updated` `{projectID}` | refetch `GET /api/worktree?projectID=` |
| `worktree.resolved` (D v1) `{projectID, directory, previous, adopted?}` | re-derive `projectID`/`subpath` of affected sessions (`data.ts:770-791`) |
| `filesystem.changed` `{file, event: add\|change\|unlink}` | refresh open file views |

**Session lifecycle and metadata**

| type | D/E | data (besides `sessionID`) | Client action |
|---|---|---|---|
| `session.created` | D1 | `projectID, location, subpath?, parentID?, slug, title?, agent?, model?, metadata?, permissions?, version` | Fetch `GET /api/session/{id}`; a new session starts empty, so treat live events as its source of truth (`data.ts:671-681`) |
| `session.forked` | D2 | `parentID, boundary, instructions?, instructionEntries?` | Fetch the new session (the reference client has no handler) |
| `session.deleted` | D2 | — | Remove the session and its cached data |
| `session.renamed` | D1 | `title` | Set title |
| `session.metadata.updated` | D1 | `metadata` | Replace metadata |
| `session.permissions` | D1 | `permissions` | Replace ruleset |
| `session.agent.selected` | D1 | `agent, previous?` | Set `info.agent`; insert an `agent-switched` row with ID `evt_→msg_` |
| `session.model.selected` | D1 | `model, previous?` | Set `info.model`; insert a `model-switched` row (`data.ts:705-729`) |
| `session.moved` | D1 | `location, projectID, subpath?` | Update location; insert a `location-switched` row |
| `session.viewed` | D1 | `idle` (epoch ms) | Refetch session (`time.viewed`) |
| `session.archived` / `session.unarchived` (2.1.0+) | D1 | — | Set `time.archived` to the event's `created`, or clear it; both also set `time.updated` |
| `session.usage.updated` | E | `cost, tokens` | Replace session totals |

**Inbox (pending input)**

| type | D/E | data | Client action |
|---|---|---|---|
| `session.inbox.enqueued` | D1 | `inboxID, item: {type: user\|synthetic\|compaction\|move, payload, delivery}` | Upsert pending item (`id = inboxID`, `time.created = event.created`) and, for user/synthetic, show it in the transcript; this is the echo that confirms an optimistic prompt (`data.ts:816-833`) |
| `session.inbox.delivered` | D1 | `inboxID` | Remove from pending; if it was a pending user input, move its row to the end of the transcript with `time.created = event.created` (`data.ts:792-807`) |
| `session.inbox.cancelled` | D1 | `inboxID` | Remove from pending and transcript |
| `session.inbox.delivery.changed` | D1 | `inboxID, delivery` | Update delivery mode |

**Execution, steps and streaming**

| type | D/E | data (besides `sessionID`) | Client action |
|---|---|---|---|
| `session.execution.started` | D1 | — | Status = running |
| `session.execution.succeeded` / `.failed {error}` / `.interrupted {reason: user\|shutdown\|superseded\|inactivity}` | D1 | | Status = idle; clear `retry`; except for `reason:"shutdown"`, insert an `idle` row (`outcome` succeeded/failed/interrupted). If any tool is still streaming/running, refetch messages; refetch session info (`data.ts:1068-1107`) |
| `session.step.started` | D1 | `assistantMessageID, agent, model, snapshot?, started` | Append a new `assistant` row (`content: []`, `time.created = started`), or reset it if the ID already exists (retry); close the previous active assistant (`data.ts:881-915`) |
| `session.step.streamed` | D1 | `assistantMessageID` | `time.streamed = created` |
| `session.step.ended` | D1 | `assistantMessageID, finish, rawFinish?, providerState?, cost, tokens, snapshot?, files?` | Complete the row (`data.ts:921-931`) |
| `session.step.failed` | D1 | `assistantMessageID, error, finish?, rawFinish?, providerState?, cost?, tokens?, snapshot?, files?` | Set `error`, `finish ?? "error"` |
| `session.retry.scheduled` | D1 | `assistantMessageID, attempt, at, error` | Show "retrying at …" (`assistant.retry`) |
| `session.text.started` | D1 | `assistantMessageID, ordinal` | Push `{type:"text", text:""}` |
| `session.text.delta` | E | `assistantMessageID, ordinal, delta` | Append to the latest text item |
| `session.text.ended` | D1 | `assistantMessageID, ordinal, text, state?` | Replace with the full text (authoritative) |
| `session.reasoning.started` / `.delta` / `.ended` | D1/E/D1 | same shape, `state?` | Same pattern on the latest open reasoning item; `.ended` sets `time.completed` |
| `session.tool.input.started` | D1 | `assistantMessageID, id, name` | Push tool item, `state {status:"streaming", input:""}` |
| `session.tool.input.delta` | E | `assistantMessageID, id, delta` | Append raw input. **Declared but not published at HEAD**: the tool-input fragments are created without a delta callback (`packages/core/src/session/runner/publish-llm-event.ts:285-298`) |
| `session.tool.input.ended` | D1 | `assistantMessageID, id, text` | Full raw input text |
| `session.tool.called` | D1 | `assistantMessageID, id, input, executed, state?` | `state → running {input, metadata:{}}`, `time.ran` |
| `session.tool.progress` | E | `assistantMessageID, id, metadata` | Replace `running.metadata` wholesale (live progress, e.g. `{shellID}` or `{sessionID, status}` for subagents) |
| `session.tool.success` | D2 | `assistantMessageID, id, content, metadata?, executed, resultState?` | `state → completed` |
| `session.tool.failed` | D2 | `assistantMessageID, id, error, content?, metadata?, executed, resultState?` | `state → error` |
| `session.synthetic` | D1 | `text, description?, metadata?` | Insert `synthetic` row (background shell/subagent completions arrive this way, with `metadata.source = "shell"\|"subagent"`) |
| `session.skill.activated` | D1 | `id, name, text` | Insert a `skill` row. The reference client has no live handler, so the row only appears on its next message fetch; a native client can insert it directly (ID `evt_→msg_`) |
| `session.instructions.updated` | D2 | `delta, text?` | If `text` present, insert a `system` row (`data.ts:834-847`) |
| `session.shell.started` / `.ended` | D1 | `shell: Shell.Info` / `+ output` | Insert / complete a `shell` row (`data.ts:858-880`) |
| `session.compaction.started` | D1 | `reason, recent, inputID?` | Insert running `compaction` row (ID = `inputID` or `evt_→msg_`) |
| `session.compaction.delta` | E | `text` | Append to running summary |
| `session.compaction.ended` | D1 | `reason, model?, providerState?, providerContext?, text, recent, cost?, tokens?` | Complete row |
| `session.compaction.failed` | D1 | `reason, error, inputID?, cost?, tokens?` | Mark failed |
| `session.revert.staged` / `.cleared` / `.committed {to}` | D1 | | Set/clear `info.revert`; on commit drop pending items and messages with `id >= to` (`data.ts:1113-1137`) |

**Requests to the user**

| type | D/E | data | Client action |
|---|---|---|---|
| `permission.asked` | E | full `Permission.Request` | Add to the session's pending list (dedupe by `id`) |
| `permission.replied` | E | `sessionID, requestID, reply` | Remove (fires for each request a reply settles, including batch rejections/approvals) |
| `form.created` | E | `{form: Form.Info}` | Add (for `sessionID == "global"`, remember `event.location`) |
| `form.replied` | E | `id, sessionID, answer` | Remove |
| `form.cancelled` | E | `id, sessionID` | Remove |

**Terminals and shells**

| type | D/E | data |
|---|---|---|
| `pty.created` / `pty.updated` | E | `{info: Pty}` |
| `pty.exited` | E | `{id, exitCode}` |
| `pty.deleted` | E | `{id}` |
| `persistent-pty.added` | E | `{sessionID, terminal: PersistentPty.Info}` |
| `persistent-pty.removed` | E | `{sessionID, ptyID}` |
| `persistent-pty.updated` (2.2.4+) | E | `{sessionID, terminal: PersistentPty.Info}`, for example after a rename (`userTitle`) |
| `shell.created` | E | `{info: Shell.Info}` |
| `shell.exited` | E | `{id, exit?, status}` |
| `shell.deleted` | E | `{id}` |

**Declared but not emitted by the server at HEAD:** `session.status {sessionID, status: idle|busy|retry{attempt, message, action?, next}}` (marked deprecated next to `session.idle`) and `session.idle` (`packages/schema/src/session-status-event.ts:9-53`), and `tui.prompt.append`, `tui.command.execute`, `tui.toast.show {title?, message, variant, duration}`, `tui.session.select` (`packages/schema/src/tui-event.ts`). They are in the public union and consumed by the TUI/app (`packages/tui/src/app.tsx:1294-1309`, `packages/app/src/session/usage-exceeded-dialogs.tsx:96`), but a grep of `packages/core`, `packages/server` and `packages/cli` finds no publisher; plugins could publish them. Decode them, but derive busy/idle from `session.execution.*` and `GET /api/session/active`.

### 7.4 Anatomy of one turn

A typical prompt produces, in order (exact interleaving varies):

1. `POST …/prompt` → `session.inbox.enqueued` (echo of your client-minted `msg_` ID).
2. `session.execution.started`, then `session.inbox.delivered {inboxID}`. The user row is now part of the projected history.
3. Per step (one LLM call): `session.step.started {assistantMessageID}` → `reasoning.*` / `text.*` fragments → for each tool call `tool.input.started` → `tool.input.ended` → `tool.called` (the tool starts running immediately, concurrently with the rest of the stream) → (`permission.asked` → reply → `permission.replied`) → `tool.progress`* → `tool.success|failed`. `session.step.streamed` marks the end of the provider response body and can arrive while tools are still running. The step closes with `session.step.ended {finish, cost, tokens}`, followed by `session.usage.updated`.
4. More steps while `finish == "tool-calls"`; prompts steered in mid-turn produce more `inbox.delivered` + steps in the same turn.
5. `session.execution.succeeded|failed|interrupted` (the projected `idle` row marks the turn boundary). For an untitled top-level session, a title is generated in the background once the first input is delivered (`session.renamed`; `packages/core/src/session/runner/llm.ts:177-180`).

Subagent tool calls create **child sessions** (`session.created` with `parentID`) whose events stream on the same connection. Link them through `tool.state.metadata.sessionID` (§9).

### 7.5 Streaming semantics

* Text and reasoning deltas are **batched every 100 ms** per fragment (`publish-llm-event.ts:106, 180-204`). Only one text fragment and one reasoning fragment can be open per step (`single = true`, `:238-284`), so "append to the latest open item of that kind" (what `data.ts:484-497` does) is correct; `ordinal` (0,1,2… per kind per step) lets you fold by position instead.
* `*.ended` carries the **complete** value and is the durable record; deltas are ephemeral. If you join mid-stream, or a delta for an unloaded message arrives, **drop it** (the reference client does, `data.ts:467-475`); the next `GET …/message` or the `.ended` event fixes the state.
* Tool input arrives as raw JSON text (`streaming`) and becomes a parsed object on `tool.called`. `state.input` is the model's raw input, captured before input repair and schema defaults, so numbers can arrive as strings and defaults can be missing.
* Events from different sources (the provider stream versus concurrently running tool fibers) have **no global order guarantee**. The publisher's contract is "consumers fold by id/ordinal rather than global position" (`publish-llm-event.ts:95-104`): key tools by `id`, text/reasoning by `ordinal` or latest-open, and assistant rows by `assistantMessageID`.

### 7.6 Ordering and consistency guarantees

* Within one session (aggregate), durable events are committed and published under a per-aggregate lock in `seq` order (`bus.ts:465-479, 576-600`), and a single SSE subscriber receives the publish order.
* Durable state is committed before the event is sent (§7.2), so "event, then GET" is safe. The opposite is **not** safe: an HTTP response may be older than events you have already applied. The reference client protects against this by recording events that arrive while a read is in flight and replaying them over the snapshot (`activeUpdates` in `data.ts:635-655`; `pendingUpdates` in `data.ts:1465-1500`).
* Optimistic writes are keyed by client-minted IDs, so the echo replaces the guess (`data.ts:349-418`).

### 7.7 How the official client does it (mirror this)

`packages/client/src/solid/connection.ts` (`createClientConnection`) manages the stream. It is used by the desktop/web app (`packages/app/src/runtime/server/client.tsx:85-101`) and the TUI (`packages/tui/src/context/client.tsx:25-39`):

* `connect()` opens `api.event.subscribe` with a **2 s timeout to the first frame**, requires `server.connected` first, then marks the connection connected (`connection.ts:32, 76-115`).
* An **idle watchdog of 45 s** (heartbeats arrive every 15 s) aborts a silent stream (`connection.ts:35, 84-92`).
* Reconnect loop: 1 s delay between attempts; the attempt counter resets if the previous connection lasted at least 1 s; an optional `reconnect()` hook can resolve a new server (for example the managed service restarted on a new URL) before retrying (`connection.ts:147-183`).
* Forced resync (`resync(reason)`) drops the current socket and reconnects immediately without backoff. It runs on `online`, and on `visibilitychange` back to visible when the stream has been quiet for more than **20 s** ("Locking a phone or switching apps hides the document without a pagehide…", `connection.ts:36-38, 211-240`). On iOS, map this to `scenePhase` / `NWPathMonitor`.
* Events are buffered and flushed in batches every 10 ms (16 ms in the app) to limit re-renders (`connection.ts:65-74`; `client.tsx:93`).
* The shared subscription (`packages/client/src/shared-events.ts`) multiplexes many consumers onto one HTTP stream, with its own per-consumer cap of 4096 queued events (`:25, 97-99`).

`packages/client/src/solid/data.ts` (`createData`) is the store and projection:

* **On every `server.connected`** (that is, after each reconnect): refetch `GET /api/session/active` (busy set, merged with any lifecycle events received during the fetch), `GET /api/location` for the default directory, VCS info and the project list (`data.ts:633-667`).
* **When the connection is not `connected`, all cached reads are invalidated** (`createEffect` → `sync.invalidate()`, `data.ts:2002-2005`), and event-driven refreshes are suppressed while disconnected (`refresh()`, `data.ts:236-243`). UI owners (open session views, sidebars) then re-call their `sync()` functions.
* Reads go through `createSync()` (`data.ts:174-227`): one in-flight load per key, "loaded" memoization, and invalidation that queues a serial reload so an older response can never overwrite a newer one.
* Session view: `session.sync(id)` = `GET /api/session/{id}`, plus children when requested (`data.ts:1656-1677`); `session.message.sync(id)` = `GET …/message?limit=20&order=desc`, reversed, merged with optimistic rows the server does not know yet (`data.ts:1690-1716`); `session.pending.sync(id)` = `GET …/inbox` merged with events seen during the fetch (`data.ts:1465-1502`); `session.permission.sync` / `session.form.sync` hydrate pending requests (`data.ts:1801-1864`).
* Older history: `message.loadMore(id)` pages with `cursor` (20 per page, or 200 per page with `all`), prepends, and publishes once (`data.ts:1717-1787`).
* Optimistic **create**: mint `ses_` ID, render immediately, `POST /api/session {id, location, …}`, roll back only if unacknowledged (`data.ts:1514-1562`). Optimistic **prompt**: mint `msg_` ID, add a pending user row immediately (including inline `data:` attachments), serialize sends per session, `POST …/prompt {id}`, roll back on rejection (`data.ts:1606-1655`). Prompts wait for an in-flight create of the same session.
* Pending-input status for UI (`data.ts:1444-1464`): `queued` (delivery = queue), `stranded` (idle and older than the last idle marker), `steering` (busy, current execution already delivered input), else `starting`.
* The transcript hides queued prompts and everything at or after a staged revert boundary (`packages/tui/src/routes/session/rows.ts:52-66`).
* `evict(sessionID)` drops heavy message data for a whole family while keeping unacknowledged optimistic rows (`data.ts:580-601, 1407-1413`).

### 7.8 Recommended iOS algorithm

1. **Connect:** `GET /api/info` (expect 200; 503 + `Retry-After` = starting). Open one `URLSession` streaming task to `/api/event` with `Authorization: Basic …` and `Accept: text/event-stream`. Parse lines incrementally: concatenate `data:` lines until a blank line, ignore `:` comments (they count as activity), JSON-decode.
2. **On `server.connected`:** mark connected, then **resync**: `GET /api/session/active`; for each *visible* scope refetch what it shows (session list page, open session info + latest message page + inbox + pending permissions + forms, location catalogs). Apply events that arrive during the fetches on top of the snapshots (record them per key, as `data.ts` does) or simply re-request if one arrives mid-fetch.
3. **Live:** apply events per §7.3 to an in-memory store keyed by session ID → message ID → content position / tool `id`. Drop deltas for rows you do not have. Batch UI updates (10-16 ms).
4. **Watchdog:** 45 s without bytes → abort and reconnect. Reconnect delay 1 s with jitter, growing to a cap such as 30 s while the server is unreachable. On entering the foreground after more than 20 s of silence, or on a network path change, force a reconnect.
5. **Backgrounding:** iOS suspends sockets quickly. Close the stream on background and treat the next `server.connected` as a full resync. For "agent finished" notifications while backgrounded you need your own push channel; the server has none.
6. **Long sessions:** fetch the newest page (`order=desc&limit=20…50`), render bottom-up, page older with `cursor.next`. Keep `cursor.previous` if you also need forward paging. Never fetch everything up front; the API caps pages at 200.
7. **Multiple directories:** a single stream covers all of them; filter by `location.directory` for catalog events and by `sessionID` for session events.

### 7.9 Experimental durable replay (not used by first-party sync)

`GET /api/experimental/session/{id}/log?after=<seq>&follow=true` streams that session's **durable** events after an exclusive `seq`, then a `{"type":"log.synced","aggregateID","seq"?}` marker, then live events (`packages/protocol/src/groups/session.ts:725-744`; `packages/schema/src/event-log.ts:7-20`; `bus.ts:150-160`). It would allow gap-free per-session catch-up, but it is experimental, excludes ephemeral deltas, is framed by Effect's generic SSE encoder (named events, failure event `effect/http-api/stream/failure`; spec `x-effect-stream`), and only the TUI devtools use it. Older replayed events may use older durable versions (for example replay-only `session.message.content.updated`, `session-event.ts:142-153`).

## 8. Terminals (PTY) and their WebSocket protocol

### 8.1 REST lifecycle (location-scoped)

| Call | Body → result | Notes |
|---|---|---|
| `POST /api/pty?location[directory]=…` | `{ command?, args?, cwd?, title?, env? }` → `{location, data: Pty}` | Default command = the configured shell; login shells get `-l`. `cwd` defaults to the location directory. Environment = the server process environment, overridden by your `env`, overridden by a host-provided PTY environment hook (empty in the stock server, `packages/server/src/pty-environment.ts:12-17`), plus `TERM=xterm-256color` and `OPENCODE_TERMINAL=1` (`packages/core/src/pty.ts:166-245`; `packages/server/src/handlers/pty.ts:42-60`). Title defaults to `Terminal <last 4 of id>`. |
| `GET /api/pty` | → `{location, data: Pty[]}` | Includes exited PTYs; only the 25 most recent exited ones are retained (`pty.ts:13-15, 230-239`). |
| `GET /api/pty/{ptyID}` | → `{location, data: Pty}` (`exitCode` once exited) | |
| `PUT /api/pty/{ptyID}` | `{ title?, size?: {rows, cols} }` → `{location, data: Pty}` | **Resize is an HTTP call**, not a WebSocket message (`pty.ts:247-253`; the reference terminal debounces and calls it on every fit, `packages/gui-extensions/src/terminal/terminal.tsx:267-279`). |
| `DELETE /api/pty/{ptyID}` | → 204 | Kills (if running) and removes. |
| `POST /api/pty/{ptyID}/connect-token` | header **`x-opencode-ticket: 1`** → `{location, data: {ticket, expires_in}}` | Single-use ticket (random UUID) valid **60 s**, bound to `{ptyID, directory, workspaceID}` (`packages/core/src/pty/ticket.ts:9-56`). Without the header, or from a disallowed `Origin`, → `403 ForbiddenError` (`handlers/pty.ts:119-143`). The custom header forces a CORS preflight so other web origins cannot mint tickets. |

Events: `pty.created`, `pty.updated`, `pty.exited {id, exitCode}`, `pty.deleted {id}`.

### 8.2 Opening the socket

`GET /api/pty/{ptyID}/connect` with WebSocket upgrade (spec marks it `x-websocket: true`, `packages/protocol/src/groups/pty.ts:120-145`). Query parameters:

| Param | Meaning |
|---|---|
| `location[directory]` | Must resolve to the same location the PTY (and ticket) belongs to. |
| `ticket` | Optional. When present, the request skips credential checks; the ticket must match the PTY and location, else `403` (`handlers/pty.ts:150-162`; `packages/server/src/middleware/authorization.ts:82-91`). |
| `cursor` | Optional replay start: an absolute output position; `-1` = tail from now (no replay); omitted or invalid = replay the whole retained buffer (`packages/core/src/pty.ts:53-55, 273-286`). |

Authentication: either the ticket (what browsers must use, since they cannot set WebSocket headers) **or** a normal `Authorization: Basic …` header on the upgrade request. `URLSessionWebSocketTask` can send the header, so a native client can skip the ticket round trip. Also: if an `Origin` header is present it must be same-host or allowed by CORS (`handlers/pty.ts:147-148`); native clients usually send none, which is accepted (`packages/server/src/cors.ts:22-26`).

Failure modes before upgrade: `403` (bad origin or ticket), `404` (unknown PTY). After upgrade: a close frame **4404** with reason `"session not found"` or `"session exited"` if attaching fails (`handlers/pty.ts:181-198`).

The reference client builds the URL as `ws(s)://<base>/api/pty/<id>/connect?location[directory]=…&cursor=…&ticket=…` with `binaryType = "arraybuffer"` (`packages/client/src/solid/pty.ts:21-41`).

### 8.3 Frame format

Server → client (`packages/core/src/pty/protocol.ts:1-37`; `handlers/pty.ts:199-203`):

1. **Replay:** the retained output from `cursor` to now, as **text frames** of at most 65,536 UTF-16 code units each (`REPLAY_CHUNK`).
2. **One binary control frame:** byte `0x00` followed by UTF-8 JSON `{"cursor": <absolute position after replay>}`.
3. **Live output:** text frames (raw terminal output, UTF-8, containing ANSI escapes).
4. On process exit or PTY removal: close frame `1000`.

Client → server: keyboard input as text frames (UTF-8). Binary frames are accepted if they are valid UTF-8, otherwise dropped (`protocol.ts:29-37`). There are no other client message types; resize goes through `PUT`.

**Cursor arithmetic.** The server counts output in **JavaScript string length (UTF-16 code units)**, not bytes (`session.cursor += chunk.length`, `packages/core/src/pty.ts:205-207`), and the reference client advances its cursor by `data.length` of each text frame (`gui-extensions/src/terminal/terminal.tsx:700-709`). In Swift, advance by `text.utf16.count` per received text frame, and replace the value whenever a control frame arrives. To resume after a disconnect, reconnect with `cursor=<last value>`. The server keeps at most **2 MiB** (2,097,152 UTF-16 units) of output per PTY (`pty.ts:12, 218-222`); if your cursor fell out of that window you get whatever is still retained, starting at the window's beginning.

Reference reconnect behaviour (`terminal.tsx:237-241, 630-760`): start from the persisted cursor, or `-1` when a serialized screen buffer was restored locally, or `0` for a fresh terminal; on abnormal close (code ≠ 1000) retry after checking whether the PTY still exists.

### 8.4 Shell commands versus PTYs

Use PTYs for interactive terminals. For "run this command and show its output" (and for the agent's own shell tool), the server uses the non-interactive **Shell** service (`/api/shell`, §5.12), whose output is paged by **byte** cursor over HTTP. The shell tool does not stream output through tool events; poll `GET /api/shell/{shellID}/output` with the `shellID` from the tool's progress metadata (the web UI polls every second, §9).

### 8.5 Persistent PTYs (experimental)

Session-bound terminals that survive server replacement, backed by a separate `opencode-pty` daemon. `ServerInfo.capabilities.persistentPty` says whether this server supports them (`packages/server/src/handlers/server.ts:25`). The TUI's terminals tab uses them (`packages/tui/src/context/session-terminals.tsx:31-93`).

* REST: `GET/POST /api/experimental/session/{sid}/terminal` (`POST` body `{command?, args[], cwd?, title, env{}, size?{cols, rows}}`), `GET …/terminal/read?lines=` (plain-text screen read), `GET/PUT/DELETE /api/experimental/persistent-pty/{id}` (`PUT {attachmentID?, size{cols, rows}}`), `GET …/{id}/snapshot` → `{info, text, checkpoint (base64 bytes), cursor{x, y}}`, `POST …/{id}/connect-token` (same `x-opencode-ticket: 1` rule), `POST /api/experimental/persistent-pty/shutdown|handoff`. Events: `persistent-pty.added`, `persistent-pty.removed`.
* WebSocket `GET /api/experimental/persistent-pty/{id}/connect?ticket=&cursor=<byte offset ≥ 0>&role=controller|observer&attachment_id=<uuid>&takeover=true|false&input_protocol=1` (`packages/server/src/handlers/persistent-pty.ts:108-207`):
  * Server first sends a JSON text frame `{"type":"attached", attachmentID, inputProtocol, info, role, generation, replay:{requestedOffset, availableOffset, endOffset, truncated}}`, then replay bytes as **binary** frames, then `{"type":"replay_complete","endOffset"}`, then live output (binary) interleaved with JSON control frames: `resized {cols, rows, generation, checkpoint (base64)}`, `exited {exitCode?, finalOffset}`, `controller_changed {attachmentID?, generation}`, `title_changed {title}`, `foreground_process_changed {process}` (`packages/core/src/persistent-pty/daemon.ts:103-117`). Close `4404 "terminal unavailable"` if it cannot attach.
  * With `input_protocol=1` every client frame is binary: `[type u8][cols u16 BE][rows u16 BE][payload]`, where `type 0` = claim control at that size and `type 1` = input bytes (`persistent-pty.ts:188-203`). Without it, raw input frames are sent at the current size.
  * Offsets here are **bytes**, unlike the regular PTY.
* Experimental: the audit marks all persistent PTY routes "outside the stable API commitment". Treat as optional.

## 9. Built-in tools and how to render them

Abbreviations: `TP/` = `packages/core/src/tool/plugin/`, `CORE/` = `packages/core/src/`, `UI/` = `packages/session-ui/src/`.

### 9.1 How tools reach the model, and what the client sees

* Built-ins are internal plugins registered in order `PatchTool … WriteTool` (`CORE/plugin/internal.ts:216-250`). A tool is `{name, input, description, execute, output?, options?{namespace?, permission?, codemode?, pinned?}}` (`packages/schema/src/tool.ts:27-42, 92-102`). Names are sanitized to `[A-Za-z0-9_-]`; namespaced tools become `<namespace>_<name>` (`CORE/tool/runtime.ts:276-281`).
* **Direct tools** (`codemode: false`) are offered to the provider individually: `read, glob, grep, edit, write, patch, shell, subagent, question, skill, webfetch, websearch` (each has `options: { codemode: false }`, for example `TP/read.ts:42`, `TP/shell.ts:195`). Everything else is reachable only through a single **CodeMode** tool named `execute`, which runs JavaScript calling `tools.<ns>.<name>(…)` (`CORE/tool.ts:230-262`). By default that covers `opencode.*`, MCP tools and `browser.*`.
* Per-model trimming: GPT-family models (`id` contains `gpt-` but not `oss`/`gpt-4`) get `patch` instead of `edit`+`write`; all others lose `patch` (`TP/patch.ts:296-306`). `websearch` disappears when web search is disabled (`TP/websearch.ts:184-191`). A tool is dropped when its permission action is wholly denied (`CORE/tool.ts:230-238`).
* **Only `content` and `metadata` reach clients.** A tool's structured `output` is used for validation and CodeMode and is never persisted (`CORE/session/runner/publish-llm-event.ts:617-634`). `state.input` is the raw model input (pre-repair, pre-defaults) (`publish-llm-event.ts:510-517`).
* Generic output bounding (`CORE/tool-output.ts:13-16, 67-117`): unless a tool sets `metadata.truncated` itself (read, glob, grep, shell do), text content is capped at **2000 lines / 50 KiB** (configurable via `tool_output.max_lines/max_bytes`); overflow is written to `<data>/tool-output/tool_<id>` (kept 7 days), a `[showing lines 1-N of M; full output saved to <path>]` marker is appended, and `metadata.truncated = true, outputPath` are set; otherwise `metadata.truncated = false` is added.
* Images in content are re-encoded/resized; undecodable ones are dropped with a `[N image(s) omitted: …]` note (`CORE/tool.ts:74-101`).
* No display titles come from the server; the web UI uses i18n labels (`packages/ui/src/i18n/en.ts:104-105, 183-211`). Unknown tools (MCP, plugins) render generically as "Called `<tool>`" (`UI/components/basic-tool.tsx:398-417`).

Tool error `type` values (open set): `tool.execution` (failure, invalid args, unknown/unavailable tool, tools disabled after max steps), `permission.rejected` (deny rule or reject-with-feedback), `aborted` ("The user declined this tool call", "The user dismissed this question", "Tool execution interrupted", location shutdown), `tool.input-json` / `tool.input-incomplete` (malformed arguments, with an excerpt of up to 2048 chars), `tool.result-missing` (provider-hosted call without result), `tool.unknown`, and the cause's own type for wrapped failures (`CORE/session/runner/step.ts:62-64, 91-93, 207-231`; `CORE/session/to-session-error.ts:61-69`; `publish-llm-event.ts:32-56, 557-576`). A permission reject *without* message or a dismissed question **ends the turn** (`CORE/session/model-request.ts:400-418`).

### 9.2 Direct tools

| Tool (name on the wire) | Input | `content` | `metadata` (client-visible) | Permission action → resources / save |
|---|---|---|---|---|
| `read` (`TP/read.ts`) | `path` (file or dir), `offset?` (1-based line/entry), `limit?` (≤ 2000) | Text: `Read file <path>, lines X-Y` + `N: text` lines; dir: `Read directory …` listing; `[Output truncated. Continue reading with offset: N]` when paged; image/PDF: text + `{type:"file", uri:"data:…", mime, name}` | `{truncated}` only | `external_directory` (if outside) then `read` → `[path]` / `["*"]` (`CORE/file-access.ts:144-161`) |
| `glob` (`TP/glob.ts`) | `pattern`, `path?`, `hidden?` (false), `limit?` (100) | absolute paths, one per line, or "No files found"; truncation note | `{count, truncated}` | `glob` → `[pattern]` / `["*"]`, metadata `{root, path, hidden, limit}` |
| `grep` (`TP/grep.ts`) | `pattern`, `path?`, `include?`, `literal?` (false), `caseSensitive?` (true), `limit?` (100 lines) | `Found N matches`, then `<abs path>:` and `  Line n: text` lines | `{matches, truncated}` | `grep` → `[pattern]` / `["*"]` |
| `edit` (`TP/edit.ts`) | `path`, `oldString`, `newString`, `replaceAll?` | `Edited <file> (N replacement[s])` | `{files: FileDiff[]}` (+ `truncated`) — unified diff of original vs post-formatter content (`TP/edit.ts:307-319`) | `edit` → `[path]` / `["*"]`, metadata `{files:[preview]}` (preview only when exactly one match; the prompt can arrive before match-count errors) |
| `write` (`TP/write.ts`) | `path`, `content` | `Wrote file successfully: …` / `Created file successfully: …` | `{truncated}` only — **no diff**; render from `input.content` | `edit` → `[path]` / `["*"]`, metadata `{files:[preview with status added\|modified]}` (`TP/write.ts:76-86`) |
| `patch` (`TP/patch.ts`, GPT models only) | `patchText` (`*** Begin Patch` … `*** Add\|Delete\|Update File:` … `*** Move to:` … `@@` … `*** End Patch`, grammar `CORE/tool/patch.txt`) | `Success. Updated the following files:` + `A/M/D path` lines | `{files: FileDiff[]}` | `external_directory` per outside target, then one `edit` request: resources = paths, metadata `{filepath, diff, files}` (`TP/patch.ts:117-125, 196-208`) |
| `shell` (`TP/shell.ts`) | `command`, `workdir?`, `timeout?` ms (default 120000 foreground; 0 = none), `background?` | foreground: output tail or `(no output)` (+ truncation note) and optionally a second item "Exited with code N" / "Killed by SIG" / "Timed out before completion" | running progress `{shellID: "sh_…"}`; completed `{status:"completed", truncated, exit?, signal?, timeout?}`; backgrounded `{status:"running", truncated:false, shellID}` (`TP/shell.ts:84-101`) | `external_directory` for `workdir`/`cd` targets, then `shell` → each parsed command / `"<prefix> *"` (`CORE/shell/parse.ts:164-205`) |
| `subagent` (`TP/subagent.ts`; V1 `task`) | `agent`, `description` (3-5 words), `prompt`, `model?` (`provider/model[#variant]`), `sessionID?` (continue a child), `background?` | `<subagent sessionID="…" state="completed">…last assistant text…</subagent>` | progress `{sessionID: <child>, status:"running"}`; completed `{sessionID, status:"completed"\|"running"}` (`TP/subagent.ts:201, 258-265`) | `subagent` → `[agentId]` / `[agentId]` |
| `question` (`TP/question.ts`) | `questions: [{question, header, options:[{label, description}], multiple?}]` (≥ 1) | `User has answered your questions: "Q"="A, B", …` | `{answers: string[][]}` | `question` → `["*"]`, no `save` |
| `skill` (`TP/skill.ts`) | `id` | `<skill_content name="…">…<skill_files>…</skill_files></skill_content>` | `{name, directory}` | `skill` → `[id]` / `[id]` |
| `webfetch` (`TP/webfetch.ts`) | `url` (http/https), `format?` (`text`, `markdown` or `html`; default `markdown`), `timeout?` s (≤ 120, default 30) | converted body (≤ 5 MiB) | `{contentType}` (+ generic `truncated`, `outputPath`) | `webfetch` → `[url]` / `["*"]` |
| `websearch` (`TP/websearch.ts`) | `query` | `## [title](url)` blocks with optional `Published:` line | `{provider}` (also as progress) | `websearch` → `[query]` / `["*"]`; may first open a provider-choice form (`metadata.kind: "websearch.provider"`) |
| `execute` (CodeMode, `CORE/codemode/tool.ts`) | `code` (JavaScript) | `[{text: output}, …nested image/PDF files as data URIs]` | `{toolCalls: [{tool: "opencode.models" \| "<server>.<tool>" \| "fetch" \| …, status: running\|completed\|error, input?}], error?: true}`; progress republishes `{toolCalls}` (`:85-89, 113-176`) | nested calls ask permissions with `source.id` = the execute call ID |

Rendering notes a client needs:

* **Diffs:** `FileDiff = {file (location-relative), patch (unified diff, jsdiff createTwoFilesPatch), additions, deletions, status}` (`TP/file-diff.ts:4-23`). For `write`, synthesize the "diff" from `input.content`. The web renderer prefers `metadata.files` and falls back to diffing `oldString`/`newString` from the input (`UI/tools/tool-renderer.tsx:956-999, 2094-2210`).
* **Shell:** a non-zero exit or timeout is still `status: completed`, so flag failure from `metadata.exit` / `timeout`. Live output is **not** in tool events: poll `GET /api/shell/{metadata.shellID}/output?cursor=` while the tool runs (the web UI polls every 1 s, `UI/tools/shell-output.ts:25-89`). Output files are retained only for the last 25 exited shells (`CORE/shell.ts:32, 159-170`).
* **Subagents:** `metadata.sessionID` is the child session ID; open it as a nested transcript (its events stream on the same connection; list children with `GET /api/session?parentID=…`). Children cannot spawn subagents by default (`experimental.subagent_depth` = 1, `TP/subagent.ts:118-133`).
* **Questions:** the tool opens a **form** titled "Questions" with `metadata: {kind: "question", tool: {messageID, id}}` and one field per question: key `q<i>`, `title` = header, `description` = question, `type: "string"` or `"multiselect"`, options `{value: label, label, description}`, `custom: true` (`TP/question.ts:74-88, 119-132`). Answer single-choice fields with a string and multiselect fields with `string[]` (`packages/app/src/session/requests/session-question-dock.tsx:308-319`). Hide the tool row while running and show the form instead (`UI/tools/tool-renderer.tsx:1348`). Cancel without a message aborts the turn; with a message it is a normal tool failure.
* **Permissions:** match `Permission.Request.source.id` to the tool item `id` to render approve/deny inline; requests from child sessions should also surface in the parent view (`packages/app/src/session/requests/session-request-tree.ts:20-72`).
* **Background work:** after `POST …/background` or `background: true`, the call completes with `metadata.status: "running"`; completion later arrives as a `synthetic` message with `metadata.source = "shell"` (`{shellID, jobID, state, exit?, …}`) or `"subagent"` (`{childID, agent, state}`) (`TP/shell.ts:157-189`; `CORE/session/subagent-completion.ts:21-46`).
* `read` also loads nearby `AGENTS.md` files as a separate synthetic message (description "Loaded …"), not as tool metadata (`TP/read.ts:87-107`).

### 9.3 CodeMode-only and MCP tools

* `opencode` namespace (`TP/opencode.ts:105-282`): `session_rename`, `session_move`, `worktree_create`, `worktree_list`, `worktree_remove`, `models`. MCP-resource tools `list_mcp_resources`, `read_mcp_resource` (`TP/mcp-resource.ts`). `browser.*` tools exist only when a desktop browser is attached (`packages/plugin-browser/src/connection.ts:26-28, 77-104`). These appear only as rows in `execute`'s `metadata.toolCalls`, never as their own tool items.
* **MCP tools** are named `<server>_<tool>` (`CORE/tool/mcp.ts:16-17, 45`). They run through CodeMode unless the server config sets `codemode: false`, in which case they appear as direct tool items with that name. Permission action = the tool name, resources `["*"]`, metadata `{input}` (`:51-63`). Content: text plus `data:` URI file items for images/audio. `isError` maps to a failure. Default execution timeout 12 h (`CORE/mcp/client.ts:36, 319`).
* **Plugin tools** use the same shape and default to CodeMode; a later registration with the same name overrides a built-in (`CORE/tool/AGENTS.md:33-54`).

### 9.4 V1 tools that are gone or renamed

| V1 | V2 | Evidence |
|---|---|---|
| `bash` | `shell` | `CORE/database/v1-migration.bun.ts:899`; `CORE/v1/config/migrate.ts:28-33` |
| `task` | `subagent` (`subagent_type`→`agent`, `task_id`→`sessionID`) | `v1-migration.bun.ts:899, 933` |
| `apply_patch` | `patch` | `v1-migration.bun.ts:899` |
| `read/edit/write` `filePath` | `path`; skill `name` → `id` | `v1-migration.bun.ts:935-940` |
| `todowrite` / `todoread` | removed (no todo API either) | `v1-migration.bun.ts:901` |
| `list`/`ls` | removed (`read` lists directories) | `CORE/tool/read-filesystem.ts:123-131` |
| `lsp`, `batch`, `codesearch`, `multiedit`, `invalid`, plan-exit | removed (`execute` replaces batch; plan is an agent) | `TP/edit.ts:205`; `CORE/plugin/plan.ts:33-53` |

**Migrated V1 sessions keep their V1 tool names and metadata** (`v1-migration.bun.ts:951-1000`), so a client should still render `bash`, `task`, `apply_patch`, `todowrite` items in old history.

## 10. The OpenAPI document and Swift code generation

### 10.1 What `packages/protocol/openapi.json` is

* Generated from the Effect `HttpApi` definition, not hand-written: `OpenApi.fromApi(ClientApi)`, then a stabilization pass that content-hashes anonymous component names (`packages/protocol/script/generate-openapi.ts:1-21`, `script/openapi-stabilize.ts:1-73`). Copied verbatim to `research/opencode-openapi.json` (SHA-256 `3fcd666b597b746bad26f56a92fe782cc86338a0b4498f43b435a2f97e4fa05a`).
* `openapi: 3.1.0`; `info = { title: "opencode HttpApi", version: "0.0.1", description: "Experimental HttpApi surface for selected instance routes." }` (`packages/protocol/src/api.ts:190-196`). **`info.version` is not the server version**, and it has not been bumped across 2.0.x.
* **118 paths, 142 operations, 285 component schemas**, 30 tags (with `session` listed twice). No `servers` entry. `securitySchemes` is empty and every operation says `security: []`, so **authentication is not described at all**. Add `Authorization: Basic …` yourself (for example in a `ClientMiddleware`).
* All 142 `operationId`s contain dots (`session.message.list`); 236 of 285 schema names contain dots (`Session.Message.Assistant`), and 9 carry numeric suffixes from de-duplication (`Session.Message.ProviderState_1…_5`, `Form.Fields_1…_3`, `Form.Answer_1`).
* Error responses are per status code with `*Encoded` schemas carrying a `_tag` enum (§4.3). There are no `default` responses.
* The same document is served live at `GET /openapi.json` (§5.1).

### 10.2 How streams and sockets are described

* The two SSE operations (`/api/event`, `/api/experimental/session/{id}/log`) declare `text/event-stream` with a schema `{ id?: string|null, event: string (required), data: <string> }` plus a vendor extension `x-effect-stream { encoding: "sse", causeSchema, errorSchema, failureEvent: "effect/http-api/stream/failure" }`.
* **The event payload is opaque in the spec:** `V2EventEncoded` and `SessionLogItemEncoded` are just `{ "type": "string", "contentMediaType": "application/json" }`. The 94-member event union (§7.3) does **not** appear in the OpenAPI document. Machine-readable sources for it are the generated TypeScript (`packages/client/src/promise/generated/types.ts:2545-2639` and the per-event types it references) and the Effect schemas in `packages/schema/src/*-event.ts` / `session-event.ts`.
* The `/api/event` handler emits only `data:` lines (no `event:` field, §7.1), contradicting the declared envelope.
* WebSockets (`pty.connect`, `persistentPty.connect`) are marked `x-websocket: true` but described as `GET` returning `application/json: boolean`, with their query parameters (`location[directory]`, `cursor`, `ticket`, `role`, `attachment_id`, `takeover`, `input_protocol`) added as plain strings (`packages/protocol/src/groups/pty.ts:131-142`, `groups/persistent-pty.ts:114-123`).
* `GET /api/fs/read/*` uses a literal `*` path segment with no path parameter; the real route takes the file path after `/api/fs/read/` (§5.10).

### 10.3 Schema patterns (counts from the HEAD document)

| Pattern | Count | Where | Consequence for codegen |
|---|---|---|---|
| `anyOf` | 368 (226 contain `{type:"null"}`) | Optional fields and all unions | No `oneOf`, no `discriminator` anywhere. Tagged unions (message types, tool states, content, events, form fields, inbox items, MCP status…) are `anyOf` of objects distinguished by a single-value `enum` on `type`/`status`. Generators produce "try every branch" wrappers. |
| `additionalProperties: false` | 496 (310 in components, 186 inline) | Nearly every object | **Strict decoding**: swift-openapi-generator emits `ensureNoAdditionalProperties` for such schemas, which throws `DecodingError` on any unknown key (OpenAPIRuntime `Conversion/CodableExtensions.swift:23-34`, checked against apple/swift-openapi-runtime `main`). One new server field would break decoding of the whole response. |
| Free-form objects | `{type:"object"}` with no properties: `Session.Message.ProviderState(_1…_5)`, `Session.Metadata`, `Form.Metadata`, `Form.Answer(_1)`; `{}` (any) for `Rpc.Input.input`, `Rpc.Output.output`, `Session.ProviderContext.messages`, settings records | | Map to `OpenAPIValueContainer` / a `JSONValue` enum. |
| `prefixItems` | 6 | `Form.Fields(_1…_3)`, `ToolState.Completed/Error.content` (encoding of `NonEmptyArray`) | Not supported by swift-openapi-generator (absent from its feature list); `items` is also present, so stripping `prefixItems` is safe. |
| `not` | 5 | `Session.Inbox.CompactionPayload = {not:{type:"null"}}` and inside `x-effect-stream` | `not` is unsupported; replace `CompactionPayload` with an empty object. |
| `allOf` | 4 | `Model.Settings`, `Provider.Settings`, `Config.*.Settings` (struct with rest record) | Supported (wrapper struct). |
| `patternProperties` | 1 | `GET /api/session/active` → `data` keyed by `^ses` | Not in the generator's feature list; treat as `[String: SessionActive]`. |
| Non-finite numbers | 30 occurrences of `"NaN"` | e.g. `number \| "Infinity"\|"-Infinity"\|"NaN"` for `Integration.Attempt*.time.*`, `Shell` exit codes, `Form.Value`, `Form.When.value` | `anyOf` of number and string enum; decode leniently. |
| `deepObject` query params | 59 | every `location` parameter | Supported by swift-openapi-generator (`deepObject`, explode true). |
| `contentEncoding: base64` + `format: byte` | 1 | `PersistentPty.Snapshot.checkpoint` | Decode as base64 string. |
| Header parameters | 2 | `x-opencode-ticket` on the two connect-token routes | |
| `DELETE` with JSON body | 1 | `DELETE /api/worktree` | Allowed by URLSession; some generators warn. |
| Recursive `$ref` cycles | 0 | | No recursion problems. |

### 10.4 Using apple/swift-openapi-generator: viable only for part of the API

swift-openapi-generator supports OpenAPI 3.1, `anyOf`/`oneOf`(+`discriminator`)/`allOf`, `additionalProperties`, deepObject query parameters, and `HTTPBody` for non-JSON bodies. Its feature list marks `not`, `security`/`securitySchemes` and `tags` as unsupported, says no specification extensions are supported, and does not list `prefixItems` or `patternProperties` (`Sources/swift-openapi-generator/Documentation.docc/Articles/Supported-OpenAPI-features.md` on `main`). OpenAPIRuntime has helpers for SSE bodies (`asDecodedServerSentEvents`, `asDecodedServerSentEventsWithJSONData`; `Sources/OpenAPIRuntime/EventStreams/ServerSentEventsDecoding.swift`).

Running it on the unmodified spec would give you:

1. Brittle decoding: `additionalProperties: false` turns any additive server change into a runtime decode failure.
2. Awkward unions: `anyOf` wrappers with ~11 optional payload slots for `Session.Message.Info` and 4 for `ToolState`, decoded by trial.
3. No typed events: `/api/event` becomes a body of opaque JSON strings.
4. Hand-written WebSocket and `fs.read` URLs.

If you want generation, preprocess the spec first (a small script in your build tooling):

* delete every `additionalProperties: false`;
* rewrite each `anyOf` whose members are `$ref`s to objects with a single-value enum on the same property into `oneOf` + `discriminator { propertyName, mapping }`; turn `anyOf [T, {type:null}]` into `T` (optional);
* drop `prefixItems` and `not`, and turn `patternProperties` into `additionalProperties`;
* strip the `"NaN"/"Infinity"` string alternatives, or keep them through a custom number type;
* rename dotted schemas (or rely on the generator's naming strategy) and set `namingStrategy: idiomatic`;
* inject the event union yourself (§7.3), or keep events hand-written.

**Recommendation:** hand-write the domain models that matter for UX and correctness (`Session.Info`, the 11 message types, assistant content, `ToolState`, `Tool.Content`, inbox items, `Permission.Request`, `Form.*`, `Model.Info`, `Agent.Info`, the event envelope and the ~94 events) as Swift enums with custom `Decodable` that switch on the discriminator, **ignore unknown keys**, and map unknown discriminator values to an `.unknown(rawJSON)` case. Treat `packages/client/src/promise/generated/types.ts` as the canonical machine-readable reference: it is generated by the project's own codegen (`packages/httpapi-codegen`) from the same Effect contract and does include the event union. Use a thin hand-written request layer, about 60 operations for parity with the desktop app, or the generator on a preprocessed spec for the long tail of catalog endpoints. Do not use `GET /openapi.json` at runtime for anything except capability probing.

## 11. The V1 line (v1.18.23) and how it differs from V2

V1 source is cited at tag `v1.18.23` (files fetched from `raw.githubusercontent.com/sst/opencode/v1.18.23/…`); the V1 spec is `packages/sdk/openapi.json` at that tag (fetched: OpenAPI 3.1.0, `info {title:"opencode", version:"1.0.0"}`, **162 paths, 188 operations, 472 schemas**). The operation set is identical in v1.18.0, v1.18.23 and v1.19.1; between them only `Config`/`ProviderConfig`/`Model` schemas changed and `/global/upgrade` made `target` required.

### 11.1 One V1 process, three surfaces

v1.18.23 serves, from one HTTP server (`packages/opencode/src/server/routes/instance/httpapi/server.ts:130-203`):

1. **130 classic V1 operations** (no `/api` prefix): `/session/*`, `/event`, `/global/*`, `/file*`, `/find*`, `/tui/*`, …
2. **58 `/api/*` operations with `v2.*` operationIds**, an early preview of the V2 HttpApi (plus 3 `/experimental/project/{id}/copy*` operations), mounted from the in-progress server package.
3. `GET /doc` (OpenAPI) and a web-UI catch-all for unknown paths.

The `/api` preview inside 1.18.23 is **not compatible with V2 HEAD**. Examples: `GET /api/health` (gone; V2 uses `/api/info`), `POST …/revert/clear` (now `DELETE …/revert`), `/api/session/{id}/history` and `/event` (gone), question routes (replaced by forms), `integration/attempt/*` paths (moved under `connect/oauth/{attemptID}`), permission reply `{reply}` (now `{decision}`). Do not target it.

### 11.2 V1 transport, auth, discovery

* `opencode serve` / `opencode web`: hostname `127.0.0.1`, port `0` = try 4096 then any free port; flags `--port`, `--hostname`, `--cors`, `--mdns`, `--mdns-domain` (V1 `cli/network.ts:6-33, 70-74`; also visible in the installed `opencode --help`). The V1 TUI does **not** listen on TCP unless given `--port`/`--hostname`/`--mdns`; otherwise it uses an in-process transport (`cli/cmd/tui.ts:233-247`). A phone can reach V1 only through `opencode serve`, `opencode web`, or a TUI started with those flags. `opencode attach <url>` connects a TUI to a running server.
* **Auth is optional**: enabled only when `OPENCODE_SERVER_PASSWORD` is set; username `OPENCODE_SERVER_USERNAME` (default `opencode`) (`server/auth.ts:17-34`). Basic auth or `?auth_token=base64(user:pass)`. 401s always carry `WWW-Authenticate`; classic routes return an empty 401 body.
* **mDNS** (V1 only): Bonjour service type `_http._tcp`, instance name `opencode-<port>`, host `opencode.local` (or `--mdns-domain`), TXT `path=/`; published only for non-loopback binds; `--mdns` defaults the hostname to `0.0.0.0` (`server/mdns.ts:6-20`). It advertises a generic `_http._tcp` service, so an iOS `NWBrowser` must browse `_http._tcp` and filter on names starting with `opencode-`.
* Health: `GET /global/health` → `{healthy: true, version: "1.18.23"}` (auth required).
* Scoping: `?directory=` query, else `x-opencode-directory` header (URI-encoded), else server cwd; `?workspace=` optional; session routes use the session's own directory (`middleware/workspace-routing.ts:69-88, 181-184`; `shared/workspace-routing.ts:20-29`). Gotcha: `GET /session` filters by directory only when `?directory=` is in the query.
* Errors: classic routes use `{name, data:{message,…}}` (`BadRequest` 400, `NotFoundError` 404, `UnknownError` 500).

### 11.3 V1 events

* Two streams: `GET /event` (one directory; payload `{id, type, properties}`) and `GET /global/event` (all directories; envelope `{directory, project?, workspace?, payload}`; server-wide events use `directory: "global"`). Same SSE framing as V2 (`data:` lines only). First event `server.connected`; **heartbeat is a JSON event `server.heartbeat` every 10 s**, not an SSE comment. `/event` ends after `server.instance.disposed` (V1 `server/routes/instance/httpapi/handlers/event.ts:25-87`).
* Event field is **`properties`**, not `data`. The union has 89 types; the chat-relevant ones are `session.created/updated/deleted {sessionID, info}`, `session.status {sessionID, status: idle|busy|retry}`, `session.idle`, `session.error`, `session.diff`, `session.compacted`, `message.updated {info}`, `message.removed`, `message.part.updated {part, time}`, `message.part.removed`, `message.part.delta {sessionID, messageID, partID, field:"text", delta}`, `todo.updated`, `command.executed`, `permission.asked/replied`, `question.asked/replied/rejected`, `pty.*`, `file.edited`, `file.watcher.updated`, `vcs.branch.updated`, `project.updated`, `tui.*`, `installation.*`, `lsp.updated`, `mcp.tools.changed`, `workspace.*`, `worktree.*`.
* `POST /sync/history {aggregateID: lastSeq}` can return missed durable events.

### 11.4 V1 data model in one paragraph

Messages are `{info: UserMessage|AssistantMessage (discriminated by role), parts: Part[]}`. Parts have IDs (`prt_…`) and 12 types: `text, reasoning, file, tool, subtask, step-start, step-finish, snapshot, patch, agent, retry, compaction`. Tool parts carry `callID, tool, state` with states `pending{input, raw} | running{input, title?, metadata?, time.start} | completed{input, output (string), title, metadata, time, attachments?} | error{input, error (string), …}`. Prompting: `POST /session/{id}/message` **blocks until the turn ends**, while `POST /session/{id}/prompt_async` returns 204 immediately; the body takes `parts: (TextPartInput | FilePartInput | AgentPartInput | SubtaskPartInput)[]`, `model {providerID, modelID}`, `agent`, `variant`. Permissions: `{id, sessionID, permission, patterns[], metadata, always[], tool?{messageID, callID}}`, replied with `POST /permission/{id}/reply {reply: once|always|reject, message?}`. Questions: `POST /question/{id}/reply {answers: string[][]}` / `…/reject`. Todos: `GET /session/{id}/todo` + `todo.updated`. Provider OAuth: `POST /provider/{id}/oauth/authorize {method}` → `{url, method: auto|code, instructions}`, then `…/oauth/callback {method, code?}`.

### 11.5 V1 → V2 (HEAD) differences that matter to a client

| Area | V1 (1.18.23) | V2 (2.0.29) |
|---|---|---|
| Base paths | `/session`, `/event`, `/global/*`, … | everything under `/api/*`, plus `/auth/connect/{code}`, `/openapi.json` |
| Health | `GET /global/health` → `{healthy, version}` | `GET /api/info` → `{version, pid, urls, paths, capabilities?}` |
| Auth | optional; username configurable | always on; username fixed `opencode`; pairing tokens; same-origin cookie |
| Discovery | mDNS `_http._tcp` (opt-in) | none; managed-service registration file locally, pairing link/QR remotely |
| Scoping | `?directory=`/header; `?workspace=` | `location[directory]`/header; no workspace selector; responses wrapped `{location, data}` |
| Event streams | `/event` (per directory) + `/global/event` | one `/api/event` for everything |
| Event shape | `{id, type, properties}`; heartbeat event every 10 s | `{id, created, type, data, location?, metadata?, durable?}`; `: heartbeat` comment every 15 s |
| Transcript | `message.*` + `message.part.*` with part IDs and `message.part.delta` | `session.step/text/reasoning/tool/…` events; messages are typed rows; assistant content has no IDs |
| Prompt | blocking `/message` or 204 `/prompt_async`, `parts[]`, model/agent in body | `POST /api/session/{id}/prompt {id?, text, files[{uri}], agents, skills, delivery, resume}` → inbox item; model/agent via `/model`, `/agent` |
| Abort / compaction / revert | `/abort`, `/summarize`, `/revert` + `/unrevert` | `/interrupt`, `/compact`, `/revert/stage` + `DELETE /revert` + `/revert/commit` |
| Permissions | `/permission/{id}/reply {reply}`, `patterns`/`always` | `/api/session/{sid}/permission/{rid}/reply {decision}`, `resources`/`save`, saved-permission API |
| Questions | `/question/*`, answers `string[][]` | forms (`/api/session/{id}/form…`), answers `{[key]: value}` |
| Files and search | `/file`, `/file/content`, `/file/status`, `/find` (text), `/find/file`, `/find/symbol` | `/api/fs/read/*` (bytes), `/api/fs/list`, `/api/fs/find`; no text or symbol search |
| Providers | `/provider`, `/provider/auth`, `/provider/{id}/oauth/*`, `PUT /auth/{id}` | `/api/provider`, `/api/model`, `/api/integration*`, `/api/credential*` |
| Gone in V2 | share, todo, LSP/formatter status, TUI control, `/sync/*`, workspaces, `/path`, `/log`, config PATCH | |
| New in V2 | | inbox (steer/queue), forms, pairing, shells, persistent PTYs, worktree API, plugins/RPC, web search, sessions stats/import/export/generate/environment/view |
| Tools | `bash`, `task`, `apply_patch`, `todowrite`, `list`, `lsp`, … | `shell`, `subagent`, `patch`, CodeMode `execute`; see §9.4 |

**V2 serves no V1 routes.** Outside `/api/*`, `/auth/*` and `/openapi.json`, a V2 server answers `GET` with the web app's `index.html` (200, `text/html`, before auth) and other methods with 405 (`packages/cli/src/services/web-ui.ts:19-31, 46-50`). V1 compatibility in V2 is limited to a one-time import of V1 sessions into the V2 database (`packages/core/src/database/v1-migration*.ts`, status at `GET /api/experimental/migration/v1`) and config normalization. The first-party V2 desktop app marks V1 servers "incompatible" and asks the user to upgrade them (`packages/app/src/runtime/i18n/en.ts:400-401, 534-536`).

### 11.6 How the V2 contract itself evolved (2.0.0 → 2.0.30)

Fetching `packages/protocol/openapi.json` at the V2 tags (raw.githubusercontent.com, `anomalyco/opencode@v2.0.N`) shows how the V2 contract itself moved:

| Tag (npm publish date) | Paths / ops / schemas | Change versus previous checkpoint |
|---|---|---|
| v2.0.0 (2026-09-11) | 119 / 139 / 236 | First V2 release. Still had `/api/health`, `/api/server`, `v2.*` operationIds, `reply`/`command` field names, POST-style inbox steer/queue, form cancel, revert clear |
| v2.0.5 (09-16) | 111 / 134 / 241 | **Breaking audit pass**: every operationId renamed (the `v2.` prefix dropped), 28 method+path pairs removed and 23 added (mostly moves under `/api/experimental` or verb changes), `reply`→`decision`, `command`→`name`, `/api/status` introduced, inbox/form/revert routes reshaped (V2_HTTP_API_AUDIT.md) |
| v2.0.10 (09-19) | 113 / 136 / 245 | `/api/status` replaced by `/api/info`; `location.reload`, `experimental.fs.write` added |
| v2.0.15, v2.0.20 (09-23, 09-29) | 113 / 136 / 245 | additive (`PATCH /api/session` gained `metadata`; new optional schema fields) |
| v2.0.25 (10-08) | 117 / 141 / 256 | additive: credential list/create, **pairing** (`/api/pair`, `/auth/connect/{code}`), `vcs.init`; `parentID` on session create |
| v2.0.29 (10-14) = HEAD | 118 / 142 / 285 | additive: `integration.connect.external`; IDs became named schemas; byte-identical to v2.0.30 |

A field-level comparison of 20 core schemas between v2.0.10 and v2.0.29 found **only additions** (for example `Provider.Info.compatibility?`, `Shell.Info.signal?`, `ServerInfo.capabilities?`, `Connection.CredentialInfo.method/status?`).

### 11.7 What changed for a client from 2.0.32 to 2.2.7

Checked on 2026-11-07 against 2.0.32's and 2.2.6's served `/openapi.json` (both recorded in `Fixtures/v2/`), the generated `types.ts` at each tag and `CHANGELOG.md`. `oasdiff` flags 159 changes as breaking, but almost all are schema-generator noise: query parameters lost `null` from their types, numbers gained a 2^53−1 maximum, boolean query flags became `"true" | "false"` enums, and `location` query parameters are now typed `object` (the deep-object `location[directory]` form clients already send). No operation was removed, and the message, form, statistics and session-info shapes are unchanged apart from the points below.

- **Session archiving (2.1.0).** `PATCH /api/session/{id}` takes `archived: boolean`; `GET /api/session` takes `archived=true|false`, which 2.0.x ignores. The durable `session.archived` and `session.unarchived` events set and clear `time.archived` (at the event's `created`) and update `time.updated`. 2.2.6 adds `opencode run --archived`, which archives the session it creates; the desktop, the TUI and this app keep archived sessions out of their lists.
- **Provider state is `native` (2.1.0).** `state` on text and reasoning, `providerState` on assistant messages and tool calls, and `resultState` on tool results became one opaque `native` object; a tool result's `native` is merged into the call's. Compaction messages and events lost `recent` and `providerContext`.
- **`time.busy` (2.2.2)** on session info: the start of the latest execution.
- **`hostname` (2.2.0)** in `GET /api/info`.
- **New events (2.2.4).** `persistent-pty.updated` (a session terminal's rename, with `userTitle` on `PersistentPty.Info`) and `artifact.updated` (experimental artifacts). The union has 97 fixed types at 2.2.6 and at 2.2.7.
- **File reads (2.2.6).** `GET /api/fs/read/*` answers with `content-disposition: attachment`, `x-content-type-options: nosniff` and a sandboxed CSP, and sends HTML, JavaScript and XML (SVG included) as `text/plain`; images, audio and video keep their type. `/api/*` requests that carry `Sec-Fetch-Site: cross-site` or `same-site` get 403 when they are navigations or come from an origin that is not allowed; clients that send no `Sec-Fetch-*` headers are unaffected.
- **PTY replay** is unchanged: text from the requested cursor, then the control frame at that cursor plus the replayed length. The 2.2.6 recording connects after the shell's greeting and gets it as replay; the 2.0.32 and 2.2.7 ones get it live, after a control frame at 0.

2.2.6 to 2.2.7, checked on 2026-11-11 against both recordings' `/openapi.json` and a live 2.2.7 sandbox: no operation, schema or event type was added or removed.

- **Integrations load after a location boots (2.2.7).** The first `GET /api/integration` for a location that just booted can answer an empty list; `integration.updated` follows once the integrations load (about 0.1 s later in a sandbox), and the list is complete from then on. A client reloads the list on that event.
- **Plugins load after a location boots (2.2.7).** Until they have, a plugin's `POST /api/rpc/<id>/<method>` answers 400 with `{"_tag":"RpcError","type":"rpc.unavailable"}` (about half a second in a sandbox; 2.2.6 answered at once). A server without the plugin gives the same answer, at any time and in every release, so a client cannot tell the two apart: the app reports the push registration unavailable and tries again on its next connection or refresh.
- **Generated text reports its usage (2.2.7).** `POST /api/session/{id}/generate` answers `tokens` and `cost` beside `text`, and they count toward the session's usage: `session.usage.recorded` has a `generate` source. `Generate.PredicateQuestion` takes optional `criteria` with `true` and `false` descriptions.
- **`credential.updated` names the credential (2.2.7):** `integrationID` and `credentialID`.
- **`experimental.console_watches` (2.2.7)** in the configuration lets Console event watches wake sessions. `GET /api/agent` no longer lists a 503 response.

## 12. Stability, versioning and capability detection

### 12.1 Release lines and cadence

| | V1 (`opencode-ai`) | V2 (`@opencode/cli`) |
|---|---|---|
| Latest | v1.19.1 (2026-10-15) | 2.0.30 (2026-10-15) |
| Cadence | 2.6 releases/week over the last 91 days; about 1.4/week since V2 launched | 31 releases in 5 weeks (2.0.0 on 2026-09-11 → 2.0.30), about 6/week, median gap under a day (npm publish times) |
| Release notes | GitHub Releases (all 300 recent releases are V1) | `CHANGELOG.md` from 2.0.26 on, `opencode.ai/changelog`; **no GitHub Releases for v2.* tags** (`/releases/tags/v2.0.29` returns 404) |
| Install | `opencode.ai/install`, npm `opencode-ai`, brew `opencode` or `anomalyco/tap/opencode` | `curl -fsSL https://opencode.ai/v2/install \| bash` (`packages/cli/src/services/updater.ts:482-483`), npm `@opencode/cli`, brew `anomalyco/tap/opencode-v2`, WinGet `Anomaly.OpenCode` (CHANGELOG v2.0.28). V1 users run `opencode upgrade --major`, which reinstalls via the V2 installer, `@opencode/cli`, or the `opencode-v2` brew formula (V1 v1.19.1 `packages/opencode/src/installation/index.ts:88-103, 154-156, 195-213`) |
| Status | Maintenance: API frozen (identical operation set from 1.18.0 to 1.19.1), sharing discontinued in 1.19.1 | Active development; the default branch is V2 |

Both lines install a binary named `opencode` and are no longer installed side by side (`services/www/src/docs/content/migrate-v1.mdx:5-6`). The machine you will test against (v1.18.23) is **V1**: to develop against V2, upgrade it (`opencode upgrade --major`) or install V2 on another machine, VM or container.

### 12.2 Versioning scheme of the API

* There is **no API version**. `info.version` is a constant (`0.0.1` in V2, `1.0.0` in V1), there is no version header, and paths are not versioned (`/api/...` is the V2 namespace, not a version).
* The only version signal is the **product version** in `GET /api/info` (`version`, semver like `2.0.29`; preview builds look like `0.0.0-<channel>-<n>`, `packages/script/src/index.ts:36-40`) and optional `capabilities` flags ("optional at every level so clients still decode servers that predate a capability", `packages/protocol/src/groups/server.ts:13-18`). Only one capability flag exists today (`persistentPty`).
* Stability tiers come from the path: `/api/experimental/*` and the persistent-PTY routes are "outside the stable API commitment"; everything else was reviewed in `V2_HTTP_API_AUDIT.md` (dispositions Keep/Change/Remove) and is intended to be the supported V2 surface. Group descriptions in the spec still say "Experimental … routes", and `info.description` says "Experimental HttpApi surface…", so treat even the "stable" surface as young.
* Generated TypeScript clients (`@opencode/client`, `@opencode/sdk`) are versioned in lockstep with the CLI (all 2.0.30), which is how the first-party apps stay compatible: the TUI replaces a background service whose version differs from its own (`packages/cli/src/commands/handlers/default.ts:35-46`), and the desktop pins the service to its bundled CLI version (`packages/desktop/src/main/service/background-service.ts:32-92`). **A third-party client has no such guarantee**: it will meet servers older and newer than the one it was built against.

### 12.3 How often breaking changes landed

* V2 contract: the first week was breaking (v2.0.0 → v2.0.5 → v2.0.10: renamed fields, removed and moved routes, `/api/health` → `/api/status` → `/api/info`; §11.6). From **v2.0.10 (2026-09-19) to v2.0.30** the HTTP contract only grew: new endpoints and new optional fields, no removals or renames in the operations and the 20 core schemas compared.
* Event schemas carry per-type versions (`durable.version`; for example `session.tool.success`/`failed`, `session.deleted`, `session.forked` and `session.instructions.updated` are already at version 2), and the published union always uses the latest version (`packages/schema/src/event.ts:156-172`). A client must tolerate new event types, new fields and changed durable versions.
* Behavioural changes still land often (for example 2.0.30 removed the share backend; 2.0.29 added automatic continuation after output-length limits). Watch `CHANGELOG.md` and re-diff `openapi.json` and the generated `types.ts` on every release.

### 12.4 Recommended detection and compatibility strategy for iOS

1. **Probe the line.** `GET /api/info` with credentials:
   * `200 application/json {version, pid, …}` → V2; parse `version`.
   * `503` + `Retry-After` → V2 starting; retry.
   * `401` with JSON body `{"_tag":"UnauthorizedError",…}` → V2, wrong credentials.
   * `401` with an **empty** body → probably V1 with a password (V1 classic routes answer 401 without a body).
   * `200 text/html` (the V1 UI catch-all) or `404` → not V2. Then `GET /global/health`: JSON `{healthy, version}` → **V1**. The official app shows V1 servers as "incompatible, upgrade to OpenCode V2" (`packages/app/src/runtime/i18n/en.ts:400-401`).
2. **Gate features by version**, with a floor of **2.0.10** (first release with `/api/info` and the audited contract; earlier 2.0.x servers have incompatible routes) and **2.0.25** for pairing and credential management. For finer checks, fetch `GET /openapi.json` once per connection and test for the presence of an operation (`paths[...]`): it is authoritative for routes, though not for events.
3. **Decode tolerantly**: ignore unknown JSON keys (do not use strict `additionalProperties: false` decoding), map unknown `type`/`status` discriminators to `.unknown`, treat absent and `null` alike, and never crash on an unknown event type.
4. **Expect 404 for unknown routes** on V2 (`/api/*` misses return an empty 404, `packages/cli/src/services/web-ui.ts:24-27`), which is a cheap feature probe for optional endpoints.
5. **Pin your test matrix**: the oldest supported 2.0.x, the current release, and the `main`/dev build (preview builds report versions like `0.0.0-dev-<n>`).

## 13. Gotchas checklist for the iOS implementation

**Connection and auth**
1. The installed opencode (1.18.23) is **V1**; V2 needs `opencode upgrade --major` or a separate install. Detect the line before anything else (§12.4).
2. V2 has **no Bonjour/mDNS**. Onboard with a pairing link/QR (`{code, urls}`), or manual URL + password.
3. LAN access is **plain HTTP**: configure ATS exceptions (`NSAllowsLocalNetworking` / per-host) and request Local Network access. HTTPS exists only through OpenTunnel or a user's reverse proxy.
4. Username is always `opencode`; `Bearer` is rejected; the pairing token is used **as the Basic password**; tokens last 30 days, have no refresh, and die when the server password changes. Re-pair on 401.
5. `/api/info` and `/openapi.json` need auth. A V2 server answers unknown non-API `GET`s with the web app's HTML (200): always check `Content-Type` before decoding.
6. Without a location the server uses **its own cwd** (`$HOME` for the managed service). Always send `location[directory]` (or `x-opencode-directory`, percent-encoded), and always pass `location` to `POST /api/session`.

**Events and sync**
7. `/api/event` has **no replay** and is killed (not throttled) when a client falls 4096 events behind. Resync on every `server.connected`; run a 45 s silence watchdog; force a reconnect when returning to the foreground.
8. `server.connected` has no `created` field. Heartbeats are SSE comments, not events.
9. Deltas (`*.delta`, `session.tool.progress`, `session.usage.updated`) are ephemeral. Drop deltas for rows you do not have and rely on `*.ended` / HTTP refetch.
10. `session.tool.input.delta` is declared but **never emitted** at HEAD; `session.status`, `session.idle` and `tui.*` are declared but have no server-side emitter. Derive busy/idle from `session.execution.*` and `GET /api/session/active`.
11. `durable.seq` gaps are normal (internal events are filtered), so do not use them for loss detection.
12. No global ordering between concurrent sources (provider stream versus tool fibers): key tools by `id`, text/reasoning by `ordinal` or the latest open item, rows by `assistantMessageID`.
13. Delivered user prompts move to the end of the transcript with the delivery time; queued prompts stay hidden until delivered; messages with `id >= revert.messageID` are hidden while a revert is staged.

**Requests**
14. Prompts carry no model or agent: call `POST …/agent` and `POST …/model {providerID, id, variant}` first (no-ops when unchanged). Reasoning effort = model `variant`.
15. Mint `msg_` IDs for prompts (ascending ID format, §4.4) to make retries idempotent and to render optimistically; reusing an ID with different content → 409.
16. Attachments: `data:` URLs need canonical base64; `file://` URLs refer to the **server's** filesystem; 20 MiB cap.
17. `POST …/fork` creates a **top-level** session (`fork` field, no `parentID`) and emits only `session.forked`.
18. Permission `reject` without a message ends the turn and rejects every pending request of that session; `always` persists `save` patterns per project. Pending permissions/forms are in-memory and vanish on restart or `location.reload`.
19. Most OAuth integrations use loopback redirects **on the server machine** (`mode: "auto"`); they cannot complete in Safari on the phone. Offer key-based methods or a "finish on your computer" flow and poll the attempt status.
20. `GET /api/credential` returns raw secrets. Do not cache it.
21. `DELETE /api/worktree` takes a JSON body; `GET /api/fs/read/<path>` is a wildcard route not modelled as a path parameter.
22. Send absent keys instead of `null`; accept `null` and non-finite-number strings (`"NaN"`, `"Infinity"`) when decoding.

**Rendering**
23. Shell tool output is not streamed in events: poll `GET /api/shell/{metadata.shellID}/output`; a non-zero exit is still `completed` (check `metadata.exit`). Output is retained only for the last 25 exited shells.
24. `write` has no diff metadata (render `input.content`); `edit`/`patch` provide `metadata.files: FileDiff[]`.
25. Subagents: `metadata.sessionID` links the child session; its events stream on the same connection.
26. MCP and plugin tools usually run inside the CodeMode `execute` tool; render `metadata.toolCalls`.
27. Migrated V1 history still contains V1 tool names (`bash`, `task`, `apply_patch`, `todowrite`) and V1-shaped metadata.

**Terminals**
28. Terminal output arrives as **text** frames; the only binary frame is `0x00` + `{"cursor":n}`. The cursor counts **UTF-16 code units**; resize is `PUT /api/pty/{id}`; tickets need `x-opencode-ticket: 1` and expire in 60 s. A native client can authenticate the upgrade with Basic auth instead.

**Codegen**
29. Do not use swift-openapi-generator on the raw spec: `additionalProperties:false` makes decoding fail on any new field, unions are discriminator-less `anyOf`, and the event union is missing. Hand-write the core models with tolerant decoding (§10.4).
30. Re-check `CHANGELOG.md`, `openapi.json` and `packages/client/src/promise/generated/types.ts` on every release (V2 ships almost daily).

## Appendix A. Complete V2 operation list (generated from `packages/protocol/openapi.json` at d0732ea)

Every operation in the spec, in document order. `location (q)` = the deepObject query parameter `location[directory]=<abs path>` (alternatively the `x-opencode-directory` header). In parameters and request bodies, optional fields are shown with `?` and the spec's `| null` alternatives are omitted (send absent keys, not `null`). In responses, `| null` is kept where the value itself is nullable. Every operation can also return `400 InvalidRequestError` (schema rejection) and `401 UnauthorizedError`; those two are omitted from the Errors column.

| # | Method | Path | operationId | Parameters | Request body | Success | Errors (besides 400/401) |
|---|---|---|---|---|---|---|---|
| 1 | GET | `/api/info` | `server.info` | — | — | 200 ServerInfo | — |
| 2 | POST | `/api/pair` | `server.pair` | — | — | 200 PairingCode | — |
| 3 | GET | `/auth/connect/{code}` | `server.connect` | code (path): string | — | 200 PairingSession | — |
| 4 | GET | `/api/location` | `location.get` | location (q) | — | 200 Location.PublicInfo | 404 LocationNotFoundError |
| 5 | POST | `/api/location/reload` | `location.reload` | — | — | 204 (no content) | 503 ServiceUnavailableError |
| 6 | GET | `/api/agent` | `agent.list` | location (q) | — | 200 { location: Location.PublicRef, data: Agent.Info[] } | 404 LocationNotFoundError |
| 7 | GET | `/api/agent/{agentID}` | `agent.get` | agentID (path): Agent.ID; location (q) | — | 200 { location: Location.PublicRef, data: Agent.Info } | 404 AgentNotFoundError \| LocationNotFoundError |
| 8 | GET | `/api/plugin` | `plugin.list` | location (q) | — | 200 { location: Location.PublicRef, data: Plugin.Info[] } | 404 LocationNotFoundError |
| 9 | POST | `/api/plugin/check` | `plugin.check` | location (q) | { target?: string } | 200 { location: Location.PublicRef, data: Plugin.Info[] } | 404 LocationNotFoundError |
| 10 | POST | `/api/plugin/update` | `plugin.update` | location (q) | { targets: string[] } | 204 (no content) | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 11 | GET | `/api/session` | `session.list` | limit (q): string; order (q): "asc"\|"desc"; search (q): string; parentID (q): Session.ID \| "null"; directory (q): AbsolutePath; project (q): Project.ID; subpath (q): RelativePath; cursor (q): SessionsCursor | — | 200 SessionsResponse | 400 InvalidCursorError |
| 12 | POST | `/api/session` | `session.create` | — | { id?: Session.ID, parentID?: Session.ID, title?: string, agent?: Agent.ID, model?: Model.Ref, location?: Location.PublicRef, metadata?: Session.Metadata, permissions?: Permission.Ruleset } | 200 { data: Session.Info } | 404 SessionNotFoundError |
| 13 | GET | `/api/experimental/session/stats` | `experimental.session.stats` | from (q): string; to (q): string; project (q): Project.ID; timezone (q): string; tools (q): "none"\|"summary"\|"detail" | — | 200 { data: SessionStats.Info } | — |
| 14 | POST | `/api/experimental/session/import` | `experimental.session.import` | — | { info: Session.Info, messages: Session.Message.Info[], location?: Location.PublicRef } | 200 { data: Session.Info } | 404 SessionNotFoundError, 409 ConflictError |
| 15 | GET | `/api/experimental/session/{sessionID}/export` | `experimental.session.export` | sessionID (path): Session.ID; sanitize (q): "true"\|"false" | — | 200 { data: SessionTransfer.Data } | 404 SessionNotFoundError, 500 UnknownError |
| 16 | GET | `/api/session/active` | `session.active` | — | — | 200 { data: Record<pattern,SessionActive> } | — |
| 17 | GET | `/api/session/{sessionID}` | `session.get` | sessionID (path): Session.ID | — | 200 { data: Session.Info } | 404 SessionNotFoundError |
| 18 | DELETE | `/api/session/{sessionID}` | `session.remove` | sessionID (path): Session.ID | — | 204 (no content) | 404 SessionNotFoundError |
| 19 | PATCH | `/api/session/{sessionID}` | `session.update` | sessionID (path): Session.ID | { title?: string, metadata?: Session.Metadata, permissions?: Permission.Ruleset } | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 20 | POST | `/api/session/{sessionID}/fork` | `session.fork` | sessionID (path): Session.ID | { before?: Session.Message.ID } | 200 { data: Session.Info } | 404 SessionNotFoundError \| MessageNotFoundError \| LocationNotFoundError |
| 21 | POST | `/api/session/{sessionID}/agent` | `session.switchAgent` | sessionID (path): Session.ID | { agent: Agent.ID } | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 22 | POST | `/api/session/{sessionID}/model` | `session.switchModel` | sessionID (path): Session.ID | { model: Model.Ref } | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 23 | POST | `/api/session/{sessionID}/move` | `session.move` | sessionID (path): Session.ID | { directory: AbsolutePath, delivery?: Session.Inbox.Delivery } | 204 (no content) | 404 SessionNotFoundError |
| 24 | POST | `/api/session/{sessionID}/prompt` | `session.prompt` | sessionID (path): Session.ID | { id?: Session.Message.ID, text: string, files?: PromptInput.FileAttachment[], agents?: Prompt.AgentAttachment[], skills?: PromptInput.SkillAttachment[], metadata?: object, delivery?: Session.Inbox.Delivery, resume?: boolean } | 200 { data: Session.Inbox.User } | 404 SessionNotFoundError \| LocationNotFoundError, 409 ConflictError |
| 25 | POST | `/api/session/{sessionID}/command` | `session.command` | sessionID (path): Session.ID | { name: string, text: string, files?: PromptInput.FileAttachment[], agents?: Prompt.AgentAttachment[], skills?: PromptInput.SkillAttachment[], delivery?: Session.Inbox.Delivery } | 204 (no content) | 404 SessionNotFoundError \| CommandNotFoundError \| LocationNotFoundError, 500 CommandExecutionError |
| 26 | POST | `/api/experimental/session/{sessionID}/skill` | `experimental.session.skill` | sessionID (path): Session.ID | { id: Skill.ID, resume?: boolean } | 204 (no content) | 404 SessionNotFoundError \| SkillNotFoundError \| LocationNotFoundError |
| 27 | POST | `/api/session/{sessionID}/synthetic` | `session.synthetic` | sessionID (path): Session.ID | { id?: Session.Message.ID, text: string, description?: string, metadata?: object, delivery?: Session.Inbox.Delivery, resume?: boolean } | 200 { data: Session.Inbox.Synthetic } | 404 SessionNotFoundError \| LocationNotFoundError, 409 ConflictError |
| 28 | POST | `/api/session/{sessionID}/shell` | `session.shell` | sessionID (path): Session.ID | { id?: Session.Message.ID, command: string } | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 29 | POST | `/api/session/{sessionID}/compact` | `session.compact` | sessionID (path): Session.ID | { id?: Session.Message.ID, delivery?: Session.Inbox.Delivery } | 200 { data: Session.Inbox.Compaction } | 404 SessionNotFoundError \| LocationNotFoundError, 409 ConflictError |
| 30 | POST | `/api/experimental/session/{sessionID}/wait` | `experimental.session.wait` | sessionID (path): Session.ID | — | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError, 503 ServiceUnavailableError |
| 31 | POST | `/api/session/{sessionID}/revert/stage` | `session.revert.stage` | sessionID (path): Session.ID | { messageID: Session.Message.ID, files?: boolean } | 200 { data: Session.Revert } | 404 MessageNotFoundError \| SessionNotFoundError \| LocationNotFoundError, 409 SessionBusyError, 500 UnknownError |
| 32 | DELETE | `/api/session/{sessionID}/revert` | `session.revert.clear` | sessionID (path): Session.ID | — | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError, 409 SessionBusyError, 500 UnknownError |
| 33 | POST | `/api/session/{sessionID}/revert/commit` | `session.revert.commit` | sessionID (path): Session.ID | — | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError, 409 SessionBusyError |
| 34 | GET | `/api/session/{sessionID}/context` | `session.context` | sessionID (path): Session.ID | — | 200 { data: Session.Message.Info[] } | 404 SessionNotFoundError, 500 UnknownError |
| 35 | GET | `/api/session/{sessionID}/diff` | `session.diff` | sessionID (path): Session.ID; from (q): Session.Message.ID; to (q): Session.Message.ID; context (q): string | — | 200 { data: FileDiff.Info[] } | 404 MessageNotFoundError \| SessionNotFoundError \| LocationNotFoundError, 500 UnknownError |
| 36 | GET | `/api/session/{sessionID}/inbox` | `session.inbox.list` | sessionID (path): Session.ID | — | 200 { data: Session.Inbox.Info[] } | 404 SessionNotFoundError |
| 37 | DELETE | `/api/session/{sessionID}/inbox/{inboxID}` | `session.inbox.cancel` | sessionID (path): Session.ID; inboxID (path): Session.Message.ID | — | 204 (no content) | 404 SessionNotFoundError |
| 38 | PATCH | `/api/session/{sessionID}/inbox/{inboxID}` | `session.inbox.update` | sessionID (path): Session.ID; inboxID (path): Session.Message.ID | { delivery: Session.Inbox.Delivery } | 204 (no content) | 404 SessionNotFoundError, 409 ConflictError |
| 39 | GET | `/api/experimental/session/{sessionID}/instructions/entries` | `experimental.session.instructions.entry.list` | sessionID (path): Session.ID | — | 200 { data: InstructionEntry.Info[] } | 404 SessionNotFoundError \| LocationNotFoundError |
| 40 | PUT | `/api/experimental/session/{sessionID}/instructions/entries/{key}` | `experimental.session.instructions.entry.put` | sessionID (path): Session.ID; key (path): InstructionEntry.Key | { value: any } | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError, 413 InstructionEntryValueTooLargeError |
| 41 | DELETE | `/api/experimental/session/{sessionID}/instructions/entries/{key}` | `experimental.session.instructions.entry.remove` | sessionID (path): Session.ID; key (path): InstructionEntry.Key | — | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 42 | POST | `/api/session/{sessionID}/generate` | `session.generate` | sessionID (path): Session.ID | { prompt: string } | 200 SessionGenerateResponse | 404 SessionNotFoundError \| LocationNotFoundError, 503 ServiceUnavailableError |
| 43 | GET | `/api/experimental/session/{sessionID}/log` | `session.log` | sessionID (path): Session.ID; after (q): Event.SeqEncoded; follow (q): "true"\|"false" | — | 200 text/event-stream: { id?: string, event: string, data: SessionLogItemEncoded } | 404 SessionNotFoundError |
| 44 | POST | `/api/session/{sessionID}/interrupt` | `session.interrupt` | sessionID (path): Session.ID; resume (q): "true"\|"false" | — | 200 SessionInterruptResponse | 404 SessionNotFoundError \| LocationNotFoundError |
| 45 | POST | `/api/session/{sessionID}/background` | `session.background` | sessionID (path): Session.ID | — | 204 (no content) | 404 SessionNotFoundError \| LocationNotFoundError |
| 46 | GET | `/api/session/{sessionID}/message/{messageID}` | `session.message.get` | sessionID (path): Session.ID; messageID (path): Session.Message.ID | — | 200 { data: Session.Message.Info } | 404 SessionNotFoundError \| MessageNotFoundError |
| 47 | GET | `/api/session/{sessionID}/form` | `session.form.list` | sessionID (path): string | — | 200 { data: Form.Info[] } | 404 SessionNotFoundError \| LocationNotFoundError |
| 48 | POST | `/api/session/{sessionID}/form` | `session.form.create` | sessionID (path): string | Form.CreatePayload | 200 { data: Form.Info } | 404 SessionNotFoundError \| LocationNotFoundError, 409 ConflictError |
| 49 | GET | `/api/session/{sessionID}/form/{formID}` | `session.form.get` | sessionID (path): string; formID (path): Form.ID | — | 200 { data: Form.Detail } | 404 SessionNotFoundError \| FormNotFoundError \| LocationNotFoundError |
| 50 | DELETE | `/api/session/{sessionID}/form/{formID}` | `session.form.cancel` | sessionID (path): string; formID (path): Form.ID; message (q): string | — | 204 (no content) | 404 SessionNotFoundError \| FormNotFoundError \| LocationNotFoundError, 409 FormAlreadySettledError |
| 51 | POST | `/api/session/{sessionID}/form/{formID}/reply` | `session.form.reply` | sessionID (path): string; formID (path): Form.ID | Form.Reply | 204 (no content) | 400 FormInvalidAnswerError, 404 SessionNotFoundError \| FormNotFoundError \| LocationNotFoundError, 409 FormAlreadySettledError |
| 52 | PUT | `/api/session/{sessionID}/environment` | `session.environment` | sessionID (path): Session.ID | { variables: Record<string,string> } | 204 (no content) | 404 SessionNotFoundError |
| 53 | POST | `/api/session/{sessionID}/view` | `session.view` | sessionID (path): Session.ID | { idle: number } | 204 (no content) | 404 SessionNotFoundError |
| 54 | GET | `/api/session/{sessionID}/message` | `session.message.list` | sessionID (path): Session.ID; limit (q): string; order (q): "asc"\|"desc"; cursor (q): string; type (q): "agent-switched"\|"model-switched"\|"location-switched"\|"user"\|"synthetic"\|"system"\|"skill"\|"shell"\|"assistant"\|"compaction" | — | 200 SessionMessagesResponse | 400 InvalidCursorError, 404 SessionNotFoundError, 500 UnknownError |
| 55 | GET | `/api/model` | `model.list` | location (q) | — | 200 { location: Location.PublicRef, data: Model.Info[] } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 56 | GET | `/api/model/default` | `model.default` | location (q) | — | 200 { location: Location.PublicRef, data: Model.Info \| null } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 57 | POST | `/api/experimental/generate` | `experimental.generate.text` | — | { prompt: string, model?: Model.Ref } | 200 GenerateTextResponse | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 58 | GET | `/api/provider` | `provider.list` | location (q) | — | 200 { location: Location.PublicRef, data: Provider.Info[] } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 59 | GET | `/api/provider/{providerID}` | `provider.get` | providerID (path): Provider.ID; location (q) | — | 200 { location: Location.PublicRef, data: Provider.Info } | 404 ProviderNotFoundError \| LocationNotFoundError, 503 ServiceUnavailableError |
| 60 | GET | `/api/integration` | `integration.list` | location (q) | — | 200 { location: Location.PublicRef, data: Integration.Info[] } | 404 LocationNotFoundError |
| 61 | GET | `/api/integration/{integrationID}` | `integration.get` | integrationID (path): Integration.ID; location (q) | — | 200 { location: Location.PublicRef, data: Integration.Info } | 404 IntegrationNotFoundError \| LocationNotFoundError |
| 62 | POST | `/api/experimental/integration/wellknown` | `experimental.integration.wellknown.add` | location (q) | { url: string } | 204 (no content) | 404 LocationNotFoundError |
| 63 | POST | `/api/integration/{integrationID}/connect/key` | `integration.connect.key` | integrationID (path): Integration.ID; location (q) | { key: string, answer?: Form.Answer, label?: string } | 204 (no content) | 404 IntegrationNotFoundError \| LocationNotFoundError |
| 64 | POST | `/api/integration/{integrationID}/connect/external` | `integration.connect.external` | integrationID (path): Integration.ID; location (q) | { methodID: Integration.MethodID, answer?: Form.Answer, label?: string } | 204 (no content) | 404 IntegrationNotFoundError \| LocationNotFoundError |
| 65 | POST | `/api/integration/{integrationID}/connect/oauth` | `integration.oauth.connect` | integrationID (path): Integration.ID; location (q) | { methodID: Integration.MethodID, answer?: Form.Answer, label?: string } | 200 { location: Location.PublicRef, data: Integration.AttemptEncoded } | 404 LocationNotFoundError |
| 66 | GET | `/api/integration/{integrationID}/connect/oauth/{attemptID}` | `integration.oauth.status` | integrationID (path): Integration.ID; attemptID (path): Integration.AttemptID; location (q) | — | 200 { location: Location.PublicRef, data: Integration.AttemptStatus } | 404 IntegrationNotFoundError \| IntegrationAttemptNotFoundError \| LocationNotFoundError |
| 67 | DELETE | `/api/integration/{integrationID}/connect/oauth/{attemptID}` | `integration.oauth.cancel` | integrationID (path): Integration.ID; attemptID (path): Integration.AttemptID; location (q) | — | 204 (no content) | 404 LocationNotFoundError |
| 68 | POST | `/api/integration/{integrationID}/connect/oauth/{attemptID}/complete` | `integration.oauth.complete` | integrationID (path): Integration.ID; attemptID (path): Integration.AttemptID; location (q) | { code?: string } | 204 (no content) | 404 IntegrationNotFoundError \| IntegrationAttemptNotFoundError \| LocationNotFoundError |
| 69 | POST | `/api/integration/{integrationID}/connect/command` | `integration.command.connect` | integrationID (path): Integration.ID; location (q) | { methodID: Integration.MethodID, label?: string } | 200 { location: Location.PublicRef, data: Integration.CommandAttempt } | 404 IntegrationNotFoundError \| IntegrationMethodNotFoundError \| LocationNotFoundError |
| 70 | GET | `/api/integration/{integrationID}/connect/command/{attemptID}` | `integration.command.status` | integrationID (path): Integration.ID; attemptID (path): Integration.AttemptID; location (q) | — | 200 { location: Location.PublicRef, data: Integration.CommandAttemptStatus } | 404 IntegrationNotFoundError \| IntegrationAttemptNotFoundError \| LocationNotFoundError |
| 71 | DELETE | `/api/integration/{integrationID}/connect/command/{attemptID}` | `integration.command.cancel` | integrationID (path): Integration.ID; attemptID (path): Integration.AttemptID; location (q) | — | 204 (no content) | 404 LocationNotFoundError |
| 72 | GET | `/api/mcp` | `mcp.list` | location (q) | — | 200 { location: Location.PublicRef, data: Mcp.Server[] } | 404 LocationNotFoundError |
| 73 | PUT | `/api/experimental/mcp/{server}` | `experimental.mcp.add` | server (path): string; location (q) | { config: Mcp.LocalConfigEncoded \| Mcp.RemoteConfigEncoded } | 204 (no content) | 404 LocationNotFoundError |
| 74 | DELETE | `/api/experimental/mcp/{server}` | `experimental.mcp.remove` | server (path): string; location (q) | — | 204 (no content) | 404 McpServerNotFoundError \| LocationNotFoundError |
| 75 | POST | `/api/experimental/mcp/{server}/connect` | `experimental.mcp.connect` | server (path): string; location (q) | — | 204 (no content) | 404 McpServerNotFoundError \| LocationNotFoundError |
| 76 | POST | `/api/experimental/mcp/{server}/disconnect` | `experimental.mcp.disconnect` | server (path): string; location (q) | — | 204 (no content) | 404 McpServerNotFoundError \| LocationNotFoundError |
| 77 | GET | `/api/mcp/resource` | `mcp.resource.catalog` | location (q) | — | 200 { location: Location.PublicRef, data: Mcp.ResourceCatalog } | 404 LocationNotFoundError |
| 78 | GET | `/api/credential` | `credential.list` | — | — | 200 { data: Credential.Entry[] } | — |
| 79 | POST | `/api/credential` | `credential.create` | — | Credential.CreateInput | 200 { data: Credential.Entry } | 409 ConflictError |
| 80 | PATCH | `/api/credential/{credentialID}` | `credential.update` | credentialID (path): Credential.ID | { label: string } | 204 (no content) | — |
| 81 | DELETE | `/api/credential/{credentialID}` | `credential.remove` | credentialID (path): Credential.ID | — | 204 (no content) | — |
| 82 | POST | `/api/credential/{credentialID}/activate` | `credential.activate` | credentialID (path): Credential.ID | — | 204 (no content) | — |
| 83 | GET | `/api/project` | `project.list` | archived (q): "true"\|"false" | — | 200 Project[] | 404 LocationNotFoundError |
| 84 | PATCH | `/api/project/{projectID}` | `project.update` | projectID (path): Project.ID | { canonical?: AbsolutePath, name?: string, icon?: Project.Icon, commands?: Project.Commands } | 200 Project | 404 ProjectNotFoundError \| LocationNotFoundError |
| 85 | GET | `/api/form` | `form.list` | location (q) | — | 200 { location: Location.PublicRef, data: Form.Info[] } | 404 LocationNotFoundError |
| 86 | GET | `/api/permission/request` | `permission.request.list` | location (q) | — | 200 { location: Location.PublicRef, data: Permission.Request[] } | 404 LocationNotFoundError |
| 87 | GET | `/api/permission/saved` | `permission.saved.list` | projectID (q): Project.ID | — | 200 { data: PermissionSaved.Info[] } | 404 LocationNotFoundError |
| 88 | DELETE | `/api/permission/saved/{id}` | `permission.saved.remove` | id (path): PermissionSaved.ID | — | 204 (no content) | 404 LocationNotFoundError |
| 89 | POST | `/api/session/{sessionID}/permission` | `session.permission.create` | sessionID (path): Session.ID | { id?: Permission.ID, action: string, resources: string[], save?: string[], metadata?: object, source?: Permission.Source, agent?: Agent.ID } | 200 { data: { id: Permission.ID, effect: Permission.Effect } } | 404 SessionNotFoundError \| LocationNotFoundError |
| 90 | GET | `/api/session/{sessionID}/permission` | `session.permission.list` | sessionID (path): Session.ID | — | 200 { data: Permission.Request[] } | 404 SessionNotFoundError \| LocationNotFoundError |
| 91 | GET | `/api/session/{sessionID}/permission/{requestID}` | `session.permission.get` | sessionID (path): Session.ID; requestID (path): Permission.ID | — | 200 { data: Permission.Request } | 404 SessionNotFoundError \| PermissionNotFoundError \| LocationNotFoundError |
| 92 | POST | `/api/session/{sessionID}/permission/{requestID}/reply` | `session.permission.reply` | sessionID (path): Session.ID; requestID (path): Permission.ID | { decision: Permission.Reply, message?: string } | 204 (no content) | 404 SessionNotFoundError \| PermissionNotFoundError \| LocationNotFoundError |
| 93 | GET | `/api/fs/read/*` | `fs.read` | location (q) | — | 200 application/octet-stream: string(binary) | 404 FileNotFoundError \| LocationNotFoundError |
| 94 | GET | `/api/fs/list` | `fs.list` | location (q); path (q): string | — | 200 { location: Location.PublicRef, data: FileSystem.Entry[] } | 404 FileNotFoundError \| LocationNotFoundError |
| 95 | GET | `/api/fs/find` | `fs.find` | location (q); query (q, required): string; type (q): "file"\|"directory"; limit (q): string | — | 200 { location: Location.PublicRef, data: FileSystem.Entry[] } | 404 LocationNotFoundError |
| 96 | POST | `/api/experimental/fs/write` | `experimental.fs.write` | location (q); path (q, required): string | application/octet-stream: string(binary) | 200 { location: Location.PublicRef, data: FileSystem.Write } | 404 LocationNotFoundError |
| 97 | GET | `/api/command` | `command.list` | location (q) | — | 200 { location: Location.PublicRef, data: Command.Info[] } | 404 LocationNotFoundError |
| 98 | GET | `/api/skill` | `skill.list` | location (q) | — | 200 { location: Location.PublicRef, data: Skill.Info[] } | 404 LocationNotFoundError |
| 99 | POST | `/api/rpc/{rpcID}/{method}` | `rpc.call` | rpcID (path): string; method (path): string; location (q) | Rpc.Input | 200 Rpc.Output | 400 RpcError, 404 LocationNotFoundError, 500 RpcInternalError |
| 100 | GET | `/api/event` | `event.subscribe` | — | — | 200 text/event-stream: { id?: string, event: string, data: V2EventEncoded } | — |
| 101 | GET | `/api/pty` | `pty.list` | location (q) | — | 200 { location: Location.PublicRef, data: Pty[] } | 404 LocationNotFoundError |
| 102 | POST | `/api/pty` | `pty.create` | location (q) | { command?: string, args?: string[], cwd?: string, title?: string, env?: Record<string,string> } | 200 { location: Location.PublicRef, data: Pty } | 404 LocationNotFoundError |
| 103 | GET | `/api/pty/{ptyID}` | `pty.get` | ptyID (path): Pty.ID; location (q) | — | 200 { location: Location.PublicRef, data: Pty } | 404 PtyNotFoundError \| LocationNotFoundError |
| 104 | PUT | `/api/pty/{ptyID}` | `pty.update` | ptyID (path): Pty.ID; location (q) | { title?: string, size?: { rows: integer, cols: integer } } | 200 { location: Location.PublicRef, data: Pty } | 404 PtyNotFoundError \| LocationNotFoundError |
| 105 | DELETE | `/api/pty/{ptyID}` | `pty.remove` | ptyID (path): Pty.ID; location (q) | — | 204 (no content) | 404 PtyNotFoundError \| LocationNotFoundError |
| 106 | POST | `/api/pty/{ptyID}/connect-token` | `pty.connect.token` | ptyID (path): Pty.ID; x-opencode-ticket (header): string; location (q) | — | 200 { location: Location.PublicRef, data: PtyTicket.ConnectToken } | 403 ForbiddenError, 404 PtyNotFoundError \| LocationNotFoundError |
| 107 | GET | `/api/pty/{ptyID}/connect` (WebSocket upgrade) | `pty.connect` | ptyID (path): Pty.ID; location[directory] (q): string; cursor (q): string; ticket (q): string | — | 200 boolean | 403 ForbiddenError, 404 PtyNotFoundError \| LocationNotFoundError |
| 108 | GET | `/api/experimental/session/{sessionID}/terminal/read` | `server.experimental.persistentPty.read` | sessionID (path): Session.ID; lines (q): PersistentPty.ReadLinesEncoded | — | 200 { data: PersistentPty.ReadResult \| null } | 503 ServiceUnavailableError |
| 109 | GET | `/api/experimental/session/{sessionID}/terminal` | `server.experimental.persistentPty.list` | sessionID (path): Session.ID | — | 200 { data: PersistentPty.Info[] } | 503 ServiceUnavailableError |
| 110 | POST | `/api/experimental/session/{sessionID}/terminal` | `server.experimental.persistentPty.create` | sessionID (path): Session.ID | PersistentPty.CreateInput | 200 { data: PersistentPty.Info } | 503 ServiceUnavailableError |
| 111 | POST | `/api/experimental/persistent-pty/shutdown` | `server.experimental.persistentPty.shutdown` | — | — | 204 (no content) | 503 ServiceUnavailableError |
| 112 | POST | `/api/experimental/persistent-pty/handoff` | `server.experimental.persistentPty.handoff` | — | — | 200 { handoff: PersistentPty.Handoff \| null } | 503 ServiceUnavailableError |
| 113 | GET | `/api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.get` | ptyID (path): Pty.ID | — | 200 { data: PersistentPty.Info } | 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 114 | PUT | `/api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.update` | ptyID (path): Pty.ID | PersistentPty.UpdateInput | 200 { data: PersistentPty.Info } | 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 115 | DELETE | `/api/experimental/persistent-pty/{ptyID}` | `server.experimental.persistentPty.remove` | ptyID (path): Pty.ID | — | 204 (no content) | 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 116 | GET | `/api/experimental/persistent-pty/{ptyID}/snapshot` | `server.experimental.persistentPty.snapshot` | ptyID (path): Pty.ID | — | 200 { data: PersistentPty.Snapshot } | 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 117 | POST | `/api/experimental/persistent-pty/{ptyID}/connect-token` | `server.experimental.persistentPty.connectToken` | ptyID (path): Pty.ID; x-opencode-ticket (header): string | — | 200 { data: PtyTicket.ConnectToken } | 403 ForbiddenError, 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 118 | GET | `/api/experimental/persistent-pty/{ptyID}/connect` (WebSocket upgrade) | `persistentPty.connect` | ptyID (path): Pty.ID; cursor (q): string; role (q): string; attachment_id (q): string; takeover (q): string; input_protocol (q): string; ticket (q): string | — | 200 boolean | 403 ForbiddenError, 404 PtyNotFoundError, 503 ServiceUnavailableError |
| 119 | GET | `/api/shell` | `shell.list` | location (q) | — | 200 { location: Location.PublicRef, data: Shell.Info[] } | 404 LocationNotFoundError |
| 120 | POST | `/api/shell` | `shell.create` | location (q) | { command: string, cwd?: string, timeout?: integer, metadata?: object } | 200 { location: Location.PublicRef, data: Shell.Info } | 404 LocationNotFoundError |
| 121 | GET | `/api/shell/{id}` | `shell.get` | id (path): Shell.ID; location (q) | — | 200 { location: Location.PublicRef, data: Shell.Info } | 404 ShellNotFoundError \| LocationNotFoundError |
| 122 | DELETE | `/api/shell/{id}` | `shell.remove` | id (path): Shell.ID; location (q) | — | 204 (no content) | 404 LocationNotFoundError |
| 123 | GET | `/api/shell/{id}/output` | `shell.output` | id (path): Shell.ID; location (q); cursor (q): string; limit (q): string | — | 200 { location: Location.PublicRef, data: { output: string, cursor: integer, size: integer, truncated: boolean } } | 404 ShellNotFoundError \| LocationNotFoundError |
| 124 | GET | `/api/reference` | `reference.list` | location (q) | — | 200 { location: Location.PublicRef, data: Reference.Info[] } | 404 LocationNotFoundError |
| 125 | GET | `/api/worktree` | `worktree.list` | projectID (q, required): Project.ID | — | 200 Worktree.List | 404 ProjectNotFoundError |
| 126 | POST | `/api/worktree` | `worktree.create` | — | Worktree.CreateInput | 200 Worktree.Info | 400 WorktreeError, 404 ProjectNotFoundError |
| 127 | DELETE | `/api/worktree` | `worktree.remove` | — | Worktree.RemoveInput | 204 (no content) | 400 WorktreeError, 404 ProjectNotFoundError |
| 128 | POST | `/api/worktree/refresh` | `worktree.refresh` | — | { projectID: Project.ID } | 204 (no content) | 400 WorktreeError, 404 ProjectNotFoundError |
| 129 | POST | `/api/vcs/init` | `vcs.init` | location (q); provider (q): string | — | 204 (no content) | 404 LocationNotFoundError, 409 ConflictError, 501 VcsInitNotSupportedError, 503 ServiceUnavailableError |
| 130 | GET | `/api/vcs` | `vcs.get` | location (q) | — | 200 { location: Location.PublicRef, data: Vcs.Info } | 404 LocationNotFoundError |
| 131 | GET | `/api/vcs/base` | `vcs.base` | location (q) | — | 200 { location: Location.PublicRef, data: Vcs.Base \| null } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 132 | GET | `/api/vcs/status` | `vcs.status` | location (q) | — | 200 { location: Location.PublicRef, data: Vcs.FileStatus[] } | 404 LocationNotFoundError |
| 133 | GET | `/api/vcs/branch` | `vcs.branch.list` | location (q); search (q): string; limit (q): string | — | 200 { location: Location.PublicRef, data: Vcs.BranchList } | 404 LocationNotFoundError |
| 134 | GET | `/api/vcs/diff` | `vcs.diff` | location (q); mode (q, required): Vcs.Mode; base (q): string; context (q): string | — | 200 { location: Location.PublicRef, data: FileDiff.Info[] } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 135 | GET | `/api/debug/location` | `debug.location.list` | — | — | 200 Location.PublicRef[] | — |
| 136 | DELETE | `/api/debug/location` | `debug.location.evict` | location (q) | — | 204 (no content) | — |
| 137 | GET | `/api/experimental/migration/v1` | `experimental.migration.v1.status` | — | — | 200 { status: "required"\|"completed" } \| { status: "running", progress: { label: string, numerator?: integer, denominator?: integer } } \| { status: "error", error: string } | — |
| 138 | GET | `/api/websearch/provider` | `websearch.providers` | location (q) | — | 200 { location: Location.PublicRef, data: WebSearch.Provider[] } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 139 | POST | `/api/websearch` | `websearch.query` | location (q) | { query: string, providerID?: WebSearch.ID } | 200 { location: Location.PublicRef, data: WebSearch.ResponseEncoded } | 404 LocationNotFoundError, 503 ServiceUnavailableError |
| 140 | GET | `/api/config` | `config.get` | location (q) | — | 200 Config.Entry[] | 404 LocationNotFoundError |
| 141 | GET | `/api/config/shell` | `config.shells` | — | — | 200 ConfigShell.Option[] | 404 LocationNotFoundError |
| 142 | PATCH | `/api/experimental/config` | `experimental.config.update` | — | Config.Patch | 204 (no content) | 404 LocationNotFoundError |

## Appendix B. All 94 V2 public event types (from the generated union `V2Event`)

Generated from `packages/client/src/promise/generated/types.ts:2545-2639` (the project's own codegen output for `OpenCodeEvent`). Every event also has the envelope fields `id`, `created` (absent on `server.connected`), `type`, optional `metadata`, optional `location: {directory, workspaceID?}`, and `durable: {aggregateID, seq, version}` when durable. Named types (e.g. `ModelRef`, `TokenUsageInfo`, `ShellInfo`) are the schemas described in §6. "Source" is the defining schema.

| # | `type` | Durability | `data` | Source |
|---|---|---|---|---|
| 1 | `location.shutdown` | ephemeral | `{}` | `packages/schema/src/location-event.ts:6` |
| 2 | `models-dev.refreshed` | ephemeral | `{}` | `packages/schema/src/models-dev.ts:6` |
| 3 | `credential.updated` | ephemeral | `{}` | `packages/schema/src/credential.ts:19` |
| 4 | `credential.switched` | ephemeral | `{ integrationID: IntegrationID; credentialID: CredentialID \| null }` | `packages/schema/src/credential.ts:23` |
| 5 | `integration.updated` | ephemeral | `{}` | `packages/schema/src/integration.ts:62` |
| 6 | `provider.updated` | ephemeral | `{}` | `packages/schema/src/provider.ts:28` |
| 7 | `model.updated` | ephemeral | `{}` | `packages/schema/src/model.ts:13` |
| 8 | `agent.updated` | ephemeral | `{}` | `packages/schema/src/agent.ts:11` |
| 9 | `session.created` | durable v1 | `{ sessionID: SessionID projectID: ProjectID location: LocationRef subpath?: RelativePath parentID?: SessionID slug: string title?: string agent?: AgentID model?: ModelRef metadata?: SessionMetadata permissions?: PermissionRuleset version: string }` | `packages/schema/src/session-event.ts:49` |
| 10 | `session.agent.selected` | durable v1 | `{ sessionID: SessionID; agent: AgentID; previous?: AgentID }` | `packages/schema/src/session-event.ts:70` |
| 11 | `session.model.selected` | durable v1 | `{ sessionID: SessionID; model: ModelRef; previous?: ModelRef }` | `packages/schema/src/session-event.ts:81` |
| 12 | `session.moved` | durable v1 | `{ sessionID: SessionID; location: LocationRef; projectID: ProjectID; subpath?: RelativePath }` | `packages/schema/src/session-event.ts:92` |
| 13 | `session.renamed` | durable v1 | `{ sessionID: SessionID; title: string }` | `packages/schema/src/session-event.ts:102` |
| 14 | `session.metadata.updated` | durable v1 | `{ sessionID: SessionID; metadata: SessionMetadata }` | `packages/schema/src/session-event.ts:112` |
| 15 | `session.permissions` | durable v1 | `{ sessionID: SessionID; permissions: PermissionRuleset }` | `packages/schema/src/session-event.ts:122` |
| 16 | `session.viewed` | durable v1 | `{ sessionID: SessionID; idle: number }` | `packages/schema/src/session-event.ts:132` |
| 17 | `session.usage.updated` | ephemeral | `{ sessionID: SessionID; cost: MoneyUSD; tokens: TokenUsageInfo }` | `packages/schema/src/session-event.ts:168` |
| 18 | `session.deleted` | durable v2 | `{ sessionID: SessionID }` | `packages/schema/src/session-event.ts:178` |
| 19 | `session.forked` | durable v2 | `{ sessionID: SessionID parentID: SessionID boundary: SessionForkBoundary instructions?: { [x: InstructionKey]: InstructionHash } instructionEntries?: InstructionEntrySnapshot }` | `packages/schema/src/session-event.ts:188` |
| 20 | `session.inbox.delivered` | durable v1 | `{ sessionID: SessionID; inboxID: SessionMessageID }` | `packages/schema/src/session-event.ts:209` |
| 21 | `session.inbox.enqueued` | durable v1 | `{ sessionID: SessionID; inboxID: SessionMessageID; item: SessionInboxItem }` | `packages/schema/src/session-event.ts:216` |
| 22 | `session.inbox.cancelled` | durable v1 | `{ sessionID: SessionID; inboxID: SessionMessageID }` | `packages/schema/src/session-event.ts:226` |
| 23 | `session.inbox.delivery.changed` | durable v1 | `{ sessionID: SessionID; inboxID: SessionMessageID; delivery: SessionInboxDelivery }` | `packages/schema/src/session-event.ts:233` |
| 24 | `session.execution.started` | durable v1 | `{ sessionID: SessionID }` | `packages/schema/src/session-event.ts:240` |
| 25 | `session.execution.succeeded` | durable v1 | `{ sessionID: SessionID }` | `packages/schema/src/session-event.ts:243` |
| 26 | `session.execution.failed` | durable v1 | `{ sessionID: SessionID; error: SessionStructuredError }` | `packages/schema/src/session-event.ts:247` |
| 27 | `session.execution.interrupted` | durable v1 | `{ sessionID: SessionID; reason: "user" \| "shutdown" \| "superseded" \| "inactivity" }` | `packages/schema/src/session-event.ts:254` |
| 28 | `session.instructions.updated` | durable v2 | `{ sessionID: SessionID; delta: { [x: string]: InstructionHash \| "removed" }; text?: string }` | `packages/schema/src/session-event.ts:262` |
| 29 | `session.synthetic` | durable v1 | `{ sessionID: SessionID; text: string; description?: string; metadata?: { [x: string]: any } }` | `packages/schema/src/session-event.ts:280` |
| 30 | `session.skill.activated` | durable v1 | `{ sessionID: SessionID; id: SkillID; name: SkillName; text: string }` | `packages/schema/src/session-event.ts:293` |
| 31 | `session.shell.started` | durable v1 | `{ sessionID: SessionID; shell: ShellInfo }` | `packages/schema/src/session-event.ts:307` |
| 32 | `session.shell.ended` | durable v1 | `{ sessionID: SessionID shell: ShellInfo output: { output: string; cursor: number; size: number; truncated: boolean } }` | `packages/schema/src/session-event.ts:317` |
| 33 | `session.step.started` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID agent: AgentID model: ModelRef snapshot?: SnapshotID started: number }` | `packages/schema/src/session-event.ts:330` |
| 34 | `session.step.streamed` | durable v1 | `{ sessionID: SessionID; assistantMessageID: SessionMessageID }` | `packages/schema/src/session-event.ts:346` |
| 35 | `session.step.ended` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID finish: "stop" \| "length" \| "tool-calls" \| "content-filter" \| "error" \| "unknown" rawFinish?: string providerState?: SessionMessageProviderState1 cost: MoneyUSD tokens: TokenUsageInfo snapshot?: SnapshotID files?: Array<RelativePath> }` | `packages/schema/src/session-event.ts:356` |
| 36 | `session.step.failed` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID error: SessionStructuredError finish?: "content-filter" rawFinish?: string providerState?: SessionMessageProviderState1 cost?: MoneyUSD tokens?: TokenUsageInfo snapshot?: SnapshotID files?: Array<RelativePath> }` | `packages/schema/src/session-event.ts:373` |
| 37 | `session.text.started` | durable v1 | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; ordinal: number }` | `packages/schema/src/session-event.ts:393` |
| 38 | `session.text.delta` | ephemeral | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; ordinal: number; delta: string }` | `packages/schema/src/session-event.ts:405` |
| 39 | `session.text.ended` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID ordinal: number text: string state?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:416` |
| 40 | `session.reasoning.started` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID ordinal: number state?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:431` |
| 41 | `session.reasoning.delta` | ephemeral | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; ordinal: number; delta: string }` | `packages/schema/src/session-event.ts:444` |
| 42 | `session.reasoning.ended` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID ordinal: number text: string state?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:455` |
| 43 | `session.tool.input.started` | durable v1 | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; id: string; name: string }` | `packages/schema/src/session-event.ts:477` |
| 44 | `session.tool.input.delta` | ephemeral | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; id: string; delta: string }` | `packages/schema/src/session-event.ts:488` |
| 45 | `session.tool.input.ended` | durable v1 | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; id: string; text: string }` | `packages/schema/src/session-event.ts:497` |
| 46 | `session.tool.called` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID id: string input: { [x: string]: any } executed: boolean state?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:508` |
| 47 | `session.tool.progress` | ephemeral | `{ sessionID: SessionID; assistantMessageID: SessionMessageID; id: string; metadata: { [x: string]: JsonValue } }` | `packages/schema/src/session-event.ts:521` |
| 48 | `session.tool.success` | durable v2 | `{ sessionID: SessionID assistantMessageID: SessionMessageID id: string content: [ToolContent1, ...Array<ToolContent1>] metadata?: { [x: string]: JsonValue } executed: boolean resultState?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:531` |
| 49 | `session.tool.failed` | durable v2 | `{ sessionID: SessionID assistantMessageID: SessionMessageID id: string error: SessionStructuredError content?: [ToolContent1, ...Array<ToolContent1>] metadata?: { [x: string]: JsonValue } executed: boolean resultState?: SessionMessageProviderState1 }` | `packages/schema/src/session-event.ts:552` |
| 50 | `session.retry.scheduled` | durable v1 | `{ sessionID: SessionID assistantMessageID: SessionMessageID attempt: number at: number error: SessionStructuredError }` | `packages/schema/src/session-event.ts:570` |
| 51 | `session.compaction.started` | durable v1 | `{ sessionID: SessionID; reason: "auto" \| "manual"; recent: string; inputID?: SessionMessageID }` | `packages/schema/src/session-event.ts:584` |
| 52 | `session.compaction.delta` | ephemeral | `{ sessionID: SessionID; text: string }` | `packages/schema/src/session-event.ts:596` |
| 53 | `session.compaction.ended` | durable v1 | `{ sessionID: SessionID reason: "auto" \| "manual" model?: ModelRef providerState?: SessionMessageProviderState1 providerContext?: SessionProviderContext text: string recent: string cost?: MoneyUSD tokens?: TokenUsageInfo }` | `packages/schema/src/session-event.ts:605` |
| 54 | `session.compaction.failed` | durable v1 | `{ sessionID: SessionID reason: "auto" \| "manual" error: SessionStructuredError inputID?: SessionMessageID cost?: MoneyUSD tokens?: TokenUsageInfo }` | `packages/schema/src/session-event.ts:624` |
| 55 | `session.revert.staged` | durable v1 | `{ sessionID: SessionID; revert: SessionRevert }` | `packages/schema/src/session-event.ts:640` |
| 56 | `session.revert.cleared` | durable v1 | `{ sessionID: SessionID }` | `packages/schema/src/session-event.ts:644` |
| 57 | `session.revert.committed` | durable v1 | `{ sessionID: SessionID; to: SessionMessageID }` | `packages/schema/src/session-event.ts:646` |
| 58 | `filesystem.changed` | ephemeral | `{ file: string; event: "add" \| "change" \| "unlink" }` | `packages/schema/src/filesystem.ts:9` |
| 59 | `reference.updated` | ephemeral | `{}` | `packages/schema/src/reference.ts:8` |
| 60 | `permission.asked` | ephemeral | `{ id: PermissionID sessionID: SessionID action: string resources: Array<string> save?: Array<string> metadata?: { [x: string]: any } source?: PermissionSource message?: string }` | `packages/schema/src/permission.ts:45` |
| 61 | `permission.replied` | ephemeral | `{ sessionID: SessionID; requestID: PermissionID; reply: PermissionReply }` | `packages/schema/src/permission.ts:47` |
| 62 | `plugin.updated` | ephemeral | `{}` | `packages/schema/src/plugin.ts:46` |
| 63 | `project.updated` | ephemeral | `{ id: ProjectID canonical: AbsolutePath vcs?: ProjectVcs name?: string icon?: ProjectIcon commands?: ProjectCommands time: ProjectTime sandboxes: Array<string> }` | `packages/schema/src/project.ts:61` |
| 64 | `worktree.updated` | ephemeral | `{ projectID: ProjectID }` | `packages/schema/src/worktree.ts:56` |
| 65 | `worktree.resolved` | durable v1 | `{ projectID: ProjectID; directory: AbsolutePath; previous: ProjectID; adopted?: Array<ProjectID> }` | `packages/schema/src/worktree.ts:61` |
| 66 | `command.updated` | ephemeral | `{}` | `packages/schema/src/command.ts:7` |
| 67 | `config.updated` | ephemeral | `{}` | `packages/schema/src/config.ts:138` |
| 68 | `skill.updated` | ephemeral | `{}` | `packages/schema/src/skill.ts:36` |
| 69 | `pty.created` | ephemeral | `{ info: Pty }` | `packages/schema/src/pty.ts:37` |
| 70 | `pty.updated` | ephemeral | `{ info: Pty }` | `packages/schema/src/pty.ts:38` |
| 71 | `pty.exited` | ephemeral | `{ id: PtyID; exitCode: number }` | `packages/schema/src/pty.ts:39` |
| 72 | `pty.deleted` | ephemeral | `{ id: PtyID }` | `packages/schema/src/pty.ts:40` |
| 73 | `persistent-pty.added` | ephemeral | `{ sessionID: SessionID; terminal: PersistentPtyInfo }` | `packages/schema/src/persistent-pty.ts:68` |
| 74 | `persistent-pty.removed` | ephemeral | `{ sessionID: SessionID; ptyID: PtyID }` | `packages/schema/src/persistent-pty.ts:69` |
| 75 | `shell.created` | ephemeral | `{ info: ShellInfo }` | `packages/schema/src/shell.ts:58` |
| 76 | `shell.exited` | ephemeral | `{ id: ShellID; exit?: number; status: "running" \| "exited" \| "timeout" \| "killed" }` | `packages/schema/src/shell.ts:59` |
| 77 | `shell.deleted` | ephemeral | `{ id: ShellID }` | `packages/schema/src/shell.ts:60` |
| 78 | `form.created` | ephemeral | `{ form: FormInfo1 }` | `packages/schema/src/form.ts:173` |
| 79 | `form.replied` | ephemeral | `{ id: FormID; sessionID: string; answer: FormAnswer2 }` | `packages/schema/src/form.ts:174` |
| 80 | `form.cancelled` | ephemeral | `{ id: FormID; sessionID: string }` | `packages/schema/src/form.ts:175` |
| 81 | `websearch.updated` | ephemeral | `{}` | `packages/schema/src/websearch.ts:41` |
| 82 | `session.status` | ephemeral | `{ sessionID: SessionID; status: SessionStatus }` | `packages/schema/src/session-status-event.ts:36` |
| 83 | `session.idle` | ephemeral | `{ sessionID: SessionID }` | `packages/schema/src/session-status-event.ts:47` |
| 84 | `tui.prompt.append` | ephemeral | `{ text: string }` | `packages/schema/src/tui-event.ts:11` |
| 85 | `tui.command.execute` | ephemeral | `{ command: \| "session.list" \| "session.new" \| "session.interrupt" \| "session.background" \| "session.compact" \| "session.page.up" \| "session.page.down" \| "session.line.up" \| "session.line.down" \| "session.half.page.up" \| "session.half.page.down" \| "session.first" \| "session.last" \| "prompt.clear" \| "prompt.submit" \| "agent.cycle" \| (string & {}) }` | `packages/schema/src/tui-event.ts:14` |
| 86 | `tui.toast.show` | ephemeral | `{ title?: string message: string variant: "info" \| "success" \| "warning" \| "error" duration?: number \| undefined }` | `packages/schema/src/tui-event.ts:41` |
| 87 | `tui.session.select` | ephemeral | `{ sessionID: SessionID }` | `packages/schema/src/tui-event.ts:53` |
| 88 | `installation.updated` | ephemeral | `{ version: string }` | `packages/schema/src/installation-event.ts:7` |
| 89 | `installation.update-available` | ephemeral | `{ version: string }` | `packages/schema/src/installation-event.ts:14` |
| 90 | `vcs.branch.updated` | ephemeral | `{ branch?: string }` | `packages/schema/src/vcs-event.ts:8` |
| 91 | `mcp.status.changed` | ephemeral | `{ server: string }` | `packages/schema/src/mcp-event.ts:23` |
| 92 | `mcp.resources.changed` | ephemeral | `{ server: string }` | `packages/schema/src/mcp-event.ts:14` |
| 93 | `rpc.*` | ephemeral | `{ [x: string]: any }` | `packages/protocol/src/groups/event.ts:14-21` |
| 94 | `server.connected` | ephemeral | `{}` | `packages/protocol/src/groups/event.ts:27-35 (and packages/server/src/handlers/event.ts:13-17)` |

## Appendix C. All 188 V1 operations (v1.18.23 `packages/sdk/openapi.json`)

Scope: **instance** = takes `?directory=` / `?workspace=` (or the `x-opencode-directory` header); **global** = no directory; **/api preview** = the early V2 surface embedded in 1.18.23, incompatible with V2 HEAD (§11.1). "Query" lists other query parameters.

| Method | Path | operationId | Scope | Query |
|---|---|---|---|---|
| PUT | `/auth/{providerID}` | `auth.set` | global | — |
| DELETE | `/auth/{providerID}` | `auth.remove` | global | — |
| POST | `/log` | `app.log` | instance | — |
| POST | `/experimental/control-plane/move-session` | `experimental.controlPlane.moveSession` | global | — |
| GET | `/global/health` | `global.health` | global | — |
| GET | `/global/event` (SSE) | `global.event` | global | — |
| GET | `/global/config` | `global.config.get` | global | — |
| PATCH | `/global/config` | `global.config.update` | global | — |
| POST | `/global/dispose` | `global.dispose` | global | — |
| POST | `/global/upgrade` | `global.upgrade` | global | — |
| GET | `/event` (SSE) | `event.subscribe` | instance | — |
| GET | `/config` | `config.get` | instance | — |
| PATCH | `/config` | `config.update` | instance | — |
| GET | `/config/providers` | `config.providers` | instance | — |
| GET | `/experimental/capabilities` | `experimental.capabilities.get` | instance | — |
| GET | `/experimental/console` | `experimental.console.get` | instance | — |
| GET | `/experimental/console/orgs` | `experimental.console.listOrgs` | instance | — |
| POST | `/experimental/console/switch` | `experimental.console.switchOrg` | instance | — |
| GET | `/experimental/tool` | `tool.list` | instance | provider, model |
| GET | `/experimental/tool/ids` | `tool.ids` | instance | — |
| GET | `/experimental/worktree` | `worktree.list` | instance | — |
| POST | `/experimental/worktree` | `worktree.create` | instance | — |
| DELETE | `/experimental/worktree` | `worktree.remove` | instance | — |
| POST | `/experimental/worktree/reset` | `worktree.reset` | instance | — |
| GET | `/experimental/session` | `experimental.session.list` | instance | roots, start, cursor, search, limit, archived |
| POST | `/experimental/session/{sessionID}/background` | `experimental.session.background` | instance | — |
| GET | `/experimental/resource` | `experimental.resource.list` | instance | — |
| GET | `/find` | `find.text` | instance | pattern |
| GET | `/find/file` | `find.files` | instance | query, dirs, type, limit |
| GET | `/find/symbol` | `find.symbols` | instance | query |
| GET | `/file` | `file.list` | instance | path |
| GET | `/file/content` | `file.read` | instance | path |
| GET | `/file/status` | `file.status` | instance | — |
| POST | `/instance/dispose` | `instance.dispose` | instance | — |
| GET | `/path` | `path.get` | instance | — |
| GET | `/vcs` | `vcs.get` | instance | — |
| GET | `/vcs/status` | `vcs.status` | instance | — |
| GET | `/vcs/diff` | `vcs.diff` | instance | mode, context |
| GET | `/vcs/diff/raw` | `vcs.diff.raw` | instance | — |
| POST | `/vcs/apply` | `vcs.apply` | instance | — |
| GET | `/command` | `command.list` | instance | — |
| GET | `/agent` | `app.agents` | instance | — |
| GET | `/skill` | `app.skills` | instance | — |
| GET | `/lsp` | `lsp.status` | instance | — |
| GET | `/formatter` | `formatter.status` | instance | — |
| GET | `/mcp` | `mcp.status` | instance | — |
| POST | `/mcp` | `mcp.add` | instance | — |
| POST | `/mcp/{name}/auth` | `mcp.auth.start` | instance | — |
| DELETE | `/mcp/{name}/auth` | `mcp.auth.remove` | instance | — |
| POST | `/mcp/{name}/auth/callback` | `mcp.auth.callback` | instance | — |
| POST | `/mcp/{name}/auth/authenticate` | `mcp.auth.authenticate` | instance | — |
| POST | `/mcp/{name}/connect` (WebSocket) | `mcp.connect` | instance | — |
| POST | `/mcp/{name}/disconnect` | `mcp.disconnect` | instance | — |
| GET | `/project` | `project.list` | instance | — |
| GET | `/project/current` | `project.current` | instance | — |
| POST | `/project/git/init` | `project.initGit` | instance | — |
| PATCH | `/project/{projectID}` | `project.update` | instance | — |
| GET | `/project/{projectID}/directories` | `project.directories` | instance | — |
| POST | `/experimental/project/{projectID}/copy/generate-name` | `experimental.projectCopy.generateName` | instance | — |
| GET | `/pty/shells` | `pty.shells` | instance | — |
| GET | `/pty` | `pty.list` | instance | — |
| POST | `/pty` | `pty.create` | instance | — |
| GET | `/pty/{ptyID}` | `pty.get` | instance | — |
| PUT | `/pty/{ptyID}` | `pty.update` | instance | — |
| DELETE | `/pty/{ptyID}` | `pty.remove` | instance | — |
| POST | `/pty/{ptyID}/connect-token` | `pty.connectToken` | instance | — |
| GET | `/question` | `question.list` | instance | — |
| POST | `/question/{requestID}/reply` | `question.reply` | instance | — |
| POST | `/question/{requestID}/reject` | `question.reject` | instance | — |
| GET | `/permission` | `permission.list` | instance | — |
| POST | `/permission/{requestID}/reply` | `permission.reply` | instance | — |
| GET | `/provider` | `provider.list` | instance | — |
| GET | `/provider/auth` | `provider.auth` | instance | — |
| POST | `/provider/{providerID}/oauth/authorize` | `provider.oauth.authorize` | instance | — |
| POST | `/provider/{providerID}/oauth/callback` | `provider.oauth.callback` | instance | — |
| GET | `/session` | `session.list` | instance | scope, path, roots, start, search, limit |
| POST | `/session` | `session.create` | instance | — |
| GET | `/session/status` | `session.status` | instance | — |
| GET | `/session/{sessionID}` | `session.get` | instance | — |
| DELETE | `/session/{sessionID}` | `session.delete` | instance | — |
| PATCH | `/session/{sessionID}` | `session.update` | instance | — |
| GET | `/session/{sessionID}/children` | `session.children` | instance | — |
| GET | `/session/{sessionID}/todo` | `session.todo` | instance | — |
| GET | `/session/{sessionID}/diff` | `session.diff` | instance | messageID |
| GET | `/session/{sessionID}/message` | `session.messages` | instance | limit, before |
| POST | `/session/{sessionID}/message` | `session.prompt` | instance | — |
| GET | `/session/{sessionID}/message/{messageID}` | `session.message` | instance | — |
| DELETE | `/session/{sessionID}/message/{messageID}` | `session.deleteMessage` | instance | — |
| POST | `/session/{sessionID}/fork` | `session.fork` | instance | — |
| POST | `/session/{sessionID}/abort` | `session.abort` | instance | — |
| POST | `/session/{sessionID}/init` | `session.init` | instance | — |
| POST | `/session/{sessionID}/share` | `session.share` | instance | — |
| DELETE | `/session/{sessionID}/share` | `session.unshare` | instance | — |
| POST | `/session/{sessionID}/summarize` | `session.summarize` | instance | — |
| POST | `/session/{sessionID}/prompt_async` | `session.prompt_async` | instance | — |
| POST | `/session/{sessionID}/command` | `session.command` | instance | — |
| POST | `/session/{sessionID}/shell` | `session.shell` | instance | — |
| POST | `/session/{sessionID}/revert` | `session.revert` | instance | — |
| POST | `/session/{sessionID}/unrevert` | `session.unrevert` | instance | — |
| POST | `/session/{sessionID}/permissions/{permissionID}` (deprecated) | `permission.respond` | instance | — |
| DELETE | `/session/{sessionID}/message/{messageID}/part/{partID}` | `part.delete` | instance | — |
| PATCH | `/session/{sessionID}/message/{messageID}/part/{partID}` | `part.update` | instance | — |
| POST | `/sync/start` | `sync.start` | instance | — |
| POST | `/sync/replay` | `sync.replay` | instance | — |
| POST | `/sync/steal` | `sync.steal` | instance | — |
| POST | `/sync/history` | `sync.history.list` | instance | — |
| POST | `/tui/append-prompt` | `tui.appendPrompt` | instance | — |
| POST | `/tui/open-help` | `tui.openHelp` | instance | — |
| POST | `/tui/open-sessions` | `tui.openSessions` | instance | — |
| POST | `/tui/open-themes` | `tui.openThemes` | instance | — |
| POST | `/tui/open-models` | `tui.openModels` | instance | — |
| POST | `/tui/submit-prompt` | `tui.submitPrompt` | instance | — |
| POST | `/tui/clear-prompt` | `tui.clearPrompt` | instance | — |
| POST | `/tui/execute-command` | `tui.executeCommand` | instance | — |
| POST | `/tui/show-toast` | `tui.showToast` | instance | — |
| POST | `/tui/publish` | `tui.publish` | instance | — |
| POST | `/tui/select-session` | `tui.selectSession` | instance | — |
| GET | `/tui/control/next` | `tui.control.next` | instance | — |
| POST | `/tui/control/response` | `tui.control.response` | instance | — |
| GET | `/experimental/workspace/adapter` | `experimental.workspace.adapter.list` | instance | — |
| GET | `/experimental/workspace` | `experimental.workspace.list` | instance | — |
| POST | `/experimental/workspace` | `experimental.workspace.create` | instance | — |
| POST | `/experimental/workspace/sync-list` | `experimental.workspace.syncList` | instance | — |
| GET | `/experimental/workspace/status` | `experimental.workspace.status` | instance | — |
| DELETE | `/experimental/workspace/{id}` | `experimental.workspace.remove` | instance | — |
| POST | `/experimental/workspace/warp` | `experimental.workspace.warp` | instance | — |
| GET | `/api/health` | `v2.health.get` | /api preview | — |
| GET | `/api/location` | `v2.location.get` | /api preview | location |
| GET | `/api/agent` | `v2.agent.list` | /api preview | location |
| GET | `/api/session` | `v2.session.list` | /api preview | limit, order, search, project, subpath, cursor |
| POST | `/api/session` | `v2.session.create` | /api preview | — |
| GET | `/api/session/active` | `v2.session.active` | /api preview | — |
| GET | `/api/session/{sessionID}` | `v2.session.get` | /api preview | — |
| POST | `/api/session/{sessionID}/agent` | `v2.session.switchAgent` | /api preview | — |
| POST | `/api/session/{sessionID}/model` | `v2.session.switchModel` | /api preview | — |
| POST | `/api/session/{sessionID}/prompt` | `v2.session.prompt` | /api preview | — |
| POST | `/api/session/{sessionID}/compact` | `v2.session.compact` | /api preview | — |
| POST | `/api/session/{sessionID}/wait` | `v2.session.wait` | /api preview | — |
| POST | `/api/session/{sessionID}/revert/stage` | `v2.session.revert.stage` | /api preview | — |
| POST | `/api/session/{sessionID}/revert/clear` | `v2.session.revert.clear` | /api preview | — |
| POST | `/api/session/{sessionID}/revert/commit` | `v2.session.revert.commit` | /api preview | — |
| GET | `/api/session/{sessionID}/context` | `v2.session.context` | /api preview | — |
| GET | `/api/session/{sessionID}/history` | `v2.session.history` | /api preview | limit, after |
| GET | `/api/session/{sessionID}/event` | `v2.session.events` | /api preview | after |
| POST | `/api/session/{sessionID}/interrupt` | `v2.session.interrupt` | /api preview | — |
| GET | `/api/session/{sessionID}/message/{messageID}` | `v2.session.message` | /api preview | — |
| GET | `/api/session/{sessionID}/message` | `v2.session.messages` | /api preview | limit, order, cursor |
| GET | `/api/model` | `v2.model.list` | /api preview | location |
| GET | `/api/provider` | `v2.provider.list` | /api preview | location |
| GET | `/api/provider/{providerID}` | `v2.provider.get` | /api preview | location |
| GET | `/api/integration` | `v2.integration.list` | /api preview | location |
| GET | `/api/integration/{integrationID}` | `v2.integration.get` | /api preview | location |
| POST | `/api/integration/{integrationID}/connect/key` | `v2.integration.connect.key` | /api preview | location |
| POST | `/api/integration/{integrationID}/connect/oauth` | `v2.integration.connect.oauth` | /api preview | location |
| GET | `/api/integration/attempt/{attemptID}` | `v2.integration.attempt.status` | /api preview | location |
| DELETE | `/api/integration/attempt/{attemptID}` | `v2.integration.attempt.cancel` | /api preview | location |
| POST | `/api/integration/attempt/{attemptID}/complete` | `v2.integration.attempt.complete` | /api preview | location |
| PATCH | `/api/credential/{credentialID}` | `v2.credential.update` | /api preview | location |
| DELETE | `/api/credential/{credentialID}` | `v2.credential.remove` | /api preview | location |
| GET | `/api/permission/request` | `v2.permission.request.list` | /api preview | location |
| GET | `/api/permission/saved` | `v2.permission.saved.list` | /api preview | projectID |
| DELETE | `/api/permission/saved/{id}` | `v2.permission.saved.remove` | /api preview | — |
| POST | `/api/session/{sessionID}/permission` | `v2.session.permission.create` | /api preview | — |
| GET | `/api/session/{sessionID}/permission` | `v2.session.permission.list` | /api preview | — |
| GET | `/api/session/{sessionID}/permission/{requestID}` | `v2.session.permission.get` | /api preview | — |
| POST | `/api/session/{sessionID}/permission/{requestID}/reply` | `v2.session.permission.reply` | /api preview | — |
| GET | `/api/fs/read/*` | `v2.fs.read` | /api preview | location |
| GET | `/api/fs/list` | `v2.fs.list` | /api preview | location, path |
| GET | `/api/fs/find` | `v2.fs.find` | /api preview | location, query, type, limit |
| GET | `/api/command` | `v2.command.list` | /api preview | location |
| GET | `/api/skill` | `v2.skill.list` | /api preview | location |
| GET | `/api/event` | `v2.event.subscribe` | /api preview | — |
| GET | `/api/pty` | `v2.pty.list` | /api preview | location |
| POST | `/api/pty` | `v2.pty.create` | /api preview | location |
| GET | `/api/pty/{ptyID}` | `v2.pty.get` | /api preview | location |
| PUT | `/api/pty/{ptyID}` | `v2.pty.update` | /api preview | location |
| DELETE | `/api/pty/{ptyID}` | `v2.pty.remove` | /api preview | location |
| POST | `/api/pty/{ptyID}/connect-token` | `v2.pty.connectToken` | /api preview | location |
| GET | `/api/pty/{ptyID}/connect` (WebSocket) | `v2.pty.connect` | /api preview | location[directory], location[workspace], cursor, ticket |
| GET | `/api/question/request` | `v2.question.request.list` | /api preview | location |
| GET | `/api/session/{sessionID}/question` | `v2.session.question.list` | /api preview | — |
| POST | `/api/session/{sessionID}/question/{requestID}/reply` | `v2.session.question.reply` | /api preview | — |
| POST | `/api/session/{sessionID}/question/{requestID}/reject` | `v2.session.question.reject` | /api preview | — |
| GET | `/api/reference` | `v2.reference.list` | /api preview | location |
| POST | `/experimental/project/{projectID}/copy` | `v2.projectCopy.create` | /api preview | location |
| DELETE | `/experimental/project/{projectID}/copy` | `v2.projectCopy.remove` | /api preview | location |
| POST | `/experimental/project/{projectID}/copy/refresh` | `v2.projectCopy.refresh` | /api preview | location |
| GET | `/pty/{ptyID}/connect` (WebSocket) | `pty.connect` | instance | cursor, ticket |



## Review and file endpoints: observed behaviour

Observed against V2 2.0.32 and 2.1.2 on 2026-10-21.

- **Path bases differ by route.** VCS diff and status paths are relative to the repository root and limited to the requested location. Session diff, revert and step-snapshot paths are relative to the project root. `fs` paths and ordinary tool paths are relative to the location. To read a file outside the location, strip the session subpath and use the project location.
- **`session.diff`** takes optional `from`, `to` and `context`, and no location. Omitted bounds resolve to the latest whole turn; omitted `context` returns full patches. Running steps compare against the working copy, and missing or disabled snapshots return an empty array. Failures come back as typed 400/404 errors, or as `UnknownError` for bad refs.
- **Patch formats.** jsdiff and Git patches use different headers. Snapshot patches for binary files are empty, while VCS patches contain a "Binary files" chunk. When a patch is cut down to headers by the size budget, retry with `context=3`. A rename appears as a delete plus an add.
- **VCS routes** use location wrappers. A branch diff without a base uses the default branch, not `vcs.base`. Keep 503 messages for the user. The provider, arrays and base may be empty until the plugin activates, and `vcs.branch.updated` requires a refresh. `vcs.init` rebuilds the location and emits `worktree.updated`.
- **`fs.read`** returns raw bytes with a guessed Content-Type, a weak ETag, Last-Modified, `no-cache, no-transform` and Accept-Ranges. It answers 304, 206 and 416 and has no server size cap. From 2.2.6 it is an attachment and sends HTML, JavaScript and XML as `text/plain` (§11.7), so pick the viewer from the path. The wildcard path is encoded segment by segment. Do not apply JSON response validation to this route.
- **`fs.list`** returns direct children, directories first with a trailing slash. It includes dot-files and ignored files, and drops symlinks. **`fs.find`** is fuzzy and ranked, excludes hidden and ignored files, caches its index for up to ten seconds, and takes `type` and `limit`.
- **`filesystem.changed`** does not report ordinary working-tree edits. Refresh on step end, idle, VCS, revert and worktree events, on foreground and open, and on pull to refresh.
