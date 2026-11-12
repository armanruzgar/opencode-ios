import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parseArgs } from 'node:util';
import { repository, resolveVersion, startSandbox, V1_VERSION } from '../opencode-sandbox/index.mjs';
import { audit } from '../opencode-sandbox/isolation.mjs';
import { stopAll } from '../opencode-sandbox/process.mjs';
import { startMock } from '../mock-llm/server.mjs';
import { Capture } from './transport.mjs';
import { scenarioNames, runScenario } from './scenarios.mjs';
import { relocate } from './sandbox-paths.mjs';

export const RECORDER_VERSION = '2.0.0';
const { values } = parseArgs({ options: { version: { type: 'string' }, scenario: { type: 'string', multiple: true }, output: { type: 'string' } } });
const selected = values.scenario ?? scenarioNames;
for (const name of selected) if (!scenarioNames.includes(name)) throw new Error(`Unknown scenario ${name}`);
const version = await resolveVersion(values.version);
const output = values.output ? path.resolve(values.output) : path.join(repository, 'Fixtures/v2', version);
const auditDir = path.join(repository, '.build/opencode-sandbox/audits', `record-${Date.now()}`);
const json = value => JSON.stringify(value, null, 2) + '\n';

await audit(auditDir, async () => {
  const mock = await startMock();
  let server, v1;
  try {
    console.log(`Recording opencode ${version}; audit ${auditDir}`);
    server = await startSandbox({ version, mockURL: mock.url });
    const metadata = new Capture(server);
    const info = await metadata.request('GET', '/api/info');
    const openapi = await metadata.request('GET', '/openapi.json');
    const results = [];
    for (const name of selected) {
      if (name === 'v1-probe') v1 ??= await startSandbox({ version: V1_VERSION, v1: true, mockURL: mock.url });
      let capture;
      try {
        const result = await runScenario(name === 'v1-probe' ? v1 : server, mock, name, { heartbeat: name === 'pairing', onCapture: c => { capture = c; } });
        results.push({ name, ...result });
        console.log(`PASS ${name} (${result.capture.events.length} events)`);
      } catch (error) {
        await mkdir(path.join(auditDir, 'failed'), { recursive: true });
        if (capture) {
          await writeFile(path.join(auditDir, 'failed', `${name}.rest.json`), json(capture.rest));
          await writeFile(path.join(auditDir, 'failed', `${name}.redacted.sse`), capture.redact(Buffer.concat(capture.chunks).toString('utf8')));
        }
        await writeFile(path.join(auditDir, 'failed', `${name}.mock.json`), json(mock.state()));
        throw error;
      }
    }
    // Publish only after every requested scenario passed.
    await Promise.all(['rest', 'sse', 'ws', 'snapshots'].map(dir => mkdir(path.join(output, dir), { recursive: true })));
    const manifest = { recorderVersion: RECORDER_VERSION, opencodeVersion: version, v1Version: selected.includes('v1-probe') ? V1_VERSION : undefined, recordedAt: new Date().toISOString(), sourceReference: 'd0732ea (read-only)', scenarios: [], omitted: scenarioNames.filter(name => !selected.includes(name)) };
    const roots = [server.root, v1?.root].filter(Boolean), hosts = [info?.hostname].filter(Boolean);
    const publish = async (relative, data) => {
      const bytes = relocate(data, roots, hosts);
      await writeFile(path.join(output, relative), bytes);
      return bytes;
    };
    await publish('info.json', json(info));
    await publish('openapi.json', json(openapi));
    await publish('rest/server.json', json(metadata.rest));
    for (const { name, capture, mock: state } of results) {
      const files = [];
      const save = async (relative, data) => {
        const bytes = await publish(relative, data);
        files.push({ path: relative, sha256: createHash('sha256').update(bytes).digest('hex') });
      };
      await save(`rest/${name}.json`, json(capture.rest));
      await save(`snapshots/${name}.json`, json(capture.snapshots ?? []));
      if (capture.chunks.length) await save(`sse/${name}.sse`, Buffer.concat(capture.chunks));
      if (capture.frames.length) await save(`ws/${name}.json`, json(capture.frames));
      manifest.scenarios.push({ name, serverVersion: name === 'v1-probe' ? V1_VERSION : version, mockScenarioHash: state.hash, calls: state.consumed, files });
    }
    await writeFile(path.join(output, 'manifest.json'), json(manifest));
    console.log(`Saved ${results.length} scenarios to ${output}`);
  } finally {
    try { await v1?.stop(); await server?.stop(); }
    finally { await stopAll(); await mock.close(); }
  }
});
