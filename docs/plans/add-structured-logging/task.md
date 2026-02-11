## 1. 概要
`yb_start` / `yb_collect` / `yb_restart` は人間可読の `echo/print` を中心に動作しており、セッション横断の時系列追跡や障害相関が難しい。共通スキーマの JSONL 構造化ログを導入し、同一 `session_id` / `cmd_id` でイベント連結できるようにして、復旧判断をログ単体で実施できる状態にする。

## 2. 現状の問題
該当箇所は以下。

- `scripts/yb_start.sh:70-73` は gtr 未導入時に説明文を `echo` 出力するのみ。
- `scripts/yb_start.sh:90,93,106,110,147-149,314-315` も文字列ログのみで、構造化された `event` や `session_id` が出ない。
- `scripts/yb_collect.sh:335-342` は tmux 通知失敗を `print(..., file=sys.stderr)` で警告するだけ。
- `scripts/yb_collect.sh:345` は完了通知を `echo` 1 行で出すのみ。
- `scripts/yb_restart.sh:84-85,91-94,114-122,182` は重要イベント（kill、worktree 削除、fallback）を `echo` / `warning` 文字列でしか記録しない。
- `docs/improvement-report.md:168-176` と `worker_002_report.yaml:41-55` で、共通 schema の欠如が次スプリント課題として明示されている。

現状挙動では script ごとに文言と粒度がバラバラで、同一障害の相関分析に必要なキーがない。障害シナリオは以下。

- `yb_restart` 実行後に `yb_start` 失敗が続いた際、どの `session_id` の restart が原因かをログだけで追跡できない。
- `yb_collect` 通知失敗（`tmux send-keys` 失敗）が dashboard 更新失敗と区別できず、復旧優先度を誤る。
- 同時運用時に複数セッションの標準出力が混在し、手作業で時系列再構成が必要になる。

## 3. ゴール
受け入れ条件:

- `.yamibaito/logs/<session_id>/events.jsonl` へ共通 schema で追記される。
- 共通必須キー `ts/level/script/session_id/cmd_id/worker_id/event/message` が 3 スクリプトで揃う。
- `yb_start` / `yb_collect` / `yb_restart` の主要分岐（開始・成功・警告・失敗）で `log_event` が呼ばれる。
- JSONL の 1 行 1 レコードが `jq -c .` で parse 可能である。
- ログ出力失敗時は処理停止せず、標準エラーにフォールバック警告を出す。

非ゴール（スコープ外）:

- 外部ログ基盤（CloudWatch, Datadog 等）への転送。
- 全スクリプト（`yb_dispatch`, `yb_stop` など）への一斉適用。
- dashboard 表示仕様の変更。

## 4. 設計方針
実装は Bash 共通ヘルパー + Python formatter の 2 層で揃える。

- Bash 共通関数:
`scripts/lib/yb_logging.sh` を新設し、`yb_log_init`（ログ先決定）と `yb_log_event`（JSONL 追記）を提供する。`yb_start.sh` と `yb_restart.sh` は先頭で source し、既存 `echo` の重要箇所を段階的に置換する。

- Python 側（`yb_collect.sh` 内 here-doc）:
`logging` + `JsonFormatter` を追加し、`collect.start` / `collect.dashboard_written` / `collect.notify_failed` などを emit する。Bash から `YB_LOG_FILE`, `YB_SESSION_ID`, `YB_CMD_ID` を環境変数で渡す。

- ログ構造:
`cmd_id` / `worker_id` が不明なイベントは空文字で埋める。`event` は固定命名（`start.worktree_created`, `restart.session_killed`, `collect.notify_failed`）とし、`message` は人間可読補足に限定する。

- エラー時挙動:
ログディレクトリ作成失敗、JSON 生成失敗、書き込み失敗は `stderr` に `log_write_failed` を出して継続する。主処理の exit code をログ系エラーで上書きしない。

影響範囲:

- 追加: `scripts/lib/yb_logging.sh`
- 変更: `scripts/yb_start.sh`, `scripts/yb_collect.sh`, `scripts/yb_restart.sh`
- 任意追記: 運用ドキュメント（ログ保存先と読み方）

## 5. 実装ステップ
1. 共通ログヘルパーを追加し、JSONL 1 行出力とセッション単位ディレクトリ作成を実装する。変更ファイル: `scripts/lib/yb_logging.sh`
2. `yb_start.sh` に `yb_log_init` と主要イベントログ（起動開始、worktree 再利用/作成、session 作成完了、異常終了）を追加する。変更ファイル: `scripts/yb_start.sh`
3. `yb_restart.sh` に主要イベントログ（session kill、worktree 削除、fallback、start 委譲）を追加する。変更ファイル: `scripts/yb_restart.sh`
4. `yb_collect.sh` の Bash 側でログコンテキストを組み立て、Python 側へ引き渡す。変更ファイル: `scripts/yb_collect.sh`
5. `yb_collect.sh` の Python 本体へ JSON formatter を追加し、通知失敗・dashboard 更新完了・index 更新完了を event 化する。変更ファイル: `scripts/yb_collect.sh`
6. ログフォーマットの運用手順（jq での確認例）を最小追記する。変更ファイル: `.yamibaito/prompts/waka.md`（必要最小限）

## 6. テスト方針
正常系:

- `yb start --session logtest-01` 実行後、`.yamibaito/logs/logtest-01/events.jsonl` が作成され、`start.*` イベントが記録される。
- `yb collect --session logtest-01` 実行後、`collect.*` イベントが同一ファイルへ追記される。
- `yb restart --session logtest-01` 実行後、`restart.*` イベントが追記され、時系列で追える。

異常系:

- `tmux` 未起動や不正 pane を作って `collect.notify_failed` を発生させ、warning レベルで JSON レコードが残ること。
- ログ出力先を意図的に書き込み不可にした場合、主処理は継続しつつ `stderr` へフォールバック警告が出ること。
- 不正 JSON 文字（改行や引用符を含む message）でも 1 行 JSON として壊れないこと。

手動テスト手順:

1. `yb start --repo <repo> --session logtest-01` を実行。
2. `yb collect --repo <repo> --session logtest-01` を実行。
3. `yb restart --repo <repo> --session logtest-01` を実行。
4. `jq -c . .yamibaito/logs/logtest-01/events.jsonl >/dev/null` で全行 parse 成功を確認。
5. `rg '"event":"(start|collect|restart)' .yamibaito/logs/logtest-01/events.jsonl` で 3 スクリプトのイベント存在を確認。

## 7. リスクと注意点
- 後方互換性: 既存運用が標準出力の文言に依存している可能性があるため、初期段階は `echo` を完全削除せず `log_event` 併記で移行する。
- 性能: 高頻度ログで I/O が増えるため、イベント粒度を「状態遷移点」に限定し、ループ内連打を避ける。
- 依存関係: Bash で JSON 文字列エスケープを自前実装すると壊れやすい。Python 補助を使うか、既存依存を明確化する。
- 他スクリプト波及: `yb_run_worker` 側が `cmd_id/worker_id` を環境変数で渡さないと相関が弱い。段階導入時に最低限の伝播設計を合わせる。
