import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { emptyState, validateStatus, events, refresh, deliver, readState, writeState, check, withLock, serviceDefinition, notifyNative, render, retryDelay, POLL_MS, ENDPOINT } from '../src/resets.mjs';

const now = Date.parse('2026-09-10T10:00:00Z');
const reset = (id = 'post-1', type = 'regular') => ({ id, reset_type: type, announced_at: '2026-09-09T18:00:00Z', text: 'A reset was reported.', source: { type: 'x_post', author: 'thsottiaux', url: 'https://x.com/thsottiaux/status/1' } });
const payload = (id = 'post-1') => ({ data: { latest_reset: reset(id), scheduled_reset: null, active_watch: null, stats: { total: 1 } }, meta: { api_version: 'v1', generated_at: '2026-09-10T09:59:00Z' } });
const forecast = () => ({ level: 'elevated', reset_chance_percent: 45, forecast_window: 'this week', observed_at: '2026-09-10T09:00:00Z', expires_at: '2026-09-11T09:00:00Z', text: 'A possible reset.', source: { type: 'observed' } });
const response = (p = payload(), status = 200, headers = {}) => new Response(status === 304 ? null : JSON.stringify(p), { status, headers });
const fresh = () => ({ ...emptyState(), status: payload(), checked_at: now, next_poll_at: now + POLL_MS });
async function temporary(t) { const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-reset-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true })); return dir; }

test('public GET uses fixed HTTPS endpoint, conditional ETag, and no account credentials', async () => {
  const s = emptyState();
  await refresh(s, { now, fetchImpl: async (url, opts) => {
    assert.equal(url, ENDPOINT); assert.equal(opts.redirect, 'error'); assert.ok(opts.signal instanceof AbortSignal);
    assert.deepEqual(Object.keys(opts.headers).sort(), ['Accept', 'User-Agent']);
    return response(payload(), 200, { etag: '"one"' });
  } });
  assert.equal(s.etag, '"one"'); assert.equal(s.checked_at, now);
  await refresh(s, { now: now + POLL_MS, fetchImpl: async (_, opts) => {
    assert.equal(opts.headers['If-None-Match'], '"one"'); assert.equal(opts.headers.Authorization, undefined);
    return response(null, 304);
  } });
  assert.equal(s.status.data.latest_reset.id, 'post-1'); assert.equal(s.checked_at, now + POLL_MS);
});

test('fresh cache skips network, and no-cache 304 is treated as failure', async () => {
  let calls = 0;
  await refresh(fresh(), { now, fetchImpl: async () => { calls++; throw Error('unexpected'); } });
  assert.equal(calls, 0);
  const s = emptyState(); await refresh(s, { now, fetchImpl: async () => response(null, 304) });
  assert.equal(s.status, null); assert.match(s.last_error, /304/);
});

test('429 honors Retry-After and retains the last usable snapshot', async () => {
  const s = fresh(); s.next_poll_at = 0;
  await refresh(s, { now, fetchImpl: async () => response({}, 429, { 'retry-after': '7200' }) });
  assert.equal(s.next_poll_at, now + 7200000); assert.equal(s.checked_at, now); assert.equal(s.status.data.latest_reset.id, 'post-1');
  assert.match(s.last_error, /429/);
  assert.equal(retryDelay(new Date(now + 10800000).toUTCString(), now, 1), 10800000);
  assert.equal(retryDelay('invalid', now, 3), 4 * POLL_MS);
  let calls = 0;
  await refresh(s, { now: now + POLL_MS, fetchImpl: async () => { calls++; } });
  assert.equal(calls, 0);
});

