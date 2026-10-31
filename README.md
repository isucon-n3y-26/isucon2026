# isucon2026

## 開発ワークフロー

```
[GitHub] <──push── [ローカル/Bob]
    │
    └──git pull──> [asia1 / europe1 / america1]
                        │
                    go build
                        │
                   systemctl restart
                        │
                   [ベンチマーク]
```

### 初回セットアップ（競技開始直後に1回だけ）

```bash
# 1. サーバーのコードをローカルへ取得して GitHub に push（すでに完了）
bash provisioning/fetch_webapp.sh
git add -A && git commit -m "initial webapp"
git push origin main

# 2. 各 App サーバーに GitHub リポジトリを clone
bash provisioning/setup_server.sh
```

### 通常サイクル（コード変更 → デプロイ → ベンチ）

```bash
# 1. コードを変更して push
git add -A && git commit -m "fix: ..."
git push origin main

# 2. 全サーバーへデプロイ（git pull + go build + restart）
bash provisioning/deploy.sh

# 3. ポータルからベンチマーク実行
#    https://portal.isucon.net/contestant
```

1台だけにデプロイしたい場合:

```bash
bash provisioning/deploy.sh asia1
bash provisioning/deploy.sh europe1
bash provisioning/deploy.sh america1
```

---

## サーバー構成

| 名前 | 役割 | Public IP | Private IP |
|---|---|---|---|
| asia1 | App (asia) | 57.181.195.208 | 192.168.1.10 |
| europe1 | App (europe) | 35.74.6.16 | 192.168.2.10 |
| america1 | App (america) | 35.74.122.15 | 192.168.3.10 |
| asia2 | DB (PostgreSQL) | 54.65.131.246 | 192.168.4.10 |
| Router | HAProxy / TLS | 52.196.102.158 | 192.168.10.10 |

## ディレクトリ構成

```
.
├── provisioning/
│   ├── setup_server.sh   # 初回: 各サーバーに git clone
│   ├── deploy.sh         # 通常: git pull + build + restart
│   ├── fetch_webapp.sh   # 初回取得: asia1 → ローカル
│   └── deploy_webapp.sh  # ローカル → 全サーバー rsync (旧方式)
└── webapp/
    ├── go/               # Go 実装 (初期起動)
    ├── sql/              # DB スキーマ・初期化スクリプト
    └── public/           # 静的ファイル
```

## 接続

```bash
ssh isucon@57.181.195.208   # asia1
ssh isucon@35.74.6.16       # europe1
ssh isucon@35.74.122.15     # america1
ssh isucon@54.65.131.246    # asia2 (DB)
```

## DB 接続

```bash
# App サーバーから
. /home/isucon/env.sh
PGPASSWORD="$ISUREAL_DB_PASSWORD" psql \
  -h "$ISUREAL_DB_HOST" -p "$ISUREAL_DB_PORT" \
  -U "$ISUREAL_DB_USER" -d "$ISUREAL_DB_NAME"
```

## DB 初期化

```bash
~/webapp/sql/init.sh
```
