#!/usr/bin/env bash
# alp v1.0.21 を3台のアプリサーバーへインストールする。
# 使い方: bash provisioning/install_alp.sh

set -euo pipefail

ALP_VERSION="1.0.21"
ALP_ARCHIVE="alp_linux_amd64.tar.gz"
ALP_URL="https://github.com/tkuchiki/alp/releases/download/v${ALP_VERSION}/${ALP_ARCHIVE}"
SSH_OPTS=(-o StrictHostKeyChecking=no)

APP_HOSTS=(
  "asia1:isucon@57.181.195.208"
  "europe1:isucon@35.74.6.16"
  "america1:isucon@35.74.122.15"
)

for TARGET in "${APP_HOSTS[@]}"; do
  NAME="${TARGET%%:*}"
  HOST="${TARGET#*:}"

  echo "==> Installing alp v${ALP_VERSION} on ${NAME} (${HOST}) ..."
  if ! ssh "${SSH_OPTS[@]}" "$HOST" 'bash -s' <<REMOTE_SCRIPT
set -euo pipefail

work_dir="\$(mktemp -d)"
trap 'rm -rf "\$work_dir"' EXIT
cd "\$work_dir"

wget -q -O "${ALP_ARCHIVE}" "${ALP_URL}"
tar -zxf "${ALP_ARCHIVE}"
test -f alp
sudo install -m 0755 alp /usr/local/bin/alp
/usr/local/bin/alp --version
REMOTE_SCRIPT
  then
    echo "ERROR: alp installation failed on ${NAME}" >&2
    exit 1
  fi

  echo "==> ${NAME} OK"
done

echo "All app servers have alp v${ALP_VERSION}."