test('malformed, oversized and stale upstream snapshots never replace the valid cache', async () => {
  const malformed = [ {}, { data: {} }, { ...payload(), meta: { api_version: 'v2' } } ];
  for (const p of malformed) { const s = fresh(); s.next_poll_at = 0; await refresh(s, { now, fetchImpl: async () => response(p) }); assert.ok(s.last_error); assert.equal(s.status.data.latest_reset.id, 'post-1'); }
  const s = fresh(); s.next_poll_at = 0;
  await refresh(s, { now, fetchImpl: async () => response(payload('new'), 200, { 'content-length': '99999999' }) });
  assert.match(s.last_error, /large/); assert.equal(s.status.data.latest_reset.id, 'post-1');
  s.next_poll_at = 0; const older = payload('older'); older.meta.generated_at = '2026-09-09T00:00:00Z';
  await refresh(s, { now, fetchImpl: async () => response(older) });
  assert.match(s.last_error, /older/); assert.equal(s.status.data.latest_reset.id, 'post-1');
});

test('network recovery clears error and resumes polling', async () => {
  const s = emptyState(); await refresh(s, { now, fetchImpl: async () => { throw Error('offline'); } });
  assert.equal(s.failures, 1); assert.match(s.last_error, /offline/);
  await refresh(s, { now: now + POLL_MS, fetchImpl: async () => response() });
  assert.equal(s.failures, 0); assert.equal(s.last_error, null); assert.ok(s.status);
});

test('first success is a quiet baseline, and restart preserves deduplication', async t => {
  const dir = await temporary(t); const s = fresh(); let notified = 0;
  const notify = async () => { notified++; };
  await deliver(s, { now, notify }); assert.equal(notified, 0); assert.equal(s.initialized, true);
  await writeState(dir, s);
  const resumed = await readState(dir);
  await deliver(resumed, { now, notify }); assert.equal(notified, 0);
  resumed.status = payload('post-2');
  await deliver(resumed, { now, notify, save: () => writeState(dir, resumed) });
  assert.equal(notified, 1);
  const again = await readState(dir); again.status.meta.generated_at = '2026-09-10T10:00:00Z';
  await deliver(again, { now, notify }); assert.equal(notified, 1);
});

test('empty feed baseline still notifies on the first later announcement', async () => {
  const s = fresh(); s.status.data.latest_reset = null; const notices = [];
  await deliver(s, { now, notify: async m => notices.push(m) });
  s.status = payload(); await deliver(s, { now, notify: async m => notices.push(m) });
  assert.equal(notices.length, 1);
});

test('planned -> executed for the same post notifies as distinct stages', async () => {
  const s = fresh(); s.status.data.latest_reset = null;
  await deliver(s, { now });
  s.status.data.scheduled_reset = { ...reset('same-post', 'banked'), status: 'scheduled', scheduled_for: '2026-09-09T10:00:00Z' };
  const notices = [];
  await deliver(s, { now, notify: async message => notices.push(message) });
  assert.match(notices[0].title, /scheduled/); assert.match(notices[0].body, /Awaiting execution/);
  assert.equal(events(s.status, now)[0].stage, 'scheduled');
  s.status.data.scheduled_reset = null; s.status.data.latest_reset = reset('same-post', 'banked');
  await deliver(s, { now, notify: async message => notices.push(message) });
  assert.equal(notices.length, 2); assert.match(notices[1].title, /Banked reset credit reported/);
});

test('forecasts are explicit, expire quietly and do not notify on every percentage edit', async () => {
  const s = fresh(); await deliver(s, { now }); const notices = [];
  s.status.data.active_watch = forecast();
  await deliver(s, { now, notify: async m => notices.push(m) });
  assert.match(notices[0].title, /AI reset forecast \(unconfirmed\)/);
  s.status.data.active_watch.reset_chance_percent = 50;
  await deliver(s, { now, notify: async m => notices.push(m) }); assert.equal(notices.length, 1);
  s.status.data.active_watch.level = 'strong';
  await deliver(s, { now, notify: async m => notices.push(m) }); assert.equal(notices.length, 2);
  s.status.data.active_watch.observed_at = '2026-09-11T00:00:00Z';
  await deliver(s, { now: now + 86400000, notify: async m => notices.push(m) }); assert.equal(notices.length, 2);
  assert.match(render(s, { now: now + 86400000 }), /Expired/);
});

