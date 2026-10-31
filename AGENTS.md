# エージェント向けガイド

## ベンチの実行

```bash
bash provisioning/bench-bot/flow.sh                # デプロイからベンチ、alp、スロークエリ、Discord 通知まで
bash provisioning/bench-bot/flow.sh --skip-deploy  # 今サーバーにあるコードでベンチから
bash provisioning/bench-bot/flow.sh --force        # origin/main を取り込んでいなくてもデプロイする
```

ポータルやブラウザの操作は不要です。走行が終わるとすぐ alp とスロークエリを標準出力に出し、最後に Discord へ通知します。レポートは `~/.cache/isucon2026/reports/` に保存します。

| スクリプト | 役割 |
|---|---|
| `provisioning/bench-bot/measure.sh` | PR を最新の main にマージした状態で計測し、スコアを台帳に記録する (改善の進め方は `isucon-improve` skill) |
| `provisioning/bench-bot/flow.sh` | 下のすべてを続けて実行する |
| `provisioning/deploy.sh` | 全サーバーへデプロイする |
| `provisioning/bench-bot/enqueue.sh` | ベンチを実行し、スコアとログを出す |
| `provisioning/alp.sh fetch` | 全サーバーのログを手元に取って alp で集計する |
| `provisioning/profile_db.sh` | `pg_stat_statements` からスロークエリを出す |

- **デプロイ:** `flow.sh` は既定でデプロイも行う。デプロイしないときは `--skip-deploy` を付ける
- **タイムアウト:** 実行中のベンチがあると完了まで待つので、実行ツールのタイムアウトを15分以上にする
- **統計:** 実行中のベンチがあると完了後に投入するので、そのベンチの SQL も統計に混ざる
- **終了コード:** 0 = 成功、1 = デプロイの失敗または走行が FAIL、2 = それ以外の失敗
- **結果の1行目:** `Job #6891 status=FINISHED passed=true score=7787`

結果を見直すときは、ベンチを走らせずに次を実行します。

```bash
bash provisioning/bench-bot/enqueue.sh result       # 最新の走行
bash provisioning/bench-bot/enqueue.sh result 6891  # 指定した走行
```

## ベンチを実行する前に

- デプロイしてもベンチは自動で走らない。デプロイとベンチは別の操作
- サーバーとベンチはチームで共有している。実行中のベンチがあれば、完了後に投入され、同時に実行した全員に同じ結果が返る
- `provisioning/deploy.sh` は手元のコードで全サーバーを上書きする。ベンチの前に、チームの変更を取り込んでいるか確認する
- 競技中に最後に行った走行が最終スコアになる。最後の走行が FAIL だと受賞の対象にならない

## alp

- 走行後75秒でサーバーのログは空になる。`alp.sh show` や `profile.sh` ではなく、`flow.sh` の出力を見る
- `flow.sh` の alp は走行直後のログを集計するので、走行後も接続が残るリクエスト (SSE の `/api/notifications` など) の一部を含まない。全件の集計は Discord か `enqueue.sh result` で見る
- 走行の間隔が75秒より短いと、前の走行のログが消えずに混ざる。alp の1行目の時刻の範囲で確認する

## 詳しい情報

- 競技のルール: `manual.md`
- サーバーと通常の作業手順: `README.md`
- bench-bot の実装: `provisioning/bench-bot/`
