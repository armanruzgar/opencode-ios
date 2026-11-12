import { spawn, execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { readFile } from 'node:fs/promises';

const groups = new Set();
// Retain identities after cleanup so an audit can attribute a process that exited.
export const sandboxGroups = new Set();
const enforcementRecords = new Map();
export function enforcementReport() {
  const launches = [...enforcementRecords.values()];
  return { verified: launches.length > 0 && launches.every(item => item.verified), launches };
}
export function refreshSandboxGroups() {
  const rows = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid='], { encoding: 'utf8' })
    .trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const owned = new Set(rows.filter(([, , pgid]) => sandboxGroups.has(pgid)).map(([pid]) => pid));
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, parent, pgid] of rows) if (owned.has(parent) && !owned.has(pid)) {
      owned.add(pid); sandboxGroups.add(pgid); changed = true;
    }
  }
}
let stopping;
const shutdownHooks = new Set();
export const onShutdown = callback => { shutdownHooks.add(callback); return () => shutdownHooks.delete(callback); };
export async function stopAll() {
  if (stopping) return stopping;
  stopping = (async () => {
    const results = await Promise.allSettled([...groups].map(group => group.stop()));
    const errors = results.filter(result => result.status === 'rejected');
    if (errors.length) throw new AggregateError(errors.map(result => result.reason), 'Process cleanup failed');
  })();
  try { await stopping; } finally { stopping = undefined; }
}
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.once(signal, async () => {
    try {
      await stopAll();
      const results = await Promise.allSettled([...shutdownHooks].map(hook => hook()));
      if (results.some(result => result.status === 'rejected')) throw new Error('Shutdown hook failed');
      process.exit(signal === 'SIGINT' ? 130 : 143);
    }
    catch (error) { console.error(error.message); process.exit(1); }
  });
}

function alive(pid) {
  try { process.kill(-pid, 0); return true; }
  catch (error) {
    if (error.code === 'ESRCH') return false;
    // Darwin can report EPERM for a process group during teardown. Confirm its
    // membership rather than interpreting a permission error as either success
    // or a dead process. Keep polling existing members until they are reaped;
    // a group that refused TERM/KILL and outlives the wait still fails cleanup.
    if (error.code === 'EPERM') {
      const groups = execFileSync('/bin/ps', ['-axo', 'pgid='], { encoding: 'utf8' }).trim().split(/\s+/).map(Number);
      return groups.includes(pid);
    }
    throw new Error(`Cannot inspect process group ${pid}: ${error.code}`, { cause: error });
  }
}

function descendants(pid) {
  const rows = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,pgid='], { encoding: 'utf8' }).trim().split('\n').map(line => line.trim().split(/\s+/).map(Number));
  const owned = new Set([pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [child, parent] of rows) if (owned.has(parent) && !owned.has(child)) { owned.add(child); changed = true; }
  }
  return rows.filter(([child]) => owned.has(child));
}

