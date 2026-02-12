# Sandbox + Symlink 制約による若衆の書き込み失敗

## 問題

worktree 環境で `.yamibaito/` がメインリポジトリへのシンボリックリンクになっている場合、
Codex（若衆）の sandbox が symlink 先への書き込みを拒否する。

```
worktree/.yamibaito → /path/to/main-repo/.yamibaito (symlink)
```

sandbox は「ワークスペース（worktree）内のファイルのみ書き込み可」のため、
symlink の実体がワークスペース外にあると `operation not permitted` になる。

## 影響

- 若衆が `reports/worker_XXX_report.yaml` を更新できない
- 若頭が代筆するか、若衆がフォールバック先（`.codex_out/`, `.codex_tmp_reports/`, `/tmp/` 等）に出力する
- フォールバック先がバラバラで回収が煩雑

## 再現条件

- `yb start --session <id>` で worktree を使用
- `.yamibaito/` が `yb start` により symlink として作成されている
- 若衆が Codex sandbox モードで実行されている

## 解決策の候補

| 案 | 内容 | メリット | デメリット |
|----|------|----------|------------|
| A | symlink をやめて実コピー | sandbox 問題が根本解消 | worktree 間で .yamibaito が共有できなくなる |
| B | queue/ と reports/ だけ worktree 内に実ディレクトリとして作成 | 共有設定は symlink のまま、書き込み先だけ worktree 内 | スクリプトのパス解決を変更する必要あり |
| C | sandbox 設定を緩和 | 変更最小 | セキュリティが緩くなる |

推奨: **B案** - 設定ファイル（config.yaml, prompts）は symlink 共有のまま、
書き込みが必要な queue/reports だけ worktree ローカルに置く。

## 関連

- `yb_start.sh` の symlink 作成処理
- `yb_dispatch.sh` / `yb_run_worker.sh` のパス解決
- `yb_collect.sh` のレポート読み取りパス

## 発見経緯

improve-plan-mode ブランチの cmd_0002（コードレビュー）で、
5名中3名の若衆が sandbox 制約でレポート出力に失敗。
若衆自体はレビューを完了しており、各自フォールバック先に成果物を出力していた。
