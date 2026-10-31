#!/bin/bash
# install.sh
# bench-bot を rsync の対象外 (/home/isucon/bench-bot) に入れて asia1 で常駐させる
# europe1, america1 には、ログを集めるための制限付き SSH 鍵だけを登録する
#
# 使い方:
#   DISCORD_WEBHOOK_URL=... bash provisioning/bench-bot/install.sh
#
# ポータルの Cookie と isuxbench.py は ~/protok から読み、asia1 にだけ置く。
# 秘密情報はリポジトリに入れない。
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROTOK_DIR="${PROTOK_DIR:-$HOME/protok}"
SSH_OPTS="-o StrictHostKeyChecking=no"
ASIA1=isucon@57.181.195.208
REMOTES=(isucon@35.74.6.16 isucon@35.74.122.15)
: "${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL を指定してください}"

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
chmod 600 "$ENV_FILE"
{
  echo "DISCORD_WEBHOOK_URL=$DISCORD_WEBHOOK_URL"
  grep -E '^ISUXPORTAL_(COOKIE|CSRF_TOKEN)=' "$PROTOK_DIR/.isuxportal.env"
} > "$ENV_FILE"

ssh $SSH_OPTS "$ASIA1" '
  set -eu
  mkdir -p /home/isucon/bench-bot
  chmod 700 /home/isucon/bench-bot
  test -f /home/isucon/bench-bot/ssh_key || ssh-keygen -q -t ed25519 -N "" -C bench-bot -f /home/isucon/bench-bot/ssh_key
'
PUBLIC_KEY="$(ssh $SSH_OPTS "$ASIA1" cat /home/isucon/bench-bot/ssh_key.pub)"

for HOST in "${REMOTES[@]}"; do
  ssh $SSH_OPTS "$HOST" '
    set -eu
    mkdir -p /home/isucon/bench-bot
    chmod 700 /home/isucon/bench-bot
    # 旧構成の常駐プロセスと Webhook URL を残さない。
    if systemctl list-unit-files bench-bot.service | grep -q bench-bot; then
      sudo systemctl disable -q --now bench-bot.service
      sudo rm -f /etc/systemd/system/bench-bot.service
      sudo systemctl daemon-reload
    fi
    rm -f /home/isucon/bench-bot/env /home/isucon/bench-bot/bot.py /home/isucon/bench-bot/bench-bot.service
  '
  scp -q $SSH_OPTS "$SCRIPT_DIR/log-access.sh" "$HOST:/home/isucon/bench-bot/"
  ssh $SSH_OPTS "$HOST" "grep -qF '$PUBLIC_KEY' ~/.ssh/authorized_keys || echo 'restrict,command=\"/home/isucon/bench-bot/log-access.sh\" $PUBLIC_KEY' >> ~/.ssh/authorized_keys"
  echo "$HOST: log access installed"
done

scp -q $SSH_OPTS -p "$ENV_FILE" "$ASIA1:/home/isucon/bench-bot/env"
scp -q $SSH_OPTS "$SCRIPT_DIR/bot.py" "$SCRIPT_DIR/bench-bot.service" "$PROTOK_DIR/scripts/isuxbench.py" "$ASIA1:/home/isucon/bench-bot/"
ssh $SSH_OPTS "$ASIA1" '
  set -eu
  chmod 600 /home/isucon/bench-bot/env
  sudo install -m 644 /home/isucon/bench-bot/bench-bot.service /etc/systemd/system/bench-bot.service
  sudo systemctl daemon-reload
  sudo systemctl enable -q bench-bot.service
  sudo systemctl restart bench-bot.service
'
echo "asia1: bench-bot installed"
