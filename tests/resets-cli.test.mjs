import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { emptyState } from '../src/resets.mjs';

const executable = process.env.CODEX_AUTH_TEST_BINARY || path.resolve('zig-out', 'bin', process.platform === 'win32' ? 'codex-auth.exe' : 'codex-auth');

test('built CLI: cached JSON, help, errors and notification status never touch auth or auto-switch', async t => {
  const home = await fs.mkdtemp(path.join(os.tmpdir(), 'codex-reset-cli-'));
  t.after(() => fs.rm(home, { recursive: true, force: true }));
  await fs.mkdir(path.join(home, 'reset-news'));
  const auth = '{"tokens":{"access_token":"test-private-token-must-not-leave"}}';
  await fs.writeFile(path.join(home, 'auth.json'), auth);
  const state = emptyState();
  state.checked_at = Date.now(); state.next_poll_at = Date.now() + 300000;
  state.status = { data: { latest_reset: null, scheduled_reset: null, active_watch: null, stats: { total: 0 } }, meta: { api_version: 'v1', generated_at: new Date().toISOString() } };
  await fs.writeFile(path.join(home, 'reset-news', 'state.json'), JSON.stringify(state));
  // A broken proxy proves these paths are offline. No service-reconcile override:
  // the command itself must stay independent of the account auto-switch service.
  const env = { ...process.env, CODEX_HOME: home, CODEX_AUTH_NODE_EXECUTABLE: process.execPath, HTTPS_PROXY: 'http://127.0.0.1:1', HTTP_PROXY: 'http://127.0.0.1:1' };
  delete env.CODEX_AUTH_SKIP_SERVICE_RECONCILE;
  const run = args => spawnSync(executable, args, { env, encoding: 'utf8', timeout: 15000 });
  const json = run(['resets', '--cached', '--json']); assert.equal(json.status, 0, json.stderr);
  assert.equal(JSON.parse(json.stdout).data.stats.total, 0); assert.ok(!json.stdout.includes('test-private-token'));
  const text = run(['resets', '--cached']); assert.equal(text.status, 0, text.stderr); assert.match(text.stdout, /RESET NEWS/); assert.ok(!text.stdout.includes('\x1b'));
  const help = run(['resets', '--help']); assert.equal(help.status, 0, help.stderr); assert.match(help.stdout, /notify/);
  const status = run(['resets', 'notify', 'status']); assert.equal(status.status, 0, status.stderr); assert.match(status.stdout, /OFF/);
  const disabled = run(['resets', 'check']); assert.equal(disabled.status, 0, disabled.stderr);
  for (const args of [['resets', '--cached', '--cached'], ['resets', 'notify', 'unknown'], ['resets', 'watch', '--json']]) assert.equal(run(args).status, 2);
  assert.equal(await fs.readFile(path.join(home, 'auth.json'), 'utf8'), auth);
  assert.ok(!(await fs.readdir(home)).includes('accounts'));
});
