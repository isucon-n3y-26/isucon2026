# エージェント向けガイド

## ベンチの実行

```bash
bash provisioning/bench-bot/enqueue.sh
```

ポータルやブラウザの操作は不要です。結果が揃うまで待ち、スコア、ベンチのログ、3サーバー集約の alp を標準出力に出します。同じ内容は Discord にも通知されます。

- **タイムアウト:** 完了まで約4分かかるので、実行ツールのタイムアウトを10分以上にする
- **終了コード:** 0 = 成功、1 = 走行が FAIL、2 = 結果を取得できない
- **出力の1行目:** `Job #6891 status=FINISHED passed=true score=7787`

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

- 走行後75秒でサーバーのログは空になる。`alp.sh show` や `profile.sh` ではなく、`enqueue.sh` の出力を見る

## 詳しい情報

- 競技のルール: `manual.md`
- サーバーと通常の作業手順: `README.md`
- bench-bot の実装: `provisioning/bench-bot/`
