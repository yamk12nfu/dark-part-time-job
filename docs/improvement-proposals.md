# Kumichou Orchestrator 改善・機能追加提案レポート

## A. エグゼクティブサマリ
- **成熟度評価**: 現状は「基盤整備の初期段階（目安: 2/5）」。
  既存計画は 15件中 3件完了・12件未着手で、Phase 1 の土台整備は完了した一方、運用自動化・可視化・安全性の中核機能はこれから実装する段階にある。
- **新規提案の全体像**: 提案は全12件。優先度内訳は **High 7件 / Medium 5件 / Low 0件**。
  12件すべてを短期/中期/長期に配置し、直近は「既存計画の未着手解消 + テスト基盤整備」を先行する。
- **実行方針**: 短期で品質ゲート再現性を確立し、中期でコスト・メトリクス・通知に加えてセキュリティ監査（C-11）とリカバリ自動化（C-8）を運用標準化する。長期で Web UI/CI/マルチリポ/DAG/ドキュメント自動生成（C-10）/プラグイン化へ展開する三段構えを推奨する。

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

## C. 新規提案
#### C-1. テスト自動化基盤
- **課題**: 自動テスト方針が `policies.tests: none` で、変更時の回帰検知が実運用で効かない。`tests/` ディレクトリは存在せず、bash実行フローのE2Eが未整備。
- **提案内容**: `scripts/lib/` の単体テストを維持しつつ、`yb_start`→`yb_dispatch`→`yb_run_worker`→`yb_collect` を通す bash E2E（正常系/異常系）を追加する。CI では PR ごとに最小E2Eを自動実行する。
- **根拠**: `.yamibaito/config.yaml` の `policies.tests: none`（line 11）。`bin/yb` のコマンド一覧に test 系サブコマンドがなく（line 10-21）、`scripts/yb_collect.sh` は品質ゲート集計を行うものの（line 1275-1282）テスト実行ステップ自体は持たない。
- **期待効果**: 回帰の早期検知により、リファクタ時の手戻りを削減。CI連携の前提を整備し、リリース判断を定量化できる。
- **security**:
  - 認可主体: フル E2E 実行は `maintainer`/`reviewer` のみ許可し、`contributor` は read-only の smoke テストのみ許可する。
  - 入力検証: テストシナリオ ID と対象コマンドは allowlist（`start/dispatch/run-worker/collect`）一致必須とし、`worker_id` は `^worker_[0-9]{3}$` 以外を拒否する。
  - 秘密情報保管: テスト用 token/API key は CI secret store から注入し、stdout/stderr とレポート出力時は値をマスクする。
- **failure policy**:
  - retry/backoff/timeout: flaky 判定の E2E は最大 2 回再試行、backoff は指数（1s/3s）、1 シナリオ timeout は 180s、ジョブ全体 timeout は 20 分。
  - circuit break: デフォルトブランチで同一シナリオが 3 連続失敗したら full E2E を停止し、smoke のみ継続する。
  - 手動介入条件: circuit open、または 2 連続 timeout でログ未収集の場合に QA がログ採取付きで手動再実行する。
- **observability**:
  - 構造化ログキー: `event`, `suite`, `case_id`, `cmd_id`, `task_id`, `worker_id`, `attempt`, `duration_ms`, `exit_code`, `correlation_id`。
  - 主要メトリクス: `yb_test_pass_rate`, `yb_test_flaky_rate`, `yb_test_duration_ms_p95`, `yb_test_timeout_total`。
  - トレース/相関ID: `parent_cmd_id:task_id` を `correlation_id` として CI→worker report→collect に引き継ぐ。
- **test strategy**:
  - 正常系: `yb start` 起動後に `yb run-worker` 完了通知から `yb collect` まで通し、最終レポートが生成されることを検証する。
  - 異常系: task/report YAML 欠損、不正 schema、collect timeout を注入し、期待どおりに fail-fast と warning 記録が行われることを検証する。
  - 回帰: 既存の `review_result` 集計・`dashboard.md` 生成フォーマットが変更されないことを snapshot 比較で固定化する。
- **優先度**: High

#### C-2. コスト管理・トークン使用量トラッキング
- **課題**: 「API 代金の無駄」を禁止している一方で、実測ベースのコスト/トークン可視化がないため、運用上の最適化判断ができない。
- **提案内容**: workerレポートに `runtime` `model` `input_tokens` `output_tokens` `cost_usd` を追加し、`yb_collect` で cmd/task/worker 単位に集計する。`config.yaml` に予算閾値（例: 日次上限）を追加し、超過時に警告を出す。
- **根拠**: `.yamibaito/prompts/oyabun.md` の F004 は `reason: "API 代金の無駄"`（line 25-29, 111）。`.yamibaito/feedback/global.md` はテンプレート上 `expected_metric` はあるが（line 19）、既存エントリ（line 30-38）にコスト実績の記録なし。`scripts/yb_collect.sh` の `report_keys`（line 916-935）にもコスト/トークン項目がなく、`.yamibaito/queue/reports/worker_003_report.yaml` も同項目を未保持（line 1-30）。
- **期待効果**: `claude` / `codex` / `gemini` の runtime選択を、品質だけでなく単価・トークン効率で比較できる。
- **security**:
  - 認可主体: 予算閾値・単価テーブルの更新は `maintainer` のみ許可し、worker は計測値書き込みのみ許可する。
  - 入力検証: `input_tokens`/`output_tokens` は 0 以上整数、`cost_usd` は 0 以上の小数（上限付き）を必須にし、欠損・負値・非数値は reject する。
  - 秘密情報保管: ベンダー API 資格情報は secret store 管理とし、レポート/ログには runtime 名と集計値のみを出力する。
