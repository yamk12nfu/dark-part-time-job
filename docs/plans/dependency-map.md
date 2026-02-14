# Plan Dependency Map

> 16 計画の依存関係・ファイル競合を整理し、並列実装の可否を判断するための資料。

## 凡例

- `→` : 論理依存（左が先に完了すべき）
- `⚠ FILE` : 同一ファイルを変更するため同時実装不可（RACE-001）
- `✅ 並列可` : 依存もファイル競合もなく同時実装可能

---

## 1. 論理依存チェーン

### Chain A: プロンプト正規化

```
fix-prompts-single-source
  → fix-prompt-spec-consistency
    → unify-sendkeys-spec
```

- fix-prompts-single-source が prompts/ を symlink 化し single source 化
- fix-prompt-spec-consistency がその上で spec_version / prompt_version を統一
- unify-sendkeys-spec が config.yaml に send-keys 仕様を集約

### Chain B: Dashboard 信頼性

```
fix-dashboard-atomic-write
  → refactor-dashboard-state
```

- fix-dashboard-atomic-write が flock + atomic write で競合排除
- refactor-dashboard-state がその安定基盤の上で state/render 分離

### Chain C: Panes スキーマ

```
fix-panes-schema
  → add-version-management
```

- fix-panes-schema が panes.json を schema_version: 2 に移行
- add-version-management がその新スキーマに orchestrator_version を埋め込む

---

## 2. ファイル競合マトリクス

各計画が変更するファイルの一覧。同じファイルを触る計画は同時にワーカーへ振れない。

### `scripts/yb_start.sh`（最多競合: 8 計画）

| 計画 | 変更内容 |
|------|----------|
| add-structured-logging | ログ出力追加 |
| add-version-management | バージョン埋め込み |
| add-worker-runtime-adapter | runtime 設定読み込み |
| externalize-worker-names | 表示名設定読み込み |
| fix-panes-schema | panes.json 生成形式変更 |
| fix-prompts-single-source | プロンプトパス解決変更 |
| fix-restart-grep-shim | env var 優先処理追加 |
| fix-startup-readiness | readiness check 追加 |

### `scripts/yb_collect.sh`（6 計画）

| 計画 | 変更内容 |
|------|----------|
| add-skill-mvp | index.yaml 連携 |
| add-structured-logging | ログ出力追加 |
| fix-collect-reset-guard | idle リセットガード |
| fix-dashboard-atomic-write | flock + atomic write |
| improve-plan-mode | plan 完了チェック追加 |
| refactor-dashboard-state | state/render 分離 |

### `bin/yb`

| 計画 | 変更内容 |
|------|----------|
| add-cleanup-command | cleanup サブコマンド追加 |
| add-skill-mvp | skill サブコマンド追加 |
| add-version-management | --version フラグ追加 |

### `scripts/yb_restart.sh`

| 計画 | 変更内容 |
|------|----------|
| add-structured-logging | ログ出力追加 |
| fix-panes-schema | panes ローダー変更 |
| fix-restart-grep-shim | grep shim 除去 |

### `.yamibaito/config.yaml`

| 計画 | 変更内容 |
|------|----------|
| add-worker-runtime-adapter | runtime 設定追加 |
| unify-sendkeys-spec | send-keys protocol 追加 |

### `.yamibaito/prompts/*`

| 計画 | 変更内容 |
|------|----------|
| fix-prompt-spec-consistency | version/spec 統一 |
| unify-sendkeys-spec | config 参照に置換 |

### `scripts/yb_init_repo.sh`

| 計画 | 変更内容 |
|------|----------|
| add-version-management | VERSION 埋め込み |
| fix-prompts-single-source | symlink 生成 |

### `scripts/yb_plan.sh`

| 計画 | 変更内容 |
|------|----------|
| add-version-management | version 埋め込み |
| fix-prompts-single-source | パス解決変更 |
| improve-plan-mode | 出力テンプレート強制 |

---

## 3. 推奨実装フェーズ

ファイル競合と論理依存の両方を考慮した、最大並列度のフェーズ分け。

