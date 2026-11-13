# Development tools

The fixture and contract tools require Node 26 and npm, plus Git and the
standard macOS process utilities. Run commands from the repository root. No
global packages, provider keys, or real model calls are needed. Design capture
installs its pinned Playwright dependency and browser locally under `.build`.

## Choosing checks

```sh
node Tools/checks/index.mjs           # the working tree against origin/main
node Tools/checks/index.mjs HEAD~1    # against another base
```

It lists the local checks a change needs, with their commands and the paths that need them
(`Tools/checks/scope.mjs`). The full UI run, an hour or more, is needed only for the app, its
extensions, its UI tests, the project and configuration, the package tests the project runs on the
simulator (snapshots, the server screens' tests, the composer editor tests and the read performance
budgets) and the fixtures they read, and the tools the run is built on (`ui-smoke`,
`opencode-sandbox`, `mock-llm`, the review and MCP fixtures, and the files it imports from the
design reference and the fixture recorder; a test follows the run's imports). Push tools, the
server's plugin and the relay need the simulator push stage on its own, recordings and the other
package tests need the package tests, and the networking, model and sync layers and the contract's
tools need the live contract. Documentation needs nothing.

## Record fixtures

```sh
node --test Tools/mock-llm/*.test.mjs Tools/opencode-sandbox/*.test.mjs Tools/fixture-recorder/*.test.mjs Tools/ui-smoke/*.test.mjs Tools/contract/*.test.mjs
node Tools/fixture-recorder/index.mjs
# Reproduce one release:
node Tools/fixture-recorder/index.mjs --version 2.0.32
# Debug selected scenarios without replacing the checked-in recording:
node Tools/fixture-recorder/index.mjs --version 2.0.32 --scenario permission-allow --output .build/fixture-debug
```

The default recorder queries npm once, selects the newest stable **2.x** release,
then pins that exact version for the whole recording. `--version` accepts an
exact stable 2.x version. It runs all 20 scenarios, including the fixed
`opencode-ai@1.19.3` detection probe.
Fixtures are published to `Fixtures/v2/<version>/` only after every selected
scenario passes. Use `--output` for partial recordings; `manifest.json` lists
omitted scenarios, consumed model calls, script hashes, and file hashes. Each session
scenario includes start/end snapshots of session info, every message page, inbox,
permissions and forms. Pairing, PTY and V1 detection have no session snapshot.

Published fixtures say `/sandbox` wherever the server reported the sandbox run
root (`.build/opencode-sandbox/<version>/<run-id>`), in plain, JSON-escaped and
URL-encoded form, so they never reveal where the checkout lives. They say
`sandbox.local` wherever the server reported this machine's host name (opencode
2.2 adds `hostname` to `/api/info`); the demo recorder does the same. The file hashes
in `manifest.json` cover the rewritten bytes. `Tools/fixture-recorder/home-paths.test.mjs`
fails if a tracked file, or an untracked file that is not ignored, contains a home
directory path or a recorded `hostname` other than `sandbox.local`, and CI runs it
on every push. Example paths in docs and screenshots use `/Users/Shared`.

## Live contracts

```sh
node Tools/contract/index.mjs
node Tools/contract/index.mjs --version 2.0.32
```

This starts the real npm V2 server and the V1 detection server, checks 401/200
authentication, single-use pairing and token authentication, the first SSE event
and a heartbeat within 20 seconds, a prompt and title round trip, PTY echo/resize/
cursor resume/deletion, the terminal contract (`Tools/contract/pty.mjs`: PTY routes and events,
the upgrade with the Authorization header, replay frames and the one 0x00 control frame, the
UTF-16 cursor across a reconnection, cursor -1, single-use tickets, the 2 MiB retained buffer
and the gap a stale cursor sees, close codes 1000 and 4404, 404 before an upgrade, and shell
output paging and removal; the buffer numbers are written to `pty-buffer.json` in the audit
folder), V1 health detection, and the push plugin live checks (see "Push"). Failures exit nonzero. This is
separate from ordinary `swift test`, which reads checked-in files and skips live cases.