- **failure policy**:
  - retry/backoff/timeout: token/cost 集計処理は最大 3 回再試行、指数 backoff（2s/4s/8s）、1 回の集計 timeout は 30s。
  - circuit break: 10 分以内に集計パース失敗が 5 回を超えた場合は自動課金アラートを停止し、raw レポート蓄積のみ継続する。
  - 手動介入条件: circuit open、または日次コスト差分が前日比 10% 超の異常値を検知した場合に運用者が手動再集計する。
- **observability**:
  - 構造化ログキー: `event`, `worker_id`, `task_id`, `runtime`, `model`, `input_tokens`, `output_tokens`, `cost_usd`, `budget_limit_usd`, `over_budget`, `correlation_id`。
  - 主要メトリクス: `yb_token_input_total`, `yb_token_output_total`, `yb_cost_usd_total`, `yb_budget_overrun_count`。
  - トレース/相関ID: `parent_cmd_id:task_id` を集計キーにし、worker report と dashboard のコスト表示を相互参照可能にする。
- **test strategy**:
  - 正常系: runtime/model ごとの token/cost が worker→task→cmd で正しく集計され、予算閾値超過時に警告が出ることを検証する。
  - 異常系: 非数値 token、負値 cost、未定義 runtime を投入し、集計拒否と warning 出力が行われることを検証する。
  - 回帰: 既存 `worker_XXX_report.yaml` の必須項目と `yb_collect` 既存集計（quality gate/feedback）が破壊されないことを contract test で検証する。
- **優先度**: High

#### C-3. 通知・外部連携（Slack/Discord/Webhook）
- **課題**: 現在の通知は tmux セッション内のメッセージ送信のみで、セッション外から完了・失敗・要対応を受け取れない。
- **提案内容**: `YB_NOTIFY_WEBHOOK_URL` を起点に Slack/Discord/Webhook 通知アダプタを追加し、`completed` / `failed` / `rework` / `escalation` 発生時にJSON通知を送る。
- **security**:
  送信時は `X-Yamibaito-Signature`（HMAC-SHA256）を必須化し、受信側で本文＋timestampの署名検証を行う。
  送信先は事前登録した allowlist（scheme/host/path prefix）に限定し、動的URLやIP直指定を拒否する。
  Webhook URL/シークレットは環境変数または vault 保管とし、ログ・dashboard・report では先頭/末尾以外をマスキングする。
  漏えい疑い時は「旧鍵無効化→新鍵払い出し→疎通確認→監査ログ記録」を1 runbookで即時実行できるようにする。
- **failure policy**:
  `retry_max=3`、`timeout_seconds=30`、`backoff=exponential(1s,2s,4s)+jitter(0-500ms)` を標準値にする。
  `idempotency_key=<cmd_id>:<task_id>:<event_type>:<attempt_group>` を付与し、受信側で重複受理を抑止する。
  最終失敗時は dead letter queue（例: `.yamibaito/queue/dead_letters/notify.jsonl`）へ退避し、`yb_collect` で可視化して手動再送可能にする。
  10 分以内に同一送信先で 5 回連続失敗した場合は circuit open とし、以降 15 分は新規送信を停止して DLQ のみへ退避する。
  circuit open 中、または `rework`/`escalation` 通知が DLQ に滞留した場合は運用者の手動再送を必須にする。
- **根拠**: `scripts/yb_run_worker.sh` の通知は `tmux send-keys` のみ（line 125-129）、`scripts/yb_collect.sh` も親分通知は `tmux send-keys` のみ（line 1431-1443）。`scripts/yb_start.sh` の export は `YB_SESSION_ID` 等に限られ（line 325）、`bin/yb` の公開コマンドにも通知サブコマンドはない（line 10-21）。
- **期待効果**: 非同期運用でも進捗把握が可能になり、長時間タスクの完了検知遅延を低減できる。
- **observability**:
  - 構造化ログキー: `event`, `event_type`, `destination`, `task_id`, `cmd_id`, `attempt`, `status_code`, `latency_ms`, `dlq_written`, `correlation_id`。
  - 主要メトリクス: `yb_notify_success_total`, `yb_notify_failure_total`, `yb_notify_latency_ms_p95`, `yb_notify_dlq_size`。
  - トレース/相関ID: `cmd_id:task_id:event_type` を通知単位の相関キーとし、送信試行から DLQ 退避まで追跡する。
- **test strategy**:
  - 正常系: `completed`/`failed`/`rework`/`escalation` 各イベントが署名付きで送信され、受信側で重複抑止されることを検証する。
  - 異常系: 署名不一致、allowlist 外 URL、タイムアウト連続発生で retry→circuit break→DLQ 退避が作動することを検証する。
  - 回帰: 既存 tmux 通知（`worker finished`、`collect complete`）が webhook 未設定時に従来どおり動作することを検証する。
