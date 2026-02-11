## 1. 概要
`yb collect` は `dashboard.md` と report index を単純上書きしており、同時実行時に last-writer-wins で更新取りこぼしが起きる。collect 全体の排他制御と atomic write を導入し、複数プロセスが重なっても dashboard と index の整合性を維持する。

## 2. 現状の問題
該当箇所は以下。

- `scripts/yb_collect.sh:205-263` は dashboard 文字列を組み立て、`open(..., "w")` で `dashboard.md` を直接上書きしている（`scripts/yb_collect.sh:262-263`）。
- `scripts/yb_collect.sh:309-313` は完了 worker の task YAML を直接上書きしている。
- `scripts/yb_collect.sh:315-327` は `_index.json` を直接上書きしている。
- `scripts/yb_collect.sh` 全体にプロセス排他（lock）が無く、同一 queue に対する同時 collect を防げない。
- `docs/improvement-report.md:178-186` と `worker_002_report.yaml:79-91` で「collect ロック + atomic replace」が改善案として明示されている。
- `.yamibaito/prompts/waka.md:77` と `.yamibaito/prompts/waka.md:333-335` が、若頭からの collect 実行を定常運用として要求しており、衝突機会が高い。

現状挙動では、同時実行した 2 プロセスがそれぞれ古いスナップショットでレンダリングし、後勝ち書き込みで先行更新が消える。障害シナリオは以下。

- collect A が report を読み込んだ後に collect B が task reset を反映し、最後に collect A が古い内容で dashboard を上書きして進捗が巻き戻る。
- 途中でプロセスが死ぬと `dashboard.md` / `_index.json` が中途半端に書かれ、以降の表示や差分判定が不安定になる。
- queue 単位で保護されないため、同一 session に対する並列呼び出しが増えるほど再現性が落ちる。

## 3. ゴール
受け入れ条件:

- `yb collect` 開始時に queue 単位の lock（例: `.yamibaito/queue_<id>/.collect.lock`）を取得する。
- lock 獲得後のみ collect 本体を実行し、終了時に確実に解放される。
- `dashboard.md` と `_index.json` は一時ファイル書き込み後 `os.replace` で原子的に置換される。
- 同時に 2 つ以上 `yb collect` を起動しても、破損ファイル（空/途中 JSON/途中 Markdown）が発生しない。
- lock 競合時は待機または timeout を明示し、黙って成功したように見せない。

非ゴール（スコープ外）:

- dashboard 生成方式そのものの刷新（state + renderer 分離）。
- collect による task reset 条件ロジックの再設計。
- queue/report の stale cleanup 実装。

## 4. 設計方針
排他は Bash、atomic write は Python ヘルパーで実装する。

- 排他制御:
`scripts/yb_collect.sh` で `"$queue_dir/.collect.lock"` を使って `flock` を取得するが、ロックスコープは最小化する。集計・レンダリングは lock 外で実行し、`dashboard.md` / `_index.json` / task YAML の最終反映（atomic replace）だけを lock 内のクリティカルセクションに閉じ込める。`--lock-timeout` を追加し、待機秒数を指定可能にする（既定 30 秒）。

- atomic write 関数:
Python 側に `atomic_write_text(path, text)` と `atomic_write_json(path, payload)` を追加する。`tempfile.NamedTemporaryFile(dir=os.path.dirname(path), delete=False)` へ書き込み、`flush + fsync` 後に `os.replace` する。

- 更新順序:
`dashboard` と `_index.json` を atomic write 化し、task YAML リセットも同様の helper を使って部分書き込みを防ぐ。生成済みデータを lock 内で一括反映し、書き込み部分のみをクリティカルセクションにする。

- エラー時挙動:
lock timeout は非0終了（例: exit 2）し、競合中であることを明示する。atomic write 失敗時は元ファイルを保持したまま失敗終了し、`stderr` に対象パスと例外を出す。

影響範囲:

- 変更: `scripts/yb_collect.sh`
- 間接影響: `yb collect` の実行時間（待機時間）、同時起動時の挙動

## 5. 実装ステップ
1. `yb_collect.sh` に lock パラメータ（`--lock-timeout`）と lock ファイルパス決定処理を追加する。変更ファイル: `scripts/yb_collect.sh`
2. 収集・レンダリングを lock 外へ出し、`flock` 区間は最終書き込み処理だけに限定する。変更ファイル: `scripts/yb_collect.sh`
3. Python 側へ `atomic_write_text` / `atomic_write_json` ヘルパーを追加する。変更ファイル: `scripts/yb_collect.sh`
4. `dashboard.md` の直書き（`scripts/yb_collect.sh:262-263` 相当）を atomic write へ置換する。変更ファイル: `scripts/yb_collect.sh`
5. `_index.json` と task YAML リセットの直書き（`scripts/yb_collect.sh:309-327` 相当）を atomic write へ置換する。変更ファイル: `scripts/yb_collect.sh`
6. lock 競合時メッセージと終了コードを統一し、運用者向けに挙動を明確化する。変更ファイル: `scripts/yb_collect.sh`

## 6. テスト方針
正常系:

- 単独 `yb collect` 実行で dashboard / index / task reset が従来通り更新される。
- `yb collect` を連続実行しても lock 解放漏れが無く、2 回目以降が正常完了する。

異常系:

- 1 つ目の collect が lock を保持中に 2 つ目を起動し、timeout 指定で競合終了（非0）になること。
- 書き込み先ディレクトリ権限を意図的に壊し、atomic write 失敗時に元ファイルが保持されること。
- 実行中に強制終了（SIGTERM）しても、途中書き込みファイルが最終成果物へ露出しないこと。

手動テスト手順:

1. 同一 session で `yb collect --session <id>` を 2 プロセス同時起動する。
2. 片方を意図的に遅延させ、もう片方に `--lock-timeout 1` を付けて競合エラーを確認する。
3. 正常完了後に `dashboard.md` 先頭行（`# 📊 組の進捗`）と `_index.json` の JSON 妥当性を確認する。
4. 競合試験を複数回繰り返し、`dashboard.md` が空ファイルや途中書き込みにならないことを確認する。

## 7. リスクと注意点
- 後方互換性: `flock` コマンド依存が増える。未導入環境向けに事前チェックとエラーメッセージを明示する。
- デッドロック/長時間待機: lock 範囲を広げすぎると待機時間が増えるため、I/O と外部コマンド実行順序を見直して最短化する。
- 他スクリプト波及: `yb dispatch` や手動編集が collect と同時に走る場合、排他の境界を queue 単位で揃えないと整合性が崩れる。
- 将来拡張との整合: 後続の state + renderer 分離（`docs/improvement-report.md:230-238`）で同じ atomic write 戦略を再利用できるよう、helper 関数を汎用化しておく。
