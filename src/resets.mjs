// Embedded in the Zig binary. This module only reads the public reset feed and
// its own state directory; it never opens auth.json or the account registry.
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';

const exec = promisify(execFile);
export const ENDPOINT = 'https://codex-resets.com/api/v1/status';
export const POLL_MS = 5 * 60 * 1000;
const MAX_BODY = 256 * 1024;
const hash = value => createHash('sha256').update(value).digest('hex');
export const clean = value => String(value ?? '').replace(/[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, ' ').replace(/\s+/gu, ' ').trim();
const stamp = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
const string = (value, max) => typeof value === 'string' && value.length <= max;
const object = value => value && typeof value === 'object' && !Array.isArray(value);
const requireValue = ok => { if (!ok) throw new Error('Invalid reset API response.'); };

export function validateStatus(payload) {
  requireValue(object(payload) && object(payload.data) && payload.meta?.api_version === 'v1' && stamp(payload.meta.generated_at));
  const data = payload.data;
  for (const key of ['latest_reset', 'scheduled_reset', 'active_watch']) requireValue(Object.hasOwn(data, key));
  const source = value => {
    requireValue(object(value) && ['x_post', 'observed'].includes(value.type));
    if (value.url !== undefined) {
      requireValue(string(value.url, 2048));
      try { requireValue(new URL(value.url).protocol === 'https:'); } catch { requireValue(false); }
    }
    if (value.type === 'x_post') requireValue(value.author === 'thsottiaux' && typeof value.url === 'string');
  };
  const reset = value => {
    requireValue(object(value) && string(value.id, 64) && value.id.length > 0 && ['regular', 'banked'].includes(value.reset_type));
    requireValue(stamp(value.announced_at) && string(value.text, 32000));
    source(value.source);
  };
  if (data.latest_reset !== null) reset(data.latest_reset);
  if (data.scheduled_reset !== null) {
    reset(data.scheduled_reset);
    requireValue(data.scheduled_reset.status === 'scheduled' && (data.scheduled_reset.scheduled_for === null || stamp(data.scheduled_reset.scheduled_for)));
  }
  if (data.active_watch !== null) {
    const w = data.active_watch;
    requireValue(object(w) && ['elevated', 'strong'].includes(w.level) && stamp(w.observed_at) && stamp(w.expires_at));
    requireValue(w.reset_chance_percent === null || (Number.isInteger(w.reset_chance_percent) && w.reset_chance_percent >= 0 && w.reset_chance_percent <= 100));
    requireValue(string(w.forecast_window, 1024) && string(w.text, 32000));
    source(w.source);
  }
  requireValue(object(data.stats) && Number.isInteger(data.stats.total) && data.stats.total >= 0);
  return payload;
}

export function events(payload, now) {
  if (!payload) return [];
  const { latest_reset: latest, scheduled_reset: scheduled, active_watch: watch } = payload.data;
  const result = [];
  // Include the stage in the identity so scheduled -> executed notifies again,
  // even when both entries refer to the same source post.
  for (const [stage, item] of [['executed', latest], ['scheduled', scheduled]]) {
    if (!item) continue;
    result.push({ key: hash(`${stage}:${item.id}:${item.reset_type}`), stage, item });
  }
  if (watch && Date.parse(watch.expires_at) > now) {
    result.push({ key: hash(`forecast:${watch.observed_at}:${watch.level}`), stage: 'forecast', item: watch });
  }
  return result;
}

export const emptyState = () => ({ version: 1, enabled: false, initialized: false, seen: [], status: null, etag: null, checked_at: null, next_poll_at: 0, failures: 0, last_error: null });

export async function readState(dir) {
  let bytes;
  try { bytes = await fs.readFile(path.join(dir, 'state.json')); }
  catch (error) { if (error.code === 'ENOENT') return emptyState(); throw error; }
  try {
    if (bytes.length > 1024 * 1024) throw new Error();
    const state = JSON.parse(bytes);
    if (state.version !== 1 || typeof state.enabled !== 'boolean' || typeof state.initialized !== 'boolean' ||
        !Array.isArray(state.seen) || state.seen.length > 4096 || state.seen.some(k => !/^[a-f0-9]{64}$/.test(k)) ||
        !Number.isFinite(state.next_poll_at) || !Number.isInteger(state.failures) || state.failures < 0 ||
        !(state.checked_at === null || Number.isFinite(state.checked_at)) ||
        !(state.etag === null || (string(state.etag, 256) && !/[\r\n]/.test(state.etag)))) throw new Error();
    if (state.status !== null) validateStatus(state.status);
    return state;
  } catch { throw new Error(`Reset state is invalid: ${path.join(dir, 'state.json')}. Move it aside to start a new notification baseline.`); }
}

export async function writeState(dir, state) {
  await atomicWrite(path.join(dir, 'state.json'), JSON.stringify(state, null, 2) + '\n');
}

async function atomicWrite(file, data) {
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, data, { mode: 0o600, flag: 'wx' });
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, { force: true }); }
}

