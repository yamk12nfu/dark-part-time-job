# tmux-agents-starter コード調査: 品質ゲート・差し戻し・フィードバック

対象: `/Users/makinokaedenari/tmux-agents-starter/`

## テーマ 1: 品質ゲートの実装（優先度 S）

### 該当ファイル
- `scripts/orchestrator.js`: tmuxペイン監視、JSON抽出、次ロールへの `send-keys` 実行、状態管理。
- `scripts/tmux-agents.sh`: ロールごとのpane起動と環境変数注入（`AGENT_ROLE` など）。
- `.agent/context/roles/quality-architect.md`: quality-architect の実際の判定観点・完了JSON仕様。

### 実装の要点
- ペイン監視は `while (true)` + 固定スリープで順次実行。`detectMissionCompletion(role, index, true)` をロールごとに呼ぶ（`scripts/orchestrator.js:36-64`）。
- 監視データ取得は `tmux capture-pane ... -p -S -5`（末尾5行のみ）で、`extractJsonObject` からJSONを抽出（`scripts/orchestrator.js:69-72`, `scripts/orchestrator.js:232-251`）。
- 抽出正規表現は `"mission":"completed"` と `"next.role"` を含むJSONのみ対象（`scripts/orchestrator.js:234`）。
- JSONは `normalizeMissionResult()` で `next` 正規化後に処理され、`next` がある場合だけ遷移する（`scripts/orchestrator.js:83-112`, `scripts/orchestrator.js:302-343`）。
- 重複実行防止は targetごとの `lastTimestamp` 比較で実施（`scripts/orchestrator.js:77-82`, `scripts/orchestrator.js:191-204`）。
- quality-architect の判定観点はロール定義に固定されており、少なくとも以下6観点を明記してレビューする契約（`.agent/context/roles/quality-architect.md:176-184`）。
  - セキュリティ整合
  - エラー/リトライ/タイムアウト
  - 可観測性
  - テスト戦略
  - 受け入れ条件
  - 要件抜け漏れ
- quality-architect の完了JSONは `next.role: executor` 固定で、`next.executor_checkout` は任意（`.agent/context/roles/quality-architect.md:43-70`）。
- ロール間データ受け渡しは2段構え。
  - 起動時: `tmux-agents.sh` が `AGENT_ROLE`, `TMUX_SESSION`, `TEAM_ID` などを `export`（`scripts/tmux-agents.sh:273-296`）。
  - 遷移時: orchestrator が `TARGET_ID`, `LOOP_COUNT`, `EXECUTOR_CHECKOUT_ID`, `EXECUTOR_RALLY_COUNT` 等を自然文で `send-keys`（`scripts/orchestrator.js:127-156`）。

### ウチへの示唆
- YAMLキュー + `send-keys` 方式でも、`target` 単位の state (`loopCount`, `lastTimestamp`) を持つと再送制御しやすい。
- 品質ゲート観点は free text にせず、role定義のチェックリストとして固定化すると、レビュー品質のぶれを抑えられる。
- 遷移ペイロードを `next.*` で一貫化すると、ロール増減時もオーケストレータ側の分岐を減らせる。

### 注意点・落とし穴
- 現実装は `next.role` を含むJSONしか抽出対象にしておらず、`next: null` など終端JSONを拾いにくい（`scripts/orchestrator.js:234`）。
- 監視が末尾5行固定なので、出力が長い・改行が多いとJSON取りこぼしリスクがある（`scripts/orchestrator.js:69`）。
- quality-architect に「NG時に second-architect へ差し戻す」専用JSON分岐はなく、品質不備は設計書修正後に approved へ寄せる運用。

## テーマ 2: 差し戻しループの実装（優先度 A）

### 該当ファイル
- `.agent/context/roles/second-reviewer.md`: 2nd-reviewer（実名 `second-reviewer`）の判定基準・JSON分岐。
- `scripts/orchestrator.js`: second-reviewer 出力の受理、loopCount更新、再実行トリガー。
- `.agent/context/roles/second-architect.md`: 差し戻し後の受け手（`LOOP_COUNT` と `EXECUTOR_CHECKOUT_ID` 取り込み）。

### 実装の要点
- second-reviewer の判定は `requestNextImplementationLoop()` で決まり、条件は「`EXECUTOR_CHECKOUT_ID` 以降に second-reviewer 自身の指摘があるか」（`.agent/context/roles/second-reviewer.md:28-35`）。
- NG時（差し戻し）JSON:
  - `next.role: second-architect`
  - `next.target: TARGET_ID`
  - `next.executor_checkout: EXECUTOR_CHECKOUT_ID`
  （`.agent/context/roles/second-reviewer.md:42-55`）
- OK時（完了）JSONは `next: null`（`.agent/context/roles/second-reviewer.md:56-67`）。
- SessionEnd で `write_progress` / `write_improvement_feedback` 後に、上記JSONを条件分岐で出力（`.agent/context/roles/second-reviewer.md:113-129`）。
- orchestrator側は second-reviewer の `next.role` 受信時に `loopCount` を加算し、次ロールへ再投入（`scripts/orchestrator.js:92-99`, `scripts/orchestrator.js:106-110`）。
- 差し戻し先は orchestrator が固定しているのではなく、second-reviewer JSON の `next.role` で決まる。現行定義上は `second-architect` 固定（`.agent/context/roles/second-reviewer.md:51`）。
- 差し戻し回数の上限は見当たらない。`loopCount` は増えるだけで cap なし（`scripts/orchestrator.js:186`, `scripts/orchestrator.js:92-99`）。
  - 参考: executorラリーには `>=6` で打ち切りがあるが、これはループ回数ではなく executor 内ラリー制御（`.agent/context/roles/executor.md:71-73`）。

