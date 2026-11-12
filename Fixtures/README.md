# Fixtures

`foundation/` contains synthetic JSON and identifier vectors for offline unit tests.
These are not captured server responses.

`source/` contains hand-made inputs for the approval and review snapshot tests:
a permission request and a question form, and patches and an image to review.

`performance/baselines.json` holds the memory baselines the read performance tests
compare against, on the simulator and on the Mac that runs `swift test`.

`v2/<server-version>/` contains real isolated npm-server recordings: 2.0.32, an
early release close to the 2.0.25 minimum, and 2.2.6. The fixture tests read
every recorded release, and the newest one is the baseline the spec watch
compares new releases with. See [`Tools/README.md`](../Tools/README.md) for
isolation, mock scripts, and commands.

```sh
node Tools/fixture-recorder/index.mjs                 # newest stable V2, resolved once
node Tools/fixture-recorder/index.mjs --version 2.0.32
node Tools/contract/index.mjs --version 2.0.32        # separate live checks
swift test --package-path Packages/OpencodeKit       # offline fixture checks
```

Each recording includes:

- `info.json` and `openapi.json`: the live server's info and OpenAPI document.
- `rest/<scenario>.json`: ordered request/response pairs. Methods, relative paths,
  headers, status and decoded bodies are retained. Credentials, pairing codes,
  cookies and tokens are redacted, and the server's `hostname` (2.2 and later)
  reads `sandbox.local`. `bodyFormat` distinguishes JSON, empty bodies
  (`null`), and text. V1 `/api/info` returns the HTML app shell, so its body is
  stored as a JSON string with `bodyFormat: "text"`.
- `sse/<scenario>.sse`: exact received HTTP entity bytes, including SSE framing
  and any comments. Transfer chunk framing is not part of the SSE payload.
  Neither newlines nor IDs/timestamps/paths are normalized. A secret in raw SSE
  causes recording to fail instead of rewriting bytes.
- `ws/pty.json`: handshakes and each sent/received RFC 6455 frame. `opcode`, `fin`,
  connection number, and base64 payload preserve text, binary `0x00` + JSON cursor
  markers, and close/control frames. Client masking bytes are transport-only and
  omitted; payloads are unmasked. Connection 2 resumes from a UTF-16 cursor.
- `manifest.json`: recorder/server versions, recording time, scenario/script
  SHA-256 hashes, consumed model calls, file SHA-256 hashes, and omissions. V1
  probe pairs live in the V2 suite, with their actual V1 version listed separately.

Each suite covers text, reasoning, read/glob/grep, allow once, rejection
with feedback, shell output fetch, answered form, child session, steer/queue,
interrupt, interrupt/resume, revert stage/clear/commit/redo, fork, compaction,
429 retry, 500 retry, terminal error, PTY, pairing, and V1 detection. Each
conversation ends with a message snapshot, which the projection-parity tests
compare with the result of replaying its stream. Server-generated IDs, times,
ports and sandbox paths vary between recordings; scripted model content is
deterministic.

`OCFoundationTests/RecordedFixtureTests.swift` enumerates recordings without
network access, checks JSONValue decoding, first-event `server.connected`, known
durable envelopes, strictly increasing sequence numbers per aggregate (gaps are
legal), REST bodies and binary PTY markers. Its SSE framing helper is test-only;
the app parses streams incrementally with `OCNetworking/SSEParser.swift`.
`OCSyncTests/ProjectionParityTests.swift` replays each recorded stream through the
stores and compares the transcript with the recorded message snapshot.

Partial debug captures should use `--output .build/fixture-debug`; repeat
`--scenario NAME` to select several. Run the full recorder to refresh a published
version. Failed scenario diagnostics and before/after isolation comparisons are
kept under `.build/opencode-sandbox/audits/`, outside the checked-in fixtures.

The foundation identifier vectors are derived from the opencode V2 source at `d0732ea`,
`packages/schema/src/identifier.ts` and the prefix declarations beside it. Each vector applies `timestamp * 4096 + counter`,
optionally complements it, keeps the low six big-endian bytes, and maps the 14
input bytes through `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`
with `byte % 62`. The sequence starts with counter 1 and resets on any timestamp
change. The 36 timestamp bits wrap every 68,719,476,736 ms; decoding a full date
requires a nearby reference time. More than 4,095 IDs/ms carries into the time bits.