The contract also runs `OCNetworkingLiveTests` through `swift test --filter
OCNetworkingLiveTests`. It supplies `OPENCODE_LIVE_URL`, `OPENCODE_LIVE_PASSWORD`,
`OPENCODE_LIVE_PID` (the authenticated `/api/info.pid`), `OPENCODE_LIVE_VERSION`,
`OPENCODE_LIVE_V1_URL`, and `OPENCODE_LIVE_V1_PASSWORD` in the child environment.
Do not point these variables at an installed or personal server. The live test
verifies Swift probe/clock correction, single-use pairing and token auth,
URLSession delegate delivery of the small first SSE frame within 3 seconds,
40 seconds of heartbeat health, and recovery after SIGSTOP for 60 seconds then
SIGCONT. It prints the measured first-frame latency and connection transitions.
The harness owns cleanup and the isolation audit throughout. Expect roughly two
to three minutes beyond the build. No source checkout is built or executed.

The live sync test also compares the store projection to REST snapshots after a
normal turn and after dropping/reconnecting the stream mid-turn. It supplies
`OPENCODE_LIVE_MOCK_URL` and `OPENCODE_LIVE_DIRECTORY` to that test.

Offline networking tests use the pinned swift-clocks 1.1.1 `TestClock`, fake
transports, and every recorded version under `Fixtures/v2/`. Startup 503 cases
are source-derived mutations of the ready-server fixture because those captures
contain no 503 response. The optional Keychain smoke test requires
`OPENCODE_TEST_KEYCHAIN=1`; unavailable Keychains are skipped.

`.github/workflows/contract.yml` runs manually and nightly at 07:23 UTC on
`xcode-27` with Node 26. It resolves V2 once for both the contract and recorder,
and uploads refreshed fixtures and isolation audits as artifacts. It does not
commit recordings. The networking and read-projection suites run against the
latest or a pinned V2 release, with V1 detection checked separately; there is no
matrix of older V2 releases.

## Push

Install the three push packages first: `npm ci` in `server/contracts`, `server/plugin` and
`server/relay`. Nothing here creates an account, deploys, or contacts APNs.

```sh
node Tools/sync-push-contracts.mjs --check   # OCPushCore's copies of constants.json and risk-rules.json
node Tools/push-e2e/plugin-checks.mjs        # the plugin live checks; Tools/contract/index.mjs runs them too
node Tools/push-e2e/index.mjs                # the local end-to-end
```

`plugin-checks.mjs` starts a sandbox whose configuration lists this checkout's `server/plugin`, and
a loopback relay that records every call. With the scripted model it proves: the plugin loads and
answers its RPC on two locations; storage is global and namespaced in opencode's `kv` table; a real
permission request is pushed after the grace period, sealed, with the right fields and the digest
of a fresh `GET`; the desktop answer replaces it; an answer inside the grace period and a valid
presence heartbeat suppress it; a root's success and a failure are pushed (opencode publishes both
without a location); a subagent's request carries its root, and its success is not pushed; Stop
replaces a pushed request once; a Live Activity follows a run; a missing session answers
`not_found`; a request in a second location is pushed once although every instance receives every
location's events; `session.moved` sends nothing. A second sandbox installs the plugin with
`opencode plugin add git+file://…` (a Git repository of the package made inside the run directory)
and loads it from the global configuration that command writes. The CLI runs under the same
`sandbox-exec` profile, with its own enforcement receipt. `push-plugin.json` in the audit directory
records the answers.

`index.mjs` adds the relay in the Workers local runtime (`wrangler dev --local`, with local D1 after
`wrangler d1 migrations apply --local`, and both Durable Objects) and the relay's mock APNs server,
with a test ES256 key made for the run. It registers a fake phone at the relay and through the
plugin, drives a real permission request and a real question, and checks the generic alert, the
headers and the envelope at the mock APNs, opens the envelopes with the TypeScript contracts and with
`OCPushCore` (`swift test --filter pushesFromTheEndToEndRunOpenInSwift`, given the capture), refuses
tampered copies, and covers the replacement, presence, an answer inside the grace period, the
relay's rate limit (test mode, 8 alerts a minute) and the `gone` path. It prints the time from the
request's event to the mock APNs. Results, the capture and the Swift log are under
`.build/push-e2e/<run>/`; the run's env file with the test key is deleted at the end. wrangler runs
with its `HOME`, XDG and log directories inside the run (`server/relay/scripts/isolated.mjs`),
telemetry off and no Cloudflare credentials, and the run fails if the account's own wrangler state
changed.

## App push in the simulator

```sh
node Tools/push-e2e/index.mjs --simulator # the checks above, then the app bridge run
node Tools/push-e2e/simulator.mjs        # only the app bridge run
```