test('failed notification is retried without repeating an earlier successful delivery', async t => {
  const dir = await temporary(t), s = fresh(); await deliver(s, { now });
  s.status = payload('new'); s.status.data.active_watch = forecast(); let attempts = 0;
  await assert.rejects(deliver(s, { now, notify: async () => { if (++attempts === 2) throw Error('notification denied'); }, save: () => writeState(dir, s) }), /denied/);
  const resumed = await readState(dir); const notices = [];
  await deliver(resumed, { now, notify: async m => notices.push(m) });
  assert.equal(notices.length, 1); assert.match(notices[0].title, /forecast/);
});

test('parallel foreground and background checks send each announcement only once', async t => {
  const dir = await temporary(t), s = fresh(); s.enabled = true; await deliver(s, { now });
  s.status = payload('new'); await writeState(dir, s);
  let count = 0; const opts = { now, fetchImpl: async () => { throw Error('cache should be fresh'); }, notify: async () => { count++; await new Promise(r => setTimeout(r, 30)); } };
  await Promise.all([check(dir, opts), check(dir, opts)]);
  assert.equal(count, 1);
});

test('disabled service performs no network or notification; offline checks retain dedup state', async t => {
  const dir = await temporary(t), s = fresh(); let calls = 0;
  await writeState(dir, s);
  await check(dir, { now, fetchImpl: async () => { calls++; }, notify: async () => { calls++; } }); assert.equal(calls, 0);
  s.enabled = true; s.next_poll_at = 0; await deliver(s, { now }); s.status = payload('cached-new'); await writeState(dir, s);
  await check(dir, { now, fetchImpl: async () => { throw Error('offline'); }, notify: async () => { calls++; } });
  assert.equal(calls, 0); assert.equal((await readState(dir)).seen.length, 1);
});

test('corrupt state is not overwritten and dead-process locks can recover', async t => {
  const dir = await temporary(t); await fs.writeFile(path.join(dir, 'state.json'), 'not json');
  await assert.rejects(readState(dir), /state is invalid/);
  assert.equal(await fs.readFile(path.join(dir, 'state.json'), 'utf8'), 'not json');
  await fs.writeFile(path.join(dir, 'check.lock'), '2147483647');
  assert.equal(await withLock(dir, async () => 42), 42);
});

test('notification text is passed as data to native tools, never executed as code', async () => {
  const calls = [], message = { title: '" & do shell script "bad', body: '$(touch /tmp/never)\n\x1b[31m data' };
  await notifyNative(message, 'darwin', async (...args) => calls.push(args));
  assert.equal(calls[0][0], '/usr/bin/osascript');
  assert.equal(calls[0][1].length, 4); assert.equal(calls[0][1][2], message.title);
  assert.ok(!calls[0][1][1].includes('bad')); assert.ok(!calls[0][1][3].includes('\x1b'));
  await notifyNative(message, 'linux', async (...args) => calls.push(args));
  assert.equal(calls[1][1][1], '--');
});

test('launchd definition has an isolated identity, exact binary and only needed environment', () => {
  const env = { PATH: '/opt/node/bin:/usr/bin', HTTPS_PROXY: 'http://127.0.0.1:7890', HTTP_PROXY: 'http://127.0.0.1:7890', SECRET_TOKEN: 'must-not-copy', HOME: '/should-not-copy' };
  const service = serviceDefinition('/tmp/codex & one', '/tmp/bin with space/codex-auth', env, '/tmp/user');
  assert.match(service.plist, /<string>resets<\/string><string>check<\/string>/);
  assert.ok(service.plist.includes('codex &amp; one')); assert.ok(service.plist.includes('127.0.0.1:7890'));
  assert.ok(!service.plist.includes('must-not-copy')); assert.ok(!service.plist.includes('should-not-copy'));
  assert.notEqual(service.label, serviceDefinition('/tmp/another', '/bin/tool', {}, '/tmp/user').label);
  assert.ok(service.file.startsWith('/tmp/user/Library/LaunchAgents/')); assert.match(service.plist, /StartInterval/);
});

