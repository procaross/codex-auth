# Slack reset announcements

A small Node.js 22+ service posts Chinese reset announcements to a single Slack
channel. It uses the same public status feed as `codex-auth resets`; it does not
need Codex, a ChatGPT login, account files, or an OpenAI API key on the server.

## Slack app

Create an app at <https://api.slack.com/apps> using
[`slack-app-manifest.json`](slack-app-manifest.json), or create a blank app and
enable Incoming Webhooks. Install it into the intended workspace and select the
notification channel. A private channel must be selected by a member of it.
Use [`notification-icon.png`](../../docs/assets/notification-icon.png) as the app
icon. Incoming webhooks use the app's name/icon and the channel selected during
installation; the worker cannot override these at send time.

Only the `incoming-webhook` scope is needed. No message-reading scopes, Socket
Mode, slash commands, event subscriptions or public HTTP endpoint are used.
Keep the generated webhook URL out of source control, command arguments and logs.

## Linux / systemd deployment

The supplied units use `/usr/local/bin/node`; adjust that path if Node is installed
elsewhere. Install a reviewed checkout under an immutable release directory such
as `/opt/codex-reset-slack/releases/<commit>` and point `current` to it. Create a
system user/group `codex-reset-slack` without a login shell. Create
`/etc/codex-reset-slack` owned by root with group `codex-reset-slack`, mode `0750`.

Create `/etc/codex-reset-slack/service.env` (root-owned, mode `0640`):

```dotenv
SLACK_DESTINATION=WORKSPACE_ID/CHANNEL_ID
```

This identifies the intended channel for state isolation; the webhook installation
controls the actual recipient. Store its URL in
`/etc/codex-reset-slack/webhook`, owned by `codex-reset-slack`, mode `0600`.
Use a protected interactive input, not shell history or an inline environment
variable. `configure-webhook.sh` can be run as root in an interactive SSH terminal
for hidden input; it validates the URL locally and stores it atomically.

Install the `.service` and `.timer` files into `/etc/systemd/system`, then:

```sh
sudo systemctl daemon-reload
sudo systemctl start codex-reset-slack.service
sudo systemctl enable --now codex-reset-slack.timer
sudo journalctl -u codex-reset-slack.service -n 10 --no-pager
```

The first successful check silently records the existing feed as a baseline.
No historical announcement is posted during setup. The timer wakes every minute;
the worker only fetches the API every five minutes and honors `ETag`, backoff and
`Retry-After`. A persistent outbox retries failed Slack posts even if a newer feed
snapshot arrives. Expired queued forecasts and plans already reported as executed
are discarded. An unchanged feed remains silent.

To send one clearly labeled setup test (does not modify the baseline):

```sh
sudo -u codex-reset-slack env TZ=Asia/Shanghai \
  RESET_STATE_DIR=/var/lib/codex-reset-slack \
  SLACK_WEBHOOK_FILE=/etc/codex-reset-slack/webhook \
  /usr/local/bin/node /opt/codex-reset-slack/current/services/slack-reset/worker.mjs test
```

Status and failures are visible in the service journal and through
`worker.mjs status` with `RESET_STATE_DIR` set. State is stored privately in
`/var/lib/codex-reset-slack/state.json` and must be preserved across deployments.
Use a separate state directory when changing channels. To stop delivery:

```sh
sudo systemctl disable --now codex-reset-slack.timer
```

For rollback, stop the timer, wait for the current oneshot to finish, point
`current` to the previous release, and start the timer. Preserve the state file
and webhook. Do not copy a macOS localhost proxy setting onto a remote server.

## Delivery limits

The public API reports announcements and predictions, not individual account
eligibility or reset-credit balances. It is a third-party feed; the source link
is included in each message. Only the latest status snapshot is polled, so events
that appear and disappear entirely while the server is offline can be missed.
A delivery acknowledged by Slack is recorded immediately. An ambiguous network
failure, or a crash between Slack acceptance and state persistence, can cause an
occasional duplicate on retry; incoming webhooks provide no idempotency receipt.
The stable event identifier in each message helps identify such duplicates.

## Tests

```sh
node --test tests/resets.test.mjs tests/slack-reset.test.mjs
```

Tests use fake public-feed responses, fake Slack responses and isolated temporary
state. They cover quiet setup, restarts, overlapping runs, persistent retry/backoff,
outbox recovery, stale forecast suppression, Chinese copy and secret redaction.