The bridge run uses the existing booted **iPhone 17 Pro**, a sandbox with the plugin,
the relay's Node entry point and its HTTP/2 mock APNs. Each accepted payload is saved
unchanged and passed to `xcrun simctl push`. It never creates or reconfigures a
simulator. The full `node Tools/ui-smoke/index.mjs` run includes this check after
its normal iPhone and iPad flows, with all simulator-dependent commands serialized.

The DEBUG app driver requires a `ui-` test identity and a loopback control URL.
It substitutes a synthetic APNs token and a loopback relay URL; these overrides
are absent from Release. It inspects the untouched delivered notification first.
A DEBUG NSE invocation marker and non-sensitive log distinguish an extension
launch from an Open-only decryption failure. If necessary, the driver invokes
OCPushCore in the app and schedules the resulting local notification. This bypasses
system NSE launch, while retaining HPKE, the shared Keychain, the protected store
and the category builder. XCUITest attempts the notification action; the fallback
calls the production action handler and bypasses SpringBoard gestures and device
authentication. The report says which path ran.

The changed-request case uses a loopback forwarding proxy: V2 pending requests are
immutable, so it changes the resources in the action's fresh GET. No reply may be
sent. The harness waits for each session to become idle before changing the mock
model's script. Approval timing ends only when the sandbox file has actually
changed. APNs collapse headers are recorded separately because `simctl push` takes
only a payload; local rendered replacements use a stable request identifier.

Evidence is under `.build/push-e2e/ui-push-<run>/`: the live `test.log`, XCTest result
bundle, raw `.apns` files and bridge results, app reports, NSE log and activity probe.
The matching isolation audit is under `.build/opencode-sandbox/audits/`.

What the simulator cannot show, so only a signed build on a device can: `simctl push`
delivers an alert payload but does not launch the Notification Service Extension (the
decrypted alert comes from the DEBUG renderer above), it cannot deliver an ActivityKit
update (`NSPOSIXErrorDomain 14`), and it issues no APNs device token (the driver
substitutes one; Live Activity push tokens do arrive and are registered with the local
relay and plugin). Real APNs delivery, lock-screen latency, device-owner authentication
for Allow once and remote Live Activity updates need a build signed with a team.

## Isolation and lifecycle

`opencode-sandbox/index.mjs` launches only
`npx -y @opencode/cli@<version> serve --hostname 127.0.0.1 --port <free-port>`
(or `npx -y opencode-ai@1.19.3 serve` for detection). It invokes npm's npx entry
point through the active Node executable. It never runs a preinstalled opencode
or an opencode source checkout. Ports 49374 and 49375 are excluded.

Each run lives under `.build/opencode-sandbox/<version>/<run-id>/`. HOME, all XDG
roots/search paths, temp directories, Git config, npm config/prefix/cache,
opencode config/model-catalog/database paths and scratch project are sandboxed.
The npm download cache is shared **only within that sandbox version**. The child
environment is built from an allowlist, with a private PATH containing Node and
system utilities. Inherited credentials, config overrides, shell startup hooks,
SSH settings, telemetry exporters, and Node flags are not passed through.

The source at `d0732ea` establishes these controls:

- `packages/cli/src/server-process.ts`: foreground `serve` skips service
  registration, service config, and remote tunnels. No service/LaunchAgent
  commands are invoked. A random password is supplied on every launch.
- `packages/cli/src/services/updater.ts`: `OPENCODE_DISABLE_AUTOUPDATE=1`;
  V2 config also sets `update: "disable"`, V1 sets `autoupdate: false`.
- `packages/util/src/observability/otlp.ts`: absent OTEL exporter endpoint disables
  remote logging/tracing. The environment omits all inherited OTEL values and
  additionally sets `OTEL_SDK_DISABLED=true` and `DO_NOT_TRACK=1`.
