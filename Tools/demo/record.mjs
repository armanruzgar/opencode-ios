// Records the in-app demo from a sandboxed opencode server and the mock model:
// node Tools/demo/record.mjs [--version 2.0.32]
//
// It writes a small project, runs scripted sessions through the same sandbox and capture the fixture
// recorder uses, and saves what the app reads (snapshots, events, files, the working-tree diff and the
// catalogs) to Packages/OpencodeKit/Sources/OCSync/Resources/Demo/demo.json. The app replays that file with
// ScenarioTransport; the demo never contacts a server.
import { execFile } from 'node:child_process';
import { mkdir, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs, promisify } from 'node:util';
import { basic, repository, resolveVersion, startSandbox } from '../opencode-sandbox/index.mjs';
import { audit } from '../opencode-sandbox/isolation.mjs';
import { stopAll } from '../opencode-sandbox/process.mjs';
import { startMock } from '../mock-llm/server.mjs';
import { relocate } from '../fixture-recorder/sandbox-paths.mjs';
import { selectMock } from '../fixture-recorder/scenarios.mjs';
import { Capture, until } from '../fixture-recorder/transport.mjs';
import { DEMO_DIRECTORY, PROJECT_FILES, SESSIONS, WORKING_CHANGES } from './script.mjs';

const { values } = parseArgs({ options: { version: { type: 'string' } } });
const fixtures = (await readdir(path.join(repository, 'Fixtures/v2'))).filter(name => /^2\.\d+\.\d+$/.test(name)).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
const version = await resolveVersion(values.version ?? fixtures.at(-1));
const output = path.join(repository, 'Packages/OpencodeKit/Sources/OCSync/Resources/Demo/demo.json');
const auditDir = path.join(repository, '.build/opencode-sandbox/audits', `demo-${Date.now()}`);

async function git(sandbox, ...args) {
  await promisify(execFile)('/usr/bin/git', ['-c', 'user.name=Demo', '-c', 'user.email=demo@example.invalid', '-c', 'commit.gpgsign=false', ...args],
    { cwd: sandbox.project, env: sandbox.env });
}

async function writeProject(sandbox, files) {
  for (const [relative, text] of Object.entries(files)) {
    const file = path.join(sandbox.project, relative);
    await mkdir(path.dirname(file), { recursive: true });
    await writeFile(file, text);
  }
}

/** Everything the app reads for one session at one moment. */
async function snapshot(c, id) {
  const session = (await c.request('GET', `/api/session/${id}`)).data;
  const messages = (await c.request('GET', `/api/session/${id}/message?limit=200&order=asc`)).data;
  const inbox = (await c.request('GET', `/api/session/${id}/inbox`)).data;
  const permissions = (await c.request('GET', `/api/session/${id}/permission`)).data;
  const forms = (await c.request('GET', `/api/session/${id}/form`)).data;
  return { eventOffset: c.events.length, session, messages, inbox, permissions, forms };
}

const finished = (c, id, count) => until(() => c.events.filter(event => event.type === 'session.execution.succeeded' && event.data.sessionID === id).length >= count, `${id} turn ${count}`, 60000);
const idle = (c, id) => until(() => c.events.some(event => event.type === 'session.execution.succeeded' && event.data.sessionID === id), `${id} finished`, 60000);

async function runSession(c, mock, spec) {
  await mock.select(spec.script);
  const created = (await c.request('POST', '/api/session', { title: spec.title, location: { directory: c.sandbox.project } })).data;
  const id = created.id;
  const initial = await snapshot(c, id);
  // Earlier turns of a long session, each answered before the next is sent.
  for (const [index, turn] of (spec.history ?? []).entries()) {
    await c.request('POST', `/api/session/${id}/prompt`, { text: turn.prompt });
    await finished(c, id, index + 1);
  }
  await c.request('POST', `/api/session/${id}/prompt`, { text: spec.prompt });
  const record = { id, kind: spec.kind, initial };
  if (spec.kind === 'permission') {
    const asked = await c.event('permission.asked', event => event.data.sessionID === id);
    record.pending = await snapshot(c, id);
    record.request = (await c.request('GET', `/api/session/${id}/permission/${asked.data.id}`)).data;
    await c.request('POST', `/api/session/${id}/permission/${asked.data.id}/reply`, { decision: 'once' });
  }
  if (spec.kind === 'form') {
    const created = await c.event('form.created', event => (event.data.form?.sessionID ?? event.data.sessionID) === id);
    const form = created.data.form ?? created.data;
    record.pending = await snapshot(c, id);
    record.request = (await c.request('GET', `/api/session/${id}/form/${form.id}`)).data;
    await c.request('POST', `/api/session/${id}/form/${form.id}/reply`, { answer: spec.answer });
  }
  await c.request('POST', `/api/experimental/session/${id}/wait`);
  await finished(c, id, (spec.history?.length ?? 0) + 1);
  record.final = await snapshot(c, id);
  record.diff = (await c.request('GET', `/api/session/${id}/diff`)).data;
  const children = (await c.request('GET', `/api/session?parentID=${id}&limit=50`)).data;
  record.children = [];
  for (const child of children) record.children.push({ id: child.id, final: await snapshot(c, child.id) });
  return record;
}

