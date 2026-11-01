import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bufferCommand, bufferDone, bufferRun } from './pty.mjs';

test('the buffer wait ends with the output, not with the echoed command line', () => {
  // bash echoes the line as typed, its newline as CR LF, before the command prints anything.
  const echo = bufferCommand.replace(/\n$/, '\r\n');
  assert.equal(bufferDone(echo), false);
  const output = `${echo}${'a'.repeat(5)}\r\nbuffer-done\r\n$ `;
  assert.equal(bufferDone(output), true);
  assert.equal(bufferRun(output), 5);
  assert.equal(bufferRun(`${echo}aaa\r\naa\r\nbuffer-done\r\n`), 2, 'Only the run that ends at the marker counts');
});