- `packages/schema/src/config.ts`: `share: "disabled"`. V1 also gets
  `OPENCODE_DISABLE_SHARE=1`. Project config discovery (including the compatibility
  paths for other agents' files), model fetches,
  watchers, LSP, formatters, and warming are disabled.
- Persistent PTY daemon execution is blocked by an `OPENCODE_PTY_BIN` path to a
  nonexistent sandbox file. Tests use ordinary `/api/pty`, which is owned by the
  foreground server, and explicitly delete each PTY. Inherited optional native
  library overrides are cleared; bundled assets resolve inside the npm sandbox.

On npm 12, only the selected opencode package is allowed to run its install-time
script, which installs its npm-distributed binary inside this sandbox. This is
a child-only setting, not a change to global npm configuration.

Every started subprocess has an owned process group. Cleanup sends TERM, then
KILL if needed, and verifies no group remains; it also tracks descendant groups
such as PTYs. This runs on success, failure, SIGINT, SIGTERM, and SIGHUP. Normal
server shutdown writes `cleanup.json` in the run directory. SIGKILL cannot be
handled. Keep the launcher in the foreground and stop it with Ctrl-C.

Every recorder/contract run saves before/after path and nanosecond-mtime listings
(depth two) for the user's four opencode directories and `~/Library/LaunchAgents`
under `.build/opencode-sandbox/audits/`. Changes attributed to a unique external
writer are warnings; sandbox writes fail. Unattributed changes are warnings only after every sandbox launch has verified enforcement. The tool
never restores or edits the user's files. macOS `sandbox-exec` additionally
denies writes to those five roots; this is not a general-purpose security
boundary for arbitrary untrusted tool scripts.

For manual API work:

```sh
node Tools/opencode-sandbox/index.mjs --version 2.0.32
# Detection only:
node Tools/opencode-sandbox/index.mjs --v1
```

The manual launcher prints the URL, per-run password, mock URL and scratch path
as a one-line handoff. Recorder/contract logs and artifacts redact credentials.
The launcher stays in the foreground until interrupted, then cleans up.

## Scripted model

`mock-llm/server.mjs` serves the provider path confirmed in
`packages/ai/src/providers/openai-compatible.ts` and
`packages/ai/src/protocols/openai-compatible-chat.ts`: **POST
`/v1/chat/completions`**, using OpenAI Chat SSE (not Responses). It sends role,
text, `reasoning_content`, indexed tool-call argument fragments, finish reason,
usage-only chunks and `[DONE]`. It also supports non-streamed chat completions.
Usage includes input/output/total, cached input and reasoning tokens.

```sh
node Tools/mock-llm/server.mjs
# Use its printed loopback URL:
curl -X POST http://127.0.0.1:PORT/admin/scenario \
  -H 'Content-Type: application/json' -d '{"name":"read-glob-grep"}'
curl http://127.0.0.1:PORT/admin/state
```

`scenarios.mjs` contains ordered primary calls. Each call accepts `deltas`
(`text`, `reasoning`, optional `delayMs`), `tools` (`name`, `arguments` or explicit
`argumentDeltas`), `finishReason`, `usage`, `delayMs`, or an `error` (`status`,
`message`, optional `retryAfter`). The admin selector also accepts
`{name, script: {calls: [...]}}`. Active calls prevent scenario replacement.
Exhausting a script is an error, never an implicit successful response.
Title, summary and compaction requests are classified from the source's prompt
templates and answered on separate deterministic lanes. Admin state lists the
consumed script indexes, kind, model, streaming flag, completion/cancellation/
error status, available tools, remaining calls and unexpected requests.

The V2 tool is named **`subagent`**, not `task`; the fixture uses the source's
name. It creates and verifies a real child session through the scripted model.

## The iPad workspace flow

```sh
node Tools/ui-smoke/index.mjs --workspace-only                # every workspace test on the iPad
node Tools/ui-smoke/index.mjs --workspace-test testTwoWindows # one of them
```

The full run's iPad stage includes `WorkspaceSmokeTests`, which the iPhone stage skips. It
presses these menu shortcuts as synthesized hardware keys: ⌘1, ⌘2, ⌥⌘↓, ⌥⌘↑, ⌥⇧⌘↓, ⌥⇧⌘↑
(with the composer focused), ⌘\, ⇧⌘R, ⌘N, ⌘K, ⌘., ⌘', ⇧⌘D, ⌘U, ⇧⌘A and ⇧⌘N; `ReviewSmokeTests`
presses ⌘F. ⌘3–⌘9 share ⌘1 and ⌘2's path and are not pressed, and ⌘↩ is not pressed because the
simulator does not deliver Return chords (see below). It drives the ⌘K switcher from the
keyboard, opens the next approval, shows two sessions in two windows (restoring both
after a relaunch), opens a third with ⇧⌘N, and drags a Files row onto the composer. Only under a
`ui-` test identity, the DEBUG app exposes a `windowInventory` element (every window's
sessions and the key window), a `commandTrace` element (commands counted where they are
dispatched, so a test proves that one key press ran one action), a `workspaceCommands`
element (the menu commands the menu bar enables). A fresh `--ui-testing-reset` launch asks
iPadOS to close windows an earlier test left open; the simulator keeps them in the app
switcher, so the tests check windows by the sessions they show. What the test saw of the windows is attached and copied next to the result bundle
as `finding-*`. The iPad simulator drops the key of the first chord after a launch, so each
flow first sends ⌘J, which no command owns; `testReviewNavigation` checks that first chord
itself. XCUITest on this simulator delivers no Return chord or Escape, neither to the menu bar
nor to a focused text view or field, so the composer flow runs Send from the switcher and the
switcher flow opens an entry with a typed newline; ⌘↩, Return and Escape in the editor and the
switcher are covered by unit tests instead. Before a chord after a tap on the composer or a
switcher field, and after the switcher closes, the flow waits until the software keyboard stops
moving: XCUITest waits for the app to idle after every event, and a chord sent while the keyboard
was still appearing once left the app without its animations-complete signal, so every later
event waited 60 seconds. Deep links go through
`XCUIDevice.shared.system.open`, because `XCUIApplication.open` relaunches the app and would
drop the window that is not on screen.
The iPhone stage's `SwitcherSmokeTests` opens the switcher from Home's toolbar button and the
context sheet from the session header.

## Terminals

```sh
node Tools/ui-smoke/index.mjs --terminal-only                            # every terminal test, on the iPhone and the iPad
node Tools/ui-smoke/index.mjs --terminal-test testResumeLosesNoOutput    # one of them
```

`TerminalSmokeTests` runs in the full run's iPhone and iPad stages. Each test pairs the sandbox,
creates a session in its project and opens its terminals: the session menu's Terminals screen on
the iPhone, the review panel's Terminal tab on the iPad. `testTerminalPrograms` edits a new file
in `vim` (Escape comes from the key bar; when a hardware keyboard hides the bar on the iPad, from
the keyboard, with Ctrl-[ after it if the simulator dropped that key) and reads it back through the
server's `fs.read`, runs `nettop` and pages with `less`, then checks `stty size` against the
terminal's size before and after Home is shown beside it (iPad only: the iPhone simulator
neither rotates the app under XCUITest nor keeps the software keyboard away reliably, so iPhone
resizing is checked on a device).
`testResumeLosesNoOutput` prints numbered `OCSEQ-<n>` lines while the app is in the background,
then while it is not running at all, and checks that every number arrives once and in order.
`testRunACommandAndStopIt` runs a command from the Run a command sheet and stops a second one,
which the server then no longer lists. Only under a `ui-` test identity, the DEBUG app exposes
the terminal's visible rows (`terminalScreen`), its size (`terminalSize`) and the marker lines of
its whole buffer (`terminalSequence`); the resume and size findings are copied next to the result
bundles as `terminal-resume-*.txt` and `terminal-size-*.txt`. A live full-screen program is
`nettop`: macOS refuses the sandboxed server's processes the set-user-ID `/usr/bin/top`, and `htop`
is not part of macOS.

## Shortcuts, Spotlight and widgets

```sh
node Tools/ui-smoke/index.mjs --system-only                               # every system test on the iPhone
node Tools/ui-smoke/index.mjs --system-test testShortcutsRunTheIntents    # one of them
```

The full run runs `SystemSmokeTests` in their own stage (`System.xcresult`, `system.log`) on
"opencode-ios iPhone", an iPhone 17 Pro on iOS 27.2, when that simulator exists (see below), and
in the iPhone stage otherwise. Each test pairs the sandbox and creates a session with a unique
title, then leaves the app for the system:

- `testShortcutsRunTheIntents` runs Send a prompt from the app's page in the Shortcuts app. A
  simulator build is not signed with a team, so the system refuses to run it ("Unable to run
  App Shortcut"); the test records the outcome, then performs Send a prompt and Get session
  status in the app through a DEBUG-only link (`opencodeios://debug-intent/send` and
  `/status`), which calls each intent's own `perform()` with the values Shortcuts would pass.
  It checks on the server that exactly one prompt with that text arrived and that the status
  matches the server's.
- `testSpotlightOpensASession` checks that the Spotlight switch in Settings is on, searches
  Spotlight for the app's name (its App Shortcuts) and for the session's title, and opens the
  session from the result.
- `testWidgetOnTheHomeScreen` makes the session wait for an approval, adds the Needs you widget
  from the widget gallery, checks that its top row is that session, opens it from the widget
  and removes the widget again, also when the test fails.

`testShortcutsRunTheIntents` and `testWidgetOnTheHomeScreen` need the system's App Intents
registry (`linkd`) to accept the app: Shortcuts lists the app's App Shortcuts from it, and the
Needs you widget is configured through an App Intent. A simulator runtime older than the SDK
the app is built with may not read the app's executable: with Xcode 27.2 and only the iOS 26.5
runtime installed, `linkd` logs `resolveWithBundle … executableError … Invalid argument` and
`Failed to register "dev.opencodeios.client": … aggregateMetadataIsEmpty`, and both tests fail
for any build of the app, with or without the debug dylib. The iOS 27.2 runtime registers the
same build, so the system tests run on an iPhone 17 Pro with it, made once with
`xcrun simctl create "opencode-ios iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-2`
after `xcodebuild -downloadPlatform iOS`. The tool only looks that simulator up by name; like the
iPhone 17 Pro, it is booted when it is down and restarted only after a stall. Everything else stays on the
iPhone 17 Pro, whose iOS 26.5 rendering the reference images use.

The DEBUG app handles the intent link only under a `ui-` test identity. Under a test identity
it also exposes an `intentTrace` element: each intent records in the App Group which process
ran it and what it answered, and the test reads the answers there. What each system app
exposed to XCUITest is attached as `finding-*` and copied next to the result bundle.

## UI smoke and snapshots

```sh
xcodegen generate
node Tools/ui-smoke/index.mjs
# Optional exact V2 release, or just the live UI flows:
node Tools/ui-smoke/index.mjs --version 2.0.32 --skip-snapshots
```

The harness uses only `opencode-sandbox` and the scripted model, creates a fresh
single-use link with `POST /api/pair`, builds once with `xcodebuild build-for-testing`
(`build.log`, while the sandbox starts) and runs every stage with `test-without-building`
against that build's `.xctestrun`, on iPhone 17 Pro (iOS 26.5) and the "opencode-ios iPad"
simulator, plus "opencode-ios iPhone" (iOS 27.2) for the system tests when it exists. `-skipPackagePluginValidation` lets the build run SwiftTerm's build plugin without
trusting it in Xcode's settings. `TEST_RUNNER_OPENCODE_UI_*` environment variables carry the sandbox
URLs, passwords and link into XCUITest. Only an isolated test identifier reaches
the app's launch environment; the tests type the connection inputs through the UI.
A full run runs the unit and snapshot tests once on the iPhone (`Units.xcresult`, `units.log`;
their reference images are 3x) while the iPad UI stage runs on the iPad (`iPad.xcresult`,
`ipad.log`), then the iPhone UI stage (`Smoke.xcresult`, `test.log`). Without the iPad
simulator the stages run one after another. Beside the iPad stage, the read performance budgets
are left out of the unit stage and run on their own once both stages end (`Performance.xcresult`,
`performance.log`), after a burst of load has settled as it must before a retry, and the
reference-image check spans both stages. A run that uses the iPad starts by shutting it down and
booting it again; the iPhone is booted only when it is down, one at a time and without creating, erasing or
reconfiguring either: an iPad that has been booted for a while can stop finishing rotations, and
then every iPad test fails in its setup, while right after a boot Shortcuts does not list the app's
App Shortcuts and the widget does not show its snapshot, which fails the iPhone's system tests. The
freshly booted iPad gets a minute to settle while the build runs (see the retries below), and a
simulator found still booting is waited for rather than shut down. A restart or boot that has not
finished within 10 minutes fails the run. `timings.json` records each
stage's start, end and minutes, and those of the restarts (`simulators`), of each retry's setup and
of the wait before the performance budgets (`performance setup`). When UI tests fail, their stage runs the failed tests again together, up to
twice, on the same build (`xcodebuild test-without-building` with an `-only-testing:` for each,
into `Smoke-attempt-2.xcresult` and `test-attempt-2.log`, and so on); a test passes when any
attempt passes or ends in an expected failure. Before each retry the one-minute load average must
drop under four per core, since a timing-sensitive test that failed in a burst of load from other
work on the host fails again inside it; the tool waits at most 15 minutes and prints `LOAD` when it
waited. Then the iPad boots afresh and gets a minute to settle (a test runner launched right after
a boot can fail on the containers the last attempt left) and the tool prints `RESTARTED`; the iPhone
keeps running. The fault proxy's faults are then cleared and the no-Git review fixture loses the
repository a failed attempt may have created.
A booted location keeps the repository it detected after `.git` is gone, so the fixture's
location is evicted (`DELETE /api/debug/location`), after which `GET /api/vcs` must report no
provider for it; other server state stays, so a retried test sees the sessions and
messages its earlier attempt left. `ReviewSmokeTests` and `SystemSmokeTests`, which look for
their own messages on the server, count only those created after the test started. UI stages
pass `-test-timeouts-enabled YES`, so a test that hangs fails at its `executionTimeAllowance`
(600 seconds when it sets none) and is retried like any other failure. No test timeout applies
before a test starts, where `xcodebuild` can wait forever on a simulator that stopped answering,
so an `xcodebuild` run of the unit, performance or UI tests that prints nothing for 25 minutes is
stopped: a UI test prints each of its steps, and a hung one fails at its allowance (900 seconds at
most). A stalled run prints `STALLED` and runs again whole, once, after the same setup as a retry,
on either simulator booted afresh; its bundle and log keep a `-stalled` suffix, and a second stall
fails the stage. The push stage's
script, silent while its tests build and run, is stopped after 40 silent minutes, and each
simulator command that ends the run after 5 minutes.
A crash during a test is that test's failure and is retried. A failure that belongs to no
failed test (a test runner lost outside any test, a summary that disagrees with the result
tree, an unknown result) fails the stage without a retry. The tool
retries itself because Xcode's `-retry-tests-on-failure` does not:
since Xcode 26 a failure in an async test whose class sets `continueAfterFailure = false`
relaunches the test runner, which drops the retry (a known Xcode issue). A
regression still fails every attempt; a burst of load on a shared host no longer fails the
whole run. The large-diff scroll test flicks a fixed sample, 60 flicks down the 5,000-line diff
from the top and back to its first row, rather than the whole diff (a device check); it logs its
worst frame but never fails on it, and its frames, hitch rate, first rows and memory checks
still fail the test. Snapshot tests never retry, because a snapshot test records a
missing reference image and would pass on its next attempt; any stage that adds or changes a
file under a `__Snapshots__` folder fails and prints `RECORDED <file>`. A test that passed on
a later attempt prints `RETRIED <test> (attempt n of 3)`; one that failed every attempt prints
`FAILED <test> (3 of 3)` and fails the stage. `retried.json` next to the result bundles lists
both per stage. A test that passed on a later attempt contributes only that attempt's
screenshots, findings and measurements, such as the approval latency and the review scroll
metrics; if that attempt attached none, the stage's checks for them fail. The full run's last
stage, the simulator push tests (`Tools/push-e2e/simulator.mjs`), runs its one test once with no
retry, also with `-test-timeouts-enabled YES`, so a hung push test fails instead of holding the
run; the snapshot check covers it too.
Debug builds use a separate JSON file and Keychain service for each test run.
Production storage is not reset. UI tests use XCTest because XCUITest requires it;
package and snapshot tests use Swift Testing.

It covers manual V2, pairing-link V2, wrong-password re-pairing, and the V1 upgrade
screen. The `.xcresult` and redacted log live under `.build/ui-smoke/`. Screenshots
are exported to `.build/screenshots/`, including onboarding, server list, both
connection forms, re-pairing, details, diagnostics, local network and update. A final
install and launch leaves the app on the booted simulator. Sandbox cleanup and
before/after isolation audits run even on failure.

`ServerSnapshots` compares 110 checked-in images: 44 connection-state images in
both appearances at accessibility size 5 and 402-/768-point widths, 60 full-screen
images across phone and iPad sizes, two component sheets, two expanded-Home sidebar images, and two native-toolbar regression images. The
snapshot library is pinned to 1.18.7. Run it independently with:

```sh
xcodebuild -project Opencode.xcodeproj -scheme Opencode \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/DerivedData -parallel-testing-enabled NO -skipPackagePluginValidation \
  -only-testing:ServerSnapshots test
```

Missing references are recorded and fail the first run. Review the PNGs under
`Packages/OpencodeKit/Tests/FeatureServersTests/__Snapshots__/` before re-running.
Ordinary `swift test` uses no network, runs the sync tests with fake connections
and virtual clocks, and skips live networking and iOS-only image comparisons.

## Strings and licence notices

```sh
node Tools/strings/sync.mjs [--check]     # after an xcodebuild build into .build/DerivedData
node Tools/notices/generate.mjs [--check]
```

`strings/sync.mjs` reads the `.stringsdata` files the compiler writes for each target and keeps every
String Catalog in step with the code: it adds new keys, removes keys the code no longer uses, keeps
existing translations and plural variations, and gives every key a comment for translators.
`notices/generate.mjs` writes the component table in `THIRD_PARTY_NOTICES.md`, and copies each licence
text, from `Packages/OpencodeKit/Sources/OCDesign/Resources/Licenses/acknowledgements.json`, the list the
app's Acknowledgements screen shows. With `--check`, either tool changes nothing and fails when
something has drifted.

## Design references

`node Tools/design-reference/index.mjs --version 2.0.32` seeds real V2 sessions using the fixture mock, signs into the UI served by that sandbox, and captures desktop, both iPad orientations, and iPhone in light/dark. Playwright and Chromium remain under `.build`; no installed browser profile or installed OpenCode is used. See `docs/design.md` for snapshot recording, import scripts, and `.build/design-compare/index.html` generation.

Every V1/V2 server, including npx, runs under macOS `sandbox-exec`. The profile denies `file-write*` in the real user's OpenCode config/data/state/cache directories and LaunchAgents, including resolved symlink destinations. Before starting npx, an in-sandbox bootstrap must fail to write a disposable canary covered by the same profile. A PID-, nonce- and profile-digest-bound receipt proves the check; restrictions inherit to all descendants. A missing/invalid receipt or successful canary write aborts the launch. Audits retain proof after process cleanup and fail if any launch lacks it.

Before/after snapshots still compare mtimes. `lsof` samples identify writable descriptors, process groups and change intervals. Changes attributed to sandbox processes always fail. With verified enforcement on every launch, unattributed writes are warnings naming the path and time; unique external writers are named too. OpenCode.app may independently modify models.json, storage/ and its databases. Missing enforcement, a failed denied-write check or an inspection failure still fails the run.

## Demo, screenshots, upstream watch and release

```sh
node Tools/demo/record.mjs                       # record the in-app demo from the sandbox and the scripted model
node Tools/screenshots/index.mjs --device "iPhone 17 Pro" --device "opencode-ios iPad" --readme
node Tools/spec-watch/index.mjs --issue --dry-run  # check the newest opencode release against the baseline
node Tools/release/version.mjs                    # print the version and build number
node Tools/release/index.mjs archive --unsigned   # unsigned archive, the dry run of the release
node Tools/onboarding/sync.mjs --check           # web/index.html matches the app's constants
```

- **Demo.** `Tools/demo/script.mjs` holds the sample project and the scripted sessions; the recorder runs them on a sandboxed server with the scripted model and writes `Packages/OpencodeKit/Sources/OCSync/Resources/Demo/demo.json`, with sandbox paths moved to `/Users/Shared/trailhead`. The app plays it with `ScenarioTransport`, which answers only its own `.invalid` host. Recording again changes the session IDs that `DemoSmokeTests` and `ScreenshotTests` name.
- **Screenshots.** `ScreenshotTests` walks the demo in light and dark on each named simulator (existing ones only) and the tool saves `.build/store-screenshots/<device>/<light|dark>-<n>-<screen>.png`. While it captures, the status bar shows 9:41 with full Wi-Fi, cellular and battery (`simctl status_bar … override`), cleared afterwards. `--readme` rebuilds `docs/images/hero.webp` and `docs/images/iphone-*.webp` from the light captures; it needs `cwebp` (Homebrew `webp`). The full UI run skips this test.
- **Spec watch.** Compares the newest `@opencode/cli` release with the newest `Fixtures/v2` baseline: its `/openapi.json` against the one recorded in `Fixtures/v2/<baseline>/openapi.json` (with `oasdiff` when installed, else a built-in summary) and its event union against the app's `ServerEvent.knownTypes`. Recording a newer release, once its changes are handled, moves the baseline. With `--issue` it opens or updates a GitHub issue using `GITHUB_TOKEN`; `--dry-run` writes the issue to `.build/spec-watch/<version>/issue.md` instead. CI runs it daily.
- **Release.** `Config/Version.xcconfig` is the only place the version and build number are set. Every signed step (`archive`, `export`, `upload`) refuses to run without `TEAM_ID`; `.github/workflows/release.yml` runs them on manual dispatch.