const location = query => `location[directory]=${encodeURIComponent(query)}`;

await audit(auditDir, async () => {
  const mock = await startMock();
  mock.select = async script => {
    await until(() => mock.state().active === 0, 'mock idle');
    const response = await fetch(mock.url + '/admin/scenario', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: 'demo', script }) });
    if (!response.ok) throw new Error(`mock: ${await response.text()}`);
  };
  let sandbox;
  try {
    console.log(`Recording the demo with opencode ${version}; audit ${auditDir}`);
    sandbox = await startSandbox({ version, mockURL: mock.url, configure: config => {
      config.providers.mock.name = 'Demo';
      config.providers.mock.models['mock-1'].name = 'Demo model';
    } });
    await writeProject(sandbox, PROJECT_FILES);
    await promisify(execFile)('/bin/rm', ['-f', path.join(sandbox.project, 'sample.txt')]);
    await git(sandbox, 'add', '-A');
    await git(sandbox, 'commit', '--quiet', '-m', 'Initial commit');
    await writeProject(sandbox, WORKING_CHANGES);

    const c = new Capture(sandbox);
    await c.openSSE();
    const sessions = [];
    for (const spec of SESSIONS) {
      const record = await runSession(c, mock, spec);
      const ids = [record.id, ...record.children.map(child => child.id)];
      const events = c.events.map((event, offset) => ({ offset, event })).filter(({ event }) => ids.some(id => JSON.stringify(event).includes(id)));
      sessions.push({ ...record, events });
      console.log(`PASS ${spec.kind} ${spec.title}`);
    }
    const dir = location(sandbox.project);
    const get = (route, query = dir) => c.request('GET', `${route}${route.includes('?') ? '&' : '?'}${query}`);
    const routes = {
      'GET /api/info': await c.request('GET', '/api/info'),
      'GET /api/project': await c.request('GET', '/api/project'),
      'GET /api/location': await get('/api/location'),
      'GET /api/agent': await get('/api/agent'),
      'GET /api/model': await get('/api/model'),
      'GET /api/provider': await get('/api/provider'),
      'GET /api/model/default': await get('/api/model/default'),
      'GET /api/mcp': await get('/api/mcp'),
      'GET /api/command': await get('/api/command'),
      'GET /api/skill': await get('/api/skill'),
      'GET /api/reference': await get('/api/reference'),
      'GET /api/vcs': await get('/api/vcs'),
      'GET /api/vcs/diff?mode=working': await get('/api/vcs/diff?mode=working'),
      'GET /api/vcs/diff?mode=branch': await get('/api/vcs/diff?mode=branch').catch(() => undefined),
      'GET /api/vcs/branch': await get('/api/vcs/branch').catch(() => undefined),
    };
    const folders = ['', ...new Set(Object.keys({ ...PROJECT_FILES, ...WORKING_CHANGES }).map(file => path.dirname(file)).filter(folder => folder !== '.'))];
    for (const folder of folders) routes[`GET /api/fs/list?path=${folder}`] = await get('/api/fs/list', `path=${encodeURIComponent(folder)}&${dir}`);
    const files = {};
    for (const file of Object.keys({ ...PROJECT_FILES, ...WORKING_CHANGES })) {
      const response = await fetch(`${sandbox.baseURL}/api/fs/read/${file.split('/').map(encodeURIComponent).join('/')}?${dir}`, { headers: { authorization: basic(sandbox.password) } });
      files[file] = { contentType: response.headers.get('content-type'), text: await response.text() };
    }
    await c.closeSSE();
    const demo = { version: 1, server: version, directory: DEMO_DIRECTORY, routes, files, sessions };
    let text = relocate(JSON.stringify(demo), [sandbox.root], [routes['GET /api/info']?.hostname].filter(Boolean)).toString();
    text = text.replaceAll('/sandbox/project', DEMO_DIRECTORY);
    // The rest of the sandbox layout reads as an ordinary machine's.
    for (const [from, to] of [['/sandbox/home', '/Users/Shared'], ['/sandbox/data', '/Users/Shared/.local/share'], ['/sandbox/config', '/Users/Shared/.config'], ['/sandbox/cache', '/Users/Shared/.cache'], ['/sandbox/state', '/Users/Shared/.local/state'], ['/sandbox/tmp', '/tmp']]) {
      text = text.replaceAll(from, to);
    }
    const left = [...text.matchAll(/.{0,60}\/sandbox.{0,40}/g)].map(match => match[0]);
    if (left.length) throw new Error(`A sandbox path is left in the demo:\n${[...new Set(left)].slice(0, 8).join('\n')}`);
    if (/\/Users\/(?!Shared)/.test(text)) throw new Error('A home path is in the demo');
    await mkdir(path.dirname(output), { recursive: true });
    await writeFile(output, text);
    console.log(`Wrote ${path.relative(repository, output)} (${Math.round(text.length / 1024)} KB, ${sessions.length} sessions)`);
  } finally {
    await sandbox?.stop();
    await stopAll();
    await mock.close();
  }
});