- **優先度**: Medium

#### C-4. メトリクス・アナリティクス基盤
- **課題**: 現状ダッシュボードは件数中心で、リードタイム・再作業率・稼働率などの運用品質指標を継続監視できない。
- **提案内容**: `events.jsonl` 形式で `assigned` `started` `finished` `reviewed` を記録し、`yb_collect` で `task completion time`、`rework rate`、`worker utilization`、`queue wait time` を算出して `dashboard.md` に追加する。
- **根拠**: `scripts/yb_collect.sh` はタスク読込で `assigned_at`/`status` を扱う（line 865）一方、完了表示は `finished_at` の生値出力のみ（line 1342）で所要時間計算がない。生成セクションも `品質ゲート` と `feedback` の件数集計中心（line 1275-1296）。README でも `dashboard.md` は `yb collect` で再生成する静的成果物として扱われている（line 65, 104）。
- **期待効果**: ボトルネック特定と品質ゲート閾値の調整が可能になり、改善活動を定量的に回せる。
- **security**:
  - 認可主体: メトリクス算出と `events.jsonl` 追記は `yb collect` 実行主体のみ許可し、一般 worker は参照専用とする。
  - 入力検証: `event_type` は `assigned|started|finished|reviewed` の allowlist、`task_id` 形式と timestamp（ISO8601）を必須検証し、破損行は隔離する。
  - 秘密情報保管: `summary`/`notes` 由来の機微情報は KPI 集計対象から除外し、可視化は task 識別子と統計値のみに限定する。
- **failure policy**:
  - retry/backoff/timeout: event 追記・集計は最大 3 回再試行、指数 backoff（1s/2s/4s）、集計 timeout は 60s（既存 collect timeout と同値）。
  - circuit break: 10 分で集計失敗 5 回、または `events.jsonl` 破損率 20% 超で KPI 拡張表示を停止し、既存件数表示モードへフォールバックする。
  - 手動介入条件: circuit open、または `events.jsonl` の整合性エラー検知時に運用者がファイル修復後 `yb collect` を再実行する。
- **observability**:
  - 構造化ログキー: `event`, `cmd_id`, `task_id`, `worker_id`, `status`, `assigned_at`, `finished_at`, `duration_ms`, `queue_wait_ms`, `correlation_id`。
  - 主要メトリクス: `yb_task_completion_seconds_p95`, `yb_rework_rate`, `yb_worker_utilization`, `yb_queue_wait_seconds_p95`。
  - トレース/相関ID: `parent_cmd_id:task_id` を共通キーとして、task lifecycle と dashboard 集計結果を突合可能にする。
- **test strategy**:
  - 正常系: `assigned→started→finished→reviewed` の一連イベントから lead time/rework rate/utilization が期待値どおり算出されることを検証する。
  - 異常系: timestamp 欠損、不正 status、重複イベントを投入し、invalid 行隔離と warning ログ出力が機能することを検証する。
  - 回帰: 既存の品質ゲート表・feedback 集計・完了一覧フォーマットが維持されることを snapshot で検証する。
- **優先度**: Medium

#### C-5. マルチリポジトリ協調タスク
- **課題**: 現状は `--repo` で単一リポジトリのみを実行対象にしており、cross-repo依存タスクを同一セッションで協調実行できない。
- **提案内容**: `.yamibaito/repos.yaml`（`repo_id`, `path`, `depends_on_repo`）と `yb start/dispatch --repo-set <file>` を追加し、`tasks/*.yaml` に `target_repo` を持たせて repo 間依存を解決しながら配車する。
- **根拠**:
  - `bin/yb` の使用法と分岐は単数 `--repo <path>` 前提（`bin/yb:11-20`, `bin/yb:28-67`）。
  - `scripts/yb_start.sh` は単一 `repo_root` 変数で `queue_dir` を1本だけ作成（`scripts/yb_start.sh:7`, `scripts/yb_start.sh:13-15`, `scripts/yb_start.sh:129-131`）。
  - `scripts/yb_dispatch.sh` も worker 起動時に単一 `--repo "{repo_root}"` を渡す実装（`scripts/yb_dispatch.sh:91-94`）。
  - ワーカー環境変数も `YB_REPO_ROOT` 単数で注入される（`scripts/yb_start.sh:325`）。
- **期待効果**: マイクロサービス横断実装を1セッションで連結でき、repo切替や依存待ちの手動調整を削減できる。
- **security**:
  - 認可主体: dispatcher は `repos.yaml` の read のみ、worker は `target_repo` に割当済み worktree のみ read/write、director のみ `--repo-set` 更新を許可。
  - 入力検証: `repo_id` は `repos.yaml` の allowlist 一致必須、`path` は `realpath` で正規化し `..`/symlink 脱出/相対パスを拒否。
  - 秘密情報保管: repo ごとの token は GitHub Secrets またはローカル環境変数で注入し、`repos.yaml`/task YAML へ平文保存しない。
- **failure policy**:
  - retry/backoff/timeout: repo 解決と dispatch API は最大 3 回再試行、指数 backoff（2s/4s/8s, jitter 20%）、1 回の dispatch timeout は 60s。
  - circuit break: 同一 `repo_id` の dispatch 失敗が 10 分で 5 回到達したら 15 分オープンし、その repo への新規割当を停止。
  - 手動介入条件: circuit open が 2 連続、または依存待ち 30 分超のタスクが発生した場合は operator が `repos.yaml` と依存定義を確認して解除。
