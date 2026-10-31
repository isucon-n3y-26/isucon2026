# isucon2026

## 開発ワークフロー（確定版・動作確認済み）

```
[ローカル / Bob]
    │
    ├─ git add/commit/push ──→ [GitHub]
    │
    └─ bash provisioning/deploy.sh
              │
              ├─ rsync (ローカルリポジトリ → 各サーバー)
              ├─ rsync (webapp/ → /home/isucon/webapp/)
              ├─ go build
              └─ systemctl restart isureal-go
                        │
                   [ベンチマーク実行]
```

> **ポイント**: サーバーはGitHubに直接アクセスできない（SSH鍵なし・HTTPS認証不可）。
> ローカルから rsync でリポジトリごと転送する方式を採用。

---

## 初回セットアップ（競技開始直後に1回だけ）

### ステップ 1: サーバーのコードをローカルへ取得

```bash
# asia1 から webapp/ をローカルへ rsync
bash provisioning/fetch_webapp.sh

# GitHub に push
git add -A && git commit -m "initial webapp"
git push origin main
```

### ステップ 2: 各サーバーにリポジトリを配置

```bash
# ローカルのリポジトリを全サーバーへ rsync（初回のみ）
bash provisioning/setup_server.sh
```

### ステップ 3: 動作確認デプロイ

```bash
bash provisioning/deploy.sh
```

3台すべてで `isureal-go.service: active` が返れば OK。

---

## 通常サイクル（コード変更 → デプロイ → ベンチ）

```bash
# 1. コードを編集

# 2. GitHub に push
git add -A && git commit -m "fix: ..."
git push origin main

# 3. 全サーバーへデプロイ（約10〜20秒）
bash provisioning/deploy.sh

# 4. ベンチマーク実行（結果が揃うまで約4分待つ）
bash provisioning/bench-bot/enqueue.sh
```

スコア、ベンチのログ、3サーバー集約の alp が標準出力に出て、Discord にも通知されます。詳しくは [AGENTS.md](AGENTS.md) を参照してください。

1台だけにデプロイしたい場合:

```bash
bash provisioning/deploy.sh asia1
bash provisioning/deploy.sh europe1
bash provisioning/deploy.sh america1
```

---

## サーバー構成

| 名前 | 役割 | Public IP | Private IP | SSH |
|---|---|---|---|---|
| asia1 | App (asia) | 57.181.195.208 | 192.168.1.10 | `ssh isucon@57.181.195.208` |
| europe1 | App (europe) | 35.74.6.16 | 192.168.2.10 | `ssh isucon@35.74.6.16` |
| america1 | App (america) | 35.74.122.15 | 192.168.3.10 | `ssh isucon@35.74.122.15` |
| asia2 | DB (PostgreSQL) | 54.65.131.246 | 192.168.4.10 | `ssh isucon@54.65.131.246` |
| Router | HAProxy / TLS | 52.196.102.158 | 192.168.10.10 | ログイン禁止 |

- ベンチマーク URL: `http://52.196.102.158:8080`
- アプリ確認 URL: `http://app.team30146-aws.127.0.0.1.nip.io`

---

## ディレクトリ構成

```
.
├── provisioning/
│   ├── setup_server.sh   # 【初回のみ】ローカルリポジトリを全サーバーへ rsync
│   ├── deploy.sh         # 【通常】rsync + go build + systemctl restart
│   ├── fetch_webapp.sh   # 【初回のみ】asia1 → ローカルへ webapp を取得
│   └── deploy_webapp.sh  # 旧方式（使用しない）
└── webapp/
    ├── go/               # Go 実装（本番使用中）
    ├── sql/              # DB スキーマ・初期化スクリプト
    └── public/           # 静的ファイル（フロントエンド）
```

---

## DB 接続

```bash
# App サーバー上で実行
. /home/isucon/env.sh
PGPASSWORD="$ISUREAL_DB_PASSWORD" psql \
  -h "$ISUREAL_DB_HOST" -p "$ISUREAL_DB_PORT" \
  -U "$ISUREAL_DB_USER" -d "$ISUREAL_DB_NAME"
```

## DB 初期化

```bash
# App サーバー上で実行
~/webapp/sql/init.sh
```

---

## ハマりポイント・メモ

### Go コマンドのパス

SSH 経由の非対話シェルでは `$PATH` が通っていないため `go` が見つからない。
`/home/isucon/local/go/bin/go` を絶対パスで指定する。

```bash
/home/isucon/local/go/bin/go build -o isureal cmd/isureal/main.go
```

### サーバーは GitHub に直接アクセス不可

- HTTPS: 認証のため `No such device or address` エラー
- SSH: サーバーに GitHub の SSH 鍵が未設定

→ **ローカルから rsync でリポジトリごと転送する方式**で解決。

### AGENTS.md は削除済み

各言語ディレクトリにあった `AGENTS.md` は AI コンテキスト汚染防止のため削除済み。
サーバー側に残っているものも `rsync --delete` で上書き削除される。

---

## 実装言語切り替え方法

初期状態は Go。切り替えたい場合は各 App サーバーで:

```bash
sudo systemctl disable --now isureal-go.service
sudo systemctl enable --now isureal-{nodejs,python,ruby,rust,perl,php}.service
```

PHP のみ追加で nginx 設定が必要:

```bash
sudo ln -s /etc/nginx/sites-available/isureal-php.conf /etc/nginx/sites-enabled/
sudo systemctl restart nginx.service
```
