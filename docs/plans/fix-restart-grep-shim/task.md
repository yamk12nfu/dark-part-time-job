## 1. 概要
`yb_restart` は restart 時の `branch_prefix` 引き継ぎのために一時 `grep` shim を生成し、`PATH` 先頭へ差し込んで `yb_start` の設定読み取りを偽装している。これを廃止し、`YB_RESTART_WORKTREE_PREFIX` を `yb_start` が明示的に受け取る設計へ変更して、環境依存とデバッグ困難性を解消する。

## 2. 現状の問題
該当コード:

- `scripts/yb_restart.sh:143-154`
  - `grep_real="$(command -v grep)"`
  - `mktemp` 配下に `grep` ラッパーを生成
  - `PATH="$tmp_bin:$PATH"` で `yb_start.sh` を `exec`
- shim 本体は `scripts/yb_restart.sh:147-149` で `-E "^\s*branch_prefix:"` の時だけ `YB_RESTART_WORKTREE_PREFIX` を返し、それ以外は実 `grep` へ委譲している。
- shim 依存の受け側は `scripts/yb_start.sh:58` (`wt_branch_prefix=$(grep -E "^\s*branch_prefix:" "$config_file" ... )`)。`yb_start.sh` には `YB_RESTART_WORKTREE_PREFIX` を直接読む処理がない。

現状挙動と障害シナリオ:

- `PATH` 差し替えに依存するため、シェル差異や実行環境によって再現性が落ちる。
- `yb_start.sh` が `grep` を追加利用した場合、意図せず shim が介入する可能性がある。
- 調査時に「設定値がどこから来たか」が追跡しづらく、保守コストが高い。

## 3. ゴール
受け入れ条件:

- `scripts/yb_restart.sh` から `grep` shim 生成と `PATH` 差し替えが完全に削除される。
- `scripts/yb_start.sh` は `YB_RESTART_WORKTREE_PREFIX` を最優先で読み、未指定時のみ `config.yaml` の `branch_prefix` を読む。
- restart の既存動作（`wt_root` / `wt_branch` 引き継ぎ、`--delete-worktree` 分岐）は維持される。
- 非 restart 起動（`yb start` 直実行）では従来通り `config.yaml` と既定値 `yamibaito` が使われる。

非ゴール（スコープ外）:

- `config.yaml` 読み取り実装全体の置換（YAML パーサ導入など）。
- `yb_restart` の worktree 削除ロジック刷新。
- 起動 readiness 改修（別タスク）。

## 4. 設計方針
実装アプローチ:

- `scripts/yb_start.sh` に prefix 解決関数（例: `resolve_worktree_branch_prefix`）を追加し、優先順位を固定する:
  1. `YB_RESTART_WORKTREE_PREFIX`（非空なら採用）
  2. `config.yaml` の `branch_prefix`（現行 `grep` 式を流用可）
  3. デフォルト `"yamibaito"`
- `scripts/yb_restart.sh` は `restart_wt_prefix` を計算したら、shim を介さず `exec env YB_RESTART_WORKTREE_PREFIX=... "$ORCH_ROOT/scripts/yb_start.sh" ...` を直接実行する。
- `restart_wt_prefix` が空の場合は env を渡さず、`yb_start.sh` 側フォールバックに任せる。

関数/構造設計:

- 新規関数（想定）: `resolve_worktree_branch_prefix()`
  - 出力: `stdout` に prefix 文字列
  - 入力: `config_file` と環境変数
- 既存変数:
  - `scripts/yb_restart.sh:138-141` の `restart_wt_prefix`
  - `scripts/yb_start.sh:58` の `wt_branch_prefix`

エラー時挙動:

- `YB_RESTART_WORKTREE_PREFIX` が不正文字列でも `session_id` サニタイズ済みロジックに従って branch 名を生成し、必要なら warning を出して既定値へフォールバックする。
- env 未設定時は現行同等動作を維持し、起動を止めない。

影響範囲:

- 主変更: `scripts/yb_restart.sh`, `scripts/yb_start.sh`
- 削除対象: `mktemp` 生成 shim (`scripts/yb_restart.sh:143-154`)
- 間接影響: restart 実行時のデバッグ手順（`PATH` 依存が消える）

## 5. 実装ステップ
1. `scripts/yb_start.sh` に `YB_RESTART_WORKTREE_PREFIX` 優先ロジックを追加し、`wt_branch_prefix` の決定処理を関数化する。
2. `scripts/yb_restart.sh` から `grep_real` / `tmp_bin` / shim 書き込み処理（`scripts/yb_restart.sh:143-154`）を削除する。
3. `scripts/yb_restart.sh` の `exec env` 呼び出しを整理し、必要時のみ `YB_RESTART_WORKTREE_PREFIX` を渡す実装へ統一する。
4. `scripts/yb_start.sh` の通常起動経路（restart 以外）で `branch_prefix` 解決が退行しないことを確認する。
5. shellcheck 相当の静的確認（未使用変数、引用漏れ）を実施し、ログ文言を更新する。

## 6. テスト方針
正常系:

- `yb restart --session <id>` で、元 worktree branch の prefix が維持される。
- `yb start --session <id>` 単独実行で、`config.yaml` の `branch_prefix` が従来通り使われる。
- `--delete-worktree` 経路は shim 削除後も既存通り動作する。

異常系:

- `YB_RESTART_WORKTREE_PREFIX` 未設定で restart しても `yb_start` が正常起動する。
- `config.yaml` に `branch_prefix` がない場合でも既定値 `yamibaito` へフォールバックする。
- `PATH` を意図的に変更した環境でも、shim 非依存のため挙動が変わらない。

手動テスト手順:

1. `branch_prefix` を設定した repo で `yb start --session grep-shim-test` を実行し、branch 名を確認。
2. 同セッションで `yb restart --session grep-shim-test` を実行し、再作成/再利用 branch の prefix が一致することを確認。
3. `set -x` 付きで `yb_restart.sh` を実行し、`mktemp` と `PATH="$tmp_bin:$PATH"` が呼ばれないことを確認。
4. `YB_RESTART_WORKTREE_PREFIX` を空にして restart し、config/既定値フォールバック動作を確認。

## 7. リスクと注意点
- 後方互換性: 既存運用が shim 前提のデバッグ手順（`which grep` で挙動確認など）を持っている場合は手順更新が必要。
- 他スクリプト波及: `yb_start.sh` の prefix 解決順を変えるため、restart 以外の起動にも影響する。通常起動の回帰確認を必須にする。
- 依存関係: `branch_prefix` の抽出は依然 `grep/awk` ベース。今回の目的は shim 廃止であり、YAML パース品質改善は別タスクとして切り分ける。
