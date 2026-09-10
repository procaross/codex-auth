import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { runCheck, slackMessage, postSlack, SlackError, readWebhook, validateWebhook } from '../services/slack-reset/worker.mjs';
import { readState, POLL_MS } from '../src/resets.mjs';
const now = Date.parse('2026-09-10T10:00:00Z');
const webhook = 'https://hooks.slack.com/services/TEST/ONLY/FAKE';
const reset = id => ({ id, reset_type: 'regular', announced_at: '2026-09-10T09:00:00Z', text: '<!channel> untrusted feed text', source: { type: 'observed', url: 'https://codex-resets.com' } });
const payload = id => ({ data: { latest_reset: reset(id), scheduled_reset: null, active_watch: null, stats: { total: 1 } }, meta: { api_version: 'v1', generated_at: new Date(now).toISOString() } });
const response = id => new Response(JSON.stringify(payload(id)));
async function setup(t) { const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-slack-test-')); t.after(() => fs.rm(dir, { recursive: true, force: true })); return { dir, destination: 'workspace/channel', now, pause: async () => {} }; }

test('baseline is silent; first new event sends Chinese message; restart is deduplicated', async t => {
  const opts = await setup(t); const sent = [];
  await runCheck({ ...opts, fetchImpl: async () => response('old'), send: async m => sent.push(m) });
  assert.equal(sent.length, 0);
  await runCheck({ ...opts, now: now + POLL_MS, fetchImpl: async () => response('new'), send: async m => sent.push(m) });
  assert.equal(sent.length, 1); assert.match(sent[0].text, /新的额度重置公告/); assert.ok(!JSON.stringify(sent).includes('<!channel>'));
  assert.equal(sent[0].mrkdwn, false); assert.equal(sent[0].blocks[0].text.type, 'plain_text');
  await runCheck({ ...opts, now: now + POLL_MS * 2, fetchImpl: async () => response('new'), send: async m => sent.push(m) });
  assert.equal(sent.length, 1); assert.equal((await readState(opts.dir)).slack.pending.length, 0);
});

test('outbox survives feed replacement and offline polling; Slack Retry-After survives restart', async t => {
  const opts = await setup(t); let attempts = 0;
  await runCheck({ ...opts, fetchImpl: async () => response('old'), send: async () => assert.fail() });
  await runCheck({ ...opts, now: now + POLL_MS, fetchImpl: async () => response('a'), send: async () => { attempts++; throw new SlackError('Slack returned HTTP 429.', '3600'); } });
  await runCheck({ ...opts, now: now + POLL_MS * 2, fetchImpl: async () => response('b'), send: async () => attempts++ });
  assert.equal(attempts, 1);
  let s = await readState(opts.dir); assert.equal(s.slack.pending.length, 2); assert.equal(s.slack.next_send_at, now + POLL_MS + 3600000);
  const sent = [];
  await runCheck({ ...opts, now: now + POLL_MS + 3600000, fetchImpl: async () => { throw Error('offline'); }, send: async m => sent.push(m) });
  assert.equal(sent.length, 2); s = await readState(opts.dir); assert.equal(s.slack.pending.length, 0); assert.match(s.last_error, /offline/);
});

test('partial success persists immediately and simultaneous checks do not duplicate', async t => {
  const opts = await setup(t);
  await runCheck({ ...opts, fetchImpl: async () => response('old'), send: async () => assert.fail() });
  const p = payload('new'); p.data.scheduled_reset = { ...reset('plan'), status: 'scheduled', scheduled_for: null };
  let count = 0;
  const next = { ...opts, now: now + POLL_MS, fetchImpl: async () => new Response(JSON.stringify(p)), send: async () => { if (++count === 2) throw new SlackError('offline'); } };
  await Promise.all([runCheck(next), runCheck(next)]);
  assert.equal(count, 2); assert.equal((await readState(opts.dir)).slack.pending.length, 1);
  await runCheck({ ...next, now: now + POLL_MS * 2, send: async m => { count++; assert.match(m.text, /计划/); } });
  assert.equal(count, 3);
});

test('expired forecasts and plans superseded by execution are not delivered after an outage', async t => {
  const opts = await setup(t);
  await runCheck({ ...opts, fetchImpl: async () => response('old'), send: async () => assert.fail() });
  const p = payload('old'); p.data.scheduled_reset = { ...reset('same'), status: 'scheduled', scheduled_for: null };
  p.data.active_watch = { level: 'strong', reset_chance_percent: 70, forecast_window: 'soon', observed_at: new Date(now).toISOString(), expires_at: new Date(now + 2 * POLL_MS).toISOString(), text: 'forecast', source: { type: 'observed' } };
  await runCheck({ ...opts, now: now + POLL_MS, fetchImpl: async () => new Response(JSON.stringify(p)), send: async () => { throw new SlackError('offline'); } });
  const sent = [];
  await runCheck({ ...opts, now: now + POLL_MS * 2, fetchImpl: async () => response('same'), send: async m => sent.push(m) });
  assert.equal(sent.length, 1); assert.match(sent[0].text, /新的额度重置公告/);
});

test('webhook transport limits destination, disables redirects and never leaks the secret on failure', async () => {
  for (const value of ['http://hooks.slack.com/services/T/B/X', 'https://evil.test/services/T/B/X', webhook + '?x=1', 'https://user:pass@hooks.slack.com/services/T/B/X', webhook + '#secret']) assert.throws(() => validateWebhook(value), /valid Slack/);
  let calls = 0;
  await postSlack(webhook, slackMessage(null, now), async (url, options) => {
    calls++; assert.equal(url, webhook); assert.equal(options.redirect, 'error'); assert.equal(options.method, 'POST'); assert.ok(options.signal); return new Response('ok');
  });
  assert.equal(calls, 1);
  await assert.rejects(postSlack(webhook, {}, async () => { throw Error(webhook); }), error => !error.message.includes(webhook) && error instanceof SlackError);
  await assert.rejects(postSlack(webhook, {}, async () => new Response(webhook, { status: 429, headers: { 'retry-after': '600' } })), error => error.retryAfter === '600' && !error.message.includes(webhook));
  await assert.rejects(postSlack(webhook, {}, async () => new Response('not ok')), /did not accept/);
  await assert.rejects(postSlack(webhook, {}, async () => new Response('x'.repeat(2048))), /invalid receipt/);
});

test('webhook file is private and changing channels cannot reuse existing delivery history', async t => {
  const opts = await setup(t); const file = path.join(opts.dir, 'webhook'); await fs.writeFile(file, webhook, { mode: 0o600 });
  assert.equal(await readWebhook(file), webhook); await fs.chmod(file, 0o644); await assert.rejects(readWebhook(file), /private/);
  await runCheck({ ...opts, fetchImpl: async () => response('old'), send: async () => assert.fail() });
  await assert.rejects(runCheck({ ...opts, destination: 'different/channel', send: async () => assert.fail() }), /Destination changed/);
});

test('test message is explicit and contains source link plus UTC+8 time', () => {
  const p = slackMessage(null, now); assert.match(p.text, /测试消息/); assert.match(p.text, /不代表发生了新的重置/);
  assert.equal(p.blocks[2].elements[0].url, 'https://codex-resets.com'); assert.match(p.blocks[3].elements[0].text, /18:00 \(UTC\+8\)/);
});
