import test from 'node:test';
import assert from 'node:assert/strict';
import { bootSimulator, restartSimulator, settleLoad, simctlJSON, simulatorState, withDeadline } from './simulators.mjs';

const udid = 'C978DCA6-BF6B-4DD4-A1C1-A41C4CDCE20D';
const clock = () => {
  let time = 0;
  return { now: () => time, sleep: async ms => { time += ms; } };
};
/** A fake `xcrun` that lists the simulator in its current state and records every other command. */
const simctl = ({ states, failShutdown = false, hang }) => {
  const calls = [];
  let listing = 0;
  const xcrun = async args => {
    if (args[1] === 'list') {
      const state = states[Math.min(listing++, states.length - 1)];
      return 'An installer notice before the JSON\n' + JSON.stringify({ devices: { 'com.apple.CoreSimulator.SimRuntime.iOS-26-5': state ? [{ udid, state, name: 'opencode-ios iPad' }] : [] } });
    }
    calls.push(args.slice(1).join(' '));
    if (args[1] === hang) return new Promise(() => {});
    if (args[1] === 'shutdown' && failShutdown) throw new Error('Unable to shutdown device in current state: Shutting Down');
    return '';
  };
  return { xcrun, calls };
};

test('simctl JSON after an installer notice parses', () => {
  assert.deepEqual(simctlJSON('Note: an Xcode update is waiting\n{"devices":{}}'), { devices: {} });
});

test('a simulator that is not listed has no state', async () => {
  assert.equal(await simulatorState(simctl({ states: [undefined] }).xcrun, udid), undefined);
});

test('a booted simulator shuts down, boots and waits for its boot', async () => {
  const { xcrun, calls } = simctl({ states: ['Booted', 'Shutdown'] });
  await restartSimulator(xcrun, udid, clock());
  assert.deepEqual(calls, [`shutdown ${udid}`, `boot ${udid}`, `bootstatus ${udid} -b`]);
});

test('a shut-down simulator boots without a shutdown', async () => {
  const { xcrun, calls } = simctl({ states: ['Shutdown'] });
  await restartSimulator(xcrun, udid, clock());
  assert.deepEqual(calls, [`boot ${udid}`, `bootstatus ${udid} -b`]);
});

test('a simulator already shutting down is waited for, then booted', async () => {
  const { xcrun, calls } = simctl({ states: ['Shutting Down', 'Shutting Down', 'Shutting Down', 'Shutdown'], failShutdown: true });
  await restartSimulator(xcrun, udid, { timeout: 10_000, interval: 1000, ...clock() });
  assert.deepEqual(calls, [`shutdown ${udid}`, `boot ${udid}`, `bootstatus ${udid} -b`]);
});

test('a simulator that never shuts down fails the restart with the shutdown error as its cause', async () => {
  const { xcrun, calls } = simctl({ states: ['Booted'], failShutdown: true });
  await assert.rejects(restartSimulator(xcrun, udid, { timeout: 3000, interval: 1000, ...clock() }), error => {
    assert.match(error.message, /is still Booted after its shutdown/);
    assert.match(error.cause.message, /Unable to shutdown/);
    return true;
  });
  assert.deepEqual(calls, [`shutdown ${udid}`], 'Never boots a simulator that did not shut down');
});

test('booting leaves a booted simulator alone and boots one that is down', async () => {
  const booted = simctl({ states: ['Booted'] });
  await bootSimulator(booted.xcrun, udid, clock());
  assert.deepEqual(booted.calls, [], 'A booted simulator keeps running');
  const down = simctl({ states: ['Shutdown'] });
  await bootSimulator(down.xcrun, udid, clock());
  assert.deepEqual(down.calls, [`boot ${udid}`, `bootstatus ${udid} -b`]);
});

test('booting waits for a simulator that is already booting instead of shutting it down', async () => {
  const { xcrun, calls } = simctl({ states: ['Booting'] });
  await bootSimulator(xcrun, udid, clock());
  assert.deepEqual(calls, [`bootstatus ${udid} -b`]);
});

test('booting fails at its deadline when simctl stops answering, state check included', async () => {
  const hung = async () => new Promise(() => {});
  await assert.rejects(bootSimulator(hung, udid, { deadline: 20 }), /did not finish booting within 0.02 s/);
});

test('a boot that stalls fails the restart at its deadline', async () => {
  const { xcrun, calls } = simctl({ states: ['Shutdown'], hang: 'bootstatus' });
  await assert.rejects(restartSimulator(xcrun, udid, { deadline: 50, ...clock() }), /did not finish restarting within 0.05 s/);
  assert.deepEqual(calls, [`boot ${udid}`, `bootstatus ${udid} -b`]);
});

test('an unlisted simulator fails the restart before any command', async () => {
  const { xcrun, calls } = simctl({ states: [undefined] });
  await assert.rejects(restartSimulator(xcrun, udid, clock()), /is not listed/);
  assert.deepEqual(calls, []);
});

test('work inside its deadline returns its result, and work past it fails with the message', async () => {
  assert.equal(await withDeadline(Promise.resolve('installed'), 1000, 'late'), 'installed');
  await assert.rejects(withDeadline(new Promise(() => {}), 20, 'simctl install did not finish'), /simctl install did not finish/);
});

test('a load under the limit needs no wait', async () => {
  let reads = 0;
  const result = await settleLoad({ limit: 48, load: () => { reads++; return 12.34; }, ...clock() });
  assert.deepEqual(result, { before: 12.3, after: 12.3, limit: 48, minutes: 0, settled: true });
  assert.equal(reads, 1);
});

test('a burst of load is waited out until it drops under the limit', async () => {
  const loads = [152.4, 120, 61, 47.9];
  const result = await settleLoad({ limit: 48, interval: 15_000, load: () => loads.shift(), ...clock() });
  assert.deepEqual(result, { before: 152.4, after: 47.9, limit: 48, minutes: 0.75, settled: true });
});

test('a load that never settles ends the wait at its limit', async () => {
  let reads = 0;
  const result = await settleLoad({ limit: 48, maxWait: 60_000, interval: 25_000, load: () => { reads++; return 200; }, ...clock() });
  assert.deepEqual(result, { before: 200, after: 200, limit: 48, minutes: 1, settled: false });
  assert.equal(reads, 4, 'Read at 0, 25, 50 and at the 60-second limit');
});
