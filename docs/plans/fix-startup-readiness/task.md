## 1. 概要
`yb start` の起動シーケンスは、Claude CLI 起動後の待機を固定 `sleep` に依存しており、環境負荷や初回認証遅延で race condition を起こす。これを、pane 生存確認とプロンプト検知に基づく readiness check（timeout 付き）へ置き換え、起動成功を条件付きで判定する方式へ変更する。目的は「成功時は確実に初期プロンプト投入まで完了」「失敗時は速やかに異常終了して再実行可能」に統一すること。

## 2. 現状の問題
該当箇所は `scripts/yb_start.sh:305-312`。現在は以下の固定待機で起動順序を制御している。

- `scripts/yb_start.sh:305` 親分ペインに `claude --dangerously-skip-permissions` を送信
- `scripts/yb_start.sh:306` `sleep 2`
- `scripts/yb_start.sh:307` 若頭ペインに同コマンドを送信
- `scripts/yb_start.sh:309` `sleep 5`
- `scripts/yb_start.sh:310` 親分の初期指示を送信
- `scripts/yb_start.sh:311` `sleep 2`
- `scripts/yb_start.sh:312` 若頭の初期指示を送信

現状挙動は「所定秒数経過=準備完了」と仮定しているため、実際の CLI 起動状態を見ていない。具体的な障害シナリオは以下。

- 初回起動や認証待ちで Claude 起動が 5 秒を超えると、`scripts/yb_start.sh:310` の初期指示が未準備状態で送られ、会話初期化が失敗する。
- 端末負荷が高いと `sleep 2` 後の若頭起動（`scripts/yb_start.sh:307`）が遅れ、以降の送信順序が崩れる。
- 失敗時に「起動待ち失敗」を検知しないため、ユーザーは tmux 内を目視確認するまで失敗に気づけない。

## 3. ゴール
受け入れ条件:

- `scripts/yb_start.sh` に readiness check 関数が追加され、固定 `sleep` 依存（`scripts/yb_start.sh:306,309,311` 相当）が廃止される。
- 親分・若頭それぞれで「Claude 起動送信 -> readiness 成功確認 -> 初期指示送信」の順序が保証される。
- readiness が timeout した場合、エラーメッセージを標準エラーへ出し、`yb start` は非0終了する。
- 成功時の既存フロー（tmux セッション作成、pane map 生成、attach 動作）は維持される。

非ゴール（スコープ外）:

- `yb_collect.sh` や `yb_restart.sh` の改修。
- Claude CLI 自体の起動時間短縮。
- tmux 構成（pane レイアウト、色、タイトル）変更。

## 4. 設計方針
readiness check は worker_002 レポート提案を採用し、`tmux display-message` と `tmux capture-pane` を組み合わせる。

- 判定1（生存）: `tmux display-message -p -t "$pane" "#{pane_dead}"` が `0`。
- 判定2（準備完了）: `tmux capture-pane -p -t "$pane" -S -40` の末尾ログに、Claude プロンプトを示す文字列（例: `^> $`、`Claude`、`/help`）を検知。
- 判定方式: 1 秒ポーリング、最大 timeout 秒で打ち切り。

関数インターフェース（想定）:

- 関数名: `wait_for_claude_ready`
- 引数:
  - `$1`: pane ターゲット（例: `"$session_name:$oyabun_pane"`）
  - `$2`: timeout 秒（省略時 `45`）
- 戻り値:
  - `0`: readiness 成功
  - `1`: timeout もしくは pane 状態不正
- timeout 挙動:
  - timeout 到達時に `claude readiness timeout: <role>` を標準エラーへ出力し、その時点で `exit 1`。

エラー時挙動:

- 親分で timeout したら若頭送信前に終了。
- 若頭で timeout したら初期指示送信前に終了。
- 途中失敗時も tmux セッションは調査用に残す（自動 `tmux kill-session` はしない）。

影響範囲:

- 主変更: `scripts/yb_start.sh`
- 間接影響: `yb start` 実行時の失敗判定タイミングとエラーメッセージ。
- 影響なし: queue 初期化、pane 配置、`panes*.json` 生成、attach 分岐。

## 5. 実装ステップ
1. `scripts/yb_start.sh` に readiness 設定値（デフォルト timeout、判定パターン）を追加する。レビュー観点: 既存変数との衝突がないこと。
2. `scripts/yb_start.sh` に `wait_for_claude_ready()` を実装する。レビュー観点: 引数/戻り値/timeout ループが設計通りであること。
3. `scripts/yb_start.sh` の起動シーケンス（現 `scripts/yb_start.sh:305-312` 相当）を置換し、各ペインで readiness 成功後に初期指示を送るよう変更する。レビュー観点: 送信順序が保証されていること。
4. timeout 時のエラーメッセージと終了コードを統一する。レビュー観点: 失敗理由がログだけで判別可能であること。
5. 手動テスト結果を本タスク配下に記録し、再現手順付きでレビューに添付する。レビュー観点: 正常系/異常系の検証が網羅されていること。

## 6. テスト方針
正常系:

- `yb start --session <new_id>` 実行で、親分・若頭ともに readiness 成功後に初期指示が投入されること。
- 複数回連続実行で、起動成功率が固定 sleep 方式より安定すること（少なくとも 5 回連続成功）。

異常系:

- Claude 起動が遅延する条件（高負荷、認証待ち）で timeout に達した場合、`yb start` が非0終了し、timeout メッセージが出ること。
- 片側ペインのみ起動失敗時に、失敗側を明示したエラーが出ること（oyabun/waka を識別可能）。

手動テスト手順:

1. `yb start --session readiness-test-01` を実行。
2. tmux へ attach し、親分/若頭ペインで Claude プロンプト出現後に初期指示が送信されていることを確認。
3. 意図的に起動を遅らせる条件で再実行し、timeout と非0終了を確認。
4. エラー時に tmux セッションが残り、追加調査できることを確認。

## 7. リスクと注意点
- 後方互換性: readiness 判定を厳しくしすぎると、既存環境で false negative（実際は起動済みだが未検知）を起こす。判定パターンは最小限から開始し、必要時のみ拡張する。
- tmux バージョン依存: `#{pane_dead}` や `capture-pane` 出力差異で判定がずれる可能性がある。想定外出力時のログを残し、調整可能な timeout/パターンを持たせる。
- 他スクリプトへの波及: `yb_restart` など `yb_start.sh` を呼ぶ経路でも新しい失敗条件が有効になる。運用手順に「timeout 時の再実行/調査手順」を追記する。