- **observability**:
  - 構造化ログキー: `event`, `cmd_id`, `task_id`, `repo_id`, `target_repo`, `attempt`, `elapsed_ms`, `result`, `error_code`。
  - 主要メトリクス: `yb_repo_dispatch_success_total`, `yb_repo_dispatch_failure_total`, `yb_repo_dispatch_latency_ms`, `yb_repo_dependency_wait_seconds`。
  - トレース/相関ID: `cmd_id:task_id` から `correlation_id` を生成し、dispatcher→worker へ `YB_CORRELATION_ID` として伝播。
- **test strategy**:
  - 正常系（2 repo 依存の自動配車）、異常系（不正 `repo_id`/`path` 脱出/依存欠損の拒否）、回帰（単一 repo 既存フロー維持）を unit/integration/e2e で分担検証。
- **優先度**: High

#### C-6. CI/CD パイプライン連携
- **課題**: `git-gtr` によるローカル worktree 運用はあるが、approve 後に CI で自動検証・マージ・デプロイする経路がない。
- **提案内容**: `.github/workflows/yb-quality-gate.yml` を追加し、`queue/reports/*_report.yaml` の `review_result: approve` を条件にテスト・品質ゲート・自動マージ判定を実行し、保護ブランチ/デプロイジョブに接続する。
- **根拠**:
  - `.github/` が存在せず GitHub Actions 定義ファイルがない（`.github`: `ls` で `No such file or directory`）。
  - `bin/yb` には `ci`/`deploy` 系サブコマンドがなく `start/dispatch/collect/worktree` 中心（`bin/yb:11-21`, `bin/yb:28-68`）。
  - `scripts/yb_start.sh`・`scripts/yb_worktree_list.sh`・`scripts/yb_restart.sh` は `gtr new/list/rm` などローカル worktree 操作が主（`scripts/yb_start.sh:90-97`, `scripts/yb_worktree_list.sh:69-74`, `scripts/yb_restart.sh:95-106`）。
  - `scripts/yb_collect.sh` は `approve/rework` 集計までで外部 CI 起動処理を持たない（`scripts/yb_collect.sh:1098-1111`, `scripts/yb_collect.sh:1278-1282`）。
- **期待効果**: approve 後の自動マージ・自動デプロイを実現し、品質ゲートを CI 必須チェックへ統合できる。
- **security**:
  - 認可主体: GitHub Actions は最小権限（既定 `contents:read`）、自動マージ job のみ `pull-requests:write`、デプロイは環境保護承認者に限定。
  - 入力検証: トリガー対象を `queue/reports/*_report.yaml` と保護ブランチに限定し、`review_result == approve` と schema 検証を両方満たした時のみ進行。
  - 秘密情報保管: デプロイ鍵・token は GitHub Secrets/Environment Secrets のみ使用し、workflow 内は `::add-mask::` でログ露出を抑止。
- **failure policy**:
  - retry/backoff/timeout: flaky step は 2 回再試行（30s/90s backoff）、workflow 全体 timeout 20 分、deploy job timeout 15 分。
  - circuit break: デフォルトブランチで連続 3 run 失敗時に auto-merge を停止し、`manual-merge-required` ラベル付与へ切替。
  - 手動介入条件: SAST/依存脆弱性 High 以上、または同一原因で 3 回連続失敗時は release manager 承認まで停止。
- **observability**:
  - 構造化ログキー: `workflow`, `run_id`, `sha`, `report_task_id`, `gate_result`, `stage`, `attempt`, `duration_ms`, `error_code`。
  - 主要メトリクス: `yb_ci_gate_pass_rate`, `yb_ci_gate_duration_seconds`, `yb_auto_merge_latency_minutes`, `yb_deploy_success_total`。
  - トレース/相関ID: `run_id` を root に `cmd_id/task_id` を annotation 付与し、ローカル report と CI 実行を相互参照可能にする。
- **test strategy**:
  - 正常系（approve report で test→gate→merge→deploy 通過）、異常系（`rework`/schema 不正/権限不足で停止）、回帰（ローカル `yb collect` 無影響）を unit/integration/e2e で検証。
- **優先度**: High

#### C-7. タスク自動スケジューリング（DAGベース）
- **課題**: 依存関係は手動資料と静的検証に留まり、実行時に `depends_on` を解決して自動で配車する仕組みがない。
- **提案内容**: `yb dispatch` に DAG スケジューラを実装し、`tasks.yaml` の依存グラフから「依存解決済みタスクのみ」を ready queue 化して空き worker へ自動割当する。完了時に後続ノードを自動解放する。
- **根拠**:
  - `docs/plans/dependency-map.md` は依存チェーン/フェーズを人手運用向けに整理した文書（`docs/plans/dependency-map.md:3`, `docs/plans/dependency-map.md:7-9`, `docs/plans/dependency-map.md:126-173`）。
  - `.yamibaito/plan/tasks.yaml` には `depends_on` が定義済み（`.yamibaito/plan/tasks.yaml:14`）。
  - `scripts/yb_dispatch.sh` は `task_id` と `status` だけを読んで `assigned|in_progress` を実行する実装で依存解決がない（`scripts/yb_dispatch.sh:71-91`）。
  - `depends_on`/DAG は `scripts/yb_plan_validate.py` の検証ロジックでのみ参照される（`scripts/yb_plan_validate.py:275`, `scripts/yb_plan_validate.py:334-339`, `scripts/yb_plan_validate.py:379-391`）。