test('rendering keeps stages, attribution, timestamps and safe narrow output', () => {
  const s = fresh(); s.status.data.latest_reset.text = 'Hello\x1b[2J\u202efeed 你好 😀 '.repeat(10);
  s.status.data.scheduled_reset = { ...reset(), status: 'scheduled', scheduled_for: null }; s.status.data.active_watch = forecast();
  for (const width of [24, 40, 80, 100]) {
    const output = render(s, { width, now }); assert.ok(!output.includes('\x1b')); assert.ok(!output.includes('\u202e'));
    for (const line of output.split('\n')) { const cells = [...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment(line)].reduce((n, {segment}) => n + (/[\p{Extended_Pictographic}\p{Script=Han}]/u.test(segment) ? 2 : 1), 0); assert.ok(cells <= width); }
  }
  const text = render(s, { now }); assert.match(text, /REPORTED EXECUTED/); assert.match(text, /awaiting execution/); assert.match(text, /AI prediction/); assert.match(text, /codex-resets.com/); assert.match(text, /account reset-credit balances may differ/);
});

test('malformed event identities, insecure links and unknown kinds are rejected', () => {
  for (const modify of [p => p.data.latest_reset.id = '', p => p.data.latest_reset.reset_type = 'mystery', p => p.data.latest_reset.source.url = 'javascript:alert(1)', p => p.data.active_watch = {}, p => delete p.data.scheduled_reset]) {
    const p = payload(); modify(p); assert.throws(() => validateStatus(p), /Invalid/);
  }
});

test('service enable/disable persists a quiet baseline and rolls back failed installation', async t => {
  const { setEnabled } = await import('../src/resets.mjs');
  const root = await temporary(t);
  const service = serviceDefinition(path.join(root, 'codex'), '/test/codex-auth', {}, root);
  let loaded = false, failBootstrap = false;
  const calls = [];
  const runner = async (_, args) => {
    calls.push(args[0]);
    if (args[0] === 'print' && !loaded) throw Error('not loaded');
    if (args[0] === 'bootout') loaded = false;
    if (args[0] === 'bootstrap') { if (failBootstrap) throw Error('bootstrap failed'); loaded = true; }
  };
  const options = { platform: 'darwin', runner, uid: 501, now, fetchImpl: async () => response() };
  await setEnabled(service, true, options);
  let state = await readState(service.dir);
  assert.equal(state.enabled, true); assert.equal(state.initialized, true); assert.equal(state.seen.length, 1); assert.equal(loaded, true);
  const installed = await fs.readFile(service.file, 'utf8'); assert.match(installed, /resets/);
  // Re-enabling retains seen IDs rather than losing notifications already queued.
  state.status = payload('new-but-unseen'); await writeState(service.dir, state);
  await setEnabled(service, true, options); assert.equal((await readState(service.dir)).seen.length, 1);
  await setEnabled(service, false, options); assert.equal(loaded, false); assert.equal((await readState(service.dir)).enabled, false);
  await assert.rejects(fs.access(service.file));
  failBootstrap = true;
  await assert.rejects(setEnabled(service, true, options), /bootstrap failed/);
  assert.equal((await readState(service.dir)).enabled, false); await assert.rejects(fs.access(service.file));
  assert.ok(calls.includes('bootstrap') && calls.includes('bootout'));
});

test('oversized streamed bodies and huge invalid Retry-After values remain bounded', async () => {
  const s = emptyState();
  await refresh(s, { now, fetchImpl: async () => new Response('x'.repeat(300000)) });
  assert.match(s.last_error, /large/);
  assert.ok(Number.isFinite(retryDelay('9'.repeat(400), now, 1)));
  assert.ok(retryDelay('9007199254740991', now, 1) + now <= Number.MAX_SAFE_INTEGER);
});
