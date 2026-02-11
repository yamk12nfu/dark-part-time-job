## 1. 概要
`yb collect` は完了レポートを見つけると同一 worker の task ファイルを即 `idle` に戻すが、report と task の対応関係（`task_id` / `parent_cmd_id`）を検証していない。これを「同一ジョブ一致時のみリセット」に変更し、再配布直後の race で新規タスクを消す事故を防ぐ。

## 2. 現状の問題
該当コードは `scripts/yb_collect.sh` の Python 埋め込み部。

- `scripts/yb_collect.sh:187` `completed_worker_ids = set()` を作成し、`scripts/yb_collect.sh:194-198` で report の `status in ("done", "completed")` だけを根拠に worker を完了扱いにしている。
- `scripts/yb_collect.sh:309-313` は `completed_worker_ids` に含まれる worker の task YAML を `IDLE_TASK_TEMPLATE` で上書きするが、現在の task 側 `task_id` / `parent_cmd_id` との一致確認がない。
- `scripts/yb_collect.sh:98-109` の `read_simple_kv()` は task/report の `task_id` と `parent_cmd_id` を取得できるのに、リセット判定では未使用。

障害シナリオ:

- worker が旧タスク `A` の report を `done` で書いた直後に、dispatcher が新タスク `B`（`status: pending`）を同じ worker の task ファイルへ配布。
- そのタイミングで `yb collect` が走ると、`scripts/yb_collect.sh:309-313` が `B` を `idle` で上書きし、未着手タスクが消失する。

## 3. ゴール
受け入れ条件:

- task リセットは「report と task が同一ジョブ（`task_id` と `parent_cmd_id` が一致）」の場合だけ実行される。
- `status: pending` / `in_progress` の task は、report が `done/completed` でもリセットされない。
- 不一致時はリセットをスキップし、`stderr` または dashboard 用ログに理由（worker_id, report_task_id, task_task_id）を残す。
- 既存の dashboard 生成 (`scripts/yb_collect.sh:205-263`) と `_index.json` 更新 (`scripts/yb_collect.sh:315-327`) は維持される。

非ゴール（スコープ外）:

- dispatcher 側の状態遷移再設計（`collected` 中間状態の導入など）。
- `read_simple_kv()` の全面置換（YAML パーサ導入）。
- queue ディレクトリ構成変更。

## 4. 設計方針
実装アプローチ:

- `scripts/yb_collect.sh` 内で task 情報を `worker_id` で引ける辞書（例: `tasks_by_worker`）に正規化する。
- 判定関数（例: `can_reset_to_idle(report, task)`）を追加し、以下を満たす時のみ `True`:
  - `report.status in {"done", "completed"}`
  - `task.status in {"done", "completed"}`（少なくとも `pending` / `in_progress` は拒否）
  - `report.task_id == task.task_id`
  - `report.parent_cmd_id == task.parent_cmd_id`
- `completed_worker_ids` を直接集める現行方式（`scripts/yb_collect.sh:187-198`）は廃止し、`done` report ごとに上記判定を通した worker だけを `workers_to_reset` に積む。

関数/構造の想定:

- 追加関数: `normalize_status(value: str) -> str`（小文字化と `None` 防御）
- 追加関数: `can_reset_to_idle(report: dict, task: dict) -> tuple[bool, str]`
  - 戻り値は `(判定結果, 理由文字列)` とし、失敗理由をログ出力に使う。

エラー時挙動:

- task ファイルが存在しない worker はスキップし、warning を残す。
- report/task のキー欠落時はリセットしない（fail-safe）。
- 1 worker の判定失敗で collect 全体は止めない（他 worker は継続処理）。

影響範囲:

- 主変更: `scripts/yb_collect.sh`
- 間接影響: task リセットタイミング（`done` report 即時リセットから「一致確認後リセット」へ）
- 影響なし: `yb_start.sh` / `yb_restart.sh` / `yb_stop.sh` の起動停止フロー

## 5. 実装ステップ
1. `scripts/yb_collect.sh` に `tasks_by_worker` 構築処理を追加し、worker ごとの現行 task を参照できるようにする。
2. `scripts/yb_collect.sh` に `normalize_status()` と `can_reset_to_idle()` を追加する。
3. `scripts/yb_collect.sh:187-198` 相当の `completed_worker_ids` 収集ロジックを、判定関数経由の `workers_to_reset` 収集へ置換する。
4. `scripts/yb_collect.sh:309-313` の上書き処理を `workers_to_reset` のみに限定し、不一致時ログを追加する。
5. `scripts/yb_collect.sh` の dashboard 生成と `_index.json` 更新に副作用がないことを確認する。

## 6. テスト方針
正常系:

- 同一 `task_id` / `parent_cmd_id` かつ `done/completed` の report/task 組み合わせでのみ `idle` リセットされる。
- 従来通り `dashboard.md` と `reports/_index.json` が更新される。

異常系:

- report は `done` だが task が別 `task_id` の場合、task が維持される。
- task が `pending` / `in_progress` の場合、`done` report があってもリセットされない。
- report に `task_id` 欠落（`null`/空）時に fail-safe でスキップされる。

手動テスト手順:

1. `.yamibaito/queue_<session>/tasks/worker_001.yaml` に新規タスク `task_id: B` を配置。
2. `.yamibaito/queue_<session>/reports/worker_001_report.yaml` に旧タスク `task_id: A` + `status: done` を配置。
3. `scripts/yb_collect.sh --repo <repo> --session <id>` を実行し、`worker_001.yaml` が `idle` 化されないことを確認。
4. report を `task_id: B` / `parent_cmd_id` 一致へ変更して再実行し、`idle` 化されることを確認。

## 7. リスクと注意点
- 後方互換性: 現在「report が done なら即 idle」前提の運用がある場合、見かけ上 idle 化が遅くなる。運用ドキュメントで判定厳格化を周知する。
- 他スクリプト波及: dispatcher が task 状態のみを見ている場合、`done` のまま残る期間が増える可能性がある。必要なら dispatcher 側表示ルールを調整する。
- 依存関係: `read_simple_kv()` の単純パースは多行 YAML に弱い。今回の比較キーは単一行スカラーに限定し、想定外形式はスキップ扱いにする。