export async function withLock(dir, fn) {
  await fs.mkdir(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, 'check.lock');
  let handle;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { handle = await fs.open(file, 'wx', 0o600); break; }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      try {
        const info = await fs.stat(file);
        const pid = Number(await fs.readFile(file, 'utf8'));
        let alive = true;
        if (Number.isInteger(pid) && pid > 0) {
          try { process.kill(pid, 0); } catch (e) { alive = e.code !== 'ESRCH'; }
        }
        if (!alive || (Date.now() - info.mtimeMs > 120000 && !(pid > 0))) await fs.rm(file, { force: true });
      } catch (e) { if (e.code !== 'ENOENT') throw e; }
      await delay(200);
    }
  }
  if (!handle) throw new Error('Another reset check is still running. Try again shortly.');
  try { await handle.writeFile(String(process.pid)); return await fn(); }
  finally { await handle.close(); await fs.rm(file, { force: true }); }
}

export function retryDelay(header, now, failures) {
  const value = header?.trim();
  let milliseconds = null;
  if (value && /^\d+$/.test(value)) milliseconds = Number(value) * 1000;
  else if (value && stamp(value)) milliseconds = Date.parse(value) - now;
  // Respect Retry-After, including when it exceeds the normal backoff ceiling.
  if (milliseconds !== null && !Number.isFinite(milliseconds)) milliseconds = null;
  return Math.min(Number.MAX_SAFE_INTEGER - now, Math.max(POLL_MS, milliseconds ?? Math.min(3600000, POLL_MS * 2 ** Math.min(failures - 1, 4))));
}

async function readResponse(response) {
  if (Number(response.headers.get('content-length')) > MAX_BODY) throw new Error('Reset API response is too large.');
  const reader = response.body?.getReader();
  if (!reader) throw new Error('Reset API returned an empty response.');
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY) throw new Error('Reset API response is too large.');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export async function refresh(state, { now = Date.now(), fetchImpl = fetch } = {}) {
  if (now < state.next_poll_at) return false;
  let retryAfter = null;
  try {
    const headers = { Accept: 'application/json', 'User-Agent': 'codex-auth-reset-news/1.0' };
    if (state.etag && state.status) headers['If-None-Match'] = state.etag;
    const response = await fetchImpl(ENDPOINT, { headers, redirect: 'error', signal: AbortSignal.timeout(20000) });
    retryAfter = response.headers.get('retry-after');
    if (response.status === 304 && state.status) {
      await response.body?.cancel();
    } else {
      if (response.status !== 200) { await response.body?.cancel(); throw new Error(`Reset API returned HTTP ${response.status}.`); }
      const status = validateStatus(await readResponse(response));
      // A stale CDN response must not roll the feed back after a newer response.
      if (state.status && Date.parse(status.meta.generated_at) < Date.parse(state.status.meta.generated_at)) throw new Error('Reset API returned an older snapshot; keeping the current cache.');
      state.status = status;
      const etag = response.headers.get('etag');
      state.etag = etag && etag.length <= 256 && !/[\r\n]/.test(etag) ? etag : null;
    }
    state.checked_at = now;
    state.next_poll_at = now + POLL_MS;
    state.failures = 0;
    state.last_error = null;
    return true;
  } catch (error) {
    state.failures++;
    state.next_poll_at = now + retryDelay(retryAfter, now, state.failures);
    state.last_error = clean(error.message).slice(0, 300);
    return false;
  }
}

