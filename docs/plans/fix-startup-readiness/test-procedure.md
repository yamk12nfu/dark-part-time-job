# fix-startup-readiness テスト手順

## 1. 前提
- 実行ディレクトリ: リポジトリルート
- `tmux` と `claude` コマンドが利用可能
- 既存セッション名と衝突しない `--session` 値を使う

## 2. 正常系
1. `yb start --session readiness-ok-01` を実行する。
2. 親分ペインと若頭ペインの両方で Claude が起動した後に、初期指示が順に投入されることを確認する。
3. コマンドが非0で終了しないことを確認する。
4. 期待結果:
   - 固定 `sleep` に依存せず起動が完了する。
   - `yb start: tmux session created: ...` が表示される。

## 3. 異常系（timeout）
1. readiness 判定を意図的に失敗させるため、以下を実行する。  
   `READINESS_TIMEOUT=5 READINESS_PATTERN='__never_match__' yb start --session readiness-timeout-01`
2. 標準エラーに次の形式のメッセージが出ることを確認する。  
   `ERROR: claude readiness timeout: <role> (pane <pane_id>, waited <timeout>s)`
3. 終了コードが非0（`exit 1`）であることを確認する。
4. timeout 後も tmux セッションが自動 kill されず、調査用に残ることを確認する。

## 4. 補足確認
- timeout が親分側で発生した場合は、若頭への初期指示投入前に停止すること。
- timeout が若頭側で発生した場合は、若頭への初期指示投入前に停止すること。
