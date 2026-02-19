# 品質ゲート＋レビュープロセス 設計概要

## 1. 今の流れ（品質ゲートなし）

```text
組長: 指示
  → 親分: YAML に書く
    → 若頭: タスク分割して若衆にアサイン
      → 若衆: 実装 → report 書く → 「終わりました」
    → 若頭: report 集めて dashboard 更新 → 完了
```

問題点: 若衆が「できた」と言えばそのまま通る。誰もチェックしていない。

## 2. 品質ゲート導入後の流れ

```text
組長: 指示
  → 親分: YAML に書く
    → 若頭: タスク分割して若衆Aにアサイン（phase: implement）
      → 若衆A（実装担当）: 実装 → report 書く → 「終わりました」
    → 若頭: report を見る → 品質ゲート ON だな
      → 若頭: 若衆B にレビュータスクを自動発行（phase: review, persona: qa_engineer）
        → 若衆B（レビュー担当）: 6観点チェックリストに沿ってレビュー
          → 全部 OK → review_result: approve → 完了
          → NG あり → review_result: rework + 修正指示
    → 若頭: rework を検知
      → 若衆A に修正タスクを再発行（loop_count +1）
        → 若衆A: 修正 → report → 若衆B: 再レビュー → ...
      → 3回差し戻しても直らない → 親分にエスカレーション
```

## 3. 設計のポイント（5つ）

### ポイント1: タスクに「フェーズ」がつく

- 今まで：タスクは「やれ」で終わり
- これから：タスクに `phase: implement | review` がつく
- 以下の YAML 例を記載:

```yaml
# 実装タスク
phase: implement
assigned_to: worker_001  # 銀次が実装

# ↓ 完了後、若頭が自動で発行

# レビュータスク
phase: review
assigned_to: worker_002  # 龍がレビュー（必ず別人）
persona: qa_engineer
```

### ポイント2: レビューは固定6観点のチェックリスト

- 以下のテーブルを記載:

| # | 観点 | 何を見るか |
|---|---|---|
| 1 | セキュリティ整合 | 認可・入力検証・秘密情報の扱い |
| 2 | エラー/リトライ/タイムアウト | 失敗時の復旧、再試行制御 |
| 3 | 可観測性 | ログ・メトリクス・障害切り分け |
| 4 | テスト戦略 | 正常系/異常系/回帰の網羅 |
| 5 | 受け入れ条件 | PRD/SPEC の基準を満たすか |
| 6 | 要件抜け漏れ | 仕様・制約の取りこぼし |

- 補足: レビュー担当はこの6項目すべてに ok | ng + コメントを返す。フリーテキストで「なんとなくOK」は許さない。

### ポイント3: 差し戻しは YAML で構造化

- レビューで NG が出た場合の report YAML 例を記載:

```yaml
review_result: rework
review_checklist:
  - item_id: security_alignment
    result: ng
    comment: "入力バリデーション欠如"
rework_instructions:
  - "API入力を allowlist で検証すること"
```

- 補足: 若頭はこれを見て、修正指示付きのタスク YAML を元の実装担当に自動で再発行する。実装担当は何を直せばいいか明確にわかる。

### ポイント4: gate_id で一連の流れを追跡

- 実装 → レビュー → 差し戻し → 再実装 → 再レビューの一連を gate_id で束ねる
- 以下の追跡例を記載:

```text
gate_id: "cmd_0022_001"
  ├── implement (worker_001, loop_count=0)
  ├── review    (worker_002, loop_count=0) → rework
  ├── implement (worker_001, loop_count=1) ← 差し戻し
  ├── review    (worker_002, loop_count=1) → approve ← 完了
```

- 補足: 向こう（tmux-agents-starter）にはなかった仕組み。「何回差し戻されたか」「誰がレビューしたか」が全部 YAML に残る。

### ポイント5: 既存の動きは壊さない

- config.yaml で quality_gate.enabled: false にすれば今まで通り
- 旧フォーマットの YAML（phase フィールドがないもの）は implement 扱い
- 段階的に導入できる設計

## 4. 実装タスクの依存関係

```text
QG-001: config + テンプレート作成 ← 基盤（これが先）
   │
   ├── QG-002: Task YAML スキーマ拡張 ─┐
   │                                    ├── QG-004: 若頭プロンプト改修（核心）
   └── QG-003: Report YAML + 若衆プロンプト ┘          │
                                                       │
                                            QG-005: yb_collect 集約改修
```

補足: QG-001 → QG-002/003（並列）→ QG-004 → QG-005 の順で流れる。

## 5. 関連ドキュメント

- PRD（要件定義）: .yamibaito/plan/2026-02-18--quality-gate/PRD.md
- SPEC（技術仕様）: .yamibaito/plan/2026-02-18--quality-gate/SPEC.md
- tasks.yaml（タスク分割）: .yamibaito/plan/2026-02-18--quality-gate/tasks.yaml
- 統合ロードマップ: docs/integration-roadmap-tmux-agents.md
- コード調査: docs/research-tmux-agents-internals.md
