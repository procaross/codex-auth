#!/bin/bash
set -euo pipefail
if [[ $EUID != 0 || ! -t 0 ]]; then
  echo 'Run this script as root in an interactive terminal.' >&2
  exit 1
fi
base=/etc/codex-reset-slack
umask 077
secret_file=$(mktemp "$base/webhook.XXXXXX")
trap 'rm -f "$secret_file"; unset webhook_value' EXIT
printf 'Paste the Slack webhook URL (hidden), then press Enter: '
IFS= read -r -s webhook_value
printf '\n'
printf '%s\n' "$webhook_value" > "$secret_file"
unset webhook_value
/usr/local/bin/node --input-type=module - "$secret_file" <<'JS'
import { readWebhook } from '/opt/codex-reset-slack/current/services/slack-reset/worker.mjs';
try { await readWebhook(process.argv[2]); }
catch { console.error('Invalid Slack webhook; the existing configuration was preserved.'); process.exit(1); }
JS
chown codex-reset-slack:codex-reset-slack "$secret_file"
chmod 0600 "$secret_file"
mv -f "$secret_file" "$base/webhook"
echo 'Webhook stored privately. No secret was printed.'
