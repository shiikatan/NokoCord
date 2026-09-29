import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const fixtureRoot = dirname(fileURLToPath(import.meta.url));
const sourcePath = join(fixtureRoot, '../../..', 'NokoCord', 'Models', 'TanOriginals.swift');
const source = await readFile(sourcePath, 'utf8');

function swiftRawString(name) {
  const startMarker = `private static let ${name} = ##"""`;
  const start = source.indexOf(startMarker);
  assert.notEqual(start, -1, `could not find ${name} in TanOriginals.swift`);
  const contentStart = start + startMarker.length;
  const end = source.indexOf('"""##', contentStart);
  assert.notEqual(end, -1, `could not find end of ${name} in TanOriginals.swift`);
  return source.slice(contentStart, end);
}

const focusJS = swiftRawString('focusShieldJS');
const focusCSS = swiftRawString('focusShieldCSS');
const workbenchJS = swiftRawString('codeWorkbenchJS');
const workbenchCSS = swiftRawString('codeWorkbenchCSS');

test('bundled Tan JavaScript remains syntactically valid', () => {
  assert.doesNotThrow(() => new Function(focusJS), 'Focus Shield JavaScript must parse');
  assert.doesNotThrow(() => new Function(workbenchJS), 'Code Workbench JavaScript must parse');
});

test('Focus Shield fixtures cover presentation profiles, accessibility, reduced motion, and cleanup', async () => {
  const fixture = await readFile(join(fixtureRoot, 'focus-shield', 'fixture.html'), 'utf8');
  for (const profile of ['screen-share', 'meeting', 'streaming']) {
    assert.match(focusJS, new RegExp(profile));
    assert.match(focusCSS, new RegExp(profile));
    assert.match(fixture, new RegExp(`data-fixture-${profile}`));
  }
  for (const contract of [
    'data-noko-focus-shield-indicator',
    'aria-live',
    'aria-pressed',
    'prefers-reduced-motion',
    'matchMedia',
    'document.activeElement',
    'api.onCleanup'
  ]) assert.match(focusJS, new RegExp(contract.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.doesNotMatch(focusJS, /fetch\(|localStorage|window\.webkit/);
});

test('Code Workbench fixtures cover bounded dynamic rendering and keyboard accessibility', async () => {
  const fixture = await readFile(join(fixtureRoot, 'code-workbench', 'fixture.html'), 'utf8');
  for (const contract of [
    'MutationObserver',
    'requestAnimationFrame',
    'pendingRoots',
    'scanBudget',
    'aria-controls',
    'aria-expanded',
    'aria-keyshortcuts',
    'aria-live',
    'contenteditable',
    'navigator.clipboard',
    'focus()'
  ]) assert.match(workbenchJS, new RegExp(contract.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(workbenchCSS, /:focus-visible/);
  assert.match(workbenchCSS, /prefers-reduced-motion/);
  assert.match(fixture, /data-fixture-dynamic-root/);
  assert.match(fixture, /contenteditable="true"/);
  assert.doesNotMatch(workbenchJS, /window\.webkit|fetch\(|localStorage|eval\(/);
});

test('mutation-budget and Safe Mode fixtures remain deterministic and page-only', async () => {
  const budget = await readFile(join(fixtureRoot, 'support', 'mutation-budget.html'), 'utf8');
  const safeMode = await readFile(join(fixtureRoot, 'support', 'safe-mode.html'), 'utf8');
  assert.match(budget, /data-fixture-editor-mutations="1000"/);
  assert.match(budget, /data-fixture-message-mutations="1000"/);
  assert.match(budget, /data-fixture-one-frame="true"/);
  assert.match(safeMode, /data-fixture-safe-mode="true"/);
  assert.doesNotMatch(safeMode, /NokoTan\.register/);
});
