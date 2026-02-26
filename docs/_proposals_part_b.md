## B. 既存改善計画の進捗棚卸し

### 概況
`docs/plans/progress-checklist.md` のチェックボックス基準では、15計画中 **完了 3件 / 進行中 0件 / 未着手 12件**。  
Phase 1 の基盤修正は3件完了しており、Phase 2 以降は着手待ちが中心。

### ステータス一覧

| # | 計画名 | ステータス | 概要 | 備考 |
|---|--------|-----------|------|------|
| 1 | fix-prompts-single-source | 完了 | `prompts/` を単一正本化 | Chain A 起点（後続依存あり） |
| 2 | fix-panes-schema | 完了 | panes schema v2 へ移行 | Chain C 起点（後続依存あり） |
| 3 | fix-dashboard-atomic-write | 完了 | `yb collect` に lock + atomic write 導入 | チェックは完了だが行内状態文言は未着手表記 |
| 4 | fix-startup-readiness | 未着手 | 起動固定 `sleep` を readiness check 化 | 過去着手後にrevert済みの注記あり |
| 5 | fix-prompt-spec-consistency | 未着手 | 4種プロンプトの front matter /語彙統一 | `fix-prompts-single-source` 依存 |
| 6 | fix-collect-reset-guard | 未着手 | idle リセットに task/parent 一致ガード追加 | `fix-dashboard-atomic-write` 依存 |
| 7 | refactor-dashboard-state | 未着手 | collect の収集/描画分離と state 正本化 | `fix-dashboard-atomic-write` 依存 |
| 8 | add-version-management | 未着手 | `VERSION` 正本化と埋め込み実装 | `fix-panes-schema` 依存 |
| 9 | fix-restart-grep-shim | 未着手 | restart の grep shim 廃止 | `fix-panes-schema` 依存 |
| 10 | unify-sendkeys-spec | 未着手 | send-keys 仕様を config 集約 | `fix-prompt-spec-consistency` 依存 |
| 11 | add-cleanup-command | 未着手 | `yb cleanup`（dry-run/archive）追加 | 論理依存なし |
| 12 | externalize-worker-names | 未着手 | worker 表示名を設定外出し | 論理依存なし（`start/config` 競合注意） |
| 13 | add-worker-runtime-adapter | 未着手 | worker runtime adapter 分岐導入 | 論理依存なし（`start/config` 競合注意） |
| 14 | add-structured-logging | 未着手 | start/collect/restart 共通 JSONL ログ基盤 | Phase 2 完了が前提 |
| 15 | add-skill-mvp | 未着手 | skill テンプレート・index・`yb skill` 実装 | Phase 2 完了が前提 |

### 推奨着手順序
1. **fix-prompt-spec-consistency**: Chain A を前進させ、`unify-sendkeys-spec` の前提を解消できる。
2. **fix-collect-reset-guard**: 完了済みの `fix-dashboard-atomic-write` の直後に、運用上の誤リセットリスクを先に低減できる。
3. **add-version-management**: Chain C の未着手依存を1つ解消しつつ、CLI/生成物のトレーサビリティを早期に確保できる。
4. **refactor-dashboard-state**: `collect` 系の基盤分離を進め、Phase 4 の高レイヤー機能（logging/skill）に備える。
5. **fix-restart-grep-shim**: restart 系の暫定実装を解消し、`scripts/yb_restart.sh` の後続改修競合を減らす。

> 補足: `dependency-map.md` は 16計画（`improve-plan-mode` を含む）前提だが、本棚卸しは `progress-checklist.md` の15計画を対象に整理した。