### ウチへの示唆
- 差し戻し判定を「指摘有無」に寄せる設計は実装しやすいが、`decision` フィールド（`approve|rework`）をJSONに明示したほうが機械判定は安定する。
- `LOOP_COUNT` と `EXECUTOR_CHECKOUT_ID` を引き継ぐ方式は、再現可能な差し戻しに有効。YAMLキューにも同等メタデータを持たせる価値が高い。

### 注意点・落とし穴
- `second-reviewer` と `2nd-reviewer` の命名揺れに注意（実装上のロール名は `second-reviewer`）。
- `next: null` を終端シグナルに使う設計と、orchestrator の `next.role` 前提抽出は相性が悪い（終端取り扱いの仕様不整合が起きやすい）。
- `scripts/orchestrator.js` では first-reviewer 監視呼び出しがコメントアウトされており、レビュー経路が定義書/READMEとズレるタイミングがある（`scripts/orchestrator.js:61-62`）。

## テーマ 3: フィードバックループの実装（優先度 A）

### 該当ファイル
- `.agent/context/feedback/README.md`: FB運用の目的・必須項目。
- `.agent/context/roles/*.md`: `read_improvement_feedback` / `write_improvement_feedback` の実行契約。
- `.agent/context/feedback/FB-global.md`, `.agent/context/feedback/roles/FB-*.md`, `.agent/context/feedback/targets/FB-*.md`: 実データ格納先。
- `.agent/threads/*.md`: 各セッションで `feedback_paths` を記録する運用ログ。

### 実装の要点
- FB-*.md は scripts 側の自動生成コードではなく、各ロール定義の Hook 契約で生成・追記される（`write_improvement_feedback`）。
  - `scripts/` 配下には `FB-` / `feedback` の実装参照が見当たらない（検索ベース）。
- 生成タイミングは基本的に SessionEnd（例: quality-architect / second-reviewer / executor いずれも SessionEnd に `write_improvement_feedback` がある）。
  - 例: `.agent/context/roles/quality-architect.md:110-118`
  - 例: `.agent/context/roles/second-reviewer.md:113-129`
  - 例: `.agent/context/roles/executor.md:213-234`
- 参照タイミングは SessionStart の `read_improvement_feedback`（次回セッション冒頭で読む）。
  - 例: `.agent/context/roles/quality-architect.md:95-103`
  - 例: `.agent/context/roles/second-reviewer.md:98-105`
- 情報源は「そのセッションのレビュー/実装結果」を要約した知見で、必須項目は `datetime/role/target/issue/root_cause/action/expected_metric/evidence`（`.agent/context/feedback/README.md:11-22`）。
- 保存先の粒度:
  - 全体横断: `FB-global.md`
  - ロール別: `roles/FB-{role}.md`
  - ターゲット別: `targets/FB-{TARGET_ID}.md`
  （`.agent/context/feedback/README.md:6-10`）
- 次回活用経路:
  - 各ロールが SessionStart で global + role + target を読む契約。
  - threadには `feedback_paths` のみ記録し、本文重複を避ける（例: `.agent/threads/2026-02-17T16:38_nexus-task-console-nextjs-migration.md:399`）。

### ウチへの示唆
- YAMLキュー方式でも、`role feedback` と `target feedback` を分離すると再利用性が高い。
- 「SessionStartで読む」「SessionEndで追記する」をワークフロー強制すると、知見が単発ログで終わりにくい。
- `feedback_paths` だけを実行ログに残す方式は、スレッド肥大化を抑えつつ追跡可能性を維持できる。

### 注意点・落とし穴
- 現状は「ロールが指示どおり書く」前提で、生成処理自体の自動検証が薄い。追記漏れは運用で起こりうる。
- `FB-global.md` の更新権限がロールごとに非対称（多くのロールは禁止、second-reviewer/adminは可）なので、設計時に責務分離を明示しないと運用衝突しやすい。
- FB形式は厳密だが、ソース（差分・テスト結果・thread）の機械抽出は未実装のため、品質はエージェント記述品質に依存する。

## 統合設計への提言
- `dark-part-time-job` へ取り込む際は、まず「遷移JSONスキーマ」を明示的に再設計するべき。`mission/target/next.*` だけでなく、`decision`, `gate`, `reason_code` を分離し、`next: null` 終端も確実に処理する。
- 差し戻しは `loop_count` と `executor_checkout_id` の継承を必須化し、回数上限と打ち切り条件（timeout/manual override）をオーケストレータ側で持つべき。
- フィードバックは tmux出力解析に混ぜず、YAMLキューの副作用として `feedback journal` を明示更新する方が堅牢。最低でも「追記済みファイル存在チェック」を完了条件に含めるべき。
- 全体として、tmux-agents-starter は「プロンプト規約で運用を成立させる」設計が強い。ウチで転用するなら、規約依存部分を機械検証可能な状態遷移に置き換えるのが安全。
