# Architecture

How the iPhone and iPad app, the push plugin and the relay are built. Paths under `packages/` refer to the opencode V2 source at commit `d0732ea` ([anomalyco/opencode](https://github.com/anomalyco/opencode), formerly sst/opencode), and the recorded fixtures come from opencode 2.0.32. [research/01-opencode-server-api.md](research/01-opencode-server-api.md) documents the V2 protocol.

## 0. Key decisions

1. **Support V2 only.** The minimum is 2.0.25, the first release with pairing. An older V2 server gets an "Update opencode" screen with the version it needs, and a V1 server gets one telling the user to run `opencode upgrade` (V1 1.19.0 or later is needed) and then `opencode upgrade --major`.
2. **A reliability core.** Each server gets one `actor ServerConnection`. It owns one SSE stream, a watchdog on received bytes, backoff with jitter, and closes the stream when the app goes to the background. It feeds a main-actor sync engine (`ReadStore`) that runs a **full resync on every `server.connected`**. The engine is ported from the reference client's `data.ts` and hardened with:
   - event handlers that are safe to apply twice;
   - duplicate removal by `seq`;
   - gap splicing (merging a fresh newest page into the history already loaded; see §2.5);
   - an outbox of unsent prompts that survives app restarts.
3. **Hand-write the models and decode them tolerantly.** An unknown type, an unknown field or a malformed element must never crash the app, end the event stream or drop a page. The V2 OpenAPI document cannot feed a code generator: its unions are `anyOf` without discriminators, and almost every object sets `additionalProperties: false`, so generated code would fail on any new server field.
4. **Use a GRDB/SQLite cache.** It stores the raw server JSON plus a few indexed columns, so the cache does not depend on the server's schema. Drafts and the outbox are persisted too. The server is always the source of truth.
5. **Push = our opencode plugin + our relay + HPKE-sealed payloads + a Notification Service Extension (NSE).** opencode has no push notifications of its own. The plugin reaches Apple through the relay, or, in direct mode, itself with the server owner's APNs key. Approvals never pass through the relay. They go over the direct connection and are checked against a digest of exactly what the user saw.
6. **Silence is never consent.** Nothing is approved automatically, and a request that times out is never treated as approved. Approving from the lock screen is on by default with risk tiers: Allow once needs an unlocked device, high-risk requests offer only Open and Reject, and "Allow always" exists only inside the app, behind device-owner authentication.
7. **No vendor in the loop.** The app talks only to the user's own servers, on the same network, over Tailscale, behind HTTPS or through OpenTunnel, plus the relay and Apple's push service for notifications. There is no account, and no analytics or crash reporting.
8. **Platform and look.** iOS and iPadOS 26.4 or later, in Swift 6 language mode, built with Xcode 27; the same build runs on Apple silicon Macs as "Designed for iPad". The app looks like the opencode desktop app, with its tokens, fonts and icons ported under their licences, but keeps a distinct name and icon so it is not mistaken for an official app.
9. **Open source.** The app is licensed under GPL-3.0-only, and the plugin, relay and shared contracts under MIT, so the privacy claims can be checked.

## 1. Overview

### 1.1 Targets and modules

**App and extensions** (generated with XcodeGen from `project.yml`)

| Target | Responsibility | Links |
|---|---|---|
| `Opencode` (app; iPhone and iPad; "Designed for iPad" on Mac) | Wires everything together and holds no feature logic. Contains `OpencodeApp` (one `WindowGroup` of session windows) and `OpencodeShortcuts` (App Shortcuts). The app delegate (`MobileAppDelegate`: APNs token, `UNUserNotificationCenterDelegate`) and the shared `ApplicationServices` (registry, windows, links, intents) live in OCSync, and `ServerRootView` in FeatureServers routes links and windows. | Everything below |
| `NotificationService` (NSE) | Opens the sealed payload; sets title, body, category, thread and badge; records what was shown. | OCPushCore, OCSecurity, OCShared |
| `Widgets` (WidgetKit) | Live Activity UI, Home and Lock Screen widgets, Control Center controls. | OCActivity, OCShared, OCIntents |

**App Intents.** Shared intents, their entities and the widget configuration are in `OCIntents`, which the app and Widgets both include through `AppIntentsPackage`. Intents only the app can run (Send a prompt, Get session status, Open a session) are in `OCAppIntents`. The app injects their implementations from OCSync. `LiveActivityIntent`s run in the app process. There is no Notification Content or Share extension.

**Local package `OpencodeKit`.** Everything compiles in Swift 6 language mode. Core targets are nonisolated; UI targets default to the main actor.

| Target | Isolation | Responsibility | Depends on |
|---|---|---|---|
| `OCFoundation` | nonisolated | `JSONValue`, lenient decoding helpers, `LossyArray`, `OpencodeID` minting (`IDMinter`), `SemVer`, `ServerClock`, redacting `os.Logger` categories | — |
| `OCModels` | `Sendable` value types | Wire models (`SessionInfo`, `SessionMessage`, `AssistantContent`, `ToolState`, `InboxItem`, `PermissionRequest`, `FormInfo`, catalogs, `FileDiff`, `PtyInfo`, `ServerInfo`, `ServerRecord`, `ConnectionState`, `ProbeOutcome`); `ServerEvent`; `StructuredError` | OCFoundation |
| `OCNetworking` | nonisolated; `ServerConnection`, `EndpointResolver` and `APIClient` are actors | `APIClient` with about 95 `Endpoint`s; `SSEParser`; `ServerConnection`; `EndpointResolver`; `ServerProbe`; `PairingParser` and `PairingService`; the terminal WebSocket (`URLSessionWebSockets`); `DirectActionClient`; `PushRelayClient` | OCModels, OCFoundation |
| `OCSecurity` | nonisolated | `KeychainStore`, `CredentialStore`, `BiometricGate`, push key material, `AppAttestService` | OCFoundation, OCModels |
| `OCPersistence` | writer actor | GRDB `CacheStore` (written by `PersistenceWriter`), `DraftStore`, `OutboxStore`, `FileCache`, migrations | OCModels, GRDB |
| `OCShared` | nonisolated | App Group snapshots (JSON files written atomically), deep-link routes, shared constants | OCFoundation |
| `OCPushCore` | nonisolated | Envelope format, HPKE open, payload schema, canonical digest, risk rules, notification categories | OCFoundation, OCModels, OCSecurity, OCShared |
| `OCIntents` | nonisolated | Intents and entities shared by the app and Widgets: stopping a Live Activity's session, the control intents and the widget configuration | OCShared |
| `OCAppIntents` | nonisolated | Intents only the app runs: Send a prompt, Get session status, Open a session | OCIntents, OCShared |
| `OCSync` | main actor | `ServerRegistry`, `ServerStore`, `ReadStore` (the per-server sync engine: event handlers, resync and writes), `SessionModel`, `TranscriptModel`, `ResyncCoordinator`, `OutboxProcessor`, `HomeOrdering`, `LiveActivityCoordinator`, `PushController`, `AppAttestClient`, `TerminalSession`; the in-app demo (`DemoMode`, played by `ScenarioTransport` from a recorded `demo.json`) | OCNetworking, OCPersistence, OCSecurity, OCShared, OCPushCore, OCActivity, OCIntents, OCAppIntents |
| `OCRender` | nonisolated, `@concurrent` | Markdown block pipeline (swift-markdown); unified-diff parser and word diff; tree-sitter highlighting; `TimelineRowBuilder`; `ToolPresenter`s | OCModels |
| `OCDesign` | main actor | Design system; `MarkdownBlockView` (Textual behind a `MarkdownBlockRenderer` protocol); `CodeBlockView`; `OCDiffView` and `CodeCollection`; status pills; composer chrome | OCRender |
| `OCActivity` | nonisolated | `SessionActivityAttributes`, shared by the app and the widget | OCShared |
| `Feature*` | main actor | `FeatureServers`, `FeatureInbox`, `FeatureTranscript`, `FeatureComposer`, `FeatureApprovals`, `FeatureReview`, `FeatureFiles`, `FeatureTerminal`, `FeatureSettings`. FeatureServers composes the others and hosts the demo (`DemoRootView`), and FeatureTranscript embeds approvals, the composer, review and terminals. | OCSync, OCDesign, OCRender; FeatureApprovals also OCPushCore and OCSecurity; FeatureTerminal also SwiftTerm |

**Rules**
- Extensions never link OCSync or OCNetworking, which keeps the NSE small and fast to start.
- Features never import OCNetworking. They call methods on the stores and the engine.
- Every user-facing string goes through its module's `localized(_:)` helper and String Catalog (`Localizable.xcstrings`), with comments for translators. English is the only language so far; `node Tools/strings/sync.mjs` keeps the catalogs in step with the code after a build.
- Two third-party engines sit behind protocols: `MarkdownBlockRenderer` (Textual) and `TerminalEngine` (SwiftTerm).
- Review, files and diff cards share one first-party, read-only `UICollectionView` renderer (`OCDiffView` and `CodeCollection`). It takes the place of Runestone, whose tree-sitter 0.20 requirement conflicts with the tree-sitter 0.25 the project uses. The transcript is a `UICollectionView` too (§3.1).

**Dependencies:** GRDB 7, swift-markdown, Textual, SwiftTreeSitter with 13 grammars and SwiftTerm. For tests: swift-snapshot-testing and swift-clocks.

### 1.2 Diagram

```
 ┌──────────────────────────── Opencode app process ─────────────────────────────┐
 │ Feature targets (SwiftUI, main actor): Servers · Inbox · Transcript ·         │
 │   Composer · Approvals · Review · Files · Terminal · Settings                 │
 │   ──► OCDesign ──► OCRender                                                   │
 │        │ observe @Observable models / call engine methods                     │
 │        ▼                                                                      │
 │ OCSync (main actor): ServerRegistry → ServerStore → ReadStore →               │
 │   SessionModel → TranscriptModel → MessageModel → ContentItemModel;           │
 │   ResyncCoordinator · OutboxProcessor · HomeOrdering · PushController         │
 │        ▲ EventBatch every 16 ms                 │ Endpoint<T> requests        │
 │        │                                        ▼                             │
 │ OCNetworking: ServerConnection · EndpointResolver · APIClient (actors) ·      │
 │   terminal WebSocket · PairingService · ServerProbe · DirectActionClient      │
 │ OCPersistence (GRDB) · OCSecurity (Keychain, Face ID) · OCPushCore · OCShared │
 │ OCModels ◄── OCFoundation                                                     │
 └──────┬─────────────────────────────────────────────────┬──────────────────────┘
        │ HTTP + SSE + WebSocket                          │ App Group JSON + shared Keychain
        │ (LAN / Tailscale / OpenTunnel / custom HTTPS)   ▼
        ▼                                   NotificationService ext   Widgets ext
 opencode V2 server (user's machine)        (HPKE open, rich alert)   (Live Activity,
  /api/*  /api/event  /api/pty/{id}/connect        ▲                   widgets, controls)
  plugin "mobilepush" ─HTTPS─► relay (Workers or Node) ─HTTP/2─► APNs
                     └─HTTP/2─► APNs directly, with the server owner's key (direct mode)
```

### 1.3 Repository layout

```
opencode-ios/
  project.yml   Config/ (signing, Version.xcconfig)   App/   Extensions/{NotificationService,Widgets}/
  Packages/OpencodeKit/{Package.swift, Sources/<target>/, Tests/<target>/, Grammars/<language>/}
  Tests/        the composer editor tests and the snapshot test host
  UITests/      XCUITest flows, driven by Tools/ui-smoke
  Fixtures/{foundation, source, v2/<server-version>/{rest,sse,ws,snapshots}}
  Tools/{opencode-sandbox, mock-llm, fixture-recorder, contract, push-e2e, ui-smoke,
         review-fixture, mcp-fixture, design-reference, grammars, strings, notices,
         demo, screenshots, spec-watch, release, onboarding}
  server/{contracts, plugin, relay}   the MIT-licensed push packages
  docs/   research/                   design notes and the V2 protocol reference
  web/                                the "Pair your phone" onboarding page
  .github/workflows/{ci, contract, plugin, relay, release}.yml
```

## 2. Core engine

### 2.1 Servers, endpoints and credentials

```swift
public struct ServerRecord: Codable, Sendable, Identifiable {
  public let id: ServerID                    // local UUID; opencode has no stable server ID
  public var name: String
  public var endpoints: [EndpointRecord]     // one credential works on all of them
  public var lastInfo: ServerInfo?           // version, pid, urls, paths, capabilities
  public var autoConnect: Bool
}
public struct EndpointRecord: Codable, Sendable, Identifiable {
  public let id: EndpointID
  public var url: URL
  public var kind: EndpointKind      // .lan, .tailnet, .tunnel, .https, .ssh, .unknown
  public var source: EndpointSource  // .pairing, .manual, .discovered, .unknown
  public var isEnabled: Bool
  public var headerNames: [String]   // reserved for custom headers; unused
  public var stats: EndpointStats    // lastSuccess, medianRTT, lastFailure
}
public enum Credential: Codable, Sendable { case password(String), pairingToken(String, expiresAt: Date), unknown }
```

**Keychain**
- One generic-password item per server (service `app.opencode.credentials`, `account = ServerID`) holds the credential and any custom header values, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. It stays in the app's own access group; only the push keys are in the group shared with the NSE.
- The token expiry is parsed from the token itself (`<expiry>.<sig>`). The app warns 5 days ahead.
- There is no refresh endpoint. A 401 on the event stream or on `/api/info` marks the server `.unauthorized` and stops connecting, and Settings opens a re-pair sheet. A 401 on any other request fails that request with "Authentication failed. Pair with the server again."

**Pairing** (`PairingParser`, `PairingService`)
- Accepts exactly what the reference parser `pairing.ts` accepts:
  - the QR payload `{code, urls}`;
  - `…/auth/connect/<code>` links, pasted or scanned from the QR code;
  - legacy `/connect#…` links, answered with "re-run `opencode pair`";
  - a manual URL plus password.
- It calls `GET <url>/auth/connect/<code>` on every URL at once (`Accept: application/json`, 5 s timeout).
- The code is single-use, so a 401 from any URL means "expired".
- Every URL becomes an endpoint of the same server. The first URL is preferred if it answers within 1 s, as in the reference.

**Endpoint racing** (`actor EndpointResolver`)
- Sends an authenticated `GET /api/info` to every enabled endpoint (timeout 2 s on the LAN, 6 s elsewhere).
- Encrypted endpoints (HTTPS, or a Tailscale address, which WireGuard encrypts) race first, because the app cannot tell whether a network is trusted; the credential goes to a plain-HTTP endpoint only when none of them answers. Within a race the order is lan, then tailnet, then https, then tunnel, and after the first 200 the resolver waits 500 ms for a better-ranked one. LAN endpoints join only after the user has seen the Local Network explanation. Notification actions (§4.6) try their endpoints the same way.
- The result carries a diagnosis per endpoint, so the UI can say *why* it failed:
  - `localNetworkDenied`, from `NWPath.unsatisfiedReason`;
  - DNS failure, for example a Pi-hole blocking `*.opentunnel.xyz`;
  - TLS error, timeout, or 401.
- Non-loopback URLs from `/api/info.urls` are added as `.discovered` endpoints.
- It re-races after a failed connect, on every `NWPathMonitor` change, and on foreground when more than 60 s have passed.
- Endpoints must be http or https. `.ssh` is reserved; the app has no SSH transport. The Keychain item can hold custom header values, and every request would send them, but no screen sets them.

**Server clock offset.** The app estimates the server's clock from the `Date` header of `/api/info` (taking the midpoint of the round trip), then refines it with event `created` timestamps. The offset lives in memory and is used for minting IDs (§2.5).

### 2.2 Probe, V1 detection and capabilities

`ServerProbe.probe(endpoint:credential:) -> ProbeOutcome`:

| Response | Outcome |
|---|---|
| `GET /api/info` returns 200 with JSON | `.v2(ServerInfo)`; a version below 2.0.25 (`ServerInfo.minimumVersion`) or outside 2.x gives `.unsupportedV2`, and an unreadable version `.notOpencode` |
| 503 with `Retry-After` | `.v2Starting(retryAfter)`, honoured rather than treated as an error |
| 401 with `{"_tag":"UnauthorizedError"}` | `.unauthorized(.v2)` |
| 401 with an empty body, 200 with `text/html`, or 404 | Probe `GET /global/health`. JSON `{healthy, version}` means `.v1(version)`; anything else is `.notOpencode` |

`ServerCapabilities` has two flags: `pairing` (opencode 2.0.25 or later, which every supported server meets) and `persistentPty` (from `info.capabilities.persistentPty`). `ServerInfo` adds one version gate of its own, `reportsBusyTime` (2.2.2 or later), for the start of a running turn. The server screen shows the capabilities, for example "Pairing needs opencode 2.0.25 or later". Experimental routes are called directly and fail like any other request. Push registration calls `POST /api/rpc/mobilepush/status`; a 404 means the plugin is not installed.

### 2.3 API client and tolerant decoding

```swift
public struct Endpoint<Response: Sendable>: Sendable {
  var method: HTTPMethod, path: String, query: [URLQueryItem] = []
  var scope: Scope                 // .global, .location(directory:), .session
  var body: Data?
  var settled: @Sendable (Int, JSONValue) -> Bool   // a status and body that mean "already done"
  var reports503Message = false, headers: [String: String] = [:]
  var decode: @Sendable (Data, HTTPURLResponse) throws -> Response
}
public actor APIClient { public func send<R>(_ e: Endpoint<R>) async throws(APIError) -> R }
public enum APIError: Error, Sendable {
  case unauthorized, serviceStarting(retryAfter: Duration)
  case server(tag: String, status: Int, body: JSONValue)
  case notOpencode(contentType: String?), transport(URLError), decoding(String), refused(ConnectionFailure), cancelled
}
```

**Request handling**
- **Location scope.** `.location` appends `location[directory]=<abs>`. Responses decode as `Located<T>{location, data}`. Stores key the result under both the canonical directory and the requested one, as `data.ts` does.
- **Authentication.** `Authorization: Basic base64("opencode:<secret>")` is sent preemptively on every request.
- **Content-type check before decoding.** V2 answers unknown GET routes with its web app's HTML.
- **Retries.** GETs are retried twice on transport errors. POSTs are never retried automatically; prompts are retried through the outbox with the same ID.
- `fs.read` URLs are built by hand.

**Decoding rules**
1. Ignore unknown keys, and treat `null` the same as an absent key.
2. Every union has a `.unknown(type: String, raw: JSONValue)` case. This covers `SessionMessage`, `AssistantContent`, `ToolState`, `InboxItem`, form fields and MCP status.
3. A malformed element becomes its union's `.undecodable(raw:error:)` and keeps its position; pages and lists decode through `LossyArray`. The transcript shows an unknown item as a notice row ("Unsupported content: <type>").
4. Numbers also accept the strings `"NaN"` and `"Infinity"`.
5. Tool inputs stay `JSONValue` because they are raw model output. Lenient typed views (`ShellInput`, `EditInput`, and so on) read them.
6. When encoding, leave keys out; never send `null`.

**Events are decoded in two stages**
1. Decode `EventHeader {id, type, created?, location?, durable?}`.
2. Switch on `type`, check the fields of the `data` object, and wrap it in that event's payload view (for example `SessionTextDeltaPayload`), which keeps the raw JSON.

An unknown type becomes `.unknown(header, raw)`. A failed decode becomes `.undecodable(header, raw, error)`. Neither ends the stream.

If an unknown or undecodable **durable** `session.*` event carries a `sessionID`, the engine refetches that session's info and newest page after a 500 ms debounce, because the event may have changed state the client does not model.

`session.status`, `tui.*`, `persistent-pty.*` and `artifact.updated` are decoded but not handled. `session.tool.input.delta` only shows a tool's input while it streams, and `session.tool.input.ended` sets the final text. `session.idle` refreshes open review and file views. `Tools/contract/check-events.mjs` compares the `ServerEvent` cases with the `V2Event` union in an opencode checkout's `packages/client/src/promise/generated/types.ts`; it is run by hand.

### 2.4 Event stream: `actor ServerConnection`

```swift
public actor ServerConnection {
  public nonisolated let output: AsyncStream<ConnectionOutput>  // .state, .events(EventBatch) or .resyncNeeded
  public func start(); public func stop(); public func forceReconnect(_ reason: ReconnectReason)
}
public enum ConnectionState: Sendable, Equatable {
  case idle, resolving, connecting(attempt: Int), connected(EndpointID, since: ContinuousClock.Instant)
  case waiting(attempt: Int, retryAt: ContinuousClock.Instant, failure: ConnectionFailure)
  case suspended, serviceStarting(Duration), unauthorized, incompatible(ProbeOutcome)
}
```

**The connection loop**
1. Resolve an endpoint.
2. Open a data task on a dedicated `URLSession`. A delegate delivers `Data` chunks; the stream is not read byte by byte through `AsyncBytes`.
3. `SSEParser` joins `data:` lines, counts `:` comments as activity, handles CR, LF and CRLF, and skips events larger than 16 MiB.
4. The first frame must be `server.connected`.
5. Events are decoded off the main actor and delivered in batches.
6. The connection asks for a resync on every `server.connected`, after a backlog overflow and after skipping an event over 16 MiB.

| Parameter | Value | Reference client |
|---|---|---|
| First-frame timeout | 3 s on the LAN, 8 s remote | 2 s |
| Watchdog | 45 s with no byte at all (heartbeat comments count) | 45 s |
| Foreground quiet threshold | 20 s, then forced reconnect | 20 s |
| Backoff | 1 s, doubling with full jitter, capped at 30 s; resets once a connection has lasted 10 s; forced reconnects skip it | fixed 1 s |
| Delivery to the MainActor | every 16 ms; immediately for `permission.*`, `form.*` and `session.execution.*` | 10–16 ms |
| In-memory backlog cap | 20,000 events, then drop them and force a resync | — |

**Failure handling**
- The read loop never waits on the main actor. A slow UI therefore cannot trigger the server's 4,096-frame overflow close.
- A 401 stops the loop (`.unauthorized`).
- A 503 waits for `Retry-After`.
- A denied Local Network permission or a failed DNS lookup (for example a blocked tunnel domain) keeps the loop retrying. The banner shows the cause, such as "Allow Local Network access in Settings.", with a Reconnect button.
- The last 50 state changes are kept for the diagnostics screen.

### 2.5 Sync engine

**Stores** (all `@MainActor @Observable final class` in OCSync)

| Store | Holds |
|---|---|
| `ServerRegistry` | Ordered `[ServerStore]`, scene-phase and network-path handling, the push controller, and the widget and Spotlight integration. `HomeOrdering` computes Home's cross-server lists from the servers. |
| `ServerStore` | `record`, the connection `state`, `connection`, `capabilities`, and `readPath`, its `ReadStore` |
| `ReadStore` | The sync engine: `projects`, `sessions: [String: SessionModel]`, `running: Set<String>`, `permissions: [String: [PermissionRequest]]`, `forms: [FormOwner: [FormInfo]]` (owner is a session, or `"global"` plus a location), `catalogs: [String: LocationCatalog]` keyed by `Location.key`, the outbox entries and the composers. `ServerStore` forwards the first six. |
| `SessionModel` | `info`; `status: RunStatus` (`idle`, `running(since)`, `retrying(attempt, at)`, taken from `session.retry.scheduled`); `pending: [InboxItem]`; `transcript: TranscriptModel?` (loaded on demand); a derived `attention`; `lastSeq` |
| `TranscriptModel` | `order: [MessageID]`, `messages: [MessageID: MessageModel]`, `olderCursor`, `loadingOlder` |
| `MessageModel` | For assistant rows, `items: [ContentItemModel]`, keyed by `ContentKey` (`.text(ordinal)`, `.reasoning(ordinal)`, `.tool(callID)`, or `.fallback(index)` for an unknown content type) |
| `ContentItemModel` | The single item a streaming delta changes, so exactly one row re-renders |
| `LocationCatalog` | Agents, models, default model, providers, commands, skills, references, MCP and VCS. Each sits in a `Revalidating<T>` cell that mirrors `createSync()`: at most one load per key in flight, and after an invalidation the reload runs afterwards, so an older response can never overwrite a newer one |

**Applying events.** The handlers port `handleEvent` from `data.ts` case by case, with these changes:

1. **Handlers are safe to apply twice.**
   - `*.started` inserts the item by `ContentKey` only if it is missing. The ordinal comes from the event; for content loaded over HTTP it is derived per kind.
   - Tool items are keyed by call ID, rows by message ID.
   - Rows the client creates locally reuse the event ID with `evt_` replaced by `msg_`, so the server's copy later replaces them. This covers agent, model and location switches, `synthetic`, `system`, `shell`, `idle` and `compaction`, plus `session.skill.activated`, which the reference does not handle live.
2. **Sequence numbers.** Each session keeps `lastSeq` from `durable.seq`.
   - Events whose `seq` the session has already applied are duplicates and are dropped.
   - Gaps are normal (filtered internal events consume numbers) and are ignored.
   - An older `seq` the session has not seen before (a backwards jump) triggers a refetch of that session.
   - HTTP snapshots carry no `seq`, so `lastSeq` resets after each snapshot.
3. **Deltas** are applied only to rows the client holds; `*.ended` is authoritative. If the client missed an item's `started` event, the item is flagged `joinedMidStream` and shown as "catching up" until `.ended` arrives.
4. Sessions without a loaded transcript receive only session-level effects: status, attention, cost and last activity.
5. **Revert hiding uses positions.** Rows at or after the boundary row's index are hidden. The ID comparison `id >= revert.messageID` is only a fallback when the boundary row is not loaded. The server itself orders by `seq`, so this stays correct even when a client-minted ID is skewed by the phone's clock.
6. Permissions and forms raised in a child session count toward the root session's attention. The engine walks `parentID` and fetches unknown parents.

**Resync on every `server.connected`** (`ResyncCoordinator`)
1. Refresh `GET /api/info`, then drain the outbox. The same IDs are reused, and the server admits each ID only once.
2. In parallel: `GET /api/session/active`, `GET /api/project` and `GET /api/session?parentID=null&limit=50`. Then fetch any running session that is not yet known. From 2.1.0 the session list adds `archived=false`, so scripted `opencode run --archived` runs cannot fill the page, and one more `archived=true` page updates only the sessions the app already holds: archiving moves `time.updated`, so a session archived while the app was away is among the newest. Home's own pages also send `archived=false`. Home, the switcher, Spotlight, widgets and Shortcuts leave archived sessions out on every version, and `session.archived` and `session.unarchived` move them out and back live.
3. In parallel:
   - `GET /api/permission/request` and `GET /api/form` for each location of a running or open session, or of a request still shown;
   - for each transcript that is on screen, `GET /api/session/{id}`, the newest page (`limit=50&order=desc`) merged by gap splicing, `GET …/inbox`, and the session's permission and form lists.
4. Invalidate all catalogs. Refetch those for the open session's location (the composer needs them); fetch the rest when they are opened.

**Events that arrive during a fetch.** This generalizes the reference's `activeUpdates` and `pendingUpdates`:
- While a snapshot of a set (active sessions, inbox, permissions, forms) is in flight, events keep updating the live model. They are also recorded as an insert/update or a deletion marker per ID, and re-applied once the snapshot lands.
- When a message snapshot lands, rows changed by durable events during the fetch keep their local version, and rows not yet acknowledged by the server are always kept.

**Gap splicing** (for the open transcript)
1. Find the newest local row (one the server has confirmed, not an optimistic placeholder) whose ID appears in the freshly fetched newest page.
2. Replace everything from that row onward with the server's rows, and keep the older local history.
3. With no overlap, fetch up to four older pages looking for one; failing that, reset to the newest page with a fresh `olderCursor`.

Messages deleted by a revert committed while the phone was disconnected disappear naturally, because the splice replaces the tail.

**Optimistic writes and the outbox**
- **ID minting.** `IDMinter` (one per server) produces `ses_` IDs (descending) and `msg_` IDs (ascending) exactly like `Identifier.create`: 12 hex characters of `ms*4096+counter`, then 14 base62 characters. It uses the server-corrected time, and each new `msg_` is forced to sort after the session's newest known message.
- **Creating a session.** The `SessionModel` appears immediately, then `POST /api/session {id, location, agent?, model?}`. Prompts to that session wait for the create to finish. The local session is removed only if the server never acknowledged it.
- **Sending a prompt:**
  1. Write `OutboxEntry {id, serverID, sessionID, prelude, body, createdAt, attempts, state}` to GRDB first. The body is the exact JSON bytes, so a retry is byte-for-byte identical.
  2. Show the row as *sending*.
  3. Run the prelude in the server's order: `POST …/agent` if it differs from `info`, then committing a staged revert if the user confirmed it, then `POST …/model` if it differs. Committing a revert deletes the rows after its boundary, so a model switch made before the commit would be lost.
  4. Send prompts for one session one at a time, in order.
  5. A 200 or the `session.inbox.enqueued` echo acknowledges the entry.
  6. On a transport error, keep the entry and retry while connected and on every reconnect (the server admits each ID only once).
  7. A resent ID that matches the first admission's session and type returns that first admission, even if the new bytes differ; the server reconciles by ID without comparing payloads. A 409 means the ID collided with another session or type. A 409 or other 4xx marks the row failed, with *Edit and resend*. Exact stored bytes remain the client's retry invariant.
  8. Entries older than 10 minutes found at launch are never sent automatically; the user is asked.
  9. Sends run inside `beginBackgroundTask`, so leaving the app right after tapping Send does not produce a false error.
- **Other optimistic changes**, each applied in the UI before the server answers:
  - a permission reply (a 404 means already settled, which counts as success);
  - a form reply (a 409 "already settled" counts as success);
  - rename, delete and delivery change;
  - cancelling a pending item, which puts its text and attachments back in the composer.
- `POST …/command` takes no ID, so it is never retried automatically.

**Foreground and background**
- **Going to the background:** within a background task, drain the outbox, flush persistence and write the App Group snapshot. Then stop the streams (`.suspended`) and close terminal sockets, keeping their cursors.
- **Becoming active:** start the streams. If the stream was quiet for more than 20 s, force a reconnect. Re-race endpoints if the network path changed or more than 60 s passed.
- **`NWPathMonitor` changes** (debounced 500 ms): re-race endpoints and force a reconnect.
- **Launches caused by a notification action** use `DirectActionClient`: no SSE and no resync.

**Pagination.** The first page holds the 50 newest messages; older pages of 50 load through `cursor.next` when the user scrolls to the top. At most six transcripts stay in memory (least recently used first out); the rest live in the cache.

### 2.6 Persistence: GRDB rather than SwiftData

**Why GRDB 7 rather than SwiftData**
1. **Schema independence.** The server is the source of truth, and its schemas change weekly. Storing raw server JSON plus a few indexed columns keeps the cache unaffected by server changes, because it is read with the same tolerant decoder. SwiftData would need an `@Model` copy of every type and a migration for each server change.
2. **Swift 6 concurrency.** GRDB's `DatabasePool` is `Sendable` and allows concurrent WAL readers, and a background writer actor batches writes. SwiftData's `ModelContext` is not `Sendable`, which pulls persistence onto the main actor.
3. **Predictable bulk work.** Bulk upserts of thousands of rows run inside explicit transactions, and tests use an in-memory database.

**Schema (migrations v1 to v6)**

| Table | Columns |
|---|---|
| `server` | `id`, `json` |
| `project` | `server_id`, `id`, `active_at`, `json` |
| `session` | `server_id`, `id`, `parent_id`, `project_id`, `directory`, `title`, `updated_at`, `idle_at`, `viewed_at`, `outcome`, `accessed_at` (for LRU retention), `json` |
| `message` | `server_id`, `session_id`, `id`, `position`, `type`, `complete`, `json` |
| `transcript_window` | `server_id`, `session_id`, `older_cursor`, `fetched_at` |
| `catalog` | `server_id`, `location_key`, `kind`, `fetched_at`, `json` |
| `draft` | `id`, `server_id`, `session_id`, `directory`, `text` (a JSON-encoded `AttributedString`), `attachments_json`, `delivery`, `options_json` (composer options, v3), `comments_json` (line comments, v4), `updated_at` |
| `outbox` | the `OutboxEntry` fields (§2.5), plus `operation`: `prompt`, `create` or `compact` (v2) |
| `pty_cursor` | `server_id`, `pty_id`, `cursor`, and for resuming a terminal `directory`, `cols`, `rows`, `screen` and `updated_at` (v6) |
| `local_meta` | `server_id`, `session_id`, `pinned`, `hidden`, `reviewed_files`, `review_state` (v4). `muted` is unused; mutes live in the push preferences. |
| `notification_reply` | `server_id`, `notification_id`, `input_id`: the prompt ID a reply from a notification used, so a repeated action never sends twice (v5) |
| `openapi_ops` | `version`, `ops`; unused |
| `cache_migration` | one-time migration markers, such as the import of the older JSON server-record file |

**Storage rules**
- **Write-behind.** Writes are debounced by 2 s and also happen at the end of a turn and on backgrounding. Nothing is written per streaming delta.
- **Keep the database out of the App Group.** It lives in the app's own sandbox, because iOS kills a suspended app that holds SQLite locks in a shared container (crash code `0xdead10cc`). Extensions read small, atomically written JSON snapshots in the App Group instead.
- **Retention:** the last 200 sessions or 300 MB, evicting the least recently used.
- **File protection:** `completeUntilFirstUserAuthentication`, which background action handling needs.

**Drafts**
- Keyed by (server, session), or by (server, directory) for a session not yet created.
- Store the attributed text, with attachment files under `Application Support/Drafts/<id>/`.
- Saved 300 ms after the last edit and whenever the scene becomes inactive.
- Never lost on navigation, crash or session switch.

### 2.7 Concurrency model

- **Main actor:** all `@Observable` stores and SwiftUI. Event handlers are cheap (appending strings, setting dictionary entries). Each terminal is a main-actor `TerminalSession` with its own WebSocket.
- **Actors:**
  - `ServerConnection` and `EndpointResolver` (one of each per server);
  - `APIClient`;
  - `OutboxProcessor`;
  - `PersistenceWriter`, `DraftStore` and `FileCache`;
  - `IDMinter` (one per server);
  - `TimelineRowBuilder` and `StreamingMarkdown`.
- **`@concurrent` functions** do event decoding, diff parsing, highlighting, code search, and image decoding and downscaling. Markdown is parsed in the `StreamingMarkdown` actor. OCSync, OCDesign and the Feature modules enable "nonisolated nonsending by default".
- **Data flow:**
  1. Bytes go through the parser inside the connection actor.
  2. Events are decoded in `@concurrent` functions into an `EventBatch: Sendable`.
  3. An `AsyncStream` carries the batches to one main-actor consumer task per server.
  4. The handlers update the models, and SwiftUI views update.

  Event handlers schedule persistence and notify the push controller, which updates Live Activities. The widget snapshot and the Spotlight index follow the models with `withObservationTracking`.
- Long-running work belongs to an actor or a store and is cancelled on `stop()`. Views own short tasks. There are no detached tasks.

## 3. Features mapped to screens

| Screen | Target | Key behaviour | Main APIs |
|---|---|---|---|
| Server list, pairing, re-pair, endpoint editor, "Update opencode" | FeatureServers | QR scanning with VisionKit `DataScannerViewController`, link paste, or manual entry. Health per endpoint and an "Unencrypted" badge for HTTP. An explanation shown before the Local Network permission prompt. A token-expiry banner. | `/auth/connect`, `/api/info` |
| Home | FeatureInbox | "Needs you" and "Running" across all servers, then the other sessions by day (see the note under this table). Each row shows project avatar, title, server/directory chip, status glyph and cost. Blocked rows have a Review button. Swipe actions: mark read (`/view`), pin, hide (local only; V2 has no archive). | session list, `session/active`, permission and form lists |
| Projects and sessions | FeatureInbox | Projects sorted by `time.active`. Search by title. | `/api/project`, `/api/session?project=` |
| New session | FeatureComposer | A directory browser (`fs.list` with an absolute path) followed by `GET /api/location`. Optional new worktree (`POST /api/worktree`). | `/api/location`, `/api/worktree` |
| Transcript | FeatureTranscript | See §3.1 | messages, events, `session.diff`, shell output |
| Composer and pickers | FeatureComposer | See §3.2. The model picker is grouped by provider, with search, a Default badge, image-input and variant badges, and prices. The agent picker shows agents where `mode != subagent && !hidden`, in their colours. The effective model and agent are always read back from the server's `session.model.selected` and `session.agent.selected` events. | prompt, command, shell, interrupt, inbox, `/model`, `/agent` |
| Session actions | FeatureComposer | Rename, Fork from message, Compact, Undo, Redo, Move to another worktree, Export, Mute notifications and Delete, from the session menu | session writes, `session.move`, export |
| Permission and question sheets | FeatureApprovals | See §3.3 | permission, form |
| Changes and review | FeatureReview | See the note under this table | `session.diff`, `vcs.*`, `revert.*` |
| Files | FeatureFiles | Lazy tree (`fs.list`) and fuzzy find (`fs.find`). Native read-only code viewer with tree-sitter highlighting (byte-bounded, off the main actor). Quick Look for images and PDFs. ETag caching and range reads for large files. "Mention in composer"; open at a line from transcript links. | `fs.*` |
| Terminal | FeatureTerminal | Terminal list per location, rendered with SwiftTerm. WebSocket authenticated with the Basic header; resume with `cursor` (advance by `utf16.count`; the binary `0x00` + JSON frame sets the cursor). Resize with a `PUT`: the first size at once, later ones at most every 100 ms. Key bar with Esc, sticky Ctrl and Alt, Tab, the arrows, `\|`, `~`, `/` and `-`. Reconnect on foreground; handle close code 4404. A sheet runs a command outside any session. | `pty.*`, `shell.*` |
| Command palette | FeatureServers | ⌘K, or the toolbar on iPhone: commands, sessions from every server, and projects | — |
| Settings | FeatureSettings | See the note under this table | integration, mcp, permission/saved, config, stats |

**Home**
- **Needs you:** a pending permission or question anywhere in the session family, or a failed session the user has not seen.
- **Running:** a member of the family is running. The row shows a status dot and how many are running.
- **By day:** every other root session, under Today, Yesterday or its date, pinned sessions first. An unread session (`time.idle > time.viewed`) has a bold title and an Unread label.

**Changes and review**
- A "Changed N files" card at the end of each turn. File names come from the steps' `snapshot.files`; line counts come from `GET /api/session/{id}/diff?from=<the turn's first prompt>`. The Changed files setting hides the card.
- VCS review of the working tree or the branch.
- Diffs are unified on narrow widths and side by side on wide ones, with word-level highlights and collapsed context.
- A per-file "Reviewed" mark.
- Long-press a line to attach a comment to the next prompt.
- Undo the turn (`revert/stage`) and Redo (`DELETE /revert`). Before the next send, the staged revert is committed after the user confirms.

**Settings**
- **App:** follow-up delivery (Steer by default), line wrapping in diffs and files, the changed-files card and the agent control; terminal font size and Option as Meta; notifications per category, quiet hours and Live Activities; widgets, Shortcuts and Spotlight. Colours follow the system appearance. The timeline detail preset (Compact by default) is chosen from the session header's menu.
- **Per server:** name, endpoints and their health, capabilities, connection diagnostics with an export that leaves out names, paths and secrets, and settings for providers, MCP, saved permissions, agents and tools, configuration, worktrees, projects, usage statistics and administration. Push status and a test push are under Notifications.
- **Providers and integrations:** connect with an API key, a device code or a pasted code. An `auto` OAuth flow shows "Finish on your computer" and polls. Accounts are managed through integration connections; `GET /api/credential` is never called.
- **Also:** MCP status and connect (an MCP OAuth sign-in always calls back to 127.0.0.1 on the server, so it must be finished in a browser on that machine); saved permissions; read-only config documents; worktrees; plugins.

### 3.1 Transcript

**Row model.** `TimelineRowBuilder` (an actor in OCRender) turns messages into `[TimelineRow]`. Completed turns are frozen and cached; only the open turn is rebuilt. Grouping follows the official detail presets (Everything, Detailed, Compact, Quiet, Messages only). Row kinds:
- `userPrompt`, with a Voice badge when the text follows the official app's `Voice delegation.` format;
- `assistantText`, `reasoning`, `tool`;
- `toolGroup`, labelled like "Used 3 Read, Glob, Grep", or "Thinking" for reasoning alone;
- `subagent`, `shell`;
- `notice`: agent, model or location switch, synthetic or system message, or content the app does not know;
- `compaction`, `retry`, `error`, `pendingInput`, `turnEnd`.

A row carries a `reference` to its content item, `children` for a group, the turn's `files`, a `badge` and a child session ID.

**Tool renderers.** The `ToolPresenter` protocol has `matches`, `summary` and `detail`. A registry falls back to `GenericToolPresenter`. Renderers per tool:

| Tool | Rendering |
|---|---|
| `read`, `glob`, `grep` | Grouped |
| `edit`, `patch` | Diff cards from `metadata.files` |
| `write` | Added-file view built from `input.content` |
| `shell` | Live output by polling `GET /api/shell/{metadata.shellID}/output` every second, only while the row is visible and the app is active. An exit or timeout badge even when the status is "completed". |
| `subagent` | A card that opens the child transcript, with a read-only composer |
| `question` | Hidden while pending; a question-and-answer summary afterwards |
| `skill`, `webfetch` | Compact rows |
| `websearch` | Result links |
| `execute` (CodeMode) | Nested `toolCalls` plus console output |
| MCP `<server>_<tool>` | Generic, with an MCP badge |
| V1 history (`bash`, `task`, `apply_patch`, `todowrite`) | Mapped to the matching renderer |
| Unknown | Name, status, pretty-printed input JSON and text content |

**Streaming performance**
- Each content item is its own `@Observable`, and updates are delivered every 16 ms.
- `StreamingMarkdown` (one per text item):
  - finished blocks are rendered once, cached by hash and drawn as `Equatable` views;
  - only the unfinished tail is re-parsed, off the main actor, at most 12 times a second;
  - unclosed syntax in the tail, such as an open code fence, is closed before parsing.
- Code fences stay plain monospace until closed, then are highlighted asynchronously.
- Tool output longer than 200 lines is folded and opens in a sheet backed by `UITextView`. Inline images from `data:` URIs are decoded off the main actor and shown at most 280 × 220 points; Markdown images are never fetched.
- The container is `TimelineCollection`: a `UICollectionView` with a compositional layout, a diffable data source and `UIHostingConfiguration` cells. (A `LazyVStack` looped endlessly in layout on iOS 26.5 with rows of varying height.) A text delta never reloads the data source. Away from the bottom, a "Jump to latest (n)" pill appears. Prepending older pages keeps the first visible row at the same offset.
- Budgets, checked by `ReadPerformanceTests` and `TimelineCollectionTests` on the simulator:
  - at most 4 ms of main-thread work per update at 50 deltas a second;
  - a cold build of 2,000 messages off the main actor within 250 ms;
  - under 250 MiB physical footprint for a rendered 5,000-row session.

**Header and selection**
- The header shows context usage and family cost. Context usage is the last assistant step's tokens divided by `limit.context`. Family cost includes children, listed with `parentID=<root>&limit=200`.
- Text selection uses iOS 27's `textSelection` behind `#available`. On iOS 26, a "Select text" sheet backed by `UITextView` stands in.

### 3.2 Composer

**Editor.** `PromptEditor` wraps a TextKit 2 `UITextView` bound to an `AttributedString`; the iOS 26 `TextEditor` did not delete mentions atomically. A `MentionAttribute` marks each mention with a kind (`file`, `agent`, `skill` or `reference`) and a value. Mentions are inserted and deleted whole, and marked text from an input method is left alone.

**Triggers**
- **`@`** suggests:
  - files from `fs.find` (debounced 120 ms);
  - subagents, skills and references.

  There are no MCP-resource mentions. V2 accepts only `data:` and `file://` attachment URIs (`packages/core/src/session/prompt.ts`), and the client has no `fs/write` upload fallback for other sources.
- **`/`** suggests server commands plus client commands:
  - `new`, `undo`, `redo`, `compact`, `fork`, `model` and `agent`;
  - `btw`, which asks a side question through `session.generate` and shows the answer in a card above the composer, outside the session's history.

  Export is in the session menu, and `/init` and `/review` come from the server's own commands.
- **`!`** switches to shell mode (`POST …/shell` with a minted ID).

**Attachments**
- Sources: PhotosPicker, camera, Files, paste, and drag and drop on iPad.
- Images are downscaled to 2,000 px and sent as canonical `data:` URLs, with a 20 MiB cap.
- Warnings appear when the model lacks image or PDF input. V2 sends PDFs only to models that declare PDF input, and drops audio and video.

**Voice.** `SpeechAnalyzer` with `SpeechTranscriber` runs on the device, primed through `contextualStrings` with file names, code symbols from recent messages and agent names. Words still being recognised are greyed out. Dictation inserts editable text and never sends it. Hands-free conversation sends the transcript after a two-second pause and a three-second countdown, which the user can cancel, then reads the reply aloud.

**Delivery**
- **Idle:** Send.
- **Running:** Send uses the default follow-up (Steer). The send menu offers:
  - *Queue instead*;
  - *Interrupt and send*: the prompt is admitted with steer, then `interrupt?resume=true` is called, which continues with the pending steered input.
- **Empty composer while running:** the button becomes Stop (`interrupt`).
- **Queue panel** above the composer lists queued prompts, with *Steer* (*Send* when idle), *Undo*, which restores the text and attachments, and *Remove*. It also lists outbox entries not yet sent: *Sending*, *Edit and resend*, or *Waiting for confirmation* with *Send*. Steering and stranded prompts stay in the timeline, with *Move to queue*.
- The keyboard stays open after sending. With a hardware keyboard, Return sends, Shift-Return inserts a newline, and ⌘↩ sends with the alternate delivery.

### 3.3 Permission and question sheets

**Where a pending request appears**
- Inline on the matching tool row (matched through `source.id`).
- In a dock above the composer, including requests from child sessions.
- As a full sheet.

**The sheet shows**
- the action;
- the **full** resources in monospace, with copy;
- the working directory;
- the edit preview from `metadata.files`;
- the `save` patterns that "Allow always" would store, for example "Always allow `git status *` in web-app";
- the risk tier.

**Buttons**
- **Reject**, with an optional note. The copy warns that rejecting also rejects the session's N other pending requests and, without a note, ends the turn.
- **Allow always**, after device-owner authentication (Face ID, Touch ID or the passcode).
- **Allow once**, the primary button. A high-risk request also needs device-owner authentication.

The request is removed from the UI as soon as the user replies. A 404 means it was already settled elsewhere.

**Questions (forms).** A generic `FormRenderer` supports:
- string fields (with options: single choice plus "Other");
- multiselect with minimum and maximum;
- number and integer, boolean, and external-URL fields;
- `when` conditions, required-field validation and a review step.

*Dismiss* asks for an optional reason, because dismissing without one ends the turn.

**Silence is never consent.** Nothing is approved automatically. Per-project auto-accept, which the desktop app has, is not offered.

### 3.4 iPad and Mac

- The layout mirrors the opencode desktop app:
  - project tabs along the top;
  - the session timeline with the prompt dock as the main column;
  - a review panel on the right with Changes, Files, Terminal and Context;
  - the Home sidebar (project picker, session search, sessions by day, with "Needs you" and "Running" on top) as a collapsible pane.

  Panes become sheets on narrow widths. On iPhone, Home is the root of a navigation stack, a session opens on top of it, and the review panel opens as a sheet.
- Home and the session column can be resized by dragging, and each window keeps its layout.
- Multiple windows with `WindowGroup(for: SessionRef.self)`, each keeping its own state in `@SceneStorage`.
- A menu bar built with `.commands`:

  | Shortcut | Action |
  |---|---|
  | ⌘N | New session |
  | ⇧⌘N | New window |
  | ⌘U | Add files |
  | ⌘↩ | Send (with the alternate delivery while a run is active) |
  | ⌘. | Stop |
  | ⌘K | Command palette |
  | ⌘F | Find |
  | ⌘' | Choose model |
  | ⇧⌘D | Cycle thinking effort |
  | ⇧⌘A | Review the next approval |
  | ⌥⌘↑, ⌥⌘↓ | Previous and next session |
  | ⌥⇧⌘↑, ⌥⇧⌘↓ | Previous and next unread session |
  | ⌘1–9 | Sessions |
  | ⌘\ | Toggle sidebar |
  | ⇧⌘R | Toggle review |
  | ⌘T, ⇧⌘W | New and close terminal |

- Drag and drop into the composer.
- The same build runs on Apple silicon Macs as "Designed for iPad".

## 4. Push notifications and Live Activities

### 4.1 Flow

1. The plugin running inside the user's opencode server sees an event and seals a payload for each registered device.
2. It sends the sealed payload to the relay (`POST /v1/push`).
3. The relay sends APNs a generic alert carrying the ciphertext, with the category `OPEN_ONLY`.
4. The NSE decrypts it and shows the full notification.
5. When the user taps an action, the app starts in the background and talks to the server **directly**. It re-reads the request, checks the digest and replies.

The relay is never on the reply path. In direct mode the plugin sends step 3's request to APNs itself, and there is no relay at all.

### 4.2 The opencode plugin

`@opencode-ios/opencode-mobile-push` (a placeholder name until the package is published), written in TypeScript against the V2 plugin API. opencode runs its TypeScript sources directly.

**Installation and scope**
- Installed once with `opencode plugin add @opencode-ios/opencode-mobile-push`. `plugin add` has no scope flag: it always adds a server plugin to the global configuration. Until the package is on npm, the plugin's directory goes in `plugins` in a configuration file instead. The app detects the plugin through the RPC `status` call and shows the install command, ready to copy, when it is missing.
- One plugin instance runs per location. In opencode 2.1.3, `ctx.event.subscribe()` gives every instance every location's events, so each instance acts only on its own location's events. When no instance of a location runs in the process, any instance settles that location's replies and its `location.shutdown`.
- `ctx.storage` is the global key-value store (`kv.ts`, a global node), so a device registered through any location is visible to all instances.
- Session events that arrive without a location (`session.execution.*`, `session.deleted`, `session.retry.scheduled`) are placed by the session's location, learned from its other events or read with `ctx.session.get`. Other events without a location are ignored. A `sent/<eventID>` claim in shared storage stops a repeated delivery from being pushed twice; claims are removed after a day.

**RPC methods** (`mobilepush`)
- `status`;
- `registerDevice({sendToken, relayURL, devicePublicKey, keyID, appServerRef, label, prefs})`, returning `{serverPublicKey, pluginVersion}`;
- `unregisterDevice`;
- `listDevices`, including the last delivery result;
- `test`;
- `registerActivity({keyID, activityRef, sessionID})`;
- `setPresence({keyID, foreground, sessionID?})`.

**Triggers**
- `permission.asked` and `form.created`, after a 3 s grace period. The push is cancelled if the request is answered first, which also skips requests a desktop client accepts automatically.
- `session.execution.failed`.
- `session.execution.succeeded`, for root sessions only, and only for a run that took a step: a run that only applied an inbox item, such as a move, finishes silently.
- When a pushed request is answered (`permission.replied`, `form.replied`, `form.cancelled`), a passive replacement with the same collapse ID, priority 5 and no sound, reads "Answered on another device". The same replacement follows when a pushed permission request ends without an answer: Stop, deleting the session, or the location shutting down.

**Presence.** While the app is in the foreground it sends a heartbeat every 30 s, valid for 45 s. Pushes to a device whose app is open are skipped, except a test push and the replacement for an alert the device already received. If presence is unknown, the push is sent.

**Child sessions.** Requests from a child session carry its own and its root's IDs. The notification is grouped under the root and opens the child session at the request, in the window that shows its root if there is one.

**Payload content**
- kind, the app's own reference for the server, session and root session IDs;
- title and project folder name;
- request ID, action, and a summary of at most 300 characters (command, path or question);
- option labels;
- risk tier, from the shared `risk-rules.json`;
- pending count;
- `digest`: lowercase hex SHA-256 of the RFC 8785 serialization of `{requestID, sessionID, action, resources, save}` for a permission request, or `{formID, sessionID, title, fields}` for a form;
- expiry.

**Direct mode.** With the plugin's `apns` option (the path to the server owner's `.p8` key, its key ID, the team ID, the app's bundle ID and the environment), the plugin sends to APNs itself: the same sealed payloads, collapse IDs, priorities, expiry and Live Activity updates, over one HTTP/2 connection per process with an ES256 provider token. It refuses a key file that other users can read, and never logs the key or returns it to the app. A device registers for it with `registerDevice {transport: "direct", apnsToken, bundleID, environment, …}` over the server connection, and the bundle ID and environment must match the key's. The app chooses relay or direct per server, under Notifications → Delivery.

**Failures.** Network failures, 5xx answers and `rejected` are retried up to three times, after 1, 2 and 4 seconds, while the push is unexpired. `gone`, or a 401 because the app revoked this server's sender, removes the registration.

### 4.3 The relay

A Hono app, MIT-licensed, with two entry points that share every route. On Cloudflare Workers (`src/worker.ts`) it uses D1, one Durable Object per rate-limited key (`RateLimiter`) and one that mints the shared APNs provider token (`ApnsTokenCache`), and calls APNs with `fetch`. On Node 24 (`src/node.ts`) it uses `node:sqlite` and `node:http2`.

| Method and path | Caller and auth | Body → result |
|---|---|---|
| `POST /v1/attest/challenge` | App, only with `APP_ATTEST=required` (404 otherwise). A per-IP limit of 60 an hour. | `{}` → `{challenge, expiresAt}`, single use, valid 5 minutes |
| `POST /v1/attest/keys` | App, only with `APP_ATTEST=required` | `{keyID, challenge, attestation}` → `{keyID}`; the relay verifies the attestation against Apple's pinned root and stores the key |
| `POST /v1/devices` | App. A per-IP limit of 20 registrations an hour. With `APP_ATTEST=required`, an App Attest assertion over a fresh challenge, in the `x-app-attest-key` and `x-app-attest-assertion` headers. `APP_ATTEST` is `off` by default. | `{apnsToken, env, bundleID}` → `{deviceID, deviceSecret}` |
| `PUT /v1/devices/{id}`, `DELETE /v1/devices/{id}` | App, `deviceSecret` | Token rotation (sent on every launch; repeating it is harmless) and removal |
| `POST /v1/devices/{id}/senders`, `DELETE …/senders/{sid}` | App, `deviceSecret` | One `sendToken` **per paired server**, so unpairing a server revokes only that one |
| `PUT /v1/devices/{id}/activities/{ref}` | App, `deviceSecret` | `{pushToken, expiresAt}` |
| `POST /v1/push` | Plugin, `Bearer sendToken` | `{kind, priority, collapse, thread, expiresAt, envelope}` → `{result: delivered \| gone \| throttled \| rejected}` |
| `POST /v1/activity` | Plugin, `sendToken` | `{ref, event: update \| end, state, staleAt, dismissAt?, priority}` |
| `GET /v1/health` | Public | Status |

The app never calls `DELETE /v1/devices/{id}`; unpairing a server revokes only that server's sender.

**What the relay stores:** token hashes, APNs tokens and Live Activity tokens, each device's environment and bundle ID, and activity expiry times. Its logs carry only the event, route, kind, result, APNs status and counts, never a token, secret, ID, IP address or envelope.

**The APNs request it builds**
- a **generic** alert ("opencode needs your approval", "A session finished");
- `mutable-content: 1`, so the NSE runs;
- the category `OPEN_ONLY` for every kind. The NSE sets the kind's category only after it has opened the envelope, so an alert the extension did not process offers no action;
- `thread-id` set to an opaque hash, and `apns-collapse-id` set to a hash of the request ID, or of the session ID for a result, all salted with the device's key ID;
- interruption level `time-sensitive` for input requests, `active` for results, `passive` for replacements;
- priority 10 or 5, and a short expiration for approvals;
- authentication with an ES256 JWT, cached for 50 minutes.

**Limits:** 30 alerts a minute and 500 a day per device; 30 Live Activity updates a minute and 2,000 a day per device; 20 registrations an hour per IP address.

Whether a Worker's `fetch` reaches APNs over HTTP/2 is not yet verified. If it does not, the Node entry point runs instead, for example on Fly.io.

### 4.4 Envelope and encryption

**Keys**
- For each paired server, the app generates an X25519 key pair (`Curve25519.KeyAgreement`). The private key goes in the shared Keychain with `AfterFirstUnlockThisDeviceOnly`.
- The app pins the plugin's static public key, which `registerDevice` returns.

**Sealing**
- **HPKE in auth mode**, which lets the NSE verify the sender:
  - suite `DHKEM(X25519, HKDF-SHA256)`, HKDF-SHA256, ChaCha20-Poly1305;
  - `@hpke/core`, `@hpke/dhkem-x25519` and `@hpke/chacha20poly1305` in the plugin, and CryptoKit's `HPKE` in the app.
- `info = "opencode-ios push v1"`.
- `aad = "oc1|kind|exp|kid"`, which binds the fields the relay can see to the ciphertext.
- The plaintext is padded to 512, 1,024 or 2,048 bytes, and the ciphertext stays under 3 KB, in `oc: {v, kid, kind, exp, enc, ct}`.

Neither the relay nor anyone who knows a device's public key can read or forge the content. Shared test vectors live in `server/contracts/` and run in both the Swift and TypeScript test suites.

### 4.5 Notification Service Extension

1. Find the keys by `kid` and open the envelope.
2. Reject it if it has expired.
3. Set:
   - title, for example "Allow `shell`?";
   - subtitle: session and project;
   - body: the summary;
   - `categoryIdentifier`, from the kind, the risk tier, whether a question is one free-text field, and the Lock-screen approvals setting;
   - `threadIdentifier`: the root session;
   - relevance score;
   - badge: the sum of the per-server pending counts kept in the App Group.
4. Write `shown/<requestID>.json`, holding the digest and summary, to the App Group.

On any failure, the generic text stays and the category stays `OPEN_ONLY`.

### 4.6 Actions and safe approval semantics

| Category | Actions, in order |
|---|---|
| `PERMISSION` | Open (brings the app forward; first, so Apple Watch Double Tap never approves anything) · Allow once (`.authenticationRequired`) · Reject (`.destructive`) · Reject with note… (text input, `.authenticationRequired`) |
| `PERMISSION_HIGH_RISK` (any `rm`, `sudo`, `git push`, `external_directory`, unknown actions, …) | Open · Reject |
| `QUESTION` | Open · Answer… (text input, `.authenticationRequired`; only for a single free-text question) |
| `FINISHED`, `FAILED` | Open · Reply… (text input, `.authenticationRequired`; queued as a prompt) |
| `OPEN_ONLY` | Open (an alert the NSE did not process, or any approval or question while Lock-screen approvals is off) |

**Handling an action** (`NotificationActionHandler`; background launch; at most 30 s)
1. Without the NSE's `shown/<requestID>.json` and a matching receipt, or with Lock-screen approvals off, nothing is sent. `DirectActionClient` tries the last working endpoint (3 s), then races the others.
2. `GET /api/session/{sid}/permission/{rid}`, or `…/form/{fid}` for a question, re-reads the request.
3. Recompute the digest:
   - if it differs, do nothing and post "The request changed. Open the app to review";
   - if the request is gone (404), post "Already handled".
4. `POST …/reply`.
5. On a 204, replace the alert with "Approved" or "Rejected". On failure, post "Couldn't reach your server". Success is never assumed.

There is no "Allow always" outside the app. Every approval made from a notification is recorded in a local audit list in Settings.

### 4.7 Live Activity lifecycle

**Start.** `LiveActivityCoordinator` starts an activity (`pushType: .token`) when the user sends a prompt from the phone. This is a setting, on by default. The static attributes (title and project) are set locally, so pushes never carry them.

**State.** `ContentState = {phase: running | needsInput | retrying | succeeded | failed | interrupted, step, toolGlyph, startedAt, updatedAt}`.

**Updates**
- In the foreground, the app updates the activity itself.
- The push token goes to the relay, and `registerActivity` to the plugin.
- The plugin sends priority-5 updates at most every 30 s, and priority 10 for "needs input" and for the end.
- Each update sets `staleDate` to now plus 5 minutes, so a sleeping laptop shows as stale.

**End.** The final state stays for 15 minutes. Activities older than 7.5 hours are restarted.

**Privacy.** The content state is plaintext to the relay and to Apple, so it stays coarse.

**Buttons:** Open, and Stop (a `LiveActivityIntent` that calls `interrupt`).

### 4.8 Scope

**Built**
- the plugin, the relay, sealed alerts and the NSE;
- the notification categories, with digest-checked approvals and answers;
- presence suppression;
- separate senders per server;
- delivery health and "Send test push";
- the badge;
- a Live Activity for runs started from the phone;
- direct mode, where the plugin sends to APNs itself with the server owner's key;
- App Attest on registration, verified by the relay when `APP_ATTEST=required` (off by default until it has been checked on a device; the simulator has no App Attest);
- notification settings: kinds can be turned off, a session and its subagents muted, and quiet hours set. A turned-off kind or a muted session arrives passive and silent; quiet hours lower time-sensitive alerts to active and the rest to passive. Approvals ignore quiet hours and mutes. The NSE applies these settings.

**Not built**
- push-to-start activities for runs started at the desk, and a multi-session "+N more" activity;
- a Notification Content extension with real option buttons and a diff preview;
- ID-only mode, where the NSE fetches the details over the direct path;
- Apple Watch;
- signed approvals dropped at the relay for when the server is unreachable;
- FCM, for an Android client.

## 5. Security model

**Credentials**
- Stored in the Keychain only: never in `UserDefaults`, URLs, logs, crash reports or the App Group.
- `AfterFirstUnlockThisDeviceOnly`, so they never migrate through iCloud or backups.
- `Authorization` headers are redacted from logs.
- `GET /api/credential`, which returns provider secrets, is never called.

**Device-owner authentication**
- Face ID, Touch ID or the passcode is always required before "Allow always" and before allowing a high-risk request once (`LAContext(.deviceOwnerAuthentication)`).
- Deleting a saved rule asks for confirmation.
- There is no app lock, and the app never shows a server password.

**App Transport Security**
- Only `NSAllowsLocalNetworking = YES`; never `NSAllowsArbitraryLoads`.
- Remote access uses HTTPS (OpenTunnel, `tailscale serve`, or a reverse proxy), or plain HTTP to a Tailscale address in 100.64.0.0/10.

**Plain HTTP on the LAN.** The Basic credential is readable by anyone on the same network. That credential gives full control of the machine, provider secrets included. Mitigations:
- an "Unencrypted" badge on HTTP endpoints;
- on every network, encrypted endpoints (HTTPS or a Tailscale address) are tried first, and the credential goes to a plain-HTTP endpoint only when none of them answers;
- plain HTTP is refused for any host that is not local (private, link-local or loopback addresses, `.local` and unqualified names) or a Tailscale address;
- pairing tokens rather than the server password. Tokens can only be revoked by changing the password, which signs out every device.

**Relay threat model**
- *Sees:* APNs and Live Activity tokens, timing, the coarse kind, padded sizes, the Live Activity state (phase, step count, tool category and two timestamps), the server's outgoing IP address and the phone's IP address.
- *Cannot:*
  - read or forge content (HPKE auth mode with a pinned sender key);
  - approve anything (approvals use the direct path and are digest-checked).
- *Can:*
  - drop or delay pushes, which delivery health makes visible;
  - send generic spam, but only with a stolen send token (rate limits apply, and tokens are revocable per server). With `APP_ATTEST=required`, registering a device also needs an App Attest assertion from the genuine app.
- A leaked APNs key allows generic spam only.

**Approvals from the lock screen**
- Every action that sends text or approves (Allow once, Reject with note…, Answer…, Reply…) requires the device to be unlocked. A plain Reject works from the lock screen.
- High-risk requests cannot be approved from a notification, and "always" is never offered there.
- The digest is checked, the APNs expiration is short, and the alert is replaced once the request is resolved.
- Nothing is approved when a timeout expires.
- Open comes first, so Watch Double Tap is safe.
- Every approval is recorded in an audit list.
- Live Activity buttons are limited to Open and Stop.

**Privacy manifests.** The app and both extensions declare the required-reason APIs they use (`UserDefaults` and file timestamps) in `PrivacyInfo.xcprivacy`. The app declares one collected data type, a device identifier for app functionality, not linked to the user and not used for tracking: the push token the relay needs. There are no tracking domains.

**Data at rest**
- The cache uses the `completeUntilFirstUserAuthentication` data protection class.
- The diagnostics export strips prompts and secrets.
- The app has no analytics or crash reporting.

**Untrusted input**
- QR and link payloads are validated like the reference parser.
- Deep links never carry credentials.
- Rendered Markdown never loads remote images automatically and never opens a link without a tap.

## 6. Testing

1. **Fixture decoding** (Swift Testing).
   - `Tools/fixture-recorder` records REST bodies, SSE streams, PTY frames and start and end snapshots from the real npm server for 20 scenarios: text and reasoning; the read, glob, grep, edit, shell, question and subagent tools; permission allow and reject; steer and queue; interrupt and resume; revert, fork and compaction; 429 and 500 retries; a final error; a terminal; pairing; and V1 detection. `Fixtures/v2/` holds two releases, 2.0.32 and 2.2.6, and every fixture test runs against both.
   - Every recorded event, message, inbox item, permission and form must decode without an `.unknown` or `.undecodable` fallback.
   - Mutation passes inject unknown keys, `null`s, `"NaN"` numbers and unknown type names. Known fields must still decode identically, and the stream must keep going.
2. **Projection parity.** Seed the store from the snapshot taken at the start of each recording, apply every recorded event twice, then compare the messages, session, pending inbox, permissions and forms with the snapshot taken at the end. This is the main guard against sync bugs. The contract job repeats it against a live server, including after a mid-turn disconnect.
3. **Sync engine unit tests**, with a fake transport and swift-clocks. They cover:
   - backoff, the watchdog and the first-frame timeout;
   - the server closing the stream mid-turn after overflow;
   - events arriving during snapshot fetches;
   - gap splicing and outbox retries;
   - 401 and 503 handling, network path changes, background and foreground.
4. **Performance budgets.** `ReadPerformanceTests` and `TimelineCollectionTests` fail if a streamed delta costs 4 ms or more of main-thread work at 50 deltas a second, if building 2,000 messages off the main actor takes 250 ms or more, or if a rendered 5,000-row session takes 250 MiB or more. They also replay an hour of streamed events and scroll a 2,000-row transcript, and compare memory with the baselines in `Fixtures/performance/baselines.json`. `ReviewSmokeTests` checks frames, hitches and memory while scrolling a 5,000-line diff, and `PerformanceSmokeTests` times a cold launch to the cached Home.
5. **Accessibility and localization.** `AccessibilitySmokeTests` runs XCUITest's accessibility audit on every main screen, in light and dark mode, on iPhone and iPad; the few exclusions name their reason. `LocalizationSnapshots` renders key screens with double-length strings and right to left, and `LocalizationLintTests` fails when a user-facing literal bypasses the String Catalogs.
6. **Demo, App Attest and direct mode.** `DemoModeTests` play the recorded demo through `ScenarioTransport` with a transport that fails the test on any network call, and `DemoSmokeTests` enters the demo from a fresh install, approves its permission, reviews its diff and leaves. The relay suites verify attestations and assertions with an injected test root, including replayed counters and challenges, with `APP_ATTEST` off and on, in both runtimes; `AppAttestClientTests` covers the app's side. The plugin's direct mode runs against an HTTP/2 APNs mock in its own suite and in `Tools/push-e2e`.
7. **Snapshot tests** (swift-snapshot-testing 1.18.7). Eight iOS test targets hold the reference images: transcript rows and every tool state, Home, sheets, diffs and review, approvals, the composer, push and Live Activity views, widgets, settings and terminals, in light and dark mode, at the largest accessibility size, at compact and regular widths.
8. **UI smoke.** `node Tools/ui-smoke/index.mjs` builds the app once, runs the unit and snapshot tests on an iPhone simulator, and runs the XCUITest flows against the real npm server in `Tools/opencode-sandbox`, with the scripted model (`Tools/mock-llm`), on an iPhone and an iPad simulator. The flows cover pairing, reading, approvals and questions, the composer, review and files, server settings, the switcher, terminals, Shortcuts, Spotlight, widgets and the iPad workspace. A loopback fault proxy blocks requests, drops prompt responses and pauses the event stream. A failed UI test runs again, up to twice. The harness runs locally; no workflow runs it.
9. **Live contract** (`contract.yml`, nightly and on demand, on a macOS runner). It starts two servers from npm inside a macOS sandbox: the newest stable 2.x release, or the exact version given to a manual run, and `opencode-ai@1.19.3` for V1 detection. It runs Node checks and the Swift live suites (`OCNetworkingLiveTests`) against them: pairing and 401, the first frame and heartbeats, recovery after the server is stopped for 60 seconds, prompt, steer and queue, interrupt, permission, question, revert and redo, fork, compaction, projection parity after a mid-turn disconnect, review and files, server settings, terminals, V1 detection and the push plugin. It also records a fresh fixture set and uploads it as an artifact; checked-in fixtures change only when someone runs the recorder and commits the result. No job tests older V2 releases. The same workflow's spec watch runs daily: when a release newer than the newest recording appears, it compares its `/openapi.json` with the one recorded in `Fixtures/v2/<version>/openapi.json` (with `oasdiff`) and its event union with what `ServerEvent` decodes, and opens one issue per release with the changes. Recording a release after checking its changes moves that baseline.
10. **Plugin and relay.** Vitest suites for the contracts and the plugin. The digest, envelope, padding, payload, risk and RFC 9180 vectors in `server/contracts/vectors` also run in `OCPushCoreTests`. The relay's suite runs in workerd and against its Node entry point, both against a mock APNs. `node Tools/push-e2e/index.mjs` sends a real permission request and question through the plugin, the relay in the local Workers runtime and a mock APNs, and opens the envelopes in TypeScript and in Swift; with `--simulator` it then delivers them to the app with `simctl push`. Real APNs delivery and the Notification Service Extension need a signed build on a device.
11. **CI on every push** (`ci.yml`). The package tests, an app build and the composer editor tests (mention tokens, marked text, hardware Return and Escape) run on Xcode 27.0 and 27.1; a check fails if a tracked file contains a home directory path, and another if `THIRD_PARTY_NOTICES.md` or `web/index.html` has drifted from its sources. `plugin.yml` and `relay.yml` run the push packages' tests when `server/` changes. `release.yml`, run by hand, archives the app: unsigned as a dry run, or signed, exported and uploaded once the team and App Store Connect secrets are set. `Config/Version.xcconfig` is the one place the version and build number are set.
12. **On a device.** Long streaming sessions, network switches, Low Data Mode, OpenTunnel and Tailscale need a real device and are not automated. Automated tests cover a server stopped for 60 seconds, blocked and lossy connections through the fault proxy, and terminal output across backgrounding.

## 7. Risks

| Risk | Mitigation |
|---|---|
| V2 changes often (about six releases a week in October 2026) and has no API version | Tolerant models with `.unknown` and `.undecodable` cases; capability and version gates; a nightly contract job against the newest release; a daily spec watch that opens an issue when a release changes the API or the event union |
| The protocol's owner has its own iOS app in beta | The app pairs with `opencode pair` links and QR codes, connects through OpenTunnel addresses, and badges prompts that arrive as voice delegations |
| Push needs a plugin the user must install | The app detects the plugin through its `status` call and, when it is missing, shows the install command in Settings → Notifications. Everything except push works without it. |
| Running the relay (APNs key custody, abuse, cost, Workers HTTP/2) | The relay is open source. It runs on Cloudflare Workers, or as a Node server with `node:http2` if a Worker cannot reach APNs over HTTP/2, which is unverified. It limits registrations per IP address and pushes per device, and its logs hold no tokens, IDs or addresses. App Attest can require the genuine app for registration. Direct mode needs no relay at all. The app shows each server's plugin, registration and last delivery. |
| OpenTunnel outages and DNS blocking | Endpoint racing across several addresses; LAN and Tailscale fallbacks; specific diagnostics |
| iOS stops the app in the background | Push and Live Activities; fast resync; persisted outbox; background tasks around sends |
| Plain HTTP on the LAN | Plain HTTP is refused except for local and Tailscale addresses. HTTP endpoints carry an Unencrypted badge and a warning when added, and endpoint racing prefers HTTPS. |
| Slow transcripts in long sessions | One observable per content item; frozen Markdown blocks and turns; pages of 50 messages; at most six transcripts in memory; a `UICollectionView` timeline; budgets enforced by `ReadPerformanceTests` |
| Pre-1.0 or single-maintainer libraries: Textual 0.5.0 (with swiftui-math 0.1.0), swift-markdown 0.7.3, swift-tree-sitter 0.10.0, SwiftTerm and the tree-sitter grammars | Each library is imported by one module, and Textual and SwiftTerm sit behind protocols (`MarkdownBlockRenderer`, `TerminalEngine`). Every package is pinned to an exact version. The 13 grammars are vendored C sources pinned by revision in `Tools/grammars/manifest.json`. |
| Client-minted IDs on a phone with a wrong clock | Server-corrected, always-increasing IDs; revert hiding by position |
| Pending permissions vanish when the server restarts or runs `location.reload` | Treat notifications as hints; re-check before acting; resync on reconnect |
| App Review (demo access, Local Network permission, guideline 4.2) | "Try a demo" on the first screen plays recorded sessions with no server and no network. Each permission string says what the access is for (`project.yml`). |

## 8. Upstream reference files

Paths under `packages/` refer to github.com/anomalyco/opencode (formerly sst/opencode) at commit `d0732ea`.

- `research/01-opencode-server-api.md`: the protocol, the event catalogue and the gotchas.
- `packages/client/src/solid/data.ts`: the reference client's event handlers, outbox, fetch overlays and pending-status rules.
- `packages/client/src/solid/connection.ts`: the stream lifecycle, watchdog and resync timings.
- `packages/app/src/servers/connect/pairing.ts`: pairing parsing and redemption.
- `packages/core/src/plugin/host.ts`, with `packages/core/src/bus.ts` and `packages/core/src/kv.ts`: how plugins load once per location, why every instance receives every location's events, and the global key-value store that holds the push plugin's registrations.
