// Shared pieces of the push live checks: a recording relay, a fake device, the plugin's RPC, and
// opening envelopes with the shared TypeScript contracts.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { mkdtemp, realpath } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { base64url, generateKeyPair, openEnvelope, PLUGIN_ID, RPC_ID } from '../../server/contracts/src/index.ts';
import { basic } from '../opencode-sandbox/index.mjs';
import { launch } from '../opencode-sandbox/process.mjs';
import { verifiedSandboxCommand } from '../opencode-sandbox/profile.mjs';
import { configureReview } from '../review-fixture/index.mjs';

export const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const pluginDirectory = path.join(repository, 'server/plugin');
/** core/src/plugin/host.ts `storage()`: each UTF-16 unit of the plugin ID as four hex digits. */
export const storageNamespace = `plugin:${[...PLUGIN_ID].map(character => character.charCodeAt(0).toString(16).padStart(4, '0')).join('')}:`;

/** The sandbox configuration hook that loads the plugin from this checkout (the configuration install). */
export function configurePlugin(config, dirs, env) {
  config.plugins = [pluginDirectory];
  return configureReview(config, dirs, env);
}

/** A loopback relay that records each call and answers from a per-token script, then "delivered". */
export async function startRecordingRelay() {
  const calls = [];
  const scripts = new Map();
  const server = http.createServer((request, response) => {
    let text = '';
    request.on('data', chunk => (text += chunk));
    request.on('end', () => {
      const token = /^Bearer (.+)$/.exec(request.headers.authorization ?? '')?.[1];
      calls.push({ path: request.url ?? '', token, body: JSON.parse(text || 'null'), at: performance.now() });
      const reply = (token && scripts.get(token)?.shift()) || { status: 200, body: { result: 'delivered' } };
      response.writeHead(reply.status, { 'content-type': 'application/json' }).end(JSON.stringify(reply.body ?? {}));
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    calls,
    pushes: () => calls.filter(call => call.path === '/v1/push'),
    activities: () => calls.filter(call => call.path === '/v1/activity'),
    script: (token, ...answers) => void scripts.set(token, answers),
    close: () => new Promise(resolve => server.close(resolve)),
  };
}

/** A phone's per-server key pair, in CryptoKit's raw 32-byte X25519 form, and its relay token. */
export async function fakeDevice(label) {
  return { label, keyID: `kid_${randomBytes(15).toString('base64url')}`, keys: await generateKeyPair(), sendToken: `ocs_${randomBytes(24).toString('base64url')}` };
}

export class RpcFailure extends Error {
  constructor(method, status, body) {
    super(`${RPC_ID}.${method}: ${status} ${JSON.stringify(body)}`);
    this.status = status;
    this.body = body;
  }
}

/**
 * `POST /api/rpc/mobilepush/<method>`, on the location of `directory` (the server's default without one). From 2.2.7
 * a plugin's RPC answers `rpc.unavailable` for a moment after its location boots, since plugins load after it; that
 * answer is asked again for up to 10 seconds.
 */
export async function rpc(server, method, input, directory) {
  const query = directory ? '?' + new URLSearchParams({ 'location[directory]': directory }) : '';
  const deadline = Date.now() + 10_000;
  for (;;) {
    const response = await fetch(`${server.baseURL}/api/rpc/${RPC_ID}/${method}${query}`, {
      method: 'POST',
      headers: { authorization: basic(server.password), 'content-type': 'application/json', accept: 'application/json' },
      // The server refuses a call without `input` ("Expected JSON value"), even for a method that takes none.
      body: JSON.stringify({ input: input ?? {} }),
      signal: AbortSignal.timeout(30000),
    });
    const text = await response.text();
    const body = text ? JSON.parse(text) : null;
    if (response.status === 400 && body?.type === 'rpc.unavailable' && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 250));
      continue;
    }
    if (response.status !== 200) throw new RpcFailure(method, response.status, body);
    return body?.output;
  }
}

export async function registerDevice(server, device, relayURL, directory, extra = {}) {
  return rpc(server, 'registerDevice', {
    sendToken: device.sendToken,
    relayURL,
    devicePublicKey: base64url.encode(device.keys.publicKey),
    keyID: device.keyID,
    appServerRef: 'srv_live_check',
    label: device.label,
    ...extra,
  }, directory);
}

/** Opens an envelope the way the app's extension will, with the device key and the pinned plugin key. */
export function openFor(envelope, device, serverPublicKey, now = Math.floor(Date.now() / 1000)) {
  return openEnvelope(envelope, {
    now,
    key: kid => (kid === device.keyID ? { recipientPrivateKey: device.keys.privateKey, senderPublicKey: base64url.decode(serverPublicKey) } : undefined),
  });
}

export async function until(predicate, label, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await predicate();
    if (value) return value;
    await delay(25);
  }
  throw new Error(`Timed out: ${label}`);
}

/** Replaces the mock model's script; it must be idle first. */
export async function script(mock, name, calls) {
  await until(() => mock.state().active === 0, 'mock idle');
  const response = await fetch(mock.url + '/admin/scenario', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name, script: { calls } }) });
  assert.equal(response.status, 200, await response.text());
}

/** The plugin's rows in the sandbox's `kv` table, read-only, without the namespace prefix. */
export function storedKeys(server) {
  const database = new DatabaseSync(path.join(server.env.XDG_DATA_HOME, 'opencode.db'), { readOnly: true });
  try {
    const rows = database.prepare('SELECT key FROM kv WHERE key LIKE ? ORDER BY key').all('plugin:%');
    return rows.map(row => row.key);
  } finally { database.close(); }
}

/**
 * Runs an opencode CLI command under the same sandbox-exec profile as the server, and verifies the
 * enforcement receipt like a server launch, so the isolation audit covers it.
 */
export async function sandboxedCLI(version, args, { env, cwd, root, deniedReads = [], timeout = 240000 }) {
  const npx = await realpath(path.join(path.dirname(process.execPath), 'npx'));
  // Its own receipt and canary: the server launched later in the same run root writes the root's.
  const receipts = await mkdtemp(path.join(root, 'cli-'));
  const invocation = await verifiedSandboxCommand(process.execPath, [npx, '-y', `@opencode/cli@${version}`, ...args], receipts, undefined, deniedReads);
  const group = launch(invocation.command, invocation.args, { cwd, env, sandboxed: true, enforcement: invocation.enforcement });
  try {
    const exit = new Promise((resolve, reject) => { group.child.once('error', reject); group.child.once('exit', resolve); });
    const deadline = Date.now() + timeout;
    let code, verified = false;
    exit.then(value => { code = value; });
    while (code === undefined) {
      if (!verified) verified = await group.verifyEnforcement();
      if (Date.now() > deadline) throw new Error(`opencode ${args.join(' ')} timed out: ${group.output}`);
      await delay(50);
    }
    if (!verified) verified = await group.verifyEnforcement();
    assert.ok(verified, 'The CLI ran without verified sandbox enforcement');
    if (code !== 0) throw new Error(`opencode ${args.join(' ')} exited ${code}: ${group.output}`);
    return group.output;
  } finally { await group.stop(); }
}
