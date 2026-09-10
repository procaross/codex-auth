import * as fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { clean, events, notification, readState, writeState, withLock, refresh, retryDelay } from '../../src/resets.mjs';

export function validateWebhook(value) {
  let url;
  try { url = new URL(value.trim()); } catch {}
  if (!url || url.protocol !== 'https:' || url.hostname !== 'hooks.slack.com' || url.port || url.username || url.password || url.search || url.hash || !/^\/services\/[A-Za-z0-9]+\/[A-Za-z0-9]+\/[A-Za-z0-9]+$/.test(url.pathname)) {
    throw new Error('Configure a valid Slack incoming webhook in the protected webhook file.');
  }
  return url.href;
}

export async function readWebhook(file) {
  if (!file || !path.isAbsolute(file)) throw new Error('SLACK_WEBHOOK_FILE must be an absolute path.');
  const info = await fs.stat(file);
  if (!info.isFile() || info.size > 4096 || (info.mode & 0o077)) throw new Error('The webhook file must be private (mode 0600 or 0400).');
  return validateWebhook(await fs.readFile(file, 'utf8'));
}

const plain = text => ({ type: 'plain_text', text: clean(text), emoji: true });
export function slackMessage(event, now = Date.now()) {
  const message = event ? notification(event) : {
    title: '重置提醒已上线 · 测试消息',
    body: '我是 Codex Auth 重置提醒机器人。后台会持续检查公告，有新的重置消息就在这里用中文通知你。这是一条测试消息，不代表发生了新的重置。',
    url: 'https://codex-resets.com',
  };
  const time = new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai', dateStyle: 'medium', timeStyle: 'short' }).format(new Date(now));
  const body = message.body.replace(/ 点击查看原文。$/, '');
  return {
    text: `${message.title}\n${body}`,
    mrkdwn: false,
    unfurl_links: false,
    unfurl_media: false,
    blocks: [
      { type: 'header', text: plain(message.title) },
      { type: 'section', text: plain(body) },
      { type: 'actions', elements: [{ type: 'button', text: plain(event ? '查看公告原文' : '查看重置信息'), url: message.url }] },
      { type: 'context', elements: [plain(`来源：codex-resets.com · ${time} (UTC+8)${event ? ` · 消息 ${event.key.slice(0, 12)}` : ''}`)] },
    ],
  };
}

export class SlackError extends Error {
  constructor(message, retryAfter = null) { super(message); this.retryAfter = retryAfter; }
}

export async function postSlack(webhook, payload, fetchImpl = fetch) {
  const url = validateWebhook(webhook);
  try {
    const response = await fetchImpl(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload), redirect: 'error', signal: AbortSignal.timeout(20000),
    });
    if (response.status !== 200) {
      await response.body?.cancel();
      throw new SlackError(`Slack returned HTTP ${response.status}.`, response.headers.get('retry-after'));
    }
    // Never log response text or a thrown fetch error: either may contain the URL secret.
    const reader = response.body?.getReader();
    if (!reader) throw new SlackError('Slack returned an empty receipt.');
    const chunks = []; let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 1024) throw new SlackError('Slack returned an invalid receipt.');
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => {}); }
    if (Buffer.concat(chunks).toString('utf8').trim() !== 'ok') throw new SlackError('Slack did not accept the message.');
  } catch (error) {
    if (error instanceof SlackError) throw error;
    throw new SlackError('Slack delivery failed or timed out; it will be retried.');
  }
}

function deliveryState(state, destination) {
  state.slack ??= { destination, pending: [], failures: 0, next_send_at: 0, last_error: null, last_sent_at: null };
  const s = state.slack;
  if (s.destination !== destination) throw new Error('Destination changed. Use a separate state directory for a different Slack channel.');
  if (!Array.isArray(s.pending) || s.pending.length > 256 || !Number.isInteger(s.failures) || s.failures < 0 || !Number.isFinite(s.next_send_at) || s.pending.some(e => !/^[a-f0-9]{64}$/.test(e.key) || !['executed', 'scheduled', 'forecast'].includes(e.stage) || !e.item)) {
    throw new Error('Slack delivery state is invalid. Restore its backup before restarting.');
  }
  return s;
}