const resetType = item => item.reset_type === 'banked' ? 'Banked reset credit' : 'Regular usage reset';
export function notification(event) {
  const item = event.item;
  const banked = item.reset_type === 'banked';
  let title, body;
  if (event.stage === 'executed') {
    title = banked ? '新的备用重置公告' : '新的额度重置公告';
    body = banked
      ? '发现备用重置次数发放或补发消息。具体适用范围以公告为准。'
      : '发现一条新的额度重置消息。具体适用范围以公告为准。';
  } else if (event.stage === 'scheduled') {
    title = banked ? '备用重置次数发放计划' : '新的额度重置计划';
    body = item.scheduled_for
      ? `预计时间：${notificationTime(item.scheduled_for)}。当前仍在等待执行。`
      : '执行时间尚未公布，当前仍在等待执行。';
  } else {
    title = 'AI 重置预测 · 尚未确认';
    body = item.reset_chance_percent === null
      ? '出现新的重置预测，尚无概率估计。这是 AI 预测，请以正式公告为准。'
      : `预估重置概率为 ${item.reset_chance_percent}%。这是 AI 预测，请以正式公告为准。`;
  }
  // Chinese summaries use structured fields. The original wording and detailed
  // eligibility stay at the source; no machine translation service is called.
  return { title, body: body + ' 点击查看原文。', url: item.source.url || 'https://codex-resets.com' };
}

function notificationTime(value) {
  const date = new Date(value);
  return new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', timeZoneName: 'short' }).format(date);
}

export function macNotifierExecutable(cliExecutable = process.argv[3]) {
  if (!cliExecutable || !path.isAbsolute(cliExecutable)) throw new Error('The Codex Auth executable path is unavailable.');
  return path.join(path.dirname(cliExecutable), 'Codex Auth.app', 'Contents', 'MacOS', 'CodexAuthNotifier');
}

export async function runMacNotifier(args, runner = exec, executable = macNotifierExecutable()) {
  let result;
  try { result = await runner(executable, args, { timeout: 45000 }); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error('The Codex Auth notification app is missing. Run scripts/build-macos-notifier.sh with the CLI binary directory.');
    let message;
    try { message = JSON.parse(error.stdout).error; } catch {}
    throw new Error(clean(message || error.message));
  }
  let receipt;
  try { receipt = JSON.parse(result.stdout); } catch { throw new Error('The Codex Auth notification app returned an invalid receipt.'); }
  if (receipt.error) throw new Error(clean(receipt.error));
  return receipt;
}

export async function notifyNative(message, platform = process.platform, runner = exec, helperExecutable) {
  const title = clean(message.title), body = clean(message.body);
  let url = '';
  try { const parsed = new URL(message.url); if (parsed.protocol === 'https:') url = parsed.href; } catch {}
  if (platform === 'darwin') {
    // Arguments, never interpolation into AppleScript or a shell command.
    const receipt = await runMacNotifier(['--send', title, body, url], runner, helperExecutable);
    if (!receipt.accepted) throw new Error('The system did not accept the notification.');
  } else if (platform === 'linux') {
    await runner('notify-send', ['--app-name=Codex Auth', '--', title, body], { timeout: 10000 });
  } else throw new Error('System notifications support macOS and Linux (notify-send).');
}

export async function deliver(state, { now = Date.now(), notify = notifyNative, save = async () => {} } = {}) {
  if (!state.status) return;
  const current = events(state.status, now);
  if (!state.initialized) {
    state.seen = current.map(event => event.key);
    state.initialized = true;
    await save();
    return;
  }
  for (const event of current) {
    if (state.seen.includes(event.key)) continue;
    // Persist each successful delivery, so a failure on the next event does not
    // resend this one on the next poll. Failed notifications remain retryable.
    await notify(notification(event));
    state.seen.push(event.key);
    state.seen = state.seen.slice(-4096);
    await save();
  }
}

