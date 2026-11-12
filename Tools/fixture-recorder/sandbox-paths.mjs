import { realpathSync } from 'node:fs';
import os from 'node:os';

// Published fixtures must not reveal where the checkout lives, so every sandbox
// run root is rewritten to this fixed path before a fixture is written.
export const PUBLISHED_ROOT = '/sandbox';
// Nor which machine recorded them: opencode 2.2 reports its host name in /api/info.
export const PUBLISHED_HOSTNAME = 'sandbox.local';

const pathCharacter = /[\w.-]/;
const encodings = [text => text, text => text.replaceAll('/', '\\/'), encodeURI, encodeURIComponent];

// Plain, JSON-escaped and URL-encoded spellings of each root, also with symlinks resolved.
// Longest first, so /private/var/root is replaced before /var/root can match inside it.
function spellings(roots) {
  const paths = new Set();
  for (const root of roots) {
    paths.add(root);
    try { paths.add(realpathSync(root)); } catch {}
  }
  const pairs = new Map();
  for (const root of paths) for (const encode of encodings) pairs.set(encode(root), encode(PUBLISHED_ROOT));
  return [...pairs].map(([from, to]) => [Buffer.from(from), Buffer.from(to)]).sort((a, b) => b[0].length - a[0].length);
}

// Replaces whole names only, so a longer name that starts with `from` stays as it is; with `leading`, so does
// one that ends with it.
function replace(bytes, from, to, leading = false) {
  const parts = [];
  let start = 0, index = bytes.indexOf(from);
  while (index !== -1) {
    const end = index + from.length;
    const whole = !(end < bytes.length && pathCharacter.test(String.fromCharCode(bytes[end])))
      && !(leading && index > 0 && pathCharacter.test(String.fromCharCode(bytes[index - 1])));
    if (whole) { parts.push(bytes.subarray(start, index), to); start = end; }
    index = bytes.indexOf(from, whole ? end : index + 1);
  }
  if (!parts.length) return bytes;
  parts.push(bytes.subarray(start));
  return Buffer.concat(parts);
}

// Host names to rewrite, longest first: the ones the server reported, and this machine's when it has a dot. A bare
// name such as `build` can also be an ordinary word, or turn up inside base64. Never `localhost`.
export function hostNames(hosts, machine = os.hostname()) {
  const names = [...hosts, ...(machine.includes('.') ? [machine] : [])];
  return [...new Set(names)].filter(host => host && host !== 'localhost').sort((a, b) => b.length - a.length);
}

// Returns the bytes with every sandbox root and host name replaced and every other byte unchanged.
export function relocate(data, roots, hosts = []) {
  let bytes = Buffer.from(data);
  for (const [from, to] of spellings(roots)) bytes = replace(bytes, from, to);
  for (const host of hostNames(hosts)) bytes = replace(bytes, Buffer.from(host), Buffer.from(PUBLISHED_HOSTNAME), true);
  return bytes;
}
