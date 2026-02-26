#### C-1. テスト自動化基盤
- **課題**: 自動テスト方針が `policies.tests: none` で、変更時の回帰検知が実運用で効かない。`tests/` ディレクトリは存在せず、bash実行フローのE2Eが未整備。
- **提案内容**: `scripts/lib/` の単体テストを維持しつつ、`yb_start`→`yb_dispatch`→`yb_run_worker`→`yb_collect` を通す bash E2E（正常系/異常系）を追加する。CI では PR ごとに最小E2Eを自動実行する。
- **根拠**: `.yamibaito/config.yaml` の `policies.tests: none`（line 11）。`tests/` は `find tests -maxdepth 3 -type f` で未存在。既存テストは `scripts/lib/test_feedback.py`（line 4 の unittest 実行）と `scripts/lib/test_collect_feedback.py`（line 4, 72）に集中し、オーケストレーション全体のE2Eは未確認。
- **期待効果**: 回帰の早期検知により、リファクタ時の手戻りを削減。CI連携の前提を整備し、リリース判断を定量化できる。
- **優先度**: High

#### C-2. コスト管理・トークン使用量トラッキング
- **課題**: 「API 代金の無駄」を禁止している一方で、実測ベースのコスト/トークン可視化がないため、運用上の最適化判断ができない。
- **提案内容**: workerレポートに `runtime` `model` `input_tokens` `output_tokens` `cost_usd` を追加し、`yb_collect` で cmd/task/worker 単位に集計する。`config.yaml` に予算閾値（例: 日次上限）を追加し、超過時に警告を出す。
- **根拠**: `.yamibaito/prompts/oyabun.md` の F004 は `reason: "API 代金の無駄"`（line 25-29, 111）。`.yamibaito/feedback/global.md` はテンプレート上 `expected_metric` はあるが（line 19）、既存エントリ（line 30-38）にコスト実績の記録なし。`scripts/yb_collect.sh` の `report_keys`（line 916-935）にもコスト/トークン項目がない。
- **期待効果**: `claude` / `codex` / `gemini` の runtime選択を、品質だけでなく単価・トークン効率で比較できる。
- **優先度**: High

#### C-3. 通知・外部連携（Slack/Discord/Webhook）
- **課題**: 現在の通知は tmux セッション内のメッセージ送信のみで、セッション外から完了・失敗・要対応を受け取れない。
- **提案内容**: `YB_NOTIFY_WEBHOOK_URL` を起点に Slack/Discord/Webhook 通知アダプタを追加し、`completed` / `failed` / `rework` / `escalation` 発生時にJSON通知を送る。
- **セキュリティ要件**:
  送信時は `X-Yamibaito-Signature`（HMAC-SHA256）を必須化し、受信側で本文＋timestampの署名検証を行う。
  送信先は事前登録した allowlist（scheme/host/path prefix）に限定し、動的URLやIP直指定を拒否する。
  Webhook URL/シークレットは環境変数または vault 保管とし、ログ・dashboard・report では先頭/末尾以外をマスキングする。
  漏えい疑い時は「旧鍵無効化→新鍵払い出し→疎通確認→監査ログ記録」を1 runbookで即時実行できるようにする。
- **再送制御（具体値）**:
  `retry_max=3`、`timeout_seconds=30`、`backoff=exponential(1s,2s,4s)+jitter(0-500ms)` を標準値にする。
  `idempotency_key=<cmd_id>:<task_id>:<event_type>:<attempt_group>` を付与し、受信側で重複受理を抑止する。
  最終失敗時は dead letter queue（例: `.yamibaito/queue/dead_letters/notify.jsonl`）へ退避し、`yb_collect` で可視化して手動再送可能にする。
- **根拠**: `.yamibaito/panes.json` は tmux ルーティング情報のみ（line 3-20）。`scripts/yb_run_worker.sh` の通知は `tmux send-keys` のみ（line 125-129）、`scripts/yb_collect.sh` も親分通知は `tmux send-keys` のみ（line 1431-1443）。`scripts/yb_start.sh` の export は `YB_SESSION_ID` 等に限られ（line 325）、3スクリプト全体に `YB_NOTIFY`/`WEBHOOK`/`SIGNATURE` 識別子がなく、Webhook secret 用の環境変数・署名検証・送信先制限・鍵ローテーション処理が現状存在しない。
- **期待効果**: 非同期運用でも進捗把握が可能になり、長時間タスクの完了検知遅延を低減できる。
- **優先度**: Medium

#### C-4. メトリクス・アナリティクス基盤
- **課題**: 現状ダッシュボードは件数中心で、リードタイム・再作業率・稼働率などの運用品質指標を継続監視できない。
- **提案内容**: `events.jsonl` 形式で `assigned` `started` `finished` `reviewed` を記録し、`yb_collect` で `task completion time`、`rework rate`、`worker utilization`、`queue wait time` を算出して `dashboard.md` に追加する。
- **根拠**: `scripts/yb_collect.sh` はタスク読込で `assigned_at`/`status` を扱う（line 865）一方、完了表示は `finished_at` の生値出力のみ（line 1342）で所要時間計算がない。生成セクションも `品質ゲート` と `feedback` の件数集計中心（line 1275-1296）。実際の `dashboard.md` も件数表主体（line 23-45）。
- **期待効果**: ボトルネック特定と品質ゲート閾値の調整が可能になり、改善活動を定量的に回せる。
- **優先度**: Medium