export async function check(dir, { foreground = false, now = Date.now(), fetchImpl = fetch, notify = notifyNative } = {}) {
  return withLock(dir, async () => {
    const state = await readState(dir);
    if (!state.enabled && !foreground) return state;
    await refresh(state, { now, fetchImpl });
    await writeState(dir, state);
    // On a failed fetch use no stale announcement to trigger a new notification.
    if (!state.last_error) {
      try {
        await deliver(state, { now, notify, save: () => writeState(dir, state) });
        state.notification_error = null;
      } catch (error) { state.notification_error = clean(error.message).slice(0, 300); }
      await writeState(dir, state);
    }
    return state;
  });
}

export function serviceDefinition(codexHome, executable, env = process.env, userHome = os.homedir()) {
  const dir = path.join(codexHome, 'reset-news');
  const label = `com.procaross.codex-auth.resets.${hash(path.resolve(codexHome)).slice(0, 12)}`;
  const xml = value => String(value).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
  const environment = { CODEX_HOME: codexHome, CODEX_AUTH_NODE_EXECUTABLE: process.execPath, NODE_USE_ENV_PROXY: '1' };
  // Carry only the runtime path and proxy configuration into launchd.
  for (const key of ['PATH', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy']) {
    if (env[key]) environment[key] = env[key];
  }
  const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(executable)}</string><string>resets</string><string>check</string></array>
<key>EnvironmentVariables</key><dict>${Object.entries(environment).map(([k, v]) => `<key>${xml(k)}</key><string>${xml(v)}</string>`).join('')}</dict>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>300</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>\n`;
  return { dir, label, file: path.join(userHome, 'Library', 'LaunchAgents', `${label}.plist`), plist };
}

async function serviceLoaded(service, runner = exec, uid = process.getuid()) {
  try { await runner('/bin/launchctl', ['print', `gui/${uid}/${service.label}`], { timeout: 10000 }); return true; }
  catch { return false; }
}

export async function setEnabled(service, enabled, { platform = process.platform, runner = exec, uid = process.getuid?.(), fetchImpl = fetch, now = Date.now() } = {}) {
  if (platform !== 'darwin') throw new Error('Background notifications currently support macOS. Use `codex-auth resets watch` on Linux.');
  await withLock(service.dir, async () => {
    const state = await readState(service.dir);
    if (enabled) {
      await refresh(state, { fetchImpl, now });
      if (!state.status || state.last_error) { await writeState(service.dir, state); throw new Error(state.last_error || 'No reset data is available yet. Try again later.'); }
      if (!state.enabled) {
        state.seen = events(state.status, now).map(e => e.key);
        state.initialized = true;
      }
      await fs.mkdir(path.dirname(service.file), { recursive: true });
      let previous = null;
      try { previous = await fs.readFile(service.file); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      const wasLoaded = await serviceLoaded(service, runner, uid);
      if (wasLoaded) await runner('/bin/launchctl', ['bootout', `gui/${uid}`, service.file], { timeout: 10000 });
      let installed = false;
      try {
        await atomicWrite(service.file, service.plist);
        await runner('/bin/launchctl', ['bootstrap', `gui/${uid}`, service.file], { timeout: 10000 });
        installed = true;
        state.enabled = true;
        await writeState(service.dir, state);
      } catch (error) {
        // Stop a newly installed job before restoring a previous definition.
        if (installed) await runner('/bin/launchctl', ['bootout', `gui/${uid}`, service.file], { timeout: 10000 }).catch(() => {});
        // Restore the previous definition if installation fails.
        if (previous) await atomicWrite(service.file, previous);
        else await fs.rm(service.file, { force: true });
        if (previous && wasLoaded) await runner('/bin/launchctl', ['bootstrap', `gui/${uid}`, service.file], { timeout: 10000 }).catch(() => {});
        throw error;
      }
    } else {
      if (await serviceLoaded(service, runner, uid)) await runner('/bin/launchctl', ['bootout', `gui/${uid}`, service.file], { timeout: 10000 });
      await fs.rm(service.file, { force: true });
      state.enabled = false;
      await writeState(service.dir, state);
    }
  });
}

// Wrap using grapheme boundaries; wide glyphs consume two terminal cells.
const segments = new Intl.Segmenter('en', { granularity: 'grapheme' });
const cellWidth = char => /[\p{Extended_Pictographic}\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\uff01-\uff60]/u.test(char) ? 2 : 1;
export function wrap(value, width) {
  const lines = []; let line = [], cells = 0;
  for (const { segment } of segments.segment(clean(value))) {
    const count = cellWidth(segment);
    if (cells + count > width) {
      // Prefer word boundaries for prose; hard-wrap long URLs and identifiers.
      const space = line.lastIndexOf(' ');
      if (space > 0) {
        lines.push(line.slice(0, space).join(''));
        line = line.slice(space + 1);
        cells = line.reduce((total, char) => total + cellWidth(char), 0);
      } else {
        lines.push(line.join('')); line = []; cells = 0;
      }
    }
    if (!line.length && segment === ' ') continue;
    line.push(segment); cells += count;
  }
  if (line.length || !lines.length) lines.push(line.join(''));
  return lines;
}
const localTime = value => {
  if (!value) return 'unknown';
  const date = new Date(value);
  const pad = n => String(n).padStart(2, '0');
  const offset = -date.getTimezoneOffset();
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())} ${offset < 0 ? '-' : '+'}${pad(Math.floor(Math.abs(offset) / 60))}${pad(Math.abs(offset) % 60)}`;
};

