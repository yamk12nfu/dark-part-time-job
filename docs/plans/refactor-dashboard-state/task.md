# タスク定義書: dashboard の状態モデル分離

## 1. 概要
`scripts/yb_collect.sh` は Python ブロック内で dashboard Markdown を直接組み立てて `dashboard.md` に上書きしており、表示項目追加・フィルタ対応・履歴保持の変更コストが高い。収集ロジックと描画ロジックを分離し、状態データ（state）を正本として持つ構造へ再編することで、将来拡張と保守性を改善する。

## 2. 現状の問題
該当コード（ファイル名・行番号）:
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:89`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:98`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:129`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:165`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:205`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:219`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:227`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:262`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/scripts/yb_collect.sh:329`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job-worktrees/yamibaito-agile-improve/docs/improvement-report.md:230`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_004_report.yaml:61`

現状の挙動:
- `read_simple_kv()`（`yb_collect.sh:98`）で task/report を簡易パースし、表示用の配列をその場で作る。
- `lines` 配列に Markdown を逐次追加（`yb_collect.sh:205` 以降）し、`dashboard.md` へ直接書き込む（`yb_collect.sh:262`）。
- 表示データの構造体が無く、収集・判定・描画・出力が一つの処理に密結合している。

障害シナリオ:
- 表示列を1つ追加するだけでも収集ロジックと文字列テンプレートの両方を同時に修正する必要があり、回帰が起きやすい。
- `dashboard.md` しか状態を持たないため、`priority` や履歴参照などの拡張時に再計算・再解析が必要になる。
- 同時実行や障害時に「どのデータから描画したか」を追跡しづらく、原因調査の再現性が下がる。

## 3. ゴール
受け入れ条件:
- `yb_collect` で「状態生成」と「Markdown描画」が分離される。
- `.yamibaito/state/dashboard{session_suffix}.json` を状態の正本として出力する。
- `dashboard.md` は state から描画される成果物とし、現行セクション構成（裁き待ち/シノギ中/完了/仕組み化のタネ/待機所/メモ）は維持する。
- `.yamibaito/state/dashboard_history{session_suffix}.jsonl` にスナップショットを追記できる。

非ゴール（スコープ外）:
- `dashboard.md` の文言や見た目の全面刷新。
- `tmux send-keys` 通知フロー（`yb_collect.sh:329` 以降）の責務変更。
- `worker` タスクの idle リセット仕様（`yb_collect.sh:265` 以降）の再設計。

## 4. 設計方針
具体的な実装アプローチ:
- `scripts/yb_collect.sh` の Python 部分を責務別関数に分割する。
- 収集フェーズで `tasks`, `reports`, `idle_workers`, `skill_candidates`, `attention`, `done` を state dict に正規化する。
- 描画フェーズは `render_dashboard_markdown(state)` だけが Markdown を生成し、収集フェーズから文字列処理を分離する。
- 出力フェーズで state JSON、history JSONL、dashboard Markdown をそれぞれ書き出す。

関数/構造体の設計:
- `build_dashboard_state(...) -> dict`
- `render_dashboard_markdown(state: dict) -> list[str]`
- `write_state_files(state: dict, markdown_lines: list[str], paths: dict) -> None`
- `state` の必須キー:
  - `schema_version`
  - `generated_at`
  - `session_suffix`
  - `current_cmd_id`
  - `attention`
  - `in_progress`
  - `completed`
  - `skill_candidates`
  - `idle_workers`

エラー時挙動:
- 個別 task/report の読込失敗は全体停止せず、`attention` に warning エントリを追加して処理継続する。
- state ファイル書き込み失敗時は `dashboard.md` を更新せず非0終了とし、破損状態の上書きを防ぐ。
- `state` ディレクトリが無い場合は `os.makedirs(..., exist_ok=True)` で作成する。

影響範囲:
- 直接変更: `scripts/yb_collect.sh`
- 実行時生成物: `.yamibaito/state/dashboard*.json`, `.yamibaito/state/dashboard_history*.jsonl`, `dashboard.md`
- 間接影響: dashboard を読む運用フロー（親分/若頭）、将来の `yb collect` フィルタ拡張

## 5. 実装ステップ
1. `scripts/yb_collect.sh` の Python ブロックで、現行の `lines` 直組み立て処理（`205` 以降）を `build_dashboard_state` と `render_dashboard_markdown` に分離する。
2. `scripts/yb_collect.sh` に state 出力先（`.yamibaito/state/dashboard{session_suffix}.json`）と履歴出力先（`.yamibaito/state/dashboard_history{session_suffix}.jsonl`）を追加する。
3. `scripts/yb_collect.sh` の `read_simple_kv` 呼び出し部（`129`, `167` 付近）で、state に必要な項目（例: `priority`）を取り込めるようにキー集合を拡張する。
4. `scripts/yb_collect.sh` の出力処理（`262` 付近）を `write_state_files` 経由に置き換え、state と markdown の書き込み順序を固定する。
5. `scripts/yb_collect.sh` の例外処理を追加し、部分的な読込失敗時の warning 記録と、致命的な書込失敗時の非0終了を実装する。
6. `scripts/yb_collect.sh` の完了通知（`329` 以降）が state 分離後も同条件で動作することを確認する。

## 6. テスト方針
正常系:
- `yb collect --repo <repo_root>` 実行で `dashboard.md` と `dashboard*.json` が同時に生成されることを確認する。
- `dashboard*.json` の `in_progress` / `completed` / `attention` 件数が、`dashboard.md` の表/箇条書き件数と一致することを確認する。
- `--session <id>` 指定時に `dashboard_<id>` 系ファイルへ分離出力されることを確認する。

異常系:
- 破損した report YAML を1件混在させ、`yb collect` が全停止せず warning を state に残して継続できることを確認する。
- `state` 出力先に書込不能条件を作り、非0終了して既存 `dashboard.md` を壊さないことを確認する。
- `panes` が欠落した場合でも `repo_root` フォールバックで最低限の state 生成が行えることを確認する（`yb_collect.sh:86` 相当）。

手動テスト手順:
1. テスト用の task/report を `queue/tasks` と `queue/reports` に配置する。
2. `scripts/yb_collect.sh --repo <repo_root>` を実行する。
3. `dashboard.md` の各セクションが従来フォーマットを維持していることを確認する。
4. `.yamibaito/state/dashboard*.json` を開き、同じ情報が構造化されていることを確認する。
5. 同じコマンドを複数回実行し、`dashboard_history*.jsonl` にスナップショットが追記されることを確認する。

## 7. リスクと注意点
- 後方互換性: `dashboard.md` のみを読んでいる既存運用は維持できるが、将来 state を正本に移行する際は参照先切替の運用周知が必要。
- 他スクリプト波及: `yb_collect.sh` の Python ブロックが肥大化しているため、分離時に通知処理・taskリセット処理を巻き込まないよう責務境界を明確にする。
- 依存関係: 将来の `yb collect --priority/--status` 実装は state 構造に依存するため、キー命名を最初に固定し schema version 管理を導入すること。
