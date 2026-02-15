# 15計画 進捗チェックリスト

- 最終更新日時: 2026-02-15（手動更新の運用を想定）
- 全体進捗サマリ: 完了 1/15、進行中 0/15、未着手 14/15
- 参照: [依存関係マップ](dependency-map.md)

## Phase 1: 基盤修正

- [x] **[fix-prompts-single-source](fix-prompts-single-source/)** — `prompts/` を単一正本に統一し、起動・計画時の参照を一本化する。
  - 対象: `scripts/yb_init_repo.sh`, `scripts/yb_start.sh`, `scripts/yb_plan.sh`, `prompts/*.md`
  - 依存: なし
  - 状態: 完了
- [ ] **[fix-panes-schema](fix-panes-schema/)** — `panes*.json` を `schema_version: 2` の非 nullable 構造へ移行し、読み取りロジックを共通化する。
  - 対象: `scripts/lib/panes.py`（新規）, `scripts/yb_start.sh`, `scripts/yb_restart.sh`, `scripts/yb_stop.sh`, `scripts/yb_worktree_list.sh`
  - 依存: なし
  - 状態: 未着手
- [ ] **[fix-dashboard-atomic-write](fix-dashboard-atomic-write/)** — `yb collect` に lock と atomic write を導入し、同時実行時の更新取りこぼしを防ぐ。
  - 対象: `scripts/yb_collect.sh`
  - 依存: なし
  - 状態: 未着手
- [ ] **[fix-startup-readiness](fix-startup-readiness/)** — `yb start` の固定 `sleep` を readiness check に置換し、起動成功判定を堅牢化する。
  - 対象: `scripts/yb_start.sh`
  - 依存: なし
  - 状態: 未着手

## Phase 2: 依存解決

- [ ] **[fix-prompt-spec-consistency](fix-prompt-spec-consistency/)** — 4種プロンプトの front matter を `spec_version`/`prompt_version` に整理し、通知責務と send-keys 語彙を統一する。
  - 対象: `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`, `.yamibaito/prompts/wakashu.md`, `.yamibaito/prompts/plan.md`, `scripts/*`（検証追加時）
  - 依存: `fix-prompts-single-source`
  - 状態: 未着手
- [ ] **[fix-collect-reset-guard](fix-collect-reset-guard/)** — report/task の `task_id` と `parent_cmd_id` 一致時のみ idle リセットするガードを追加する。
  - 対象: `scripts/yb_collect.sh`
  - 依存: `fix-dashboard-atomic-write`
  - 状態: 未着手
- [ ] **[refactor-dashboard-state](refactor-dashboard-state/)** — `yb collect` の収集と描画を分離し、`dashboard state` JSON を正本として出力する。
  - 対象: `scripts/yb_collect.sh`, `.yamibaito/state/dashboard*.json`, `.yamibaito/state/dashboard_history*.jsonl`
  - 依存: `fix-dashboard-atomic-write`
  - 状態: 未着手
- [ ] **[add-version-management](add-version-management/)** — `VERSION` を正本に CLI 表示と生成物の `orchestrator_version` 埋め込みを実装する。
  - 対象: `VERSION`（新規）, `bin/yb`, `scripts/yb_start.sh`, `scripts/yb_plan.sh`, `scripts/yb_init_repo.sh`, `templates/queue/director_to_planner.yaml`
  - 依存: `fix-panes-schema`
  - 状態: 未着手
- [ ] **[fix-restart-grep-shim](fix-restart-grep-shim/)** — `yb_restart` の `grep` shim を廃止し、`YB_RESTART_WORKTREE_PREFIX` を明示受け渡しへ変更する。
  - 対象: `scripts/yb_restart.sh`, `scripts/yb_start.sh`
  - 依存: `fix-panes-schema`
  - 状態: 未着手

## Phase 3: 機能追加

- [ ] **[unify-sendkeys-spec](unify-sendkeys-spec/)** — send-keys 仕様を `config.yaml` の共通プロトコルへ集約し、プロンプト記述を参照型に統一する。
  - 対象: `.yamibaito/config.yaml`, `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`
  - 依存: `fix-prompt-spec-consistency`
  - 状態: 未着手
- [ ] **[add-cleanup-command](add-cleanup-command/)** — stale queue/panes を dry-run と archive 退避で安全掃除する `yb cleanup` を追加する。
  - 対象: `bin/yb`, `scripts/yb_cleanup.sh`（新規）, `scripts/yb_common.sh`
  - 依存: なし
  - 状態: 未着手
- [ ] **[externalize-worker-names](externalize-worker-names/)** — worker 表示名を設定ファイル化し、pane 表示と dashboard 表示の命名を運用設定で制御可能にする。
  - 対象: `templates/config.yaml`, `.yamibaito/config.yaml`, `scripts/yb_start.sh`
  - 依存: なし
  - 状態: 未着手
- [ ] **[add-worker-runtime-adapter](add-worker-runtime-adapter/)** — worker ごとの runtime 設定を導入し、`yb_run_worker` を adapter 分岐で実行する。
  - 対象: `.yamibaito/config.yaml`, `templates/config.yaml`, `scripts/yb_run_worker.sh`, `scripts/yb_start.sh`
  - 依存: なし
  - 状態: 未着手

## Phase 4: 高レイヤー機能

- [ ] **[add-structured-logging](add-structured-logging/)** — `start/collect/restart` に共通 JSONL ログ基盤を導入し、`session_id/cmd_id` で相関追跡可能にする。
  - 対象: `scripts/lib/yb_logging.sh`（新規）, `scripts/yb_start.sh`, `scripts/yb_collect.sh`, `scripts/yb_restart.sh`
  - 依存: Phase 2 完了（`fix-prompt-spec-consistency`, `fix-collect-reset-guard`, `refactor-dashboard-state`, `add-version-management`, `fix-restart-grep-shim`）
  - 状態: 未着手
- [ ] **[add-skill-mvp](add-skill-mvp/)** — skill テンプレート・index・`yb skill` CLI を実装し、collect の候補検出と登録フローを接続する。
  - 対象: `bin/yb`, `scripts/yb_skill.sh`（新規）, `scripts/yb_collect.sh`, `.yamibaito/templates/skill/SKILL.md.tmpl`（新規）, `.yamibaito/skills/index.yaml`（新規）
  - 依存: Phase 2 完了（`fix-prompt-spec-consistency`, `fix-collect-reset-guard`, `refactor-dashboard-state`, `add-version-management`, `fix-restart-grep-shim`）
  - 状態: 未着手
