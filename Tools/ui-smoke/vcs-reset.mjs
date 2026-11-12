import { basic } from '../opencode-sandbox/index.mjs';

/** The VCS provider the server reports for a directory, or undefined when it reports none. */
export async function vcsProvider(server, directory) {
  const query = new URLSearchParams({ 'location[directory]': directory });
  const response = await fetch(`${server.baseURL}/api/vcs?${query}`, { headers: { authorization: basic(server.password) }, signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error(`GET /api/vcs answered ${response.status}`);
  const { data } = await response.json() ?? {};
  // Without its `data` object the answer says nothing about the repository, so it must not pass for "none".
  if (typeof data !== 'object' || data === null || Array.isArray(data)) throw new Error('GET /api/vcs answered without a data object');
  return data.provider || undefined;
}

/**
 * Evicts the server's booted location for a directory. A booted location keeps the repository state it detected after
 * the directory's `.git` is removed (2.0.32 and 2.2.6 both do); the next request boots it again and detects anew.
 */
export async function evictLocation(server, directory) {
  const query = new URLSearchParams({ 'location[directory]': directory });
  const response = await fetch(`${server.baseURL}/api/debug/location?${query}`, { method: 'DELETE', headers: { authorization: basic(server.password) }, signal: AbortSignal.timeout(5000) });
  if (response.status !== 204) throw new Error(`DELETE /api/debug/location answered ${response.status}`);
}

/**
 * Waits until the server stops reporting a repository for a directory whose `.git` was removed, in case it kept the
 * repository state it saw; throws when it still reports one at the deadline.
 */
export async function waitForNoProvider(provider, { timeout = 10_000, interval = 200, now = Date.now, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
  const deadline = now() + timeout;
  for (;;) {
    const current = await provider();
    if (!current) return;
    if (now() >= deadline) throw new Error(`The server still reports a ${current} repository for the no-Git fixture after its reset`);
    await sleep(interval);
  }
}