export function render(state, { width = 88, color = false, now = Date.now() } = {}) {
  width = Math.max(24, Math.min(100, width));
  const output = [];
  const line = (text = '', style = '') => {
    for (const part of wrap(text, width)) output.push(color && style ? `\x1b[${style}m${part}\x1b[0m` : part);
  };
  const rule = () => line('─'.repeat(width), '38;2;165;181;185');
  line('CODEX / RESET NEWS', '1;38;2;8;131;153');
  line('Public announcements · codex-resets.com', '38;2;124;139;146');
  rule();
  if (!state.status) line('No cached reset news. Run `codex-auth resets` to fetch it.');
  else {
    if (state.last_error || now - state.checked_at >= POLL_MS) line('CACHED SNAPSHOT · last successful check ' + localTime(state.checked_at), '38;2;185;101;86');
    const data = state.status.data;
    const reset = (title, item) => {
      line(); line(title, '1;38;2;8;131;153');
      if (!item) { line('None reported.', '38;2;124;139;146'); return; }
      line(resetType(item), '1');
      line('Announced  ' + localTime(item.announced_at), '38;2;124;139;146');
      if (title.startsWith('SCHEDULED')) line('Expected   ' + localTime(item.scheduled_for) + ' · awaiting execution');
      line(item.text);
      line(item.source.url || 'Source: community observation', '38;2;124;139;146');
    };
    reset('LATEST / REPORTED EXECUTED', data.latest_reset);
    reset('SCHEDULED / PENDING', data.scheduled_reset);
    line(); line('WATCH / AI FORECAST', '1;38;2;8;131;153');
    const watch = data.active_watch;
    if (!watch) line('No active forecast.', '38;2;124;139;146');
    else {
      line(`${Date.parse(watch.expires_at) <= now ? 'Expired' : watch.level.toUpperCase()} · ${watch.reset_chance_percent === null ? 'chance unavailable' : `${watch.reset_chance_percent}% estimated chance`} · ${watch.forecast_window}`);
      line('Expires    ' + localTime(watch.expires_at), '38;2;124;139;146');
      line(watch.text); line('AI prediction, not an official commitment.', '38;2;185;101;86');
      line(watch.source.url || 'Source: community observation', '38;2;124;139;146');
    }
    line(); rule();
    line(`${data.stats.total} recorded resets · Checked ${localTime(state.checked_at)}`, '38;2;124;139;146');
  }
  if (state.last_error) line(state.last_error, '38;2;185;101;86');
  if (state.notification_error) line('Notification error: ' + state.notification_error, '38;2;185;101;86');
  line(`Background notifications: ${state.enabled ? 'ON' : 'OFF'}`, '38;2;124;139;146');
  line('Public news; eligibility and account reset-credit balances may differ.', '38;2;124;139;146');
  return output.join('\n') + '\n';
}

