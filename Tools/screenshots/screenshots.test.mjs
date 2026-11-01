import assert from 'node:assert/strict';
import test from 'node:test';
import { README_IMAGES, STATUS_BAR, screenshotName } from './index.mjs';

test('attachments become ordered light and dark file names', () => {
  assert.equal(screenshotName('shot-light-04-markdown_0_6D1F2A.png'), 'light-04-markdown.png');
  assert.equal(screenshotName('shot-dark-01-add-server_1_AB'), 'dark-01-add-server.png');
  assert.equal(screenshotName('failure-screen_0_AB.png'), undefined);
  assert.equal(screenshotName('shot-sepia-01-home_0'), undefined);
});

test('every README phone image keeps its published name', () => {
  assert.deepEqual(Object.values(README_IMAGES).sort(), ['iphone-add-server.webp', 'iphone-commands.webp', 'iphone-home.webp',
    'iphone-markdown.webp', 'iphone-permission.webp', 'iphone-question.webp', 'iphone-session.webp']);
});

test('captures show 9:41 with full signal and battery', () => {
  const value = flag => STATUS_BAR[STATUS_BAR.indexOf(flag) + 1];
  assert.equal(value('--time'), '9:41');
  assert.deepEqual([value('--wifiBars'), value('--cellularBars'), value('--batteryLevel'), value('--batteryState')], ['3', '4', '100', 'discharging']);
});
