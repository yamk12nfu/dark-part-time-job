# タスク定義書: send-keys 仕様統一

## 1. 概要
`tmux send-keys` の実行ルールが `oyabun.md` と `waka.md` に重複し、同じ意味のメソッド名が `two_bash_calls` と `two_calls` で分岐しているため、仕様変更時に片側だけ更新されるリスクが高い。共通仕様を `.yamibaito/config.yaml` に集約し、各プロンプトは参照に統一することで、運用手順とドキュメントの一貫性を保つ。

## 2. 現状の問題
該当コード（ファイル名・行番号）:
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/oyabun.md:45`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/oyabun.md:77`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/oyabun.md:131`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/oyabun.md:200`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/waka.md:62`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/waka.md:81`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/waka.md:105`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/prompts/waka.md:226`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/config.yaml:1`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job-worktrees/yamibaito-agile-improve/docs/improvement-report.md:218`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_004_report.yaml:37`

現状の挙動:
- 親分プロンプトは `send_keys.method: two_bash_calls`、若頭プロンプトは `send_keys.method: two_calls` で同義ルールを別名管理している。
- 2段送信ルール（メッセージ送信と `Enter` 送信の分離）が両ファイルで重複説明され、禁止例・許可例も個別に持っている。
- `.yamibaito/config.yaml` に send-keys 共通仕様が存在せず、仕様の正本がプロンプト本文に分散している。

障害シナリオ:
- 仕様変更時に `oyabun.md` のみ更新し `waka.md` が旧ルールのまま残ると、若頭側が旧運用を続けて通知事故が起きる。
- `method` 値の語彙揺れにより、将来的に lint/検証を導入した際に機械判定が不安定になる。
- 新規プロンプト追加時にどちらをコピーすべきか不明となり、重複仕様がさらに増える。

## 3. ゴール
受け入れ条件:
- `.yamibaito/config.yaml` に `protocols.send_keys` を追加し、`method` を `two_step_send_keys` へ統一する。
- `oyabun.md` と `waka.md` の Front Matter の `send_keys.method` は同一語彙を参照し、旧語彙（`two_bash_calls` / `two_calls`）を残さない。
- 2段送信の仕様説明は「設定の正本 + プロンプトからの参照」に整理し、重複定義を解消する。
- 既存の運用意図（1回目=メッセージのみ、2回目=Enterのみ）は変えない。

非ゴール（スコープ外）:
- `wakashu.md` や `plan.md` の全面改稿。
- `tmux send-keys` 実行コード（例: `scripts/yb_collect.sh:339`, `scripts/yb_collect.sh:340`）の挙動変更。
- 通知責務（誰が誰に報告するか）の再設計。

## 4. 設計方針
具体的な実装アプローチ:
- `.yamibaito/config.yaml` に `protocols.send_keys` を新設し、`method`, `rule`, `forbidden_patterns` を定義して仕様正本を一本化する。
- `.yamibaito/prompts/oyabun.md` と `.yamibaito/prompts/waka.md` は「実行ルールの本文丸写し」を減らし、`config.yaml` の `protocols.send_keys` を参照する記述へ揃える。
- Front Matter の `workflow.*.method` と `send_keys.method` を同じ値（`two_step_send_keys`）に統一する。

関数/構造体の設計:
- 追加する構造は設定スキーマのみ。想定キー:
  - `protocols.send_keys.method`
  - `protocols.send_keys.rule`
  - `protocols.send_keys.forbidden_patterns`
  - `protocols.send_keys.steps`

エラー時挙動:
- `protocols.send_keys` が欠落している場合でも、運用は従来どおり2段送信を行う（後方互換優先）。
- ただし実装タスク内で静的検証（`rg`）を必須化し、欠落・旧語彙混在をPR段階で検知する。

影響範囲:
- 直接変更: `.yamibaito/config.yaml`, `.yamibaito/prompts/oyabun.md`, `.yamibaito/prompts/waka.md`
- 間接影響: 今後の prompt 追加時の send-keys 記述ルール、運用手順書の参照先

## 5. 実装ステップ
1. `.yamibaito/config.yaml` に `protocols.send_keys` セクションを追加し、共通仕様を定義する。
2. `.yamibaito/prompts/oyabun.md` の `workflow` と `send_keys` の `method` を `two_step_send_keys` に変更し、重複説明を `config.yaml` 参照へ寄せる。
3. `.yamibaito/prompts/waka.md` の `workflow` と `send_keys` の `method` を `two_step_send_keys` に変更し、`oyabun.md` と同一語彙・同一ルールに合わせる。
4. `rg -n "two_bash_calls|two_calls" .yamibaito/prompts .yamibaito/config.yaml` を実行し、旧語彙が残っていないことを確認する。
5. `rg -n "protocols.send_keys|two_step_send_keys" .yamibaito/prompts .yamibaito/config.yaml` を実行し、参照の一貫性を確認する。

## 6. テスト方針
正常系:
- 設定ファイルに `protocols.send_keys` が存在し、`method` が `two_step_send_keys` であることを確認する。
- `oyabun.md` と `waka.md` の `workflow` / `send_keys` で同じ `method` 値が使われていることを確認する。
- send-keys の禁止パターンと正しい2段送信手順が矛盾なく記載されていることを確認する。

異常系:
- 片方のプロンプトだけ旧語彙へ戻した場合、`rg` チェックで差異を検知できることを確認する。
- `protocols.send_keys` を削除した場合、レビュー項目で欠落を検出できることを確認する。

手動テスト手順:
1. `yb start` でセッションを起動する。
2. 親分から若頭、若頭から若衆への通知をそれぞれ1回実行する。
3. `tmux` の対象ペインで「メッセージ送信」と「Enter送信」が2回に分かれて実行されることを確認する。
4. 既存通知（`scripts/yb_collect.sh:339`, `scripts/yb_collect.sh:340`）が従来どおり成立することを確認する。

## 7. リスクと注意点
- 後方互換性: 旧語彙を参照する外部ドキュメントや過去メモがある場合、表記ゆれで混乱が残る可能性がある。
- 他スクリプト波及: 将来 `method` 値を機械判定するスクリプトを追加した際、語彙統一が前提になるため今回の定義を正本として固定する必要がある。
- 依存関係: `send-keys` に関する責務定義（親分/若頭/若衆）と整合を保つため、通知経路の仕様変更は別タスクとして分離する。