- **期待効果**: Phase分割の運用を自動化し、依存未解決タスクの誤実行防止と worker 稼働率の向上を両立できる。
- **security**:
  - 認可主体: scheduler は queue 状態更新のみ可能、worker は自身に割当済み `task_id` のみ遷移可能、director が DAG 更新権限を保持。
  - 入力検証: `task_id` 形式検証、`depends_on` 実在確認、自己依存/循環依存を拒否し、ノード上限（例: 1000）超過時は計画読み込みを停止。
  - 秘密情報保管: DAG 実行自体は追加 secret を持たず、必要 token は既存環境変数境界を継承し scheduler ログへ出力しない。
- **failure policy**:
  - retry/backoff/timeout: ready queue 更新トランザクションは 4 回再試行、指数 backoff（1s/2s/4s/8s）、lock 取得 timeout 10s。
  - circuit break: lock timeout 5 分で 20 回超、または循環依存エラー 10 件超で auto-scheduling を一時停止。
  - 手動介入条件: circuit open 時、または orphan（依存解決不能）タスクが 5 件超で planner が DAG 定義を修正する。
- **observability**:
  - 構造化ログキー: `event`, `plan_id`, `task_id`, `depends_on`, `ready_queue_size`, `blocked_count`, `attempt`, `result`, `error_code`。
  - 主要メトリクス: `yb_scheduler_ready_queue_size`, `yb_scheduler_dispatch_lag_seconds`, `yb_scheduler_blocked_tasks_total`, `yb_scheduler_circuit_open_total`。
  - トレース/相関ID: `plan_id:task_id` を scheduler/worker 共通の相関キーとし、dispatch から完了報告まで一貫追跡する。
- **test strategy**:
  - 正常系（トポロジカル順の配車）、異常系（循環/欠損依存・競合更新の安全停止）、回帰（依存なしタスクの FIFO 相当維持）を unit/integration/e2e で検証。
- **優先度**: High

#### C-8. ロールバック & git リカバリ自動化
- **課題**: rework 時の git 状態復帰は手動運用で、失敗時も「手動で確認」にフォールバックするため、復旧速度と安全性が担当者依存になっている。
- **提案内容**: `yb recover`（`--task <id> --mode soft|hard`）を追加し、タスク開始時スナップショット（tag/patch）から自動復旧できるようにする。`review_result: rework` で復旧候補を提示し、承認後に自動適用する。
- **根拠**:
  - `bin/yb` に rollback/recover サブコマンドがない（`bin/yb:11-21`, `bin/yb:28-68`）。
  - `scripts/yb_restart.sh` は `worktree remove`/`gtr rm` 失敗時に「手動で確認してください」と警告（`scripts/yb_restart.sh:98-107`）。
  - `scripts/yb_stop.sh` も `gtr rm` 失敗時に同様の手動フォールバック（`scripts/yb_stop.sh:85-87`）。
  - `.yamibaito/config.yaml` の `quality_gate` は `max_rework_loops` など判定設定のみで git 復旧方針がない（`.yamibaito/config.yaml:15-20`）。
  - `scripts/yb_collect.sh` の rework 処理も集計のみで git 操作を行わない（`scripts/yb_collect.sh:1098-1111`）。
- **期待効果**: rework 時の復旧を標準化して MTTR を短縮し、`reset/revert` 誤操作リスクを下げられる。
- **security**:
  - 認可主体: `--mode hard` は director/admin のみ実行可、worker は自身担当タスクに対する `--mode soft` のみ許可。
  - 入力検証: `task_id` は厳格な ID 形式に限定し、snapshot 参照は `.yamibaito/snapshots/` 配下 allowlist（tag/patch）以外を拒否。
  - 秘密情報保管: patch 生成前に secret scan を実施し、検出時は保存中止; git 操作ログでは環境変数値を常時マスクする。
- **failure policy**:
  - retry/backoff/timeout: `git apply`/`git reset` は最大 2 回再試行（3s 固定 backoff）、1 コマンド timeout 20s、recover 全体 timeout 5 分。
  - circuit break: 同一 `task_id` の hard recover 失敗が 2 回連続した時点で自動 recover を停止し read-only モード化。
  - 手動介入条件: conflict 未解消、snapshot 欠損、または secret scan 失敗時は maintainer が手動復旧手順へ移行する。
- **observability**:
  - 構造化ログキー: `event`, `task_id`, `mode`, `snapshot_id`, `git_head_before`, `git_head_after`, `attempt`, `duration_ms`, `result`, `error_code`。
  - 主要メトリクス: `yb_recover_success_total`, `yb_recover_failure_total`, `yb_recover_duration_ms`, `yb_recover_manual_intervention_total`。
  - トレース/相関ID: `task_id` と `review_target_task_id` を共通相関キーにし、rework 判定から recover 実行まで連結追跡する。
