import test from 'node:test';
import assert from 'node:assert/strict';
import { launch } from '../opencode-sandbox/process.mjs';
import { runUntilQuiet } from './stall.mjs';

const watch = { quiet: 400, interval: 50 };

test('a command that finishes returns its output', async () => {
  assert.equal((await runUntilQuiet(launch, '/bin/echo', ['done'], {}, watch)).trim(), 'done');
});

test('a command that keeps printing is never stopped', async () => {
  const output = await runUntilQuiet(launch, '/bin/sh', ['-c', 'for i in 1 2 3 4 5 6 7 8; do echo $i; sleep 0.15; done'], {}, watch);
  assert.equal(output.trim().split('\n').length, 8, 'Ran 1.2 s, three times the silence limit, while printing every 0.15 s');
});

test('a command that falls silent is stopped and marked stalled', async () => {
  const started = Date.now();
  await assert.rejects(runUntilQuiet(launch, '/bin/sh', ['-c', 'echo waiting; sleep 30'], {}, watch), error => {
    assert.equal(error.stalled, true);
    assert.match(error.message, /printed nothing for 0.4 s and was stopped: waiting/);
    return true;
  });
  assert.ok(Date.now() - started < 10_000, 'Stopped long before the command would have ended');
});

test('a command that cannot be stopped still ends as stalled, with the cleanup error as its cause', async () => {
  // Stands in for a process group that refuses its signals and never exits.
  const fake = () => {
    const stream = () => ({ on() {} });
    const child = { stdout: stream(), stderr: stream(), once() {} };
    const cleanup = Promise.reject(new Error('kill EPERM'));
    cleanup.catch(() => {});
    return { child, output: 'waiting', stop: () => cleanup };
  };
  await assert.rejects(runUntilQuiet(fake, 'xcodebuild', [], {}, watch), error => {
    assert.equal(error.stalled, true);
    assert.match(error.message, /printed nothing for 0.4 s and was stopped: waiting/);
    assert.match(error.cause.message, /kill EPERM/);
    return true;
  });
});

test('a command that fails is not marked stalled', async () => {
  await assert.rejects(runUntilQuiet(launch, '/bin/sh', ['-c', 'echo broken; exit 3'], {}, watch), error => {
    assert.equal(error.stalled, undefined);
    assert.match(error.message, /exited 3: broken/);
    return true;
  });
});