export function launch(command, args, { cwd, env, sandboxed = false, enforcement } = {}) {
  if (sandboxed && (!enforcement || command !== '/usr/bin/sandbox-exec')) {
    throw new Error('Sandbox enforcement is required for every server launch');
  }
  const child = spawn(command, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
  if (sandboxed && child.pid) {
    sandboxGroups.add(child.pid);
    enforcementRecords.set(child.pid, { pid: child.pid, verified: false, profileDigest: enforcement.profileDigest,
      protectedRoots: enforcement.protectedRoots, receipt: enforcement.receipt, descendantsInherit: true });
  }
  let output = '', failure;
  let cleanup;
  const secrets = [...new Set([env?.OPENCODE_PASSWORD, env?.OPENCODE_SERVER_PASSWORD, env?.OPENCODE_LIVE_PASSWORD, env?.OPENCODE_LIVE_V1_PASSWORD,
    env?.TEST_RUNNER_OPENCODE_UI_PASSWORD, env?.TEST_RUNNER_OPENCODE_UI_V1_PASSWORD,
    env?.TEST_RUNNER_OPENCODE_UI_PROXY_TOKEN,
    env?.TEST_RUNNER_OPENCODE_UI_PAIRING_LINK].filter(Boolean))]
    .flatMap(secret => [secret, Buffer.from(`opencode:${secret}`).toString('base64')]);
  const redactedOutput = () => {
    let text = output;
    for (const secret of secrets) text = text.replaceAll(secret, '[REDACTED]');
    // UI tests can mint fresh, single-use links after the process has launched.
    text = text.replace(/https?:\/\/[^\s'"<>]+\/auth\/connect\/[A-Za-z0-9_-]+/g, '[REDACTED]');
    // XCTest truncates typeText arguments before emitting them, including SecureField inputs.
    text = text.replace(/Type '[^'\n]*' into/g, "Type '[REDACTED]' into");
    return text;
  };
  child.on('error', error => { failure = error; });
  for (const stream of [child.stdout, child.stderr]) stream.on('data', data => {
    // Redact the joined output when reading, including secrets split across chunks.
    output = (output + data.toString()).slice(-24000);
  });
  const group = {
    child,
    async verifyEnforcement() {
      if (!sandboxed) throw new Error('Process was not launched with sandbox enforcement');
      if (enforcementRecords.get(child.pid)?.verified) return true;
      let proof;
      try { proof = JSON.parse(await readFile(enforcement.receipt, 'utf8')); }
      catch (error) {
        // Bootstrap can still be writing the receipt. The caller retries within
        // its existing deadline; only a complete, matching proof verifies it.
        if (error.code === 'ENOENT' || error instanceof SyntaxError) return false;
        throw error;
      }
      if (!proof || proof.pid !== child.pid || proof.token !== enforcement.token || proof.profileDigest !== enforcement.profileDigest ||
          proof.deniedWrite !== true || JSON.stringify(proof.protectedRoots) !== JSON.stringify(enforcement.protectedRoots)) {
        throw new Error('Sandbox enforcement receipt is invalid');
      }
      Object.assign(enforcementRecords.get(child.pid), { verified: true, deniedWrite: true, verifiedAt: proof.verifiedAt });
      return true;
    },
    get output() { return redactedOutput(); },
    check() {
      if (failure) throw failure;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error(`Child exited (${child.exitCode ?? child.signalCode}): ${redactedOutput()}`);
    },
    async stop() {
      if (cleanup) return cleanup;
      cleanup = (async () => {
        if (!child.pid) { groups.delete(group); return; }
        // PTYs can establish their own session/group. Remember only verified
        // descendants before terminating the parent, and check those groups too.
        const children = descendants(child.pid);
        const ownedGroups = new Set([child.pid, ...children.map(([, , pgid]) => pgid)]);
        if (sandboxed) for (const pgid of ownedGroups) sandboxGroups.add(pgid);
        const ownGroup = Number(execFileSync('/bin/ps', ['-o', 'pgid=', '-p', String(process.pid)], { encoding: 'utf8' }).trim());
        if (ownedGroups.has(ownGroup)) throw new Error('Refusing to signal the harness process group');
        for (const signal of ['SIGTERM', 'SIGKILL']) {
          for (const pgid of ownedGroups) if (alive(pgid)) {
            // Darwin can also refuse a signal with EPERM to a group that is already tearing down (xcodebuild does
            // under load); whether the group is gone is what counts, and the survivor check below decides that.
            try { process.kill(-pgid, signal); } catch (error) { if (error.code !== 'ESRCH' && error.code !== 'EPERM') throw error; }
          }
          for (let i = 0; i < 40 && [...ownedGroups].some(alive); i++) await delay(50);
          if (![...ownedGroups].some(alive)) break;
        }
        // A loaded host can take longer than that to reap a killed group.
        for (let i = 0; i < 600 && [...ownedGroups].some(alive); i++) await delay(50);
        const survivors = [...ownedGroups].filter(alive);
        if (survivors.length) throw new Error(`Process groups ${survivors.join(', ')} survived cleanup`);
        groups.delete(group);
      })();
      return cleanup;
    },
  };
  groups.add(group);
  return group;
}

export async function run(command, args, options) {
  const group = launch(command, args, options);
  try {
    const code = await new Promise((resolve, reject) => {
      group.child.once('error', reject);
      group.child.once('exit', resolve);
    });
    if (code !== 0) throw new Error(`${command} exited ${code}: ${group.output}`);
    return group.output;
  } finally { await group.stop(); }
}