- **test strategy**:
  - 正常系（`soft`/`hard` で期待状態へ復旧）、異常系（snapshot 欠損/権限不足/競合差分で circuit break）、回帰（`yb restart/stop` 継続利用）を unit/integration/e2e で検証。
- **優先度**: Medium

#### C-9. Web ダッシュボード（リアルタイム可視化）
- **課題**: `dashboard.md` は Markdown の静的スナップショットで、`yb collect` 実行時のみ更新される。
  検索・複合フィルタ・複数セッション横断の即時監視が運用上ほぼ不可能。
- **提案内容**: `.yamibaito/state/dashboard*.json` を正本にした Web UI（SSE/ポーリング更新）を導入し、`status`/`worker`/`task_id`/`priority`/`session` で絞り込み可能にする。
  入口として `yb dashboard serve` を追加し、`dashboard.md` は後方互換の静的エクスポートに限定する。
- **根拠**: `dashboard.md:1-82` は固定レイアウトで保存されるのみ、`scripts/yb_collect.sh:1150-1367` で `lines` を組み立てて `dashboard.md` を一括上書きしている。
  `docs/plans/refactor-dashboard-state/task.md:33-35` は JSON state/history 正本化を要求し、`docs/plans/progress-checklist.md:36-39` では当該計画が未着手。
- **期待効果**: タスク探索時間の短縮（例: grep/目視中心の確認から UI フィルタ中心へ移行し、一次切り分け時間を 30-50% 短縮）。
  セッション横断監視により、滞留タスクや rework 再発の検知を早期化。
- **security**: 閲覧主体は `maintainer`/`reviewer` のみ許可し、`yb dashboard serve` は起動時にローカル認可トークンを検証する。
  フィルタ入力は `status|worker|task_id|priority|session` の allowlist と文字種検証（`task_id` は `^cmd_[0-9]+_task_[0-9]+`）を必須化し、秘密情報は `DASHBOARD_AUTH_TOKEN` を env/secret store 配置、ログとUIでは token/path を先頭末尾3文字以外マスクする。
  権限外ユーザーのセッション参照は 404 応答に統一し、タスク存在有無の推測を防止する。
- **failure policy**: state 読み込み/SSE 配信失敗は最大3回 retry（2s/4s/8s exponential backoff）、各読取 timeout は 5 秒、SSE 無通信 timeout は 15 秒とする。
  最終失敗時は当該セッションを `stale` 表示へ遷移し `escalation` ログを出力、運用は `yb collect --rebuild-dashboard` による手動復旧を実施する。
- **observability**: 構造化ログは `event`,`task_id`,`worker`,`session`,`query_hash`,`latency_ms`,`retry_count`,`correlation_id` を共通キーとして出力する。
  主要メトリクスは `dashboard_refresh_latency_p95`,`dashboard_refresh_error_rate`,`dashboard_stale_sessions` とし、アラート閾値は「error_rate > 5% (5分)」「latency_p95 > 2000ms (10分)」「stale_sessions >= 20」を採用する。
- **test strategy**: 正常系は `bats test/dashboard_serve.bats` でフィルタ検索・SSE 更新・静的エクスポート互換を integration で検証する。
  異常系は不正フィルタ値/認可失敗/破損 JSON 入力を integration で、回帰は `dashboard.md` 出力差分を snapshot 比較して `./bin/yb dashboard serve --once` を CI 実行する。
  併せて query validator の allowlist/regex を unit で固定化し、入力仕様の退行を防ぐ。
- **優先度**: High

#### C-10. ドキュメント自動生成の拡張
- **課題**: Living Spec は `approve` 連動更新を定義しているが、API ドキュメント生成や配布向け変更ログ自動生成は対象外。
  仕様ドキュメント更新と実装差分追随が reviewer の手作業に依存する。
- **提案内容**: `approve` 後フックに「API 仕様抽出 + 変更ログ生成」ジョブを追加し、`.yamibaito/spec/` 更新に加えて配布用ドキュメントを自動生成する。
  具体的には `scripts/yb_doc_sync.sh`（新規）で差分解析し、`api.md` と release note 断片を生成・検証する。
- **根拠**: `.yamibaito/plan/2026-02-19--living-spec/PRD.md:23` は approve パスへの Living Spec 更新組み込みのみを定義。
  同 PRD の Out of scope（`30-33`）で「完全自動要約・自動生成」「外部公開ドキュメント生成」を除外し、FR でも対象は4ファイル（`37`）に限定される。`.yamibaito/plan/PRD.md:1-28` は汎用テンプレートで API 自動生成要件を持たない。
- **期待効果**: 仕様と実装差分の反映遅延を抑制し、初期学習時の参照分散を削減。
  reviewer のドキュメント更新工数を削減し、オンボーディング時の理解速度を向上。
- **security**: 実行主体は `doc-sync-bot`（approve 後フック専用）に限定し、書き込み先権限は `.yamibaito/spec/` と `docs/releases/` のみ付与する。
  入力は commit range と変更対象パスの allowlist 検証（`..`/絶対パス/外部 URL を拒否）を行い、秘密情報は CI secret store (`GITHUB_TOKEN`,`DOC_SYNC_KEY`) に配置、ログでは token/署名を完全マスクする。
  生成ドキュメント内リンクはリポジトリ相対パスのみ許可し、外部 URL 挿入は検証で失敗扱いにする。
