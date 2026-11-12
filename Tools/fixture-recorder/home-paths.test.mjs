import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PUBLISHED_HOSTNAME } from './sandbox-paths.mjs';

const repository = fileURLToPath(new URL('../..', import.meta.url));
const escape = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Untracked files that are not ignored are searched too, so a leak fails before it is committed.
// Latin-1 maps every byte to one character, so binary files are searched too.
function searchFiles(matches, extensions) {
  const files = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: repository, encoding: 'utf8' }).split('\0').filter(Boolean);
  return files.filter(file => {
    if (extensions && !extensions.includes(path.extname(file))) return false;
    const absolute = path.join(repository, file);
    try { if (!lstatSync(absolute).isFile()) return false; } catch { return false; }
    return matches(readFileSync(absolute).toString('latin1'));
  });
}

test('repository files contain no home directory paths', () => {
  // Example paths in docs and screenshots live under /Users/Shared. Windows paths such as
  // C:/Users/test in the reference file URI tests are not home directories on this Mac.
  const patterns = [/(?<![A-Za-z]:)\/Users\/(?!Shared\b)[^/\s"'`<>\\]+/];
  const home = os.homedir();
  if (home.split('/').filter(Boolean).length > 1) patterns.push(new RegExp(`${escape(home)}(?![\\w.-])`));
  assert.deepEqual(searchFiles(text => patterns.some(pattern => pattern.test(text))), []);
});

test('recorded server info names no machine', () => {
  // opencode 2.2 reports `hostname` in /api/info; recordings and the demo carry the placeholder instead.
  const names = text => [...text.matchAll(/"hostname"\s*:\s*"([^"]*)"/g)].map(match => match[1]);
  assert.deepEqual(searchFiles(text => names(text).some(name => name !== PUBLISHED_HOSTNAME), ['.json', '.sse']), []);
});
