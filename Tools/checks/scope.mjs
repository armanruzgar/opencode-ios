/**
 * Which local checks a change needs, from the paths it touches. The full UI run takes an hour or more, so it runs only
 * for changes that can alter what it tests: the app, its extensions, its UI and snapshot tests, the project, the
 * package tests the project runs on the simulator and the fixtures they read, and the tools the run is built on (a test
 * in scope.test.mjs follows the run's imports). CI runs the package build, the Node suites it covers, and the plugin and
 * relay suites on every push.
 */
export const checks = {
  ui: { command: 'node Tools/ui-smoke/index.mjs', what: 'the full UI run, with the simulator push stage' },
  push: { command: 'node Tools/push-e2e/simulator.mjs', what: 'the simulator push stage on its own' },
  package: { command: 'swift test --package-path Packages/OpencodeKit', what: 'the package tests, fixtures included' },
  contract: { command: 'node Tools/contract/index.mjs', what: 'the live server contract' },
  node: { command: 'node --test Tools/*/*.test.mjs', what: 'the Node suites' },
  plugin: { command: '(cd server/contracts && npm test) && (cd server/plugin && npm test)', what: 'the push contracts and plugin suites' },
  relay: { command: '(cd server/relay && npm test)', what: 'the relay suite' },
};

const tool = name => new RegExp(`^Tools/${name}/`);
const rules = [
  ['ui', /^(App|Extensions|UITests|Config|Tests)\//, /^project\.yml$/,
    /^Packages\/OpencodeKit\/(Sources|Grammars)\//, /^Packages\/OpencodeKit\/Package\.(swift|resolved)$/,
    // The package tests the project runs on the simulator (project.yml): snapshots, the server screens' UIKit tests and
    // the read performance budgets, with the fixtures they read.
    /^Packages\/OpencodeKit\/Tests\/([A-Za-z]+Snapshots|FeatureServersTests)\//, /^Packages\/OpencodeKit\/Tests\/OCSyncTests\/ReadPerformanceTests\.swift$/,
    /^Fixtures\/(source|performance)\//,
    ...['ui-smoke', 'opencode-sandbox', 'mock-llm', 'review-fixture', 'mcp-fixture'].map(tool),
    /^Tools\/design-reference\/seed\.mjs$/, /^Tools\/fixture-recorder\/(scenarios|transport|websocket)\.mjs$/],
  // The push stage runs the relay in process, beside the plugin.
  ['push', tool('push-e2e'), /^server\/(plugin|contracts|relay)\//],
  ['package', /^Packages\//, /^Fixtures\//],
  ['contract', ...['contract', 'opencode-sandbox', 'mock-llm', 'fixture-recorder', 'push-e2e', 'mcp-fixture', 'review-fixture'].map(tool),
    /^Packages\/OpencodeKit\/(Sources\/(OCNetworking|OCModels|OCSync)|Tests\/OCNetworkingLiveTests)\//, /^server\/(plugin|contracts)\//,
    /^Fixtures\/source\/review\//],
  ['node', /^Tools\/.+\.mjs$/],
  ['plugin', /^server\/(plugin|contracts)\//],
  ['relay', /^server\/(relay|contracts)\//],
];

/** The checks the paths need, each with the paths that need it, in the order to run them; the full UI run covers the push stage. */
export function scope(paths) {
  const needed = new Map();
  for (const file of paths) {
    for (const [check, ...patterns] of rules) {
      if (!patterns.some(pattern => pattern.test(file))) continue;
      if (!needed.has(check)) needed.set(check, []);
      needed.get(check).push(file);
    }
  }
  if (needed.has('ui')) needed.delete('push');
  const order = ['node', 'plugin', 'relay', 'package', 'contract', 'push', 'ui'];
  return order.filter(check => needed.has(check)).map(check => ({ check, ...checks[check], paths: needed.get(check) }));
}