export async function runCheck({ dir, destination, now = Date.now(), fetchImpl = fetch, send, pause = delay }) {
  if (!destination) throw new Error('SLACK_DESTINATION must identify the workspace and channel.');
  return withLock(dir, async () => {
    const state = await readState(dir);
    const s = deliveryState(state, destination);
    const updated = await refresh(state, { now, fetchImpl });
    if (updated) {
      const current = events(state.status, now);
      if (!state.initialized) {
        state.seen = current.map(e => e.key);
        state.initialized = true;
      } else {
        const fresh = current.filter(e => !state.seen.includes(e.key) && !s.pending.some(p => p.key === e.key));
        if (s.pending.length + fresh.length > 256) throw new Error('Slack delivery queue is full. Resolve delivery failures before continuing.');
        s.pending.push(...fresh);
      }
    }
    // Persist the outbox before delivery, including API cache/backoff metadata.
    await writeState(dir, state);
    if (now < s.next_send_at) return state;
    let sent = 0;
    while (s.pending.length && sent < 3) {
      const event = s.pending[0];
      const expired = event.stage === 'forecast' && Date.parse(event.item.expires_at) <= now;
      const superseded = event.stage === 'scheduled' && state.status?.data.latest_reset?.id === event.item.id;
      if (!expired && !superseded) {
        try { await send(slackMessage(event, now)); }
        catch (error) {
          s.failures++;
          s.next_send_at = now + retryDelay(error instanceof SlackError ? error.retryAfter : null, now, s.failures);
          s.last_error = error instanceof SlackError ? error.message : 'Slack delivery failed; it will be retried.';
          await writeState(dir, state);
          return state;
        }
        s.last_sent_at = now;
        sent++;
      }
      state.seen = [...state.seen, event.key].slice(-4096);
      s.pending.shift();
      s.failures = 0; s.next_send_at = 0; s.last_error = null;
      await writeState(dir, state);
      if (s.pending.length && sent > 0 && sent < 3) await pause(1100);
    }
    return state;
  });
}

export function health(state) {
  return {
    initialized: state.initialized,
    checked_at: state.checked_at && new Date(state.checked_at).toISOString(),
    next_poll_at: new Date(state.next_poll_at).toISOString(),
    feed_error: state.last_error,
    destination: state.slack?.destination ?? null,
    pending: state.slack?.pending.length ?? 0,
    delivery_error: state.slack?.last_error ?? null,
    last_sent_at: state.slack?.last_sent_at ? new Date(state.slack.last_sent_at).toISOString() : null,
  };
}

export async function main(args = process.argv.slice(2), env = process.env) {
  const [action = 'check'] = args;
  if (args.length > 1 || !['check', 'status', 'test'].includes(action)) throw new Error('Usage: node services/slack-reset/worker.mjs [check|status|test]');
  const dir = env.RESET_STATE_DIR;
  if (!dir || !path.isAbsolute(dir)) throw new Error('RESET_STATE_DIR must be an absolute path.');
  if (action === 'status') { console.log(JSON.stringify(health(await readState(dir)))); return; }
  const webhook = await readWebhook(env.SLACK_WEBHOOK_FILE);
  const send = payload => postSlack(webhook, payload);
  if (action === 'test') { await send(slackMessage(null)); console.log('Slack accepted the test notification.'); return; }
  const state = await runCheck({ dir, destination: env.SLACK_DESTINATION, send });
  console.log(JSON.stringify(health(state)));
  if (state.last_error || state.slack.last_error) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => { console.error(clean(error.message)); process.exitCode = 1; });
}