- **failure policy**: 差分取得・生成・検証の各ステップは最大2回 retry（10s/30s backoff）、ジョブ全体 timeout は 90 秒とする。
  最終失敗時は `rework` 用メモを自動添付して `escalation` 通知し、運用は `scripts/yb_doc_sync.sh --from <sha> --to <sha>` の手動復旧フローへ遷移する。
- **observability**: 構造化ログは `event`,`commit_from`,`commit_to`,`generated_files`,`validation_errors`,`duration_ms`,`correlation_id` を必須項目にする。
  主要メトリクスは `doc_sync_success_rate`,`doc_sync_duration_p95`,`doc_drift_count` とし、アラート閾値は「2連続失敗」「duration_p95 > 60000ms (15分)」「drift_count > 0 が24時間継続」を設定する。
- **test strategy**: 正常系は `bats test/yb_doc_sync.bats` で approve 後フックから `api.md`/release note 断片生成を integration で検証する。
  異常系は secret 未設定・禁止パス混入・破損差分入力を integration で、回帰は fixture ベース golden 比較を CI コマンド `scripts/yb_doc_sync.sh --check` で実行する。
  生成テンプレートの境界ケース（空差分/大量差分）は unit 相当の fixture テストで継続監視する。
- **優先度**: Medium

#### C-11. セキュリティ監査の自動化
- **課題**: レビュー観点に `security_alignment` はあるが、静的解析やシークレット検査の自動実行経路がない。
  セキュリティ判定がレビューコメントの主観依存になり、再現性が弱い。
- **提案内容**: `yb security audit` を追加し、最低限 `gitleaks`（秘密情報）+ `semgrep`（コードパターン）+ 依存脆弱性スキャンを一括実行する。
  品質ゲート入力へ `security_findings_count`/`severity`/`failed_rule_ids` を連携し、`approve` 判定の前提データにする。
- **根拠**: `.yamibaito/templates/review-checklist.yaml:3-5` はセキュリティ項目を定義するが、実行ツールや証跡形式の指定はない。
  `.yamibaito/config.yaml:15-20` は quality gate のテンプレート参照のみでセキュリティツール設定を保持せず、`scripts` 配下にも専用監査スクリプトは存在しない（`scripts/*` 一覧）。
- **期待効果**: 人手レビュー前に高リスク変更を機械検出でき、見逃し率を低減。
  ゼロデイ公表時もルール更新による横断再監査を即時実行しやすくなる。
- **security**: `approve` 判定に影響する監査実行主体は `maintainer`/`reviewer` に限定し、`contributor` は read-only dry-run のみ許可する。
  入力はルール定義ファイルと対象パスを allowlist 検証（リモート rule URL 禁止・パス正規化必須）し、外部 DB/API 資格情報は secret store 配置、監査ログのシークレット断片は `***` でマスクする。
  監査成果物の保存先は `artifacts/security/` に固定し、外部アップロード経路はデフォルト無効とする。
- **failure policy**: `gitleaks`/`semgrep`/依存スキャンは各1回 retry（15s fixed backoff）、ツール単体 timeout は 120 秒、集約処理 timeout は 300 秒とする。
  最終失敗時は quality gate を `rework` 遷移に固定して `security_escalation` を発火し、手動復旧は `yb security audit --tool <name> --rerun` で個別再実行する。
- **observability**: 構造化ログは `tool`,`rule_id`,`severity`,`file`,`exit_code`,`duration_ms`,`retry_count`,`correlation_id` を出力する。
  主要メトリクスは `security_findings_total{severity}`,`security_audit_runtime_p95`,`security_tool_failure_rate`,`security_override_count` とし、アラート閾値は「critical > 0 即時」「tool_failure_rate > 10% (1時間)」「override_count >= 5/日」を設定する。
- **test strategy**: 正常系は既知脆弱パターン fixture とクリーン fixture の2系統で `yb security audit --format json` を integration 実行する。
  異常系は scanner 不在・タイムアウト・壊れた結果 JSON を integration で、回帰は gate 連携フィールド（`security_findings_count`,`severity`,`failed_rule_ids`）の contract test を `bats test/security_audit.bats` で継続検証する。
  さらに severity 正規化ロジックは unit テストで固定し、ツール更新時の判定ブレを抑止する。
- **優先度**: High

#### C-12. プラグイン・拡張アーキテクチャ
- **課題**: 新機能追加は `bin/yb` の case 分岐と `scripts/` 直編集が前提で、拡張点が明文化されていない。
  外部コントリビュータが機能追加する際に本体改修と競合解消が必須になる。
- **提案内容**: `plugins.d` 方式を導入し、`plugin.yaml`（command, hooks, permissions）を読み込んで `yb` サブコマンドを動的登録する。
  フックは `collect/post_collect/review_precheck` など最小集合から開始し、署名検証または allowlist で読み込み制御する。
- **根拠**: `bin/yb:28-77` は固定サブコマンドのハードコード実装、`scripts` も固定ファイル群で拡張規約がない（`scripts` 一覧）。
  `.yamibaito/skills` は空ディレクトリで現時点で実体スキルがなく、`docs/plans/add-skill-mvp/task.md:9-13` でも候補表示止まり・`yb skill` 不在が課題化されている。
