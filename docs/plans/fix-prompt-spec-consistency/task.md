## 1. 概要
親分・若頭・若衆・planner の prompt front matter で、バージョン定義と通知経路仕様が一致していない。仕様項目を `spec_version`（共通仕様版）と `prompt_version`（個別文面版）に分離し、通知責務・send-keys 記法を単一仕様に統一する。目的は、運用手順の解釈差による誤通知・重複通知・保守時の反映漏れを防ぐこと。

## 2. 現状の問題
該当コードと現状挙動:

- `.yamibaito/prompts/oyabun.md:9`, `.yamibaito/prompts/waka.md:9`, `.yamibaito/prompts/wakashu.md:9`  
  `version: "2.0"` を使用。
- `.yamibaito/prompts/plan.md:9`  
  `version: "1.0"` を使用。4 prompt 間で「何の version か」が定義されていない。
- `.yamibaito/prompts/waka.md:69`-`.yamibaito/prompts/waka.md:71`  
  若頭の起床契機を「若衆の tmux send-keys や yb run-worker 終了通知」と定義。
- `.yamibaito/prompts/wakashu.md:33`, `.yamibaito/prompts/wakashu.md:63`-`.yamibaito/prompts/wakashu.md:66`  
  若衆は send-keys 禁止で、通知は `yb run-worker` が行うと定義。
- `.yamibaito/prompts/oyabun.md:45`, `.yamibaito/prompts/oyabun.md:77` と `.yamibaito/prompts/waka.md:62`, `.yamibaito/prompts/waka.md:81`, `.yamibaito/prompts/waka.md:105`  
  send-keys 手順名が `two_bash_calls` と `two_calls` で揺れている。
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_004_report.yaml:15`-`/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_004_report.yaml:33`  
  上記矛盾が高優先度課題として報告済み。

障害シナリオ:

- 実装者が `waka.md` を信じると「若衆が直接 send-keys してよい」と誤解し、`yb_run_worker` 通知と二重経路になる。
- `version` の意味が曖昧なため、将来の仕様破壊変更を検出できず、異なる仕様を混在運用してしまう。
- send-keys 手順名の揺れで自動チェックやテンプレート生成時に変換漏れが起きる。

## 3. ゴール
受け入れ条件:

- 4 prompt すべてで `spec_version` を同一値に揃え、`prompt_version` を個別管理に分離する。
- 通知仕様を一本化する（推奨: 若衆は send-keys 禁止、若頭通知は `yb run-worker` のみ）。
- send-keys 手順名を単一語彙（例: `two_step_send_keys`）へ統一する。
- 仕様必須項目（version/notification/send_keys）に欠損や矛盾があれば検知できる検証手順を定義する。

非ゴール（スコープ外）:

- ペルソナ文体や語調の大幅改稿。
- queue/panes のスキーマ変更。
- `yb run-worker` 自体の runtime 分岐実装（課題(5)で対応）。

## 4. 設計方針
実装アプローチ:

- prompt front matter の共通必須キーを定義する。
  - `spec_version`: 全 prompt 共通の仕様版。
  - `prompt_version`: 各 prompt 個別の改訂版。
  - `notification.worker_completion`: 通知責務の正規値。
  - `send_keys.method`: 手順名（単一語彙）。
- `waka.md` と `wakashu.md` の通知経路を同一ルールに合わせ、矛盾記述を削除する。
- `oyabun.md`/`waka.md` の send-keys 記法を統一し、本文中の説明文・例も同じ語彙へ更新する。

関数/構造体設計（検証スクリプトを導入する場合の想定）:

- `PromptSpec`（辞書/データクラス）  
  フィールド: `file`, `spec_version`, `prompt_version`, `send_keys_method`, `notification_mode`。
- `parse_front_matter(path) -> PromptSpec`
- `validate_cross_prompt_consistency(specs) -> list[str]`  
  矛盾一覧を返し、1件でもあれば `exit 1`。

エラー時挙動:

- 必須キー欠損、許可外の `send_keys.method`、通知仕様矛盾を検出した時点で検証失敗。
- 失敗時は「ファイル名 + キー名 + 期待値/実値」を出力し、修正箇所を即特定できるようにする。

影響範囲:

- 主要: `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`, `.yamibaito/prompts/wakashu.md`, `.yamibaito/prompts/plan.md`
- 間接: prompt を参照する運用手順、レビュー観点

## 5. 実装ステップ
1. 共通仕様（`spec_version`、通知責務、`send_keys.method` 正規値）を先に確定する。  
   変更ファイル: `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`, `.yamibaito/prompts/wakashu.md`, `.yamibaito/prompts/plan.md`
2. 4 prompt の front matter で `version` 運用を `spec_version` + `prompt_version` に移行する。  
   変更ファイル: 同上
3. `waka.md` の通知経路記述（`69-71` 付近）を `wakashu.md` の禁止ルールと矛盾しない形へ修正する。  
   変更ファイル: `.yamibaito/prompts/waka.md`, `.yamibaito/prompts/wakashu.md`
4. send-keys メソッド名（`two_bash_calls` / `two_calls`）を統一し、本文の例示・説明も同期する。  
   変更ファイル: `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`
5. front matter 検証手順（スクリプトまたはチェックコマンド）を追加し、以後の差分で再発しないようにする。  
   変更ファイル: `scripts/`（必要時）

## 6. テスト方針
正常系:

- 4 prompt をパースした結果、`spec_version` が全件一致する。
- 若衆通知責務が `waka.md` と `wakashu.md` で同一解釈になる。
- send-keys メソッド名が全ファイルで正規値のみになる。

異常系:

- 1ファイルだけ旧キー（`version` のみ）へ戻した場合に検証が失敗する。
- `waka.md` 側だけ通知責務を変更して矛盾させた場合に検証が失敗する。
- 許可外 `send_keys.method` を入れた場合に検証が失敗する。

手動テスト手順:

1. 4 prompt の front matter を目視で確認（version/notification/send_keys）。
2. 検証コマンドを実行し、成功時 `exit 0` を確認。
3. 意図的に `waka.md` の通知記述を崩して再実行し、失敗メッセージの特定性を確認。
4. 元へ戻して再実行し、成功を確認。

## 7. リスクと注意点
- 後方互換性: 既存の `version` 単独参照ロジックがあれば読み替えが必要。移行期間は併記または互換読み込みを用意する。
- 他スクリプト波及: prompt を機械読み取りするスクリプトがあれば新キーへ追従が必要。
- 依存関係: 課題(3)の単一ソース化前に修正すると `prompts/` と `.yamibaito/prompts/` の再乖離が起こる。適用順は「課題(3) -> 課題(4)」を推奨する。
- 運用面: 通知責務変更は運用手順書と口頭運用ルールにも反映しないと再発する。
