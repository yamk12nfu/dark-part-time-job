## 1. 概要
`prompts/` と `.yamibaito/prompts/` が二重管理になっているため、実行時に参照されるプロンプトと開発時に編集されるプロンプトが乖離する。`prompts/` を単一の正本（single source of truth）に統一し、実行側は常にその正本を参照する構成へ改める。目的は、仕様の反映漏れ・環境差分・再初期化時の上書き事故をなくすこと。

## 2. 現状の問題
該当コードと現状挙動:

- `scripts/yb_init_repo.sh:50`-`scripts/yb_init_repo.sh:53`  
  毎回 `"$ORCH_ROOT/prompts/*.md"` を `"$repo_root/.yamibaito/prompts/*.md"` に `cp` している（差分検知なし、上書き）。
- `scripts/yb_start.sh:302`-`scripts/yb_start.sh:303`  
  親分/若頭の起動時プロンプトは `.yamibaito/prompts` 側のみを参照する。
- `scripts/yb_plan.sh:91`  
  planner も `.yamibaito/prompts/plan.md` を参照する。
- `prompts/waka.md:92` と `.yamibaito/prompts/waka.md:84`-`.yamibaito/prompts/waka.md:94`  
  root 側にある `note_worktree` の説明が runtime 側には存在しない（既存差分）。
- `prompts/wakashu.md:57` と `.yamibaito/prompts/wakashu.md:53`-`.yamibaito/prompts/wakashu.md:60`  
  同様に worktree 注意事項の記載が runtime 側で欠落している。
- `.yamibaito/queue_agile-improve/reports/worker_003_report.yaml:82`-`.yamibaito/queue_agile-improve/reports/worker_003_report.yaml:99`  
  既に「二重管理が高優先度課題」として報告済み。

障害シナリオ:

- root 側だけ更新しても、既存環境で `yb init` を再実行しない限り実行仕様に反映されない。
- runtime 側を緊急修正しても、次回 `yb init` で無条件上書きされる。
- 開発者がどちらを正本として扱うべきか判断できず、レビューで見た内容と実行時挙動が一致しない。

## 3. ゴール
受け入れ条件:

- プロンプト正本を `repo_root/prompts/*.md` に一本化し、`yb start` と `yb plan` は正本を直接解決して読む。
- `.yamibaito/prompts` は互換目的でシンボリックリンク（または同等の参照）に統一し、コピー運用を廃止する。
- 起動時に「prompts 実体が壊れている（リンク切れ・欠損）」場合は即時エラー終了し、欠損ファイル名を出力する。
- 既存運用向けに移行レイヤーを設け、旧構成（実ディレクトリ）からの移行手順が明示される。

非ゴール（スコープ外）:

- プロンプト本文の内容変更（役割定義や文言の改訂）。
- `yb collect` など prompt 参照を持たないスクリプトの機能変更。
- tmux レイアウトやキュー構造の変更。

## 4. 設計方針
実装アプローチ:

- 参照解決を共通化する関数を導入する（例: `resolve_prompt_path(repo_root, role)`）。
- 初期化時は `scripts/yb_init_repo.sh` で `ensure_prompt_link(repo_root)` を呼び、`.yamibaito/prompts` を `../prompts` へのリンクに正規化する。
- `scripts/yb_start.sh` と `scripts/yb_plan.sh` は `.yamibaito/prompts` 直参照を廃止し、共通解決関数経由で `repo_root/prompts/*.md` を読む。

関数/構造体設計（Shell想定）:

- `resolve_prompt_path <repo_root> <name>`  
  戻り値: `stdout` に実ファイルパス。存在しなければ `stderr` 出力して `return 1`。
- `ensure_prompt_link <repo_root>`  
  役割: `.yamibaito/prompts` をリンク化。既存が実ディレクトリの場合は `--migrate-prompts` 指定時のみ退避して置換。
- `validate_required_prompts <repo_root>`  
  対象: `oyabun.md`, `waka.md`, `wakashu.md`, `plan.md`。

エラー時挙動:

- 必須プロンプト欠損時は `exit 1`（ファイル名を含む）。
- `.yamibaito/prompts` がリンク化できない環境では、互換フォールバック（読み取りのみ）に落とすが警告を出す。

影響範囲:

- 主要: `scripts/yb_init_repo.sh`, `scripts/yb_start.sh`, `scripts/yb_plan.sh`
- 間接: `prompts/*.md` の運用手順（編集場所の統一）

## 5. 実装ステップ
1. `scripts/yb_init_repo.sh` に prompt 正規化関数（`ensure_prompt_link`, `validate_required_prompts`）を追加し、`cp` ベース処理（`50-53`）を置換する。  
   変更ファイル: `scripts/yb_init_repo.sh`
2. `scripts/yb_start.sh` の `oyabun_prompt`/`waka_prompt` 設定（`302-303`）を共通解決関数呼び出しに置換する。  
   変更ファイル: `scripts/yb_start.sh`
3. `scripts/yb_plan.sh` の `plan_prompt` 設定（`91`）を同じ解決関数に統一する。  
   変更ファイル: `scripts/yb_plan.sh`
4. 旧構成からの移行手順（既存 `.yamibaito/prompts` 実ディレクトリの扱い）をコメントまたは運用ドキュメントに追記する。  
   変更ファイル: `scripts/yb_init_repo.sh`（必要なら `docs`）
5. root と runtime の差分チェック手順（移行後は常に一致すること）を確認して完了条件にする。  
   変更ファイル: なし（検証手順）

## 6. テスト方針
正常系:

- 新規 repo で `yb init` 後、`.yamibaito/prompts` が正しく `prompts/` を参照している。
- `yb start` が `prompts/oyabun.md` と `prompts/waka.md` を読み、起動メッセージ送信まで成功する。
- `yb plan` が `prompts/plan.md` を読み込んで planner に投入できる。

異常系:

- `prompts/waka.md` を欠損させた状態で `yb start` すると、欠損名付きで失敗終了する。
- `.yamibaito/prompts` が壊れたリンクの場合、初期化または起動時に検知して異常終了する。
- 旧実ディレクトリが残る環境で移行フラグなし実行時、勝手に破壊せず警告で止まる。

手動テスト手順:

1. `yb init --repo <repo_root>` を実行。
2. `ls -l .yamibaito/prompts` でリンク状態を確認。
3. `yb start --repo <repo_root> --session prompt-source-test` を実行し、プロンプト読込成功を確認。
4. `yb plan --repo <repo_root> --title prompt-source-test` を実行し、planner プロンプト投入を確認。
5. `prompts/waka.md` を一時退避して再度 `yb start` を実行し、異常終了とエラーメッセージを確認。

## 7. リスクと注意点
- 後方互換性: `.yamibaito/prompts` を直接編集する運用は破綻するため、編集先を `prompts/` に統一する告知が必要。
- 他スクリプト波及: 将来 `.yamibaito/prompts` 直参照を追加すると再発する。参照解決関数の利用を規約化する。
- 依存関係: シンボリックリンクの扱いが環境依存（特に一部ファイルシステム）なので、リンク不可時フォールバック方針を先に決める。
- 課題依存: 課題(4)の仕様整合修正時は、必ず正本側（`prompts/`）だけを編集する運用へ切り替えてから実施する。
