## 1. 概要
`yb run-worker` は実行基盤を `codex exec` に固定しており、worker ごとに runtime（Codex / Claude Code など）を切り替えられない。`workers` 設定に runtime 抽象を追加し、`yb_run_worker.sh` を adapter 分岐方式へ変更する。目的は、既存運用を壊さずに runtime 多様化と段階移行を可能にすること。

## 2. 現状の問題
該当コードと現状挙動:

- `scripts/yb_run_worker.sh:77`  
  実行コマンドが `["codex", "exec", "--sandbox", sandbox, "-"]` に固定されている。
- `scripts/yb_run_worker.sh:59`-`scripts/yb_run_worker.sh:61`  
  task YAML から読むのは `sandbox` のみで、runtime 指定を解決していない。
- `scripts/yb_start.sh:50`-`scripts/yb_start.sh:53`  
  worker 数が `workers.codex_count` に結合され、設定語彙が runtime 非依存になっていない。
- `.yamibaito/config.yaml:1`-`.yamibaito/config.yaml:8`  
  `workers.codex_count` と `codex.*` しかなく、worker ごとの runtime マッピングが存在しない。
- `scripts/yb_start.sh:305`-`scripts/yb_start.sh:307`  
  親分/若頭は Claude CLI で起動しており、worker 側だけ codex 固定という非対称構成。
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_003_report.yaml:102`-`/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_003_report.yaml:124`  
  高優先度課題として runtime 抽象化が提案済み。

障害シナリオ:

- 一部 worker だけ別 runtime へ切り替える段階移行ができず、全体一括移行しか選べない。
- `codex` 不可環境で worker が即失敗し、代替 runtime へフォールバックできない。
- 設定名が `codex_count` のままなので、runtime 多様化後に意味不一致が発生する。

## 3. ゴール
受け入れ条件:

- `workers.count`（runtime 非依存）と `workers.default_runtime`、`workers.runtimes.<worker_id>` を解釈できる。
- `yb_run_worker.sh` が runtime を解決し、adapter（例: `run_with_codex`, `run_with_claude_code`）で実行する。
- 未設定時は後方互換として `default_runtime=codex` を採用し、`codex_count` も読める。
- 未知 runtime、必要バイナリ欠損、設定不正時に明確なエラーで非0終了する。
- 既存の完了通知（`tmux send-keys` で waka へ通知）は runtime 非依存で維持される。

非ゴール（スコープ外）:

- 親分/若頭の起動 runtime 切替機構の導入。
- task YAML スキーマ全体の刷新。
- 各 runtime 固有の高度オプション最適化。

## 4. 設計方針
実装アプローチ:

- config スキーマを拡張する（互換読み込み前提）。
  - `workers.count`
  - `workers.default_runtime`
  - `workers.runtimes.worker_XXX`
- `yb_run_worker.sh` 内 Python に runtime 解決レイヤーを追加し、実行処理を adapter 関数へ分離する。

関数/構造体設計（`yb_run_worker.sh` 内 Python）:

- `load_config(repo_root) -> dict`
- `resolve_worker_runtime(config, worker_id) -> str`  
  優先順位: `workers.runtimes[worker_id]` > `workers.default_runtime` > `"codex"`。
- `run_with_codex(task_content, sandbox, work_dir) -> int`
- `run_with_claude_code(task_content, work_dir) -> int`
- `run_worker(task_content, runtime, sandbox, work_dir) -> int`  
  `runner_map = {"codex": run_with_codex, "claude": run_with_claude_code}` で dispatch。

エラー時挙動:

- runtime 未対応: `unsupported runtime '<name>'` を `stderr` 出力し `exit 2`。
- バイナリ未インストール: `command not found` を runtime 名付きで出力し `exit 127`。
- 設定読み込み失敗: `config parse error` を出力し `exit 2`。
- runner 実行結果は終了コードをそのまま伝播し、通知処理は現行と同条件で実施する。

影響範囲:

- 主要: `scripts/yb_run_worker.sh`, `scripts/yb_start.sh`, `.yamibaito/config.yaml`
- 間接: worker 起動手順、設定テンプレート（必要なら `templates/config.yaml`）

## 5. 実装ステップ
1. `.yamibaito/config.yaml` の runtime 拡張スキーマ（`workers.count/default_runtime/runtimes`）を定義し、既存 `codex_count` 互換ルールを明文化する。  
   変更ファイル: `.yamibaito/config.yaml`（必要なら `templates/config.yaml`）
2. `scripts/yb_start.sh` の worker 数取得ロジック（`50-53`）を `workers.count` 優先 + `codex_count` フォールバックへ変更する。  
   変更ファイル: `scripts/yb_start.sh`
3. `scripts/yb_run_worker.sh` の Python 部分に config 読み込みと `resolve_worker_runtime()` を追加する。  
   変更ファイル: `scripts/yb_run_worker.sh`
4. `scripts/yb_run_worker.sh` で adapter 関数（`run_with_codex`, `run_with_claude_code`）を実装し、`cmd` 固定実装（`77`）を置換する。  
   変更ファイル: `scripts/yb_run_worker.sh`
5. 失敗時メッセージと終了コードを統一し、運用者が `runtime設定不正` と `実行時失敗` を区別できるようにする。  
   変更ファイル: `scripts/yb_run_worker.sh`

## 6. テスト方針
正常系:

- `workers.default_runtime=codex` のみ設定で従来通り実行できる。
- `workers.runtimes.worker_002=claude` を設定し、該当 worker だけ claude adapter が使われる。
- `codex_count` しかない旧設定でも worker 数解決と実行が成立する。

異常系:

- `workers.runtimes.worker_001=unknown` で `unsupported runtime` エラーになる。
- `claude` 未導入環境で claude adapter 実行時にバイナリ欠損エラーになる。
- `config.yaml` 破損時に `config parse error` で失敗する。

手動テスト手順:

1. `.yamibaito/config.yaml` をデフォルト runtime のみで設定し、`yb run-worker --repo <repo> --worker worker_001` を実行。
2. `worker_002` だけ runtime を変更して再実行し、実行ログの runner 名を確認。
3. 未知 runtime 値を入れて再実行し、終了コードとエラーメッセージを確認。
4. `yb start --session runtime-adapter-test` で pane 作成と worker 数解決が問題ないことを確認。

## 7. リスクと注意点
- 後方互換性: 既存環境は `codex_count` 前提のため、互換読み込みを削ると起動不能になる。移行期間は必須。
- 他スクリプト波及: `yb_start.sh` の worker 数解決変更は queue 初期化件数にも影響するため、`yb_init_repo.sh` 側の整合確認が必要。
- 依存関係: runtime ごとに CLI の入力仕様（stdin/引数）が異なる。adapter で吸収できない差分は明示的に unsupported とする。
- 運用リスク: runtime 混在時に失敗再現性が下がるため、実行ログへ runtime 名を必ず残す。
