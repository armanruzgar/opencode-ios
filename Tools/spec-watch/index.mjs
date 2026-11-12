// Spec watch: finds stable 2.x releases newer than the recorded fixtures, compares the newest one's
// /openapi.json with the one served by the newest recorded release, Fixtures/v2/<baseline>/openapi.json
// (oasdiff when installed, plus a structural summary), diffs its generated event union against the app's
// decoder, and opens one GitHub issue per release. Recording a release moves the baseline.
//
//   node Tools/spec-watch/index.mjs                     # report only; the issue text goes to stdout
//   node Tools/spec-watch/index.mjs --issue             # also open the issue (CI: GITHUB_TOKEN, GITHUB_REPOSITORY)
//   node Tools/spec-watch/index.mjs --issue --dry-run   # everything but the GitHub call; the issue is only written to disk
//   node Tools/spec-watch/index.mjs --version 2.0.40 --openapi file.json --types types.ts   # recorded inputs, no server
import { execFile } from 'node:child_process';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs, promisify } from 'node:util';
import { basic, repository, startSandbox } from '../opencode-sandbox/index.mjs';
import { audit } from '../opencode-sandbox/isolation.mjs';
import { stopAll } from '../opencode-sandbox/process.mjs';
import { startMock } from '../mock-llm/server.mjs';
import { appEventTypes, compareVersions, eventDiff, issueBody, issueTitle, newerVersions, parseOasdiff, summarizeOpenAPI } from './diff.mjs';
import { ensureIssue } from './github.mjs';

const { values } = parseArgs({ options: {
  version: { type: 'string' }, openapi: { type: 'string' }, types: { type: 'string' },
  issue: { type: 'boolean' }, 'dry-run': { type: 'boolean' }, 'require-oasdiff': { type: 'boolean' },
} });

const read = file => readFile(path.resolve(file), 'utf8');
const fixtureVersions = async () => (await readdir(path.join(repository, 'Fixtures/v2'))).filter(name => /^2\.\d+\.\d+$/.test(name)).sort(compareVersions);
const baseline = (await fixtureVersions()).at(-1);
if (!baseline) throw new Error('No recorded fixtures under Fixtures/v2');

async function registry() {
  const response = await fetch('https://registry.npmjs.org/@opencode%2fcli', { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`npm registry: ${response.status}`);
  return response.json();
}

/** The served /openapi.json of `version`, from a sandboxed server (Tools/opencode-sandbox). */
async function servedOpenAPI(version) {
  let result;
  await audit(path.join(repository, '.build/opencode-sandbox/audits', `spec-watch-${Date.now()}`), async () => {
    const mock = await startMock();
    try {
      const server = await startSandbox({ version, mockURL: mock.url });
      try {
        const response = await fetch(`${server.baseURL}/openapi.json`, { headers: { authorization: basic(server.password) }, signal: AbortSignal.timeout(30000) });
        if (!response.ok) throw new Error(`/openapi.json: ${response.status}`);
        result = await response.json();
      } finally { await server.stop(); }
    } finally { await stopAll(); await mock.close(); }
  });
  return result;
}

/** The generated client types at the release tag, which carry the event union. */
async function upstreamTypes(version) {
  for (const tag of [`v${version}`, version]) {
    const url = `https://raw.githubusercontent.com/anomalyco/opencode/${tag}/packages/client/src/promise/generated/types.ts`;
    const response = await fetch(url, { signal: AbortSignal.timeout(30000) });
    if (response.ok) return response.text();
  }
  return undefined;
}

async function oasdiff(base, next) {
  const binary = process.env.OASDIFF || 'oasdiff';
  try {
    const { stdout } = await promisify(execFile)(binary, ['changelog', base, next, '--format', 'json'], { maxBuffer: 32 * 1024 * 1024 });
    return parseOasdiff(stdout);
  } catch (error) {
    if (error.code === 'ENOENT' && !values['require-oasdiff']) return undefined;
    throw error;
  }
}

const notes = [];
let version = values.version, newer = version ? [version] : [];
if (version && !/^2\.\d+\.\d+$/.test(version)) throw new Error('--version must be an exact stable 2.x version');
if (!version) {
  newer = newerVersions(await registry(), baseline);
  version = newer.at(-1);
  if (!version) {
    console.log(`No stable 2.x release newer than ${baseline}.`);
    process.exit(0);
  }
}

const output = path.join(repository, '.build/spec-watch', version);
await mkdir(output, { recursive: true });
const next = values.openapi ? JSON.parse(await read(values.openapi)) : await servedOpenAPI(version);
await writeFile(path.join(output, 'openapi.json'), JSON.stringify(next, null, 2) + '\n');
const baseFile = path.join(repository, 'Fixtures/v2', baseline, 'openapi.json');
const base = JSON.parse(await read(baseFile));
const changes = await oasdiff(baseFile, path.join(output, 'openapi.json'));
if (!changes) notes.push('oasdiff is not installed here; install it to list breaking changes.');

const types = values.types ? await read(values.types) : await upstreamTypes(version);
let events;
if (types) {
  try {
    events = eventDiff(types, appEventTypes(await read(path.join(repository, 'Packages/OpencodeKit/Sources/OCModels/ServerEvent.swift'))));
  } catch (error) {
    notes.push(`The event union could not be parsed: ${error.message}`);
  }
}

const title = issueTitle(version);
const body = issueBody({ version, baseline, newer, summary: summarizeOpenAPI(base, next), oasdiff: changes, events, notes });
await writeFile(path.join(output, 'issue.md'), `# ${title}\n\n${body}`);
console.log(`# ${title}\n\n${body}`);

const report = path.relative(repository, path.join(output, 'issue.md'));
if (values.issue && values['dry-run']) {
  console.log(`Dry run: would open or reuse the issue "${title}" in ${process.env.GITHUB_REPOSITORY || 'GITHUB_REPOSITORY'}. Text: ${report}`);
} else if (values.issue) {
  const result = await ensureIssue({ repository: process.env.GITHUB_REPOSITORY, token: process.env.GITHUB_TOKEN, title, body });
  console.log(result.created ? `Opened issue #${result.number}` : `Issue #${result.number} is already open`);
} else {
  console.log(`Issue not opened (pass --issue). Text: ${report}`);
}
