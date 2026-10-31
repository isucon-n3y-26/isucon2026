---
name: isucon-improve
description: ISUCON の改善サイクルの進め方。改善項目の issue 化、issue ごとの worktree での実装、PR の計測とスコア比較、採否の判定、マージまでを扱う。改善に着手するとき、ベンチやスコア比較をするとき、measure.sh を使うとき、Sonnet などのエージェントに実装を任せるときに読む。
---

# ISUCON の改善サイクル

worktree で並列にできるのは実装だけで、計測はチームで1本の共有サーバーを順番に使う。

```
洗い出し → issue → worktree で実装 → PR → 計測 → 採否 → マージ → 再計測して優先度を見直す
```

## 守ること

- 1項目につき issue、ブランチ、PR を1つずつにする。複数の項目をまとめない
- デプロイとベンチはユーザーの指示があるときだけ実行する。`baseline`、`pr`、`adopt` もこれに含む
- 実装を担当するエージェントは、デプロイもベンチもマージもしない。ローカル検証と PR 作成で止まる
- worktree から `flow.sh` や `deploy.sh` を実行しない。`measure.sh` は worktree から実行してよく、デプロイは専用の clone から行う
- ルーター IP の 443/8080 を宛先に接続しない

## 1. 洗い出しと issue 化

賢いモデルが、`flow.sh` のレポート (`~/.cache/isucon2026/reports/`) の alp とスロークエリ、コードから洗い出す。分析は仮説として扱い、issue を作る前にコードと `manual.md` で確かめる。

issue には次を書く。

- **根拠:** 走行の Job 番号と、スロークエリや alp の数値
- **仮説:** 何がどれだけ良くなるか
- **変更箇所:** ファイルと関数
- **ローカルでの検証方法**
- **依存する issue、衝突しそうな issue**
- **スコア以外に見る指標:** 対象のクエリやエンドポイントの時間

## 2. 実装

同時に実装するのは3件程度にする。ボトルネックは改善のたびに移るので、後回しの issue は前提が崩れていることがある。

```bash
git fetch origin
git worktree add ../wt-issue-<番号> -b perf/issue-<番号> origin/main
```

実装を任せるときは、モデルに Sonnet を指定し、作業ディレクトリ、issue 番号、この skill を読むことを伝える。

PR には `Closes #<番号>` と、ローカルで確かめたことを書く。本文の書き方は `pr-description` skill に従う。

索引は `webapp/sql/reset.sql` に `CREATE INDEX IF NOT EXISTS` で書く。`001-schema.sql` は構築済みの DB には流れない。

## 3. 計測

計測には1回あたり数分かかる。実行ツールのタイムアウトを `--runs` の回数 × 15分以上にする。

```bash
bash provisioning/bench-bot/measure.sh baseline --runs 3  # 今の main に記録がないときだけ
bash provisioning/bench-bot/measure.sh pr <番号>
bash provisioning/bench-bot/measure.sh show
```

`pr` は、PR を最新の main にマージした状態をデプロイして計測する。GitHub のマージと同じ内容 (同じ tree) なので、採用すれば結果がそのまま次の main の基準になる。main の計測をやり直す必要はない。

| 止まったときの表示 | すること |
|---|---|
| main のスコアがない | `baseline` を実行する |
| 計測中です | 終わるのを待つ。持ち主がいないロックだと確かめてから `unlock` する |
| DB の索引が main の計測時と違う | 下の「索引の残留」を見る |
| main と衝突している | PR のブランチで解消する |
| この計測のコードで走っていません | 誰かが走行中にデプロイした。チームに確認して計測し直す |

## 4. 採否

スコアだけで決めない。基準の `baseline` の回数が少ないと、差がばらつきの範囲か判断できない。

| 結果 | 判定 |
|---|---|
| スコアの差が main のばらつきより大きく、FAIL がない | 採用する |
| スコアは動かないが、対象の指標は改善した | 保留する。別のボトルネックに隠れている可能性があるので、閉じない |
| スコアも指標も改善しない、または悪化した | 却下する。PR に結果を書いて閉じる |

採用するときは、次のコマンドでマージする。今の main にマージした内容が未計測なら、マージせずに止まる。

```bash
bash provisioning/bench-bot/measure.sh adopt <番号>
```

却下した場合、サーバーには PR のコードが残っている。次の `pr` か `baseline` で上書きされるが、競技の終わりが近いなら main をデプロイし直す。

## 索引の残留

`reset.sql` は索引を消さないので、却下した PR の索引は DB に残り、以降の計測に影響する。`measure.sh` は計測前に索引が基準と同じか確かめ、違えば止まる。

1. `measure.sh indexes` で残っている索引を確かめる
2. 却下した PR の索引なら、ユーザーの許可を得て `asia2` で `DROP INDEX` する
3. 計測し直す

`--allow-index-drift` は、その差が結果に影響しないと分かっているときだけ使う。

## 再計測と見直し

2〜3件マージするたびに、`~/.cache/isucon2026/reports/` の最新のレポートを賢いモデルに読ませ、issue の優先度を見直して、不要になったものを閉じる。

## 競技の終わり

**最後に行った走行が最終スコアになり、FAIL だと受賞の対象にならない。** 終了の前に実験をやめ、`measure.sh baseline` で main を計測して通過を確かめる。
