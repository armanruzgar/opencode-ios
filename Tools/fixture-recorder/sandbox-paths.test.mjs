import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { hostNames, PUBLISHED_HOSTNAME, relocate } from './sandbox-paths.mjs';

const root = '/work/opencode-ios/.build/opencode-sandbox/2.0.32/0d7313e0';
const escaped = text => text.replaceAll('/', '\\/');

test('relocate replaces the plain, JSON-escaped and URL-encoded run root', () => {
  const lines = root => [`"directory":"${root}/project"`, `"cwd":"${escaped(root)}\\/project"`,
    `"output":"1 matches\\n${root}/project/sample.txt"`, `?directory=${encodeURIComponent(`${root}/project`)}`, `file://${root}`, root];
  assert.equal(relocate(lines(root).join('\n'), [root]).toString(), lines('/sandbox').join('\n'));
});

test('relocate keeps longer names and every other byte unchanged', () => {
  const kept = ` ${root}1 ${root}-copy `;
  const input = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(`${kept}${root}/tmp/opencode`)]);
  assert.deepEqual(relocate(input, [root]), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(`${kept}/sandbox/tmp/opencode`)]));
  assert.deepEqual(relocate(Buffer.from('no paths'), [root]), Buffer.from('no paths'));
});

test('relocate replaces the reported host name where it stands alone', () => {
  const host = 'Example-MacBook-Pro.local';
  const input = `{"hostname":"${host}","note":"x${host} ${host}x ${host}"}`;
  assert.equal(relocate(input, [root], [host]).toString(), `{"hostname":"${PUBLISHED_HOSTNAME}","note":"x${host} ${host}x ${PUBLISHED_HOSTNAME}"}`);
});

test("this machine's host name is rewritten unasked only when it has a dot, and localhost never", () => {
  assert.deepEqual(hostNames([], 'Example-MacBook-Pro.local'), ['Example-MacBook-Pro.local']);
  assert.deepEqual(hostNames([], 'build'), [], 'A bare name may be an ordinary word');
  assert.deepEqual(hostNames(['build', 'localhost'], 'build'), ['build'], 'The name the server reported is always rewritten');
  assert.deepEqual(hostNames(['a.local'], 'longer.local'), ['longer.local', 'a.local']);
  const host = os.hostname(), rewritten = host.includes('.') && host !== 'localhost';
  assert.equal(relocate(`"hostname":"${host}"`, [root]).toString(), `"hostname":"${rewritten ? PUBLISHED_HOSTNAME : host}"`);
  assert.equal(relocate('http://localhost:4096', [root], ['localhost']).toString(), 'http://localhost:4096');
});

test('relocate also replaces the root with symlinks resolved', () => {
  const link = mkdtempSync(path.join(os.tmpdir(), 'relocate-'));
  try {
    assert.equal(relocate(`${link}/a ${realpathSync(link)}/b`, [link]).toString(), '/sandbox/a /sandbox/b');
  } finally { rmSync(link, { recursive: true }); }
});
