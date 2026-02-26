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
