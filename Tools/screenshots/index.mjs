// App Store and README screenshots from the in-app demo, light and dark:
//   node Tools/screenshots/index.mjs [--device "iPhone 17 Pro"] [--device "opencode-ios iPad"] [--readme]
//
// Runs the ScreenshotTests UI test on each named simulator (existing ones only; nothing is created or changed, and the
// status bar override for the capture is cleared after it) and saves
// `.build/store-screenshots/<device>/<light|dark>-<n>-<screen>.png`. `--readme` then rebuilds the README
// images in docs/images from the light captures (an iPhone and an iPad device are needed for the hero); it needs
// `cwebp` (Homebrew `webp`).
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { copyFile, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, promisify } from 'node:util';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const output = path.join(repository, '.build/store-screenshots');
const run = async (command, args, options = {}) =>
  (await promisify(execFile)(command, args, { maxBuffer: 256 * 1024 * 1024, cwd: repository, ...options })).stdout;

/** `shot-<scheme>-<n>-<screen>_<suffix>.png`, as XCTest exports an attachment, to the saved name. */
export function screenshotName(attachment) {
  const match = /^shot-(light|dark)-(\d+)-([a-z-]+?)(?:_[^/]*)?$/.exec(attachment);
  return match ? `${match[1]}-${match[2]}-${match[3]}.png` : undefined;
}

/** The README image each light capture becomes, and its width in pixels. */
export const README_IMAGES = {
  home: 'iphone-home.webp',
  session: 'iphone-session.webp',
  permission: 'iphone-permission.webp',
  question: 'iphone-question.webp',
  markdown: 'iphone-markdown.webp',
  commands: 'iphone-commands.webp',
  'add-server': 'iphone-add-server.webp',
};
export const README_WIDTH = 600;
/** `simctl status_bar override` arguments for every capture. */
export const STATUS_BAR = ['--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
  '--cellularMode', 'active', '--cellularBars', '4', '--batteryState', 'discharging', '--batteryLevel', '100'];
/** Puts a simulator's status bar back; a failure is reported, since the override would otherwise stay. */
const clearStatusBar = async udid => {
  try { await run('/usr/bin/xcrun', ['simctl', 'status_bar', udid, 'clear']); }
  catch (error) { console.error(`Could not clear the status bar of ${udid}: ${error.message}`); }
};

async function capture(device, runID) {
  const simctl = await run('/usr/bin/xcrun', ['simctl', 'list', 'devices', 'available', '--json']);
  const devices = Object.values(JSON.parse(simctl.slice(simctl.indexOf('{'))).devices).flat();
  const simulator = devices.find(item => item.name === device);
  assert.ok(simulator, `No simulator named "${device}"; this tool uses existing simulators only`);
  const destination = `platform=iOS Simulator,id=${simulator.udid}`;
  const folder = path.join(output, device), result = path.join(output, `${device}.xcresult`), attachments = path.join(output, `${device}-attachments`);
  await rm(folder, { recursive: true, force: true }); await rm(result, { recursive: true, force: true }); await rm(attachments, { recursive: true, force: true });
  await mkdir(folder, { recursive: true });
  console.log(`Capturing on ${device}`);
  const log = path.join(output, `${device}.log`);
  // The status bar reads 9:41 with full Wi-Fi, cellular and battery while capturing, and goes back to normal after,
  // even when the capture fails. An override needs a booted device, so it is booted first.
  await run('/usr/bin/xcrun', ['simctl', 'bootstatus', simulator.udid, '-b']);
  await run('/usr/bin/xcrun', ['simctl', 'status_bar', simulator.udid, 'override', ...STATUS_BAR]);
  // An interrupted run clears it too; the finally below does not run when Node is signalled.
  const interrupted = signal => { clearStatusBar(simulator.udid).finally(() => process.exit(128 + (signal === 'SIGINT' ? 2 : 15))); };
  process.once('SIGINT', interrupted); process.once('SIGTERM', interrupted);
  try {
    await writeFile(log, await run('/usr/bin/xcodebuild', ['-project', 'Opencode.xcodeproj', '-scheme', 'Opencode', '-destination', destination,
      '-derivedDataPath', '.build/DerivedData', '-skipPackagePluginValidation', '-resultBundlePath', result, '-parallel-testing-enabled', 'NO',
      '-only-testing:OpencodeUITests/ScreenshotTests', 'test'], { env: { ...process.env, TEST_RUNNER_OPENCODE_UI_TEST_ID: runID } }));
  } catch (error) {
    await writeFile(log, `${error.stdout ?? ''}\n${error.message}`);
    throw new Error(`ScreenshotTests failed on ${device}; see ${path.relative(repository, log)}`);
  } finally {
    process.off('SIGINT', interrupted); process.off('SIGTERM', interrupted);
    await clearStatusBar(simulator.udid);
  }
  await run('/usr/bin/xcrun', ['xcresulttool', 'export', 'attachments', '--path', result, '--output-path', attachments]);
  const manifest = JSON.parse(await readFile(path.join(attachments, 'manifest.json'), 'utf8'));
  const saved = [];
  for (const test of manifest) for (const attachment of test.attachments ?? []) {
    const name = screenshotName(attachment.suggestedHumanReadableName ?? '');
    if (!name) continue;
    await copyFile(path.join(attachments, attachment.exportedFileName), path.join(folder, name));
    saved.push(name);
  }
  assert.ok(saved.some(name => name.startsWith('light-')) && saved.some(name => name.startsWith('dark-')), `No light and dark screenshots from ${device}`);
  console.log(`PASS ${saved.length} screenshots in ${path.relative(repository, folder)}`);
  return { device, folder, saved, ipad: saved.some(name => name.endsWith('-workspace.png')) };
}

async function readme(sets) {
  const iphone = sets.find(set => !set.ipad), ipad = sets.find(set => set.ipad);
  assert.ok(iphone && ipad, '--readme needs an iPhone and an iPad device');
  const light = (set, screen) => {
    const name = set.saved.filter(item => item.startsWith('light-')).find(item => item.endsWith(`-${screen}.png`));
    assert.ok(name, `Missing light ${screen} screenshot from ${set.device}`);
    return path.join(set.folder, name);
  };
  const images = path.join(repository, 'docs/images');
  const scratch = path.join(output, 'readme');
  await mkdir(scratch, { recursive: true });
  for (const [screen, file] of Object.entries(README_IMAGES)) {
    const resized = path.join(scratch, screen + '.png');
    await run('/usr/bin/sips', ['--resampleWidth', String(README_WIDTH), light(iphone, screen), '--out', resized]);
    await run('cwebp', ['-quiet', '-q', '82', '-m', '6', resized, '-o', path.join(images, file)]);
  }
  const hero = path.join(scratch, 'hero.png');
  await run('/usr/bin/xcrun', ['swift', path.join(repository, 'Tools/screenshots/compose.swift'), light(ipad, 'workspace'), light(iphone, 'home'), hero]);
  await run('cwebp', ['-quiet', '-q', '82', '-m', '6', hero, '-o', path.join(images, 'hero.webp')]);
  console.log(`PASS README images: hero.webp and ${Object.values(README_IMAGES).join(', ')}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { values } = parseArgs({ options: { device: { type: 'string', multiple: true }, readme: { type: 'boolean' } } });
  const devices = values.device ?? ['iPhone 17 Pro'];
  await run('xcodegen', ['generate']);
  const runID = `ui-shots-${Date.now()}`;
  const sets = [];
  // One simulator at a time: the UI tests and the build share the derived data folder.
  for (const device of devices) sets.push(await capture(device, runID));
  if (values.readme) await readme(sets);
}
