import os from 'node:os';

const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

/** simctl can print installer notices before its JSON (an Xcode update waiting for an administrator); skip them. */
export const simctlJSON = output => JSON.parse(output.slice(output.indexOf('{')));

/** A simulator's state as simctl lists it ("Booted", "Shutdown", "Shutting Down"), or undefined when it is not listed. */
export async function simulatorState(xcrun, udid) {
  const listed = simctlJSON(await xcrun(['simctl', 'list', 'devices', '--json']));
  return Object.values(listed.devices).flat().find(device => device.udid === udid)?.state;
}

/**
 * Shuts a simulator down, boots it again and waits until it has finished booting. A simulator that has been booted for
 * a while can stop finishing rotations, and then every iPad test fails in its setup ("Rotation to portrait did not
 * finish"); a fresh boot clears that. It never creates, erases or reconfigures a simulator. A restart still unfinished
 * at `deadline` fails, so a boot that stalls on a loaded host fails the run instead of holding it forever.
 */
export async function restartSimulator(xcrun, udid, { deadline = 10 * 60_000, ...options } = {}) {
  await withDeadline(restart(xcrun, udid, options), deadline, `Simulator ${udid} did not finish restarting within ${deadline / 1000} s`);
}

/** Boots a simulator that is not booted, waiting until it has finished booting; a booted one is left as it is. */
export async function bootSimulator(xcrun, udid, { deadline = 10 * 60_000, ...options } = {}) {
  if (await simulatorState(xcrun, udid) === 'Booted') return;
  await withDeadline(restart(xcrun, udid, options), deadline, `Simulator ${udid} did not finish booting within ${deadline / 1000} s`);
}

/** The result of `work`, or an error with `message` once `ms` have passed; the timer never outlives the work. */
export async function withDeadline(work, ms, message) {
  let timer;
  const expired = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), ms); });
  try { return await Promise.race([work, expired]); } finally { clearTimeout(timer); }
}

async function restart(xcrun, udid, { timeout = 120_000, interval = 1000, now = Date.now, sleep = pause }) {
  let state = await simulatorState(xcrun, udid);
  if (state === undefined) throw new Error(`Simulator ${udid} is not listed`);
  if (state !== 'Shutdown') {
    // `shutdown` fails on a simulator that is already shutting down, so the state it reaches decides.
    let failure;
    try { await xcrun(['simctl', 'shutdown', udid]); } catch (error) { failure = error; }
    const deadline = now() + timeout;
    for (state = await simulatorState(xcrun, udid); state !== 'Shutdown'; state = await simulatorState(xcrun, udid)) {
      if (now() >= deadline) throw new Error(`Simulator ${udid} is still ${state ?? 'unlisted'} after its shutdown`, { cause: failure });
      await sleep(interval);
    }
  }
  await xcrun(['simctl', 'boot', udid]);
  await xcrun(['simctl', 'bootstatus', udid, '-b']);
}

/**
 * Waits until the one-minute load average is under `limit` (four per core by default) or `maxWait` has passed. A
 * timing-sensitive UI test that failed in a burst of load from other work on the host fails again if it runs again
 * inside that burst. Returns the load before and after, the limit, the minutes waited and whether the load settled.
 */
export async function settleLoad({ limit = 4 * os.availableParallelism(), maxWait = 15 * 60_000, interval = 15_000, load = () => os.loadavg()[0], now = Date.now, sleep = pause } = {}) {
  const started = now(), before = load();
  let after = before;
  while (after >= limit && now() - started < maxWait) {
    await sleep(Math.min(interval, maxWait - (now() - started)));
    after = load();
  }
  const round = value => Math.round(value * 10) / 10;
  return { before: round(before), after: round(after), limit, minutes: Math.round((now() - started) / 600) / 100, settled: after < limit };
}