### Phase 1: 基盤修正

| グループ | 計画 | 主な変更対象 | 備考 |
|----------|------|-------------|------|
| **P1-A** | fix-prompts-single-source | init_repo, start, plan | Chain A の起点 |
| **P1-B** | fix-panes-schema | lib/panes.py(新), start, restart, stop | Chain C の起点 |
| **P1-C** | fix-dashboard-atomic-write | collect | Chain B の起点 |
| **P1-D** | fix-startup-readiness | start | ⚠ P1-A, P1-B と start.sh 競合 |

> **最大並列**: P1-A + P1-C（start.sh 競合なし）。次に P1-B。最後に P1-D。

### Phase 2: 依存解消

| グループ | 計画 | 先行依存 | 主な変更対象 |
|----------|------|----------|-------------|
| **P2-A** | fix-prompt-spec-consistency | ← fix-prompts-single-source | prompts/* |
| **P2-B** | fix-collect-reset-guard | ← fix-dashboard-atomic-write ※推奨 | collect |
| **P2-C** | refactor-dashboard-state | ← fix-dashboard-atomic-write | collect |
| **P2-D** | add-version-management | ← fix-panes-schema | VERSION(新), bin/yb, start, plan, init_repo |
| **P2-E** | fix-restart-grep-shim | ← fix-panes-schema ※restart.sh 競合 | restart, start |

> **最大並列**: P2-A + P2-B + P2-D（ファイル競合なし）。次に P2-C + P2-E。

### Phase 3: 機能追加

| グループ | 計画 | 先行依存 | 主な変更対象 |
|----------|------|----------|-------------|
| **P3-A** | unify-sendkeys-spec | ← fix-prompt-spec-consistency | config.yaml, prompts |
| **P3-B** | add-cleanup-command | なし | bin/yb, yb_cleanup.sh(新) |
| **P3-C** | externalize-worker-names | なし | config.yaml, start |
| **P3-D** | add-worker-runtime-adapter | なし | config.yaml, start, run_worker |

> **最大並列**: P3-A + P3-B（競合なし）。P3-C と P3-D は config + start 競合で順次。

### Phase 4: 高レイヤー機能

| グループ | 計画 | 先行依存 | 主な変更対象 |
|----------|------|----------|-------------|
| **P4-A** | add-structured-logging | Phase 2 完了後 | lib/yb_logging.sh(新), start, restart, collect |
| **P4-B** | add-skill-mvp | Phase 2 完了後 | templates(新), skills(新), bin/yb, collect |
| **P4-C** | improve-plan-mode | Phase 2 完了後 | plan, collect, dashboard |

> **最大並列**: collect.sh で全計画が競合するため順次推奨。P4-A は広範囲に影響するため単独実行が安全。

---

## 4. 依存グラフ

```
Phase 1                   Phase 2                    Phase 3                 Phase 4
──────────────────────────────────────────────────────────────────────────────────────

[prompts-single-source]─→ [prompt-spec-consistency]─→ [unify-sendkeys-spec]

[panes-schema] ─────────→ [version-management]
                     └──→ [restart-grep-shim]

[atomic-write] ─────────→ [dashboard-state]                                [logging]
                     └──→ [collect-reset-guard]                            [skill-mvp]
                                                                           [plan-mode]
[startup-readiness]

                          [cleanup-command] ──────→ (独立)
                          [ext-worker-names] ─────→ (独立)
                          [worker-runtime-adapter]→ (独立)
```

---

## 5. クイックリファレンス: 完全独立の計画

以下は論理依存なしでどのフェーズでも単独実装可能。
ただしファイル競合は上記マトリクスを確認のこと。

| 計画 | 新規ファイル中心 | 競合リスク |
|------|-----------------|-----------|
| add-cleanup-command | ✅ yb_cleanup.sh | 低（bin/yb のみ共有） |
| add-worker-runtime-adapter | — | 中（config + start） |
| externalize-worker-names | — | 中（config + start） |
| fix-startup-readiness | — | 中（start） |
