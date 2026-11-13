import assert from 'node:assert/strict';
import { seedReviewRepository, configureReview } from '../review-fixture/index.mjs';
import { assertEditorCoverage } from './editor-coverage.mjs';
import { changedSnapshots, mergeAttempts, passes, retriedLines, retryable, snapshotTree, testCases } from './attempts.mjs';
import { startFaultProxy } from './fault-proxy.mjs';
import { configureComposer } from './composer-config.mjs';
import { seedReadScreens } from './read-screens.mjs';
import { seedAdmin } from './admin-fixture.mjs';
import { evictLocation, vcsProvider, waitForNoProvider } from './vcs-reset.mjs';
import { bootSimulator, restartSimulator, settleLoad, simctlJSON, withDeadline } from './simulators.mjs';
import { runUntilQuiet } from './stall.mjs';
import path from 'node:path';
import { mkdir, writeFile, readFile, copyFile, rm, readdir, stat, rename } from 'node:fs/promises';
import { parseArgs, promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { repository, resolveVersion, startSandbox, V1_VERSION } from '../opencode-sandbox/index.mjs';
import { audit } from '../opencode-sandbox/isolation.mjs';
import { launch, stopAll, run } from '../opencode-sandbox/process.mjs';
import { startMock } from '../mock-llm/server.mjs';

const { values } = parseArgs({ options: { version: { type: 'string' }, 'skip-snapshots': { type: 'boolean' }, 'review-only': { type: 'boolean' }, 'review-test': { type: 'string' }, 'ipad-only': { type: 'boolean' }, 'read-flows-only': { type: 'boolean' }, 'composer-only': { type: 'boolean' }, 'worktree-only': { type: 'boolean' }, 'composer-test': { type: 'string' }, 'workspace-only': { type: 'boolean' }, 'workspace-test': { type: 'string' }, 'system-only': { type: 'boolean' }, 'system-test': { type: 'string' }, 'admin-only': { type: 'boolean' }, 'admin-test': { type: 'string' }, 'terminal-only': { type: 'boolean' }, 'terminal-test': { type: 'string' }, 'session-only': { type: 'boolean' }, 'a11y-only': { type: 'boolean' } } });
const workspaceTests = ['testMenuNavigationAndSwitcher', 'testMenuComposerCommands', 'testReviewNextApproval', 'testTwoWindows', 'testDragFileIntoComposer'];
const workspaceTest = values['workspace-test'];
if (workspaceTest) assert.ok(workspaceTests.includes(workspaceTest), 'Unknown workspace test');
const workspaceOnly = values['workspace-only'] || Boolean(workspaceTest);
// The iPad flow's workspace captures: the menu bar, the switcher, two windows and drag and drop.
const workspaceScreens = ['ipad-workspace-review-open', 'ipad-palette', 'ipad-workspace-composer-commands', 'ipad-workspace-next-approval', 'ipad-windows-second', 'ipad-workspace-drop-mention'];
const reviewTest = values['review-test'];
if (reviewTest) assert.ok(['testReviewAndFiles', 'testLargeDiffScroll', 'testReviewNavigation'].includes(reviewTest), 'Unknown review test');
const reviewOnly = values['review-only'] || Boolean(reviewTest);
const reviewScreens = (ipad = false) => [
  ...(!reviewTest || reviewTest === 'testReviewAndFiles' ? ['review-changes', 'review-comment', 'review-files', ...(ipad ? [] : ['review-created-git'])] : []),
  ...(!reviewTest || reviewTest === 'testReviewNavigation' ? ['review-turn-navigation', 'review-reviewed', 'review-file-tree', 'review-file-link'] : []),
  ...(!reviewTest || reviewTest === 'testLargeDiffScroll' ? (ipad ? ['review-large-split-nowrap', 'review-large-split'] : ['review-large-unified']) : []),
].map(name => (ipad ? 'ipad-' : '') + name);
const composerTest = values['composer-test'] ?? (values['worktree-only'] ? 'testInterruptAndNewWorktree' : undefined);
if (composerTest) assert.ok(['testComposerDurabilityAndSends', 'testComposerQueueAndSessionActions', 'testInterruptAndNewWorktree'].includes(composerTest), 'Unknown composer test');
const composerOnly = values['composer-only'] || Boolean(composerTest);
const systemTests = ['testShortcutsRunTheIntents', 'testSpotlightOpensASession', 'testWidgetOnTheHomeScreen'];
const systemTest = values['system-test'];
if (systemTest) assert.ok(systemTests.includes(systemTest), 'Unknown system test');
const systemOnly = values['system-only'] || Boolean(systemTest);
const adminTests = ['testProvidersAndMCP', 'testSavedPermissionAndConfiguration', 'testWorktreeRemovalAsksFirst', 'testSwitcherOpensSettings'];
const adminTest = values['admin-test'];
if (adminTest) assert.ok(adminTests.includes(adminTest), 'Unknown admin test');
const adminOnly = values['admin-only'] || Boolean(adminTest);
// The iPhone system flow's captures: Shortcuts, Spotlight, the widget and Settings.
const systemScreens = ['system-shortcuts-send', 'system-shortcuts-status', 'system-spotlight', 'system-widget', 'system-settings'];
const terminalTests = ['testTerminalPrograms', 'testResumeLosesNoOutput', 'testRunACommandAndStopIt'];
const terminalTest = values['terminal-test'];
if (terminalTest) assert.ok(terminalTests.includes(terminalTest), 'Unknown terminal test');
const terminalOnly = values['terminal-only'] || Boolean(terminalTest);
// The terminal flow's captures on each device: the shell, vim, top, the resumed run and Run a command.
const terminalScreens = (ipad = false) => [
  ...(!terminalTest || terminalTest === 'testTerminalPrograms' ? ['terminal-shell', 'terminal-vim', 'terminal-top'] : []),
  ...(!terminalTest || terminalTest === 'testResumeLosesNoOutput' ? ['terminal-resumed'] : []),
  ...(!terminalTest || terminalTest === 'testRunACommandAndStopIt' ? ['terminal-run'] : []),
].map(name => (ipad ? 'ipad-' : '') + name);
// A failed UI test runs again, up to twice, on the same build: a test passes when any attempt passes, so a regression
// still fails while a burst of load on the shared host no longer restarts the whole run. Unit and snapshot tests run
// once: a snapshot test records a missing reference image and would pass on the next attempt.
const attemptsAllowed = 3;
// A UI test that hangs ends at its `executionTimeAllowance` (600 seconds when it sets none) and fails like any other,
// so it can run again; without this XCTest waits for it forever.
const timeouts = ['-test-timeouts-enabled', 'YES'];
const sessionOnly = values['session-only'];
// The accessibility audit alone, on the iPhone and then the iPad.
const a11yOnly = values['a11y-only'];
const full = !reviewOnly && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly && !values['ipad-only'] && !values['read-flows-only'] && !values['skip-snapshots'];
const version = await resolveVersion(values.version);
const runID = `ui-${Date.now()}`;
const output = path.join(repository, '.build/ui-smoke', runID);
await mkdir(output, { recursive: true });
const testResults = async (result, report = 'tests') => JSON.parse((await promisify(execFile)('/usr/bin/xcrun', ['xcresulttool', 'get', 'test-results', report, '--path', result],
  { maxBuffer: 64 * 1024 * 1024 })).stdout);
/** The failed tests of a failed run, or an error when the failure is not theirs alone. */
async function failedTests(stage, result, failure) {
  const plan = retryable(await testResults(result, 'summary').catch(() => ({})), testCases(await testResults(result).catch(() => ({}))));
  if (plan.problem) throw new Error(`${stage}: not retried, ${plan.problem}`, { cause: failure });
  return plan.failing;
}
// SwiftTerm applies a build-tool plugin; xcodebuild refuses a package plugin nobody validated unless told not to check
// (trusting it in Xcode instead would change the host's settings).
const pluginFlags = ['-skipPackagePluginValidation'];
let xctestrun;
/** Builds the app and every test bundle once; each stage then runs `test-without-building` against this build. */
async function buildForTesting() {
  try {
    await writeFile(path.join(output, 'build.log'), await run('/usr/bin/xcodebuild', ['-project', 'Opencode.xcodeproj', '-scheme', 'Opencode',
      '-destination', destination, '-derivedDataPath', '.build/DerivedData', ...pluginFlags, 'build-for-testing'], { cwd: repository }));
  } catch (error) {
    await writeFile(path.join(output, 'build.log'), error.message);
    throw error;
  }
  const products = path.join(repository, '.build/DerivedData/Build/Products');
  const runs = await Promise.all((await readdir(products)).filter(name => /^Opencode_iphonesimulator.*\.xctestrun$/.test(name))
    .map(async name => ({ file: path.join(products, name), modified: (await stat(path.join(products, name))).mtimeMs })));
  assert.ok(runs.length > 0, 'build-for-testing wrote no .xctestrun');
  return runs.sort((a, b) => b.modified - a.modified)[0].file;
}
// The longest a working xcodebuild stays silent: a UI test prints each of its steps, and a hung one fails at its time
// allowance (900 seconds at most); a longer silence is a simulator that stopped answering (see stall.mjs).
const quietLimit = 25 * 60_000;
/**
 * Runs the built tests into a result bundle and writes its log. A run that adds or changes a reference image fails;
 * `guard: false` leaves that check to a stage running beside this one, so a recording is reported once. A run that
 * prints nothing for `quietLimit` is stopped and throws an error marked `stalled`.
 */
async function xcodebuildTest(result, log, args, env, { guard = true } = {}) {
  const before = guard ? await snapshotTree(repository) : undefined;
  let failure;
  try {
    await writeFile(path.join(output, log), await runUntilQuiet(launch, '/usr/bin/xcodebuild', ['-xctestrun', xctestrun, '-resultBundlePath', result,
      '-parallel-testing-enabled', 'NO', ...args, '-collect-test-diagnostics', 'never', 'test-without-building'], { cwd: repository, env }, { quiet: quietLimit }));
  } catch (error) {
    failure = error;
    await writeFile(path.join(output, log), error.message);
  }
  const recorded = guard ? changedSnapshots(before, await snapshotTree(repository)) : [];
  for (const file of recorded) console.log(`RECORDED ${file}`);
  // Never retried: a second attempt would compare against the image the first one wrote.
  if (recorded.length > 0) throw Object.assign(new Error('The run added or changed reference images: ' + recorded.join(', '), { cause: failure }), { recorded });
  if (failure) throw failure;
}
/** Each stage's start, end and minutes, in `timings.json`. */
const timings = {};
async function timed(stage, work) {
  const started = Date.now();
  try { return await work(); } finally {
    timings[stage] = { started: new Date(started).toISOString(), ended: new Date().toISOString(), minutes: Math.round((Date.now() - started) / 600) / 100 };
    await writeFile(path.join(output, 'timings.json'), JSON.stringify(timings, null, 2) + '\n');
  }
}
const xcrun = args => run('/usr/bin/xcrun', args);
const destinationOf = simulator => `platform=iOS Simulator,id=${simulator}`;
/** Waits out a burst of load on the host before work that measures time, and says so when it waited. */
async function settle(before) {
  const load = await settleLoad();
  if (load.minutes > 0) console.log(`LOAD ${load.before} before ${before}: waited ${load.minutes} min, now ${load.after}${load.settled ? '' : `, still not under ${load.limit}`}`);
}
// Right after a boot the simulator is still clearing away the containers of the apps the last run installed; a test
// runner launched then can fail with "Failed to create a bundle instance" for a path under containermanagerd/Dead,
// which ends the stage, so a freshly booted simulator gets a minute to settle.
const settleAfterBoot = () => new Promise(resolve => setTimeout(resolve, 60_000));
/**
 * Before tests run again. A timing-sensitive test that failed in a burst of load fails again inside it, so the load
 * settles first. The iPad boots afresh, since one that stopped finishing rotations fails every iPad test in its setup;
 * the iPhones keep running, since right after a boot Shortcuts does not list the app's App Shortcuts and the widget
 * does not show the app's snapshot, which fails the system tests. `restart` boots either afresh, as after a stall.
 * Then the fixtures reset.
 */
const prepareRetry = (stage, simulator, beforeRetry, before, { restart = simulator === ipad?.udid } = {}) => timed(`${stage} ${before} setup`, async () => {
  await settle(`${stage} ${before}`);
  if (restart) {
    await restartSimulator(xcrun, simulator);
    await settleAfterBoot();
    console.log(`RESTARTED the ${stage} simulator before ${before}`);
  }
  await beforeRetry();
});
/**
 * Runs a stage's tests; when they stall, keeps the stalled bundle and log beside the next ones (`-stalled`) and runs
 * them again whole, once, after the same setup as a retry. A stalled attempt may have finished no test, so its results
 * explain nothing; a second stall fails the stage.
 */
async function onceMoreIfStalled(stage, simulator, result, log, attempt, beforeRerun = async () => {}) {
  try { return await attempt(); } catch (error) {
    if (!error.stalled) throw error;
    console.log(`STALLED ${stage}: xcodebuild printed nothing for ${quietLimit / 60_000} minutes and was stopped; the stage runs again`);
    await rename(result, result.replace(/\.xcresult$/, '-stalled.xcresult')).catch(() => rm(result, { recursive: true, force: true }));
    await rename(path.join(output, log), path.join(output, log.replace(/\.log$/, '-stalled.log'))).catch(() => {});
    // A simulator that stopped answering boots afresh, iPhone or iPad.
    await prepareRetry(stage, simulator, beforeRerun, 'rerun', { restart: true });
    return await attempt();
  }
}
const retried = {};
const exportAttachments = async (result, folder) => {
  await run('/usr/bin/xcrun', ['xcresulttool', 'export', 'attachments', '--path', result, '--output-path', folder]);
  return JSON.parse(await readFile(path.join(folder, 'manifest.json'), 'utf8'));
};
/**
 * A UI stage. The failed tests run again together, up to twice, on the same build; the tool does this itself because
 * Xcode 26 and later drops its own retry when a failure in an async test that stops at its first failure relaunches
 * the test runner (Apple's known issue 108565878). Before each retry the host's load settles, the iPad boots afresh
 * (see prepareRetry) and `beforeRetry` resets the fixtures a failed attempt can leave changed. A first attempt that stalls
 * runs again whole, once. Prints the tests that ran again, keeps them in retried.json, and returns each test's
 * attachments from the attempt that passed.
 */
async function uiStage(stage, simulator, result, log, attachments, filters, env, beforeRetry, { guard = true } = {}) {
  let failure;
  try {
    await onceMoreIfStalled(stage, simulator, result, log,
      () => xcodebuildTest(result, log, ['-destination', destinationOf(simulator), ...timeouts, ...filters], env, { guard }), beforeRetry);
  } catch (error) { failure = error; }
  // A run that recorded a reference image is never retried: a second attempt would compare against that image. A
  // run that stalled twice has no results that could explain it.
  if (failure?.recorded || failure?.stalled) throw failure;
  let failing = failure ? await failedTests(stage, result, failure) : [];
  const manifest = await exportAttachments(result, attachments);
  const tests = failing.map(test => ({ test: test.id, attempts: 1, passed: null })), later = [];
  try {
    for (let attempt = 2; attempt <= attemptsAllowed && failing.length > 0; attempt++) {
      await prepareRetry(stage, simulator, beforeRetry, `attempt ${attempt}`);
      const bundle = result.replace(/\.xcresult$/, `-attempt-${attempt}.xcresult`), folder = `attempt-${attempt}`;
      const retryLog = log.replace(/\.log$/, `-attempt-${attempt}.log`);
      let retryFailure;
      try {
        await onceMoreIfStalled(stage, simulator, bundle, retryLog, () => xcodebuildTest(bundle, retryLog, ['-destination', destinationOf(simulator),
          ...timeouts, ...failing.map(test => '-only-testing:' + test.only)], env, { guard }), beforeRetry);
      } catch (error) { if (error.recorded || error.stalled) throw error; retryFailure = error; }
      for (const entry of tests) if (failing.some(test => test.id === entry.test)) entry.attempts = attempt;
      if (retryFailure) await failedTests(`${stage} attempt ${attempt}`, bundle, retryFailure);
      const outcomes = new Map(testCases(await testResults(bundle)).map(test => [test.id, test.result]));
      const passed = failing.filter(test => passes(outcomes.get(test.id))).map(test => test.id);
      for (const entry of tests) if (passed.includes(entry.test)) entry.passed = attempt;
      // The tests that passed take this attempt's attachments, so its export has to work.
      if (passed.length > 0) later.push({ directory: folder, manifest: await exportAttachments(bundle, path.join(attachments, folder)), passed });
      failing = failing.filter(test => !passed.includes(test.id));
    }
  } finally {
    // Also when a retry fails outside its tests: what ran again is always on record.
    for (const line of retriedLines(tests, attemptsAllowed)) console.log(line);
    retried[stage] = tests;
    await writeFile(path.join(output, 'retried.json'), JSON.stringify(retried, null, 2) + '\n');
  }
  if (failing.length > 0) throw new Error(`${stage}: ${failing.map(test => test.id).join(', ')} failed ${attemptsAllowed} times`, { cause: failure });
  return mergeAttempts(manifest, later);
}
await run('xcodegen', ['generate'], { cwd: repository });
const inventory = simctlJSON(await run('/usr/bin/xcrun', ['simctl', 'list', 'devices', 'available', '--json']));
const devices = Object.values(inventory.devices).flat();
const device = devices.find(device => device.name === 'iPhone 17 Pro' && device.state === 'Booted')
  ?? devices.find(device => device.name === 'iPhone 17 Pro');
assert.ok(device, 'The existing iPhone 17 Pro simulator is required');
const ipad = devices.find(device => device.name === 'opencode-ios iPad');
const mainSimulator = values['ipad-only'] || workspaceOnly ? (assert.ok(ipad, 'The workspace tests need the opencode-ios iPad simulator'), ipad.udid) : device.udid;
const destination = destinationOf(mainSimulator);
const ipadRun = ipad && !values['ipad-only'] && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !sessionOnly;
// The system tests run on their own simulator when there is one, an iOS 27 iPhone: an older runtime's App Intents
// registry cannot read builds from Xcode 27's SDK, so Shortcuts lists none of the app's App Shortcuts and the Needs you
// widget gets no configuration intent. Everything else stays on the iPhone 17 Pro, whose runtime the references use.
const systemPhone = devices.find(device => device.name === 'opencode-ios iPhone');
const defaultUI = !reviewOnly && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly && !values['ipad-only'] && !values['read-flows-only'];
const systemStageRun = Boolean(systemPhone) && (defaultUI || systemOnly);
// Every simulator the run uses: the app is installed and launched on the iPhone at the end of every run.
const simulators = [...new Set([device.udid, mainSimulator, ...(ipadRun ? [ipad.udid] : []), ...(systemStageRun ? [systemPhone.udid] : [])])];
await audit(path.join(repository, '.build/opencode-sandbox/audits', runID), async () => {
  // A run that uses the iPad starts on a freshly booted one (see restartSimulator); the iPhone is booted and keeps
  // running when it is up (see prepareRetry). One at a time, so two boots don't pile onto a loaded host. The build
  // waits for them and needs no server, so both run while the sandbox starts; a failure surfaces where it is awaited.
  const restarting = timed('simulators', async () => {
    for (const simulator of simulators) await (simulator === ipad?.udid ? restartSimulator : bootSimulator)(xcrun, simulator);
  });
  const building = restarting.then(() => timed('build', buildForTesting));
  building.catch(() => {});
  // The freshly booted iPad settles while the build runs (see settleAfterBoot).
  const settled = restarting.then(() => simulators.includes(ipad?.udid) ? settleAfterBoot() : undefined);
  settled.catch(() => {});
  const mock = await startMock();
  let server, v1, proxy;
  try {
    server = await startSandbox({ version, mockURL: mock.url, configure: async (config, dirs, env) => { await configureComposer(config, dirs, env); return configureReview(config, dirs, env); } });
    const worktreeDirectory = path.join(server.root, 'composer-worktree-project');
    await mkdir(worktreeDirectory);
    await writeFile(path.join(worktreeDirectory, 'README.md'), 'Composer worktree UI fixture\n');
    await run('/usr/bin/git', ['init', '--quiet', worktreeDirectory], { env: server.env, cwd: server.root });
    await run('/usr/bin/git', ['add', 'README.md'], { env: server.env, cwd: worktreeDirectory });
    await run('/usr/bin/git', ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--quiet', '-m', 'Fixture'], { env: server.env, cwd: worktreeDirectory });
    const admin = await seedAdmin(server);
    v1 = await startSandbox({ version: V1_VERSION, v1: true, mockURL: mock.url });
    const screens = await seedReadScreens(server, mock);
    const review = await seedReviewRepository(server, mock);
    proxy = await startFaultProxy(server.baseURL);
    const result = path.join(output, 'Smoke.xcresult');
    const environment = {
      ...process.env,
      TEST_RUNNER_OPENCODE_UI_REVIEW: JSON.stringify(review),
      TEST_RUNNER_OPENCODE_UI_READ_SCREENS: JSON.stringify(screens),
      TEST_RUNNER_OPENCODE_UI_MOCK_URL: mock.url,
      TEST_RUNNER_OPENCODE_UI_DIRECTORY: server.project,
      TEST_RUNNER_OPENCODE_UI_WORKTREE_DIRECTORY: worktreeDirectory,
      TEST_RUNNER_OPENCODE_UI_ADMIN: JSON.stringify(admin),
      TEST_RUNNER_OPENCODE_UI_URL: server.baseURL,
      TEST_RUNNER_OPENCODE_UI_PROXY_URL: proxy.url,
      TEST_RUNNER_OPENCODE_UI_PROXY_TOKEN: proxy.adminToken,
      TEST_RUNNER_OPENCODE_UI_PASSWORD: server.password,
      TEST_RUNNER_OPENCODE_UI_V1_URL: v1.baseURL,
      TEST_RUNNER_OPENCODE_UI_V1_PASSWORD: v1.password,
      TEST_RUNNER_OPENCODE_UI_TEST_ID: runID,
    };
    // A failed attempt can leave the fault proxy blocking or dropping traffic and the no-Git fixture with a repository.
    const beforeRetry = async () => {
      const reset = await fetch(proxy.url + '/__fault', { method: 'POST', headers: { 'x-fault-token': proxy.adminToken, 'content-type': 'application/json' },
        body: JSON.stringify({ blocked: false, dropPrompts: 0, pauseEvents: false, reset: true }) });
      assert.equal(reset.status, 200, 'The fault proxy resets before a retry');
      await rm(path.join(review.noGit, '.git'), { recursive: true, force: true });
      // A booted location keeps the repository it detected, so the fixture's location is evicted and boots again;
      // the retried test must start without a repository.
      await evictLocation(server, review.noGit);
      await waitForNoProvider(() => vcsProvider(server, review.noGit));
    };
    const screenshots = path.join(repository, '.build/screenshots');
    await mkdir(screenshots, { recursive: true });
    // The folder is recreated before each copy, since something else may clear .build during a long run; a missing
    // attachment warns, and the per-stage screenshot assertions decide whether the run fails.
    const saveScreenshot = async (source, name) => {
      await mkdir(screenshots, { recursive: true });
      try { await copyFile(source, path.join(screenshots, `${name}.png`)); return true; } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        console.warn(`WARNING screenshot ${name} not copied: ${error.message}`);
        return false;
      }
    };
    // Wall-clock budgets: beside the iPad stage they run on their own afterwards, on a host the UI tests are not loading.
    const performance = '-only-testing:ReadSnapshots/ReadPerformanceTests';
    const unitsStage = async ({ guard = true, skipPerformance = false } = {}) => {
      const units = path.join(output, 'Units.xcresult');
      await onceMoreIfStalled('units', mainSimulator, units, 'units.log', () => xcodebuildTest(units, 'units.log', ['-destination', destination,
        '-skip-testing:OpencodeUITests', ...(skipPerformance ? [performance.replace('-only-', '-skip-')] : [])], environment, { guard }));
      // The full test tree outgrows the process helper's 24,000-character output tail.
      const editorResults = await testResults(units);
      await writeFile(path.join(output, 'test-results.json'), JSON.stringify(editorResults, null, 2));
      assertEditorCoverage(editorResults);
      console.log('PASS all composer editor regression tests ran in the standard scheme');
    };
    const iphoneStage = async () => {
      const attachments = path.join(output, 'attachments');
      const manifest = await uiStage(values['ipad-only'] || workspaceOnly ? 'iPad' : 'iPhone', mainSimulator, result, 'test.log', attachments, ['-skip-testing:OpencodeUITests/PushSmokeTests', '-skip-testing:OpencodeUITests/ScreenshotTests',
        ...(a11yOnly ? ['-only-testing:OpencodeUITests/AccessibilitySmokeTests'] : sessionOnly ? ['-only-testing:OpencodeUITests/SessionSmokeTests'] : adminOnly ? ['-only-testing:OpencodeUITests/AdminSmokeTests' + (adminTest ? '/' + adminTest : '')] : workspaceOnly ? ['-only-testing:OpencodeUITests/WorkspaceSmokeTests' + (workspaceTest ? '/' + workspaceTest : '')] : terminalOnly ? ['-only-testing:OpencodeUITests/TerminalSmokeTests' + (terminalTest ? '/' + terminalTest : '')] : systemOnly ? ['-only-testing:OpencodeUITests/SystemSmokeTests' + (systemTest ? '/' + systemTest : '')] : reviewOnly ? ['-only-testing:OpencodeUITests/ReviewSmokeTests' + (reviewTest ? '/' + reviewTest : '')] : composerOnly ? ['-only-testing:OpencodeUITests/ComposerSmokeTests' + (composerTest ? '/' + composerTest : '')] : values['ipad-only'] || values['read-flows-only'] ? ['-only-testing:OpencodeUITests/ReadSmokeTests'] : ['-only-testing:OpencodeUITests', '-skip-testing:OpencodeUITests/WorkspaceSmokeTests',
          ...(systemStageRun ? ['-skip-testing:OpencodeUITests/SystemSmokeTests'] : [])])],
        environment, beforeRetry);
      if (full || adminOnly) assert.ok(manifest.some(test => test.testIdentifier?.includes('AdminSmokeTests/')), 'Server settings smoke tests must run; regenerate the Xcode project after adding test sources');
      if (full || a11yOnly) assert.ok(manifest.some(test => test.testIdentifier?.includes('AccessibilitySmokeTests/')), 'The accessibility audit must run; regenerate the Xcode project after adding test sources');
      if (full || sessionOnly) assert.ok(manifest.some(test => test.testIdentifier?.includes('SessionSmokeTests/')), 'Session smoke tests must run; regenerate the Xcode project after adding test sources');
      if (!reviewOnly && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly) assert.ok(manifest.some(test => test.testIdentifier?.includes('ReadSmokeTests/testReadScreens')), 'Read smoke test must run; regenerate the Xcode project after adding test sources');
      const captured = new Set();
      for (const test of manifest) for (const attachment of test.attachments ?? []) {
        // Findings the tests record about the simulator, kept next to the result bundle.
        const finding = attachment.suggestedHumanReadableName ?? '';
        if (finding.startsWith('finding-')) await copyFile(path.join(attachments, attachment.exportedFileName), path.join(output, (values['ipad-only'] || workspaceOnly ? 'ipad-' : '') + path.basename(finding)));
        // Terminal findings: the resume sequences and the sizes stty reported.
        if (finding.startsWith('terminal-resume') || finding.startsWith('terminal-size')) await copyFile(path.join(attachments, attachment.exportedFileName), path.join(output, finding.split('_')[0] + '.txt'));
        for (const name of [...reviewScreens(Boolean(values['ipad-only'])), ...workspaceScreens, ...systemScreens, ...terminalScreens(), 'palette-iphone', 'context-sheet', 'composer-replace-draft', 'composer-sent', 'composer-queue', 'composer-new', 'composer-delete', 'composer-revert-confirmation', 'composer-send-menu', 'composer-worktree', 'permission-dock', 'permission-sheet', 'permission-reject', 'question-sheet', 'question-review', 'inbox', 'session-list', 'transcript-tools', 'transcript-live', 'subagent', 'ipad-split', 'ipad-portrait', 'onboarding', 'home', 'server-list', 'add-server-password', 'add-server', 're-pair', 'server-detail', 'diagnostics', 'local-network', 'update']) {
          if (attachment.suggestedHumanReadableName?.startsWith(name + '_')) {
            if (await saveScreenshot(path.join(attachments, attachment.exportedFileName), name)) captured.add(name);
            break;
          }
        }
      }
      if ((full || terminalOnly) && !values['ipad-only']) for (const name of terminalScreens()) assert.ok(captured.has(name), `Missing terminal screenshot: ${name}`);
      if (!reviewOnly && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly) for (const name of ['inbox', 'session-list', 'transcript-tools', 'transcript-live', 'subagent']) assert.ok(captured.has(name), `Missing read screenshot: ${name}`);
      if (workspaceOnly && !workspaceTest) for (const name of workspaceScreens) assert.ok(captured.has(name), `Missing iPad workspace screenshot: ${name}`);
      if ((full || systemOnly) && !systemTest && !systemStageRun) for (const name of systemScreens) assert.ok(captured.has(name), `Missing system screenshot: ${name}`);
      if (!reviewOnly && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly) {
      assert.ok(manifest.some(test => test.testIdentifier?.includes('ReadSmokeTests/testApprovals')), 'Approval smoke test must run');
      const latencyAttachment = manifest.flatMap(test => test.attachments ?? []).find(item => item.suggestedHumanReadableName?.startsWith('approval-latency'));
      assert.ok(latencyAttachment, 'Missing approval latency measurement');
      const latency = await readFile(path.join(attachments, latencyAttachment.exportedFileName), 'utf8');
      await writeFile(path.join(output, 'approval-latency.json'), latency);
      const answer = manifest.flatMap(test => test.attachments ?? []).find(item => item.suggestedHumanReadableName?.startsWith('answer-latency'));
      assert.ok(answer, 'Missing question answer latency measurement');
      await copyFile(path.join(attachments, answer.exportedFileName), path.join(output, 'answer-latency.json'));
      console.log('PASS permission allow once, question answer, reject with note; ' + latency.trim());
      console.log(`PASS live transcript, jump to latest, subagent, viewed state and deep link; ${result}`);
      }
      if (!reviewOnly && !values['ipad-only'] && !values['read-flows-only'] && !composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly) for (const name of ['onboarding', 'server-list', 'update']) assert.ok(captured.has(name));
      if (full) for (const name of ['palette-iphone', 'context-sheet']) assert.ok(captured.has(name), `Missing switcher screenshot: ${name}`);
      if (!composerOnly && !workspaceOnly && !systemOnly && !adminOnly && !terminalOnly && !sessionOnly && !a11yOnly && !values['read-flows-only'] && !values['ipad-only']) {
        for (const name of reviewScreens()) assert.ok(captured.has(name), `Missing review screenshot: ${name}`);
        for (const test of manifest) for (const attachment of test.attachments ?? []) {
          for (const name of ['review-scroll', 'review-comment-server', 'file-comment-server']) if (attachment.suggestedHumanReadableName?.startsWith(name)) await copyFile(path.join(attachments, attachment.exportedFileName), path.join(output, name + '.json'));
        }
      }
      if (reviewOnly && values['ipad-only']) {
        for (const name of reviewScreens(true)) assert.ok(captured.has(name), `Missing iPad review screenshot: ${name}`);
        for (const test of manifest) for (const attachment of test.attachments ?? []) {
          for (const name of ['review-scroll-nowrap', 'review-scroll', 'review-comment-server']) {
            if (!attachment.suggestedHumanReadableName?.startsWith(name)) continue;
            await copyFile(path.join(attachments, attachment.exportedFileName), path.join(output, 'ipad-' + name + '.json'));
            break;
          }
        }
      }
    };
    const ipadStage = async (options) => {
      const ipadResult = path.join(output, 'iPad.xcresult');
      const ipadAttachments = path.join(output, 'ipad-attachments');
      const ipadFilters = a11yOnly ? ['-only-testing:OpencodeUITests/AccessibilitySmokeTests']
        : terminalOnly ? ['-only-testing:OpencodeUITests/TerminalSmokeTests' + (terminalTest ? '/' + terminalTest : '')]
        : [...(reviewOnly ? [] : ['-only-testing:OpencodeUITests/AccessibilitySmokeTests', '-only-testing:OpencodeUITests/ReadSmokeTests/testReadScreens', '-only-testing:OpencodeUITests/ComposerSmokeTests/testComposerQueueAndSessionActions',
          '-only-testing:OpencodeUITests/WorkspaceSmokeTests', '-only-testing:OpencodeUITests/TerminalSmokeTests',
          '-only-testing:OpencodeUITests/AdminSmokeTests/testSwitcherOpensSettings']), '-only-testing:OpencodeUITests/ReviewSmokeTests' + (reviewTest ? '/' + reviewTest : '')];
      const ipadScreens = a11yOnly ? [] : terminalOnly ? terminalScreens(true) : [...(reviewOnly ? [] : ['ipad-split', 'ipad-portrait', 'ipad-composer-queue', 'ipad-composer-new', ...workspaceScreens, ...terminalScreens(true)]), ...reviewScreens(true)];
      const ipadManifest = await uiStage('iPad', ipad.udid, ipadResult, 'ipad.log', ipadAttachments, ipadFilters,
        environment, beforeRetry, options);
      const ipadCaptured = new Set();
      for (const test of ipadManifest) for (const attachment of test.attachments ?? []) {
        const finding = attachment.suggestedHumanReadableName ?? '';
        if (finding.startsWith('finding-')) await copyFile(path.join(ipadAttachments, attachment.exportedFileName), path.join(output, 'ipad-' + path.basename(finding)));
        if (finding.startsWith('ipad-terminal-resume') || finding.startsWith('ipad-terminal-size')) await copyFile(path.join(ipadAttachments, attachment.exportedFileName), path.join(output, finding.split('_')[0] + '.txt'));
        for (const name of ipadScreens) {
          if (attachment.suggestedHumanReadableName?.startsWith(name + '_')) {
            if (await saveScreenshot(path.join(ipadAttachments, attachment.exportedFileName), name)) ipadCaptured.add(name);
            break;
          }
        }
      }
      for (const name of ipadScreens) assert.ok(ipadCaptured.has(name), `Missing iPad screenshot: ${name}`);
      for (const test of ipadManifest) for (const attachment of test.attachments ?? []) {
        if (attachment.suggestedHumanReadableName?.startsWith('review-scroll')) await copyFile(path.join(ipadAttachments, attachment.exportedFileName), path.join(output, attachment.suggestedHumanReadableName.startsWith('review-scroll-nowrap') ? 'ipad-review-scroll-nowrap.json' : 'ipad-review-scroll.json'));
        if (attachment.suggestedHumanReadableName?.startsWith('review-comment-server')) await copyFile(path.join(ipadAttachments, attachment.exportedFileName), path.join(output, 'ipad-review-comment-server.json'));
      }
      console.log(a11yOnly ? 'PASS iPad accessibility audit' : terminalOnly ? 'PASS iPad terminals' : 'PASS iPad read flows, split-view captures, menu bar, switcher, two windows, drag and drop and terminals');
    };
    // Shortcuts, Spotlight and the widget on the iOS 27 iPhone (see systemPhone), with the iPhone stage's retries.
    const systemStage = async () => {
      const systemAttachments = path.join(output, 'system-attachments');
      const systemManifest = await uiStage('System', systemPhone.udid, path.join(output, 'System.xcresult'), 'system.log', systemAttachments,
        ['-only-testing:OpencodeUITests/SystemSmokeTests' + (systemTest ? '/' + systemTest : '')], environment, beforeRetry);
      const systemCaptured = new Set();
      for (const test of systemManifest) for (const attachment of test.attachments ?? []) {
        const finding = attachment.suggestedHumanReadableName ?? '';
        if (finding.startsWith('finding-')) await copyFile(path.join(systemAttachments, attachment.exportedFileName), path.join(output, path.basename(finding)));
        const name = systemScreens.find(name => finding.startsWith(name + '_'));
        if (name && await saveScreenshot(path.join(systemAttachments, attachment.exportedFileName), name)) systemCaptured.add(name);
      }
      if (!systemTest) for (const name of systemScreens) assert.ok(systemCaptured.has(name), `Missing system screenshot: ${name}`);
      console.log(`PASS Shortcuts, Spotlight and the widget on ${systemPhone.name}`);
    };
    xctestrun = await building;
    await settled;
    if (full && ipadRun) {
      // The snapshot and unit stage needs the iPhone simulator, whose screen scale its references use, and the iPad UI
      // stage runs beside it on the iPad. The unit stage's own check sees any reference image either one records.
      // Neither stage checks reference images itself; the tree is compared once both have settled.
      const before = await snapshotTree(repository);
      const stages = await Promise.allSettled([timed('units', () => unitsStage({ guard: false, skipPerformance: true })),
        timed('iPad', () => ipadStage({ guard: false }))]);
      const recorded = changedSnapshots(before, await snapshotTree(repository));
      for (const file of recorded) console.log(`RECORDED ${file}`);
      if (recorded.length > 0) throw new Error('The run added or changed reference images: ' + recorded.join(', '));
      const failures = stages.filter(stage => stage.status === 'rejected').map(stage => stage.reason);
      for (const failure of failures) console.error(failure);
      if (failures.length > 0) throw failures.length === 1 ? failures[0] : new AggregateError(failures, 'The unit and iPad stages failed');
      // The budgets measure wall-clock time and never run again, so a burst of load on the host is waited out first.
      await timed('performance setup', () => settle('the performance budgets'));
      const budgets = path.join(output, 'Performance.xcresult');
      await timed('performance', () => onceMoreIfStalled('performance', mainSimulator, budgets, 'performance.log',
        () => xcodebuildTest(budgets, 'performance.log', ['-destination', destination, performance], environment)));
      await timed('iPhone', iphoneStage);
      if (systemStageRun) await timed('System', systemStage);
    } else {
      if (full) await timed('units', unitsStage);
      // A system-only run with the iOS 27 iPhone has nothing for the iPhone stage.
      if (!(systemOnly && systemStageRun)) await timed(values['ipad-only'] || workspaceOnly ? 'iPad' : 'iPhone', iphoneStage);
      if (systemStageRun) await timed('System', systemStage);
      if (ipadRun) await timed('iPad', ipadStage);
    }
    // Leave a freshly installed, launched app on the requested booted simulator. A simulator that stopped answering
    // can hold any of these commands forever, so each has 5 minutes; cleanup below stops one that ran out.
    const bounded = (args, options) => withDeadline(run('/usr/bin/xcrun', args, options), 5 * 60_000, `simctl ${args[1]} did not finish within 5 minutes`);
    const afterTests = simctlJSON(await bounded(['simctl', 'list', 'devices', '--json']));
    const current = Object.values(afterTests.devices).flat().find(item => item.udid === device.udid);
    if (current.state !== 'Booted') await bounded(['simctl', 'boot', device.udid]);
    await bounded(['simctl', 'bootstatus', device.udid, '-b']);
    await bounded(['simctl', 'install', device.udid, '.build/DerivedData/Build/Products/Debug-iphonesimulator/Opencode.app']);
    await bounded(['simctl', 'launch', '--terminate-running-process', device.udid, 'dev.opencodeios.client'],
      { env: { ...process.env, SIMCTL_CHILD_OPENCODE_UI_TEST_ID: runID + '-read' } });
    console.log('PASS screenshots exported; app installed and launched on the booted simulator');
  } finally {
    try { await proxy?.close(); await v1?.stop(); await server?.stop(); }
    finally { await stopAll(); await mock.close(); }
  }
});
console.log('PASS UI smoke process cleanup and opencode isolation audit');

if (full) {
  // The push stage runs its one test once, with no retry, and must not record a reference image either.
  const before = await snapshotTree(repository);
  // Its script prints nothing while its xcodebuild builds and tests, so it is stopped after 40 silent minutes, well
  // past an incremental build and one test (600-second allowance) on a loaded host.
  console.log(await runUntilQuiet(launch, process.execPath, ['Tools/push-e2e/simulator.mjs', '--version', version], { cwd: repository }, { quiet: 40 * 60_000 }));
  const recorded = changedSnapshots(before, await snapshotTree(repository));
  for (const file of recorded) console.log(`RECORDED ${file}`);
  assert.deepEqual(recorded, [], 'The push stage added or changed reference images');
}