- **期待効果**: 本体への直接改修を減らし、機能追加のリードタイム短縮とレビュー負荷分散を実現。
  コミュニティ提供プラグインでチーム固有ワークフローを取り込みやすくなる。
- **security**: プラグインの install/enable は `maintainer` のみ許可し、実行時は `reviewer` 以上かつ署名検証/allowlist 通過済み plugin のみロードする。
  `plugin.yaml` は schema 検証（必須キー、`command` の禁止文字、`permissions` の最小権限）を行い、秘密情報は `YB_PLUGIN_<NAME>_*` の env/secret store 配置、標準出力ログの key/token/password パターンをマスクする。
  `permissions` 未宣言プラグインは deny-by-default とし、暗黙権限付与を禁止する。
- **failure policy**: 各 hook 実行は最大2回 retry（1s/3s backoff）、hook timeout は 20 秒、plugin 初期化 timeout は 10 秒とする。
  最終失敗時は当該 plugin を自動 `disabled` 遷移して親タスクを `rework` 扱いにし、`plugin_escalation` 通知後に `yb plugin disable <name>` + 再実行の手動復旧へ切り替える。
- **observability**: 構造化ログは `plugin_name`,`plugin_version`,`hook`,`event`,`exit_code`,`duration_ms`,`retry_count`,`correlation_id` を共通出力する。
  主要メトリクスは `plugin_load_failures`,`plugin_hook_timeout_count`,`plugin_execution_latency_p95`,`disabled_plugins_count` とし、アラート閾値は「load_failures >= 3/10分」「hook_timeout_count > 5/時」「disabled_plugins_count > 0 が30分継続」を採用する。
- **test strategy**: 正常系は dynamic command 登録と `collect/post_collect/review_precheck` フック連鎖を integration（`bats test/plugins.bats`）で確認する。
  異常系は不正 manifest・署名不一致・権限超過要求・hook timeout を integration で、回帰は plugin 無効時の既存 `yb` サブコマンド互換を e2e（`./bin/yb collect`,`./bin/yb review`）で検証する。
  manifest schema/parser の unit テストを追加し、互換性破壊を PR 時点で検知する。
- **優先度**: Medium

## D. 優先度マトリクス

| 象限 | 定義 | 該当提案 |
|---|---|---|
| Quick Win | 高影響 / 低コスト | C-1 テスト自動化基盤、C-2 コスト管理・トークン使用量トラッキング、C-3 通知・外部連携、C-4 メトリクス・アナリティクス基盤 |
| Strategic | 高影響 / 高コスト | C-5 マルチリポジトリ協調タスク、C-6 CI/CD パイプライン連携、C-7 タスク自動スケジューリング（DAG）、C-9 Web ダッシュボード、C-11 セキュリティ監査の自動化 |
| Nice-to-have | 低影響 / 低コスト | C-10 ドキュメント自動生成の拡張 |
| Future | 低影響 / 高コスト | C-8 ロールバック & git リカバリ自動化、C-12 プラグイン・拡張アーキテクチャ |

> 注: 優先度（High/Medium）は「必要性」を示し、本マトリクスは「影響度×実装コスト」で相対配置している。

## E. 推奨ロードマップ

| 期間 | 主目的 | 重点実施項目 | 配置理由（採用理由） | 成果物イメージ |
|---|---|---|---|---|
| 短期（1-2週） | 既存改善計画の消化と品質の土台づくり | 既存計画の未着手解消（特に `fix-prompt-spec-consistency`、`fix-collect-reset-guard`、`add-version-management`）、C-1 テスト自動化基盤 | C-1 は中期以降の変更量増加に対する回帰防止の前提。既存チェーンの詰まりを先に解消することで、以降の施策を並行投入しやすくなる。 | 最小E2Eが回る状態、主要チェーンのブロッカー解消 |
| 中期（1ヶ月） | 運用最適化（コスト/可視化/通知/安全性）の標準化 | C-2 コスト管理、C-4 メトリクス基盤、C-3 通知連携、C-11 セキュリティ監査自動化、C-8 ロールバック & git リカバリ自動化 | C-11 はレビュー観点の機械化を早期に導入して見逃しを減らすため中期配置。C-8 は rework ループ運用が本格化する時期に MTTR を下げる効果が高いため中期配置。 | コスト/トークン可視化、主要運用KPIの継続監視、セッション外通知、監査自動化、rework 復旧時間の短縮 |
| 長期（3ヶ月） | スケール運用に向けた実行基盤拡張 | C-9 Web UI、C-6 CI連携、C-5 マルチリポ協調、C-7 DAG スケジューリング、C-10 ドキュメント自動生成拡張、C-12 プラグイン化 | C-10 は C-6 の approve 後フック/CI 導線に依存するため長期配置。C-5/C-7/C-9/C-12 は実行基盤そのものを拡張する施策で、短中期の運用品質安定化後に投入するのが安全。 | リアルタイム運用UI、approve→CI/merge の自動導線、複数repo自動配車、配布ドキュメント自動更新、拡張可能な実行アーキテクチャ |

上記は「短期で運用品質を安定化し、中長期で拡張性を獲得する」順序を前提とする。とくに短期項目の完了を中期以降の開始条件として扱うことで、再作業率と設計負債の増加を抑制できる。