export async function main(args) {
  try {
    const [major, minor] = process.versions.node.split('.').map(Number);
    if (major < 22) throw new Error('Node.js 22+ is required for reset news.');
    const hasProxy = ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy'].some(k => process.env[k]);
    if (hasProxy && !(major >= 24 || (major === 22 && minor >= 21))) throw new Error('Reset news via an environment proxy requires Node.js 22.21+ or 24+.');
    const [action, codexHome, executable, cacheMode, format] = args;
    const service = serviceDefinition(codexHome, executable);
    const helper = process.platform === 'darwin' ? macNotifierExecutable(executable) : undefined;
    const notify = message => notifyNative(message, process.platform, exec, helper);
    if (action === 'enable' || action === 'disable') {
      if (action === 'enable' && process.platform === 'darwin') {
        const receipt = await runMacNotifier(['--authorize'], exec, helper);
        if (!receipt.authorized) throw new Error('System notification permission was not granted.');
      }
      await setEnabled(service, action === 'enable');
      console.log(action === 'enable' ? 'Reset notifications enabled. A quiet baseline is saved; new announcements will trigger system notifications. Checks run every 5 minutes while signed in.' : 'Reset notifications disabled.');
    } else if (action === 'status') {
      const state = await readState(service.dir);
      const loaded = process.platform === 'darwin' && await serviceLoaded(service);
      console.log(`Reset notifications: ${state.enabled ? 'ON' : 'OFF'}\nBackground service: ${loaded ? 'loaded' : 'not loaded'}\nLast successful check: ${localTime(state.checked_at)}\nNext API check: ${state.next_poll_at ? localTime(state.next_poll_at) : 'not scheduled'}\nLast API error: ${clean(state.last_error) || 'none'}\nLast notification error: ${clean(state.notification_error) || 'none'}`);
    } else if (action === 'test_notification') {
      await notify({ title: '测试通知 · 已就绪', body: '这是一条测试通知。发现新的重置消息时，我会在这里提醒你。', url: 'https://codex-resets.com' });
      console.log('Test notification submitted. If no banner appears, check system notification permissions and Focus settings.');
    } else if (action === 'check' || action === 'watch') {
      if (action === 'watch') {
        if (!['darwin', 'linux'].includes(process.platform)) throw new Error('Foreground notifications support macOS and Linux.');
        console.log('Watching public reset news. First check is a quiet baseline. Press Ctrl+C to stop.');
      }
      do {
        const state = await check(service.dir, { foreground: action === 'watch', notify });
        if (state.last_error || state.notification_error) {
          console.error('Reset news: ' + clean(state.last_error || state.notification_error));
          if (action === 'check') process.exitCode = 1;
        }
        if (action === 'watch') await delay(POLL_MS);
      } while (action === 'watch');
    } else if (action === 'show') {
      const state = cacheMode === 'cached' ? await readState(service.dir) : await withLock(service.dir, async () => {
        const state = await readState(service.dir);
        await refresh(state);
        await writeState(service.dir, state);
        return state;
      });
      if (format === 'json') console.log(JSON.stringify({ ...state.status, cache: { checked_at: state.checked_at, stale: !state.status || !!state.last_error || Date.now() - state.checked_at >= POLL_MS, next_poll_at: state.next_poll_at, error: state.last_error }, notifications_enabled: state.enabled }, null, 2));
      else process.stdout.write(render(state, { width: process.stdout.columns || 88, color: !!process.stdout.isTTY && !Object.hasOwn(process.env, 'NO_COLOR') && process.env.TERM !== 'dumb' }));
      if (!state.status || state.last_error) process.exitCode = 1;
    } else throw new Error('Unknown reset command. Run `codex-auth resets --help`.');
  } catch (error) { console.error('Reset news: ' + clean(error.message)); process.exitCode = 1; }
}
