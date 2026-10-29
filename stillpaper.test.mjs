// Guards for Stillpaper. The build tests compile the real app with swiftc into temp folders, once for
// Intel, once for this Mac and once from a source download, and check what they produce; they skip on
// a machine without swiftc.
// Run from the repo root: node --test stillpaper.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const source = readFileSync(path.join(here, 'Stillpaper.swift'), 'utf8');
const git = (...a) => spawnSync('git', a, { cwd: here, encoding: 'utf8' }).stdout.trim();
const method = (name) => {
  const from = source.slice(source.indexOf(`func ${name}(`));
  return from.slice(0, from.indexOf('\n  }\n'));
};
const minos = (exe) => spawnSync('otool', ['-l', exe], { encoding: 'utf8' }).stdout.match(/LC_BUILD_VERSION[\s\S]*?minos ([\d.]+)/)?.[1];

// The app shows whatever page its user picks, so it ships knowing no address at all.
test('there is no built-in page: nothing loads until one is chosen, and a first run asks for it', () => {
  assert.doesNotMatch(source, /defaultURL/);
  assert.doesNotMatch(source, /"https?:\/\/[^"]/, 'no web address may be written into the source');
  assert.match(source, /static var url: String\?/);
  assert.match(method('resume'), /guard !running, Settings\.pageURL != nil else \{ return \}/);
  assert.match(method('load'), /guard let url = Settings\.pageURL else \{ return \}/);
  assert.match(method('applicationDidFinishLaunching'), /if Settings\.pageURL == nil \{ DispatchQueue\.main\.async \{ self\.editURL\(\) \} \}/);
  assert.match(method('statusLine'), /Settings\.pageURL == nil/, 'the menu says no page is set');
});

// Measured 2026-10-20 on an animated dashboard page (Intel Mac, macOS 12): 53% of a core with
// motion, 31% with only the CSS rule, 7% once SVG animations were paused too. Both halves of the
// freeze carry the saving.
test('the motion freeze stops CSS animations and SVG animations', () => {
  assert.match(source, /animation:none!important/);
  assert.match(source, /pauseAnimations\(\)/);
  assert.match(source, /new MutationObserver\(pause\)/, 'SVGs drawn after load must be paused too');
});

// A plist that is written but never loaded does nothing until the next login. Writing and loading
// have to stay together, and the copy launchd started must never boot itself out.
test('Open at login loads the agent it writes, and unloads it unless launchd owns this copy', () => {
  const body = method('toggleLogin');
  assert.ok(body.indexOf('launchctl(["bootstrap"') > body.indexOf('data.write(to: agentURL)'), 'bootstrap must follow the plist write');
  assert.match(body, /launchctl\(\["bootout"/);
  assert.match(body, /XPC_SERVICE_NAME"\] != bundleID/, 'booting out the job launchd started would quit the app');
});

test('the build targets the Mac it runs on and pins the macOS 12 minimum', () => {
  const build = readFileSync(path.join(here, 'build.sh'), 'utf8');
  assert.match(build, /arch="\$\{ARCH:-\$\(uname -m\)\}"/);
  assert.match(build, /swiftc -O -target "\$arch-apple-macos12"/);
  assert.match(build, /<key>LSMinimumSystemVersion<\/key><string>12\.0<\/string>/);
});

// Stored as 100644, build.sh answered ./build.sh with "permission denied" in a clone or a download.
test('build.sh is executable, so ./build.sh runs from a clone or a source download', () => {
  assert.match(git('ls-files', '-s', 'build.sh'), /^100755 /);
});

test('an Intel build compiles for macOS 12', { timeout: 600000 }, (t) => {
  if (spawnSync('which', ['swiftc']).status !== 0) return t.skip('swiftc not installed');
  const out = mkdtempSync(path.join(os.tmpdir(), 'stillpaper-x86-'));
  try {
    const r = spawnSync('bash', [path.join(here, 'build.sh')], { env: { ...process.env, OUT_DIR: out, ARCH: 'x86_64' }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const exe = path.join(out, 'Stillpaper.app', 'Contents', 'MacOS', 'Stillpaper');
    assert.equal(spawnSync('lipo', ['-archs', exe], { encoding: 'utf8' }).stdout.trim(), 'x86_64');
    assert.equal(minos(exe), '12.0');
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

test('the build stamps Version, build and commit into the bundle', { timeout: 600000 }, (t) => {
  if (spawnSync('which', ['swiftc']).status !== 0) return t.skip('swiftc not installed');
  const out = mkdtempSync(path.join(os.tmpdir(), 'stillpaper-'));
  try {
    const r = spawnSync('bash', [path.join(here, 'build.sh')], { env: { ...process.env, OUT_DIR: out }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    const app = path.join(out, 'Stillpaper.app');
    const exe = path.join(app, 'Contents', 'MacOS', 'Stillpaper');
    assert.ok(existsSync(exe));
    assert.equal(minos(exe), '12.0');
    const plist = readFileSync(path.join(app, 'Contents', 'Info.plist'), 'utf8');
    const key = (k) => plist.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`))?.[1];
    assert.equal(key('CFBundleIdentifier'), 'com.ivdezine.stillpaper');
    assert.match(key('CFBundleShortVersionString'), /^\d+\.\d+\.\d+$/);
    assert.equal(key('CFBundleVersion'), git('rev-list', '--count', 'HEAD'));
    assert.equal(key('GitCommit').replace(/-dirty$/, ''), git('rev-parse', '--short=7', 'HEAD'));
    assert.match(plist, /<key>LSUIElement<\/key><true\/>/, 'no Dock icon');
  } finally {
    rmSync(out, { recursive: true, force: true });
  }
});

// A release's Source code download has no git history, so a build from one was stamped
// "build 0 (unknown)". git now writes the commit into build.sh as it exports the archive. The
// export is of HEAD, as a release download would be, and runs ./build.sh the way a reader would.
test('a build from a source download names the commit it was cut from', { timeout: 600000 }, (t) => {
  if (spawnSync('which', ['swiftc']).status !== 0) return t.skip('swiftc not installed');
  const tmp = mkdtempSync(path.join(os.tmpdir(), 'stillpaper-archive-'));
  try {
    const src = path.join(tmp, 'src'), out = path.join(tmp, 'out');
    mkdirSync(src);
    assert.equal(spawnSync('git', ['archive', '-o', path.join(tmp, 'src.tar'), 'HEAD'], { cwd: here }).status, 0);
    assert.equal(spawnSync('tar', ['-xf', path.join(tmp, 'src.tar'), '-C', src]).status, 0);
    const r = spawnSync('./build.sh', { cwd: src, env: { ...process.env, OUT_DIR: out }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr || String(r.error));
    const plist = readFileSync(path.join(out, 'Stillpaper.app', 'Contents', 'Info.plist'), 'utf8');
    const key = (k) => plist.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`))?.[1];
    assert.equal(key('GitCommit'), git('rev-parse', '--short=7', 'HEAD'));
    assert.equal(key('CFBundleVersion'), '0', 'a download has no history to count');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
