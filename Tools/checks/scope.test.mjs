import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { scope } from './scope.mjs';

const names = paths => scope(paths).map(item => item.check);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

/** The repository files an entry point loads: relative imports, and files it names with `new URL(…, import.meta.url)`. */
function loaded(entry) {
  const reference = /(?:\bfrom\s*|\bimport\s*\(?\s*|\bnew URL\(\s*)['"](\.{1,2}\/[^'"]+)['"]/g;
  const seen = new Set(), queue = [path.join(repository, entry)];
  while (queue.length > 0) {
    const file = queue.pop();
    if (seen.has(file)) continue;
    seen.add(file);
    if (!/\.(mjs|js|ts)$/.test(file)) continue;
    for (const [, specifier] of readFileSync(file, 'utf8').matchAll(reference)) {
      const target = path.resolve(path.dirname(file), specifier);
      const found = [target, target.replace(/\.js$/, '.ts'), `${target}.ts`, `${target}.mjs`, path.join(target, 'index.ts')]
        .find(candidate => existsSync(candidate) && statSync(candidate).isFile());
      if (found) queue.push(found);
    }
  }
  return [...seen].map(file => path.relative(repository, file));
}

test('app code, its tests on the simulator, the fixtures they read and the project need the full UI run', () => {
  for (const path of ['App/OpencodeApp.swift', 'Extensions/Widgets/SessionWidgets.swift', 'UITests/SmokeTestCase.swift', 'project.yml',
    'Config/App.entitlements', 'Packages/OpencodeKit/Package.swift', 'Packages/OpencodeKit/Grammars/bash/include/Grammar.h',
    'Packages/OpencodeKit/Tests/ComposerSnapshots/__Snapshots__/SessionScreenSnapshots/session.png',
    'Packages/OpencodeKit/Tests/FeatureServersTests/__Snapshots__/DesignScreenTests/commandPalette.palette-empty-dark-393-accessibility5.png',
    'Packages/OpencodeKit/Tests/OCSyncTests/ReadPerformanceTests.swift', 'Tests/ComposerEditorTests/EditorBehaviorTests.swift',
    'Fixtures/source/approvals/permission.json', 'Fixtures/performance/baselines.json']) {
    assert.ok(names([path]).includes('ui'), path);
  }
});

test('package sources need the UI run, the package tests and, for the networking layers, the contract', () => {
  assert.deepEqual(names(['Packages/OpencodeKit/Sources/OCSync/ReadStore.swift']), ['package', 'contract', 'ui']);
  assert.deepEqual(names(['Packages/OpencodeKit/Sources/FeatureComposer/ComposerView.swift']), ['package', 'ui']);
});

test('recordings and package unit tests need only the package tests', () => {
  assert.deepEqual(names(['Fixtures/v2/2.2.7/openapi.json', 'Packages/OpencodeKit/Tests/OCSyncTests/ReadStoreTests.swift']), ['package']);
});

test('the UI runner and the sandbox need their Node suites and the UI run; the contract tools need the contract', () => {
  assert.deepEqual(names(['Tools/ui-smoke/index.mjs']), ['node', 'ui']);
  assert.deepEqual(names(['Tools/opencode-sandbox/process.mjs']), ['node', 'contract', 'ui']);
  assert.deepEqual(names(['Tools/contract/admin.mjs']), ['node', 'contract']);
  assert.deepEqual(names(['Tools/fixture-recorder/transport.mjs']), ['node', 'contract', 'ui']);
  assert.deepEqual(names(['Tools/fixture-recorder/index.mjs']), ['node', 'contract']);
  assert.deepEqual(names(['Tools/design-reference/seed.mjs']), ['node', 'ui']);
  assert.deepEqual(names(['Tools/design-reference/review.mjs']), ['node']);
});

test('push tools need the push stage alone, unless the UI run is needed anyway', () => {
  assert.deepEqual(names(['Tools/push-e2e/support.mjs']), ['node', 'contract', 'push']);
  assert.deepEqual(names(['Tools/push-e2e/support.mjs', 'App/OpencodeApp.swift']), ['node', 'contract', 'ui']);
});

test('the server packages need their suites, and the push stage, which runs the plugin and the relay; docs need nothing', () => {
  assert.deepEqual(names(['server/plugin/src/index.ts']), ['plugin', 'contract', 'push']);
  assert.deepEqual(names(['server/relay/src/worker.ts']), ['relay', 'push']);
  assert.deepEqual(names(['README.md', 'research/01-opencode-server-api.md', 'docs/app-store.md', 'Tools/README.md']), []);
});

test('every file the UI run, the push stage and the contract load needs that check', () => {
  for (const [entry, check] of [['Tools/ui-smoke/index.mjs', 'ui'], ['Tools/push-e2e/simulator.mjs', 'push'], ['Tools/contract/index.mjs', 'contract']]) {
    const files = loaded(entry);
    assert.ok(files.length > 10, `${entry} loads ${files.length} files`);
    for (const file of files) {
      const needed = names([file]);
      // The full UI run includes the push stage.
      assert.ok(needed.includes(check) || (check === 'push' && needed.includes('ui')), `${file}, loaded by ${entry}, needs ${check}: ${needed}`);
    }
  }
});

test('each check lists the paths that need it', () => {
  const [item] = scope(['Fixtures/v2/2.2.7/info.json', 'README.md']);
  assert.equal(item.check, 'package');
  assert.deepEqual(item.paths, ['Fixtures/v2/2.2.7/info.json']);
});
