// The server settings contract, against the sandbox: integrations and accounts (connect by key, rename, activate,
// remove; the secret-returning credential list is never read), MCP servers registered at runtime from the fixture,
// saved permissions, catalogs and plugin checks, project settings, worktrees with the dirty refusal, configuration
// and the shell patch, booted locations, eviction and reload. OAuth needs a real provider and is unit-tested instead.
import assert from 'node:assert/strict';
import path from 'node:path';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { Capture, until } from '../fixture-recorder/transport.mjs';
import { run } from '../opencode-sandbox/process.mjs';

const at = directory => 'location%5Bdirectory%5D=' + encodeURIComponent(directory);

export async function adminContract(sandbox) {
  const c = new Capture(sandbox);
  await c.openSSE();
  const result = {};
  try {
    const directory = path.join(sandbox.root, 'admin-contract');
    await mkdir(directory);
    await writeFile(path.join(directory, 'README.md'), 'Admin contract fixture\n');
    const git = args => run('/usr/bin/git', args, { env: sandbox.env, cwd: directory });
    await git(['init', '--quiet', '--initial-branch=main']); await git(['add', 'README.md']);
    await git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'Fixture']);
    const here = at(directory);
    const projectID = (await c.request('GET', '/api/location?' + here)).project.id;

    // Integrations and accounts. From 2.2.7 a location that just booted lists no integrations yet and publishes
    // integration.updated once they load, a moment later; the app reloads the list on that event, and this reads it
    // again until the mock provider is in it.
    let integrations, late = false;
    await until(async () => {
      integrations = await c.request('GET', '/api/integration?' + here);
      if (integrations.data.some(item => item.id === 'mock')) return true;
      late = true;
      await new Promise(resolve => setTimeout(resolve, 250));
    }, 'The mock provider is listed');
    // A list that came late must say so with the event the app reloads on.
    if (late) await c.event('integration.updated');
    assert.equal(integrations.location.directory, directory);
    const mock = integrations.data.find(item => item.id === 'mock');
    assert.ok(mock.methods.some(method => method.type === 'key'), 'The mock provider takes a key');
    for (const label of ['Contract first', 'Contract second']) {
      await c.request('POST', `/api/integration/mock/connect/key?${here}`, { key: 'fake-contract-key-not-a-secret', label }, { status: 204 });
    }
    let accounts = (await c.request('GET', '/api/integration/mock?' + here)).data.connections.filter(item => item.type === 'credential');
    assert.deepEqual(accounts.map(item => item.label).slice(0, 2), ['Contract second', 'Contract first'], 'The newest account is first, the active one');
    assert.ok(accounts.every(item => item.id.startsWith('cred_') && !('key' in item) && !('value' in item)), 'Connections carry no secret');
    const first = accounts.find(item => item.label === 'Contract first');
    await c.request('PATCH', `/api/credential/${first.id}`, { label: 'Contract renamed' }, { status: 204 });
    await c.request('POST', `/api/credential/${first.id}/activate`, undefined, { status: 204 });
    await c.event('credential.switched', event => event.data.credentialID === first.id);
    accounts = (await c.request('GET', '/api/integration/mock?' + here)).data.connections.filter(item => item.type === 'credential');
    assert.equal(accounts[0].label, 'Contract renamed', 'Activating moves the account first');
    for (const account of accounts) await c.request('DELETE', `/api/credential/${account.id}`, undefined, { status: 204 });
    assert.equal((await c.request('GET', '/api/integration/mock?' + here)).data.connections.filter(item => item.type === 'credential').length, 0);
    await c.request('GET', `/api/integration/mock/connect/oauth/con_missing?${here}`, undefined, { status: 404 });
    result.integrations = integrations.data.length;

    // MCP servers at runtime, in this location only.
    const fixture = path.join(sandbox.root, 'mcp-fixture.mjs');
    await copyFile(fileURLToPath(new URL('../mcp-fixture/server.mjs', import.meta.url)), fixture);
    await c.request('PUT', `/api/experimental/mcp/fixture?${here}`, { config: { type: 'local', command: ['node', fixture] } });
    await c.request('PUT', `/api/experimental/mcp/broken?${here}`, { config: { type: 'local', command: ['/nonexistent/broken-mcp'] } });
    const status = async name => (await c.request('GET', '/api/mcp?' + here)).data.find(server => server.name === name)?.status;
    await until(async () => (await status('fixture'))?.status === 'connected' && (await status('broken'))?.status === 'failed', 'MCP servers settle');
    assert.ok((await status('broken')).error.length > 0, 'A failed server carries its error');
    const resources = (await c.request('GET', '/api/mcp/resource?' + here)).data.resources;
    assert.ok(resources.some(item => item.uri === 'fixture://notes' && item.server === 'fixture'), 'Fixture resources can be mentioned');
    await c.request('POST', `/api/experimental/mcp/fixture/disconnect?${here}`, undefined, { status: 204 });
    assert.equal((await status('fixture')).status, 'disabled');
    await c.request('POST', `/api/experimental/mcp/fixture/connect?${here}`, undefined, { status: 204 });
    await until(async () => (await status('fixture'))?.status === 'connected', 'MCP reconnects');
    assert.equal((await c.request('GET', '/api/mcp?' + at(sandbox.project))).data.some(server => server.name === 'fixture'), false, 'Runtime servers stay in their location');

    // Saved permissions, from a request answered "always".
    const session = (await c.request('POST', '/api/session', { title: 'Admin contract', location: { directory },
      permissions: [{ action: 'shell', resource: '*', effect: 'ask' }] })).data;
    const asked = (await c.request('POST', `/api/session/${session.id}/permission`, { action: 'shell', resources: ['printf contract'], save: ['printf *'] })).data;
    assert.equal(asked.effect, 'ask');
    await c.request('POST', `/api/session/${session.id}/permission/${asked.id}/reply`, { decision: 'always' }, { status: 204 });
    const saved = (await c.request('GET', '/api/permission/saved?projectID=' + encodeURIComponent(projectID))).data;
    const rule = saved.find(item => item.action === 'shell' && item.resource === 'printf *');
    assert.ok(rule?.id.startsWith('psv_') && rule.projectID === projectID && rule.time.created > 0, 'Allow always saved the pattern');
    await c.request('DELETE', `/api/permission/saved/${rule.id}`, undefined, { status: 204 });
    // Deleting again succeeds too (v2.2.1); the app also treats a 404 as already deleted.
    await c.request('DELETE', `/api/permission/saved/${rule.id}`, undefined, { status: 204 });
    assert.ok(!(await c.request('GET', '/api/permission/saved?projectID=' + encodeURIComponent(projectID))).data.some(item => item.id === rule.id));
    await c.request('DELETE', `/api/session/${session.id}`, undefined, { status: 204 });

    // Catalogs and plugins.
    for (const kind of ['agent', 'command', 'skill', 'reference', 'plugin']) {
      const list = await c.request('GET', `/api/${kind}?${here}`);
      assert.ok(Array.isArray(list.data), `${kind} answers a located list`);
    }
    const checked = await c.request('POST', '/api/plugin/check?' + here, {});
    assert.ok(Array.isArray(checked.data) && checked.data.every(item => item.source && item.state), 'A plugin check answers the list');

    // Project settings.
    const project = await c.request('PATCH', `/api/project/${projectID}`, { name: 'Admin contract', icon: { color: 'blue' }, commands: { start: 'true' } });
    assert.ok(project.name === 'Admin contract' && project.icon.color === 'blue' && project.commands.start === 'true');
    await c.event('project.updated', event => event.data.id === projectID);
    assert.ok(Array.isArray(await c.request('GET', '/api/project?archived=true')), 'Archived projects answer a bare array');

    // Worktrees: the dirty refusal, then force.
    const created = await c.request('POST', '/api/worktree', { projectID, name: 'contract-wt' });
    const listed = await c.request('GET', '/api/worktree?projectID=' + encodeURIComponent(projectID));
    assert.ok(listed.some(item => item.directory === created.directory && item.strategy === 'git'), 'The new worktree is listed with its strategy');
    assert.ok(listed.some(item => item.directory === directory && item.strategy === undefined), 'The list includes the project checkout');
    await writeFile(path.join(created.directory, 'dirty.txt'), 'uncommitted\n');
    await until(async () => (await c.request('GET', '/api/vcs/status?' + at(created.directory))).data.some(item => item.file === 'dirty.txt'), 'Status lists the change');
    const refused = await c.request('DELETE', '/api/worktree', { projectID, directory: created.directory, force: false }, { status: 400 });
    assert.ok(refused._tag === 'WorktreeError' && refused.data.forceRequired === true, 'A dirty worktree needs force');
    await c.request('DELETE', '/api/worktree', { projectID, directory: created.directory, force: true }, { status: 204 });
    await c.request('POST', '/api/worktree/refresh', { projectID }, { status: 204 });
    assert.ok(!(await c.request('GET', '/api/worktree?projectID=' + encodeURIComponent(projectID))).some(item => item.directory === created.directory));

    // Configuration and the shell.
    const config = await c.request('GET', '/api/config?' + here);
    assert.ok(Array.isArray(config) && config.some(entry => entry.type === 'document'), 'Configuration answers a bare array of documents');
    assert.ok(JSON.stringify(config).includes('fixture-not-a-secret'), 'The raw documents hold the secret the app redacts');
    const shells = await c.request('GET', '/api/config/shell');
    assert.ok(shells.some(shell => shell.path === '/bin/bash'));
    await c.request('PATCH', '/api/experimental/config', { shell: '/bin/bash' }, { status: 204 });

    // Booted locations, eviction and reload.
    const booted = await c.request('GET', '/api/debug/location');
    assert.ok(booted.some(item => item.directory === directory), 'The fixture location is booted');
    await c.request('DELETE', '/api/debug/location?' + here, undefined, { status: 204 });
    assert.ok(!(await c.request('GET', '/api/debug/location')).some(item => item.directory === directory), 'Evicted');
    // Right after an eviction the reload can answer 503 ServiceUnavailableError while that location stops.
    let reload;
    await until(async () => {
      reload = await fetch(sandbox.baseURL + '/api/location/reload', { method: 'POST', headers: { authorization: 'Basic ' + Buffer.from('opencode:' + sandbox.password).toString('base64') } });
      if (reload.status === 503) result.reload503 = (result.reload503 ?? 0) + 1;
      return reload.status !== 503;
    }, 'Reload accepted');
    assert.equal(reload.status, 204);
    await c.event('location.shutdown', () => true);
    result.locations = booted.length;
    return result;
  } finally { await c.closeSSE(); }
}
