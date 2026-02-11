# yamibaito 改善レポート

yamibaito は、tmux 上で親分・若頭・若衆の複数エージェントを起動し、キュー配布・進捗収集・レポート生成を行う運用オーケストレータである。本レポートは 4 件の調査結果を統合し、運用事故を防ぐための優先度付き改善計画として再整理した。

## 優先度サマリ

### 即対応
このグループは、誤タスク消去や起動失敗のように、日次運用の継続性を直接壊す課題を対象とする。いずれも失敗時の影響範囲が広く、放置すると障害調査コストより先に運用停止リスクが顕在化するため、最優先で着手する。

| 課題名 | 影響度 | 優先度 | 一言要約 |
|---|---|---|---|
| 起動シーケンスの固定 sleep 依存 | 高 | 即対応 | 起動待機が時間固定で race し、初回起動で指示投入に失敗する。 |
| `yb_collect` のタスクリセット防御不足 | 高 | 即対応 | 完了 report を根拠に誤った task を `idle` へ戻す可能性がある。 |
| `panes.json` の nullable 構造 | 高 | 即対応 | 読み取り側で場当たり的な null 防御が増え、再起動時に誤判定を誘発する。 |
| `prompts/` の二重管理 | 高 | 即対応 | ルートと runtime コピーが乖離し、実行仕様が環境ごとに変わる。 |
| プロンプト仕様の不整合 | 高 | 即対応 | 送信責務と version の定義がファイル間で矛盾している。 |
| worker runtime の `codex` 固定 | 高 | 即対応 | worker ごとの実行基盤を選べず、拡張と互換運用を阻害する。 |
| skill 運用 MVP 未整備 | 高 | 即対応 | 候補検出後の登録・検証フローがなく運用が閉じない。 |
| `yb_restart` の `grep` shim 依存 | 高 | 即対応 | PATH 差し替えで設定注入する実装が壊れやすく保守不能。 |

### 次スプリント
このグループは、可観測性と保守性を高めるための課題である。即時障害には直結しないが、障害時の復旧時間や運用負債に直結するため、次スプリントでまとめて改善する。

| 課題名 | 影響度 | 優先度 | 一言要約 |
|---|---|---|---|
| 構造化ログ不足 | 中 | 次スプリント | `echo/print` 中心で、障害時の時系列追跡が難しい。 |
| dashboard 更新の排他制御不足 | 中 | 次スプリント | 同時実行で last-writer-wins が起き、更新が取りこぼされる。 |
| stale queue/report の残留 | 中 | 次スプリント | stop/restart 後の寿命管理がなく、古い状態が蓄積する。 |
| worker 表示名のハードコード | 中 | 次スプリント | 表示ポリシー変更にコード修正が必要で運用変更に弱い。 |
| オーケストレータ version 管理不在 | 中 | 次スプリント | 生成物がどの実装由来か追跡できない。 |
| send-keys 仕様の重複定義 | 中 | 次スプリント | 同一ルールが複数 prompt に重複し記法も揺れている。 |

### 将来
このグループは、運用安定化後に行う構造改善である。設計効果は高いが変更範囲が広いため、先に即対応・次スプリントの安全性改善を終えてから着手する。

| 課題名 | 影響度 | 優先度 | 一言要約 |
|---|---|---|---|
| dashboard の状態モデル分離 | 中 | 将来 | 文字列組み立て中心の実装を state + renderer に分離する。 |

## 即対応の詳細

### 起動シーケンスの固定 sleep 依存
**何が問題か**  
`yb start` は Claude CLI 起動直後の入力送信を `sleep 2/5/2` に依存している。端末負荷や初回認証の遅延があると、プロンプト投入が先行して初期化に失敗する。

**どこが該当するか**  
`scripts/yb_start.sh:305`、`scripts/yb_start.sh:306`、`scripts/yb_start.sh:309`、`scripts/yb_start.sh:311`。

**どう直すか**  
固定待機を廃止し、pane の生存確認とプロンプト検知を組み合わせた readiness check に置き換える。失敗時は timeout で即時に異常終了させ、再実行可能な失敗として扱う。

```bash
wait_for_claude_ready() {
  local pane="$1" timeout="${2:-45}" i=0
  while [ "$i" -lt "$timeout" ]; do
    dead="$(tmux display-message -p -t "$pane" "#{pane_dead}" 2>/dev/null || echo 1)"
    if [ "$dead" = "0" ] && tmux capture-pane -p -t "$pane" -S -40 | grep -E -q "(^> $|Claude|/help)"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}
```

### `yb_collect` のタスクリセット防御不足
**何が問題か**  
完了 report を検出した worker の task ファイルを機械的に `idle` 化しており、`task_id` や `parent_cmd_id` の整合を確認していない。再配布直後に collect が走ると、別タスクを消す race が起こる。

**どこが該当するか**  
`scripts/yb_collect.sh:166`、`scripts/yb_collect.sh:193`、`scripts/yb_collect.sh:265`、`scripts/yb_collect.sh:309`。

**どう直すか**  
リセット条件を「report と task が同一ジョブを指す」場合に限定する。さらに `idle` 直行ではなく、`collected` 中間状態を経由して dispatcher 側で確定させる。

```python
def can_reset_to_idle(report, task):
    completion = {"done", "completed"}
    report_status = (report.get("status") or "").lower()
    task_status = (task.get("status") or "").lower()
    return (
        report_status in completion
        and task_status in completion
        and report.get("task_id") == task.get("task_id")
        and report.get("parent_cmd_id") == task.get("parent_cmd_id")
    )
```

### `panes.json` の nullable 構造
**何が問題か**  
`worktree_root` と `worktree_branch` が `null` 許容のため、読み取り側が推測ロジックを持ち始めている。再起動や停止時の処理がスクリプトごとに分岐し、整合性保証が難しい。

**どこが該当するか**  
`scripts/yb_start.sh:255`、`scripts/yb_start.sh:257`、`scripts/yb_restart.sh:55`、`scripts/yb_restart.sh:114`、`scripts/yb_stop.sh:62`、`scripts/yb_worktree_list.sh:37`。

**どう直すか**  
`schema_version` を導入し、`worktree.enabled/root/branch` の非 nullable 構造へ統一する。読み取りは共通ライブラリに集約し、正規化済みデータのみを上位スクリプトへ渡す。

### `prompts/` の二重管理
**何が問題か**  
初期化時に `prompts/` を `.yamibaito/prompts/` にコピーし、実行時はコピー側を参照する。マスターと runtime が分離して差分管理不能になり、意図しない仕様分岐を生む。

**どこが該当するか**  
`scripts/yb_init_repo.sh:50`、`scripts/yb_start.sh:302`、`scripts/yb_plan.sh:91`、`prompts/waka.md:92`、`.yamibaito/prompts/waka.md:91`。

**どう直すか**  
`prompts/` を単一ソースに固定し、`.yamibaito/prompts` は symlink 化する。コピー運用を残す場合は `yb prompts sync` と `source_hash` 検証を必須化する。

### プロンプト仕様の不整合
**何が問題か**  
`spec_version` と通知責務の定義が prompt 間でそろっておらず、「若衆が send-keys するかどうか」が文書ごとに矛盾している。運用手順の解釈差が作業ミスを生む。

**どこが該当するか**  
`.yamibaito/prompts/oyabun.md:9`、`.yamibaito/prompts/waka.md:9`、`.yamibaito/prompts/wakashu.md:9`、`.yamibaito/prompts/plan.md:9`、`.yamibaito/prompts/wakashu.md:63`、`.yamibaito/prompts/wakashu.md:66`。

**どう直すか**  
`spec_version` を全 prompt で統一し、通知経路を 1 方式に固定する。推奨は「若衆は send-keys 禁止、通知は `yb run-worker` のみ」である。

### worker runtime の `codex` 固定
**何が問題か**  
`yb_run_worker.sh` が `codex exec` 前提で実装されており、worker ごとに Claude Code など別 runtime を選択できない。役割分担の自由度が低く、移行戦略も取りにくい。

**どこが該当するか**  
`scripts/yb_run_worker.sh:77`、`scripts/yb_start.sh:50`、`.yamibaito/config.yaml:2`。

**どう直すか**  
`config.yaml` に `default_runtime` と worker 別 `runtimes` を追加し、`yb_run_worker.sh` は runtime adapter で分岐させる。既存 `codex_count` は移行レイヤーで吸収する。

### skill 運用 MVP 未整備
**何が問題か**  
プロンプト上では skill 抽出フローが定義されているが、テンプレート生成・index 登録・検証コマンドが未実装で、運用上は候補検出で止まる。

**どこが該当するか**  
`.yamibaito/skills/`、`.yamibaito/prompts/waka.md:91`、`.yamibaito/prompts/waka.md:337`、`.yamibaito/prompts/oyabun.md:302`、`scripts/yb_collect.sh:176`、`scripts/yb_collect.sh:241`。

**どう直すか**  
`.yamibaito/templates/skill/SKILL.md.tmpl`、`yb skill init`、`yb skill validate`、`.yamibaito/skills/index.yaml` を MVP として同時導入し、collect が検出した候補を未登録一覧として可視化する。

### `yb_restart` の `grep` shim 依存
**何が問題か**  
`yb_restart.sh` は一時ディレクトリに `grep` ラッパーを生成し、`PATH` 先頭に差し込んで `branch_prefix` を擬似注入している。環境依存が強く、デバッグ時の再現性を損なう。

**どこが該当するか**  
`scripts/yb_restart.sh:143`、`scripts/yb_restart.sh:145`、`scripts/yb_restart.sh:154`、`scripts/yb_start.sh:58`。

**どう直すか**  
shim を廃止し、restart 由来の値は環境変数で明示受け渡しする。`yb_start.sh` 側で「環境変数があれば優先、なければ config 読み取り」に統一する。

```bash
# yb_restart.sh
exec env \
  YB_RESTART_WORKTREE_ROOT="$wt_root" \
  YB_RESTART_WORKTREE_BRANCH="$wt_branch" \
  YB_RESTART_WORKTREE_PREFIX="$restart_wt_prefix" \
  "$ORCH_ROOT/scripts/yb_start.sh" "${start_args[@]}"

# yb_start.sh
if [ -n "${YB_RESTART_WORKTREE_PREFIX:-}" ]; then
  wt_branch_prefix="$YB_RESTART_WORKTREE_PREFIX"
else
  wt_branch_prefix="$(read_branch_prefix_from_config "$config_file")"
fi
```

## 次スプリントの詳細

### 構造化ログ不足
**何が問題か**  
Bash/Python 双方でログが散発的な `echo/print` に留まり、障害時にイベントの相関が追えない。運用者が手作業で時系列を再構成する必要がある。

**どこが該当するか**  
`scripts/yb_start.sh:70`、`scripts/yb_collect.sh:335`、`scripts/yb_restart.sh:84`。

**どう直すか**  
`.yamibaito/logs/<session_id>/events.jsonl` を標準出力先とし、`ts/level/script/session_id/cmd_id/worker_id/event/message` を共通 schema 化する。Bash は `log_event` 関数、Python は JSON formatter を共通利用する。

### dashboard 更新の排他制御不足
**何が問題か**  
collect 同時実行時に `dashboard.md` の単純上書きが競合し、最後に書いた処理のみ残る。最新状態が欠落し、判断材料の信頼性が落ちる。

**どこが該当するか**  
`scripts/yb_collect.sh:205`、`scripts/yb_collect.sh:262`、`scripts/yb_collect.sh:315`。

**どう直すか**  
collect 全体をロックし、`tmp` 書き出し後に `os.replace` で atomically 置換する。最低限、同時起動時の更新取りこぼしをなくしてから次段の構造改善へ進む。

### stale queue/report の残留
**何が問題か**  
queue と report の寿命管理がなく、終了済み session のデータが残り続ける。古いファイルが現行運用と混在し、誤読と誤収集の温床になる。

**どこが該当するか**  
`scripts/yb_start.sh:114`、`scripts/yb_stop.sh:44`、`scripts/yb_restart.sh:82`、`scripts/yb_init_repo.sh:23`。

**どう直すか**  
`yb cleanup` を追加し、TTL と active session 判定に基づいて archive へ退避する。`yb start` 前に stale 検出警告を出し、自動削除は opt-in とする。

### worker 表示名のハードコード
**何が問題か**  
表示名が `yb_start.sh` の固定配列に埋め込まれており、運用ポリシー変更時にコード修正が必要になる。

**どこが該当するか**  
`scripts/yb_start.sh:206`、`scripts/yb_start.sh:249`、`.yamibaito/panes.json:16`。

**どう直すか**  
`config.yaml` に `workers.display_names` を追加し、未指定時だけ既定名へフォールバックする。表示ポリシーをコードから分離する。

### オーケストレータ version 管理不在
**何が問題か**  
`yb --version` がなく、生成物にも orchestrator version が残らない。障害時に「どの実装で作られた状態か」を特定できない。

**どこが該当するか**  
`bin/yb:10`、`bin/yb:28`、`.yamibaito/config.yaml:1`、`.yamibaito/panes.json:1`。

**どう直すか**  
`VERSION` ファイルを導入し、`yb --version` で表示する。`panes*.json` と planner 出力に `orchestrator_version` を埋め込み、互換ポリシーを SemVer で明示する。

### send-keys 仕様の重複定義
**何が問題か**  
2段 send-keys のルールが複数 prompt に重複し、`two_bash_calls` と `two_calls` のように語彙が揺れている。修正時に反映漏れが発生しやすい。

**どこが該当するか**  
`.yamibaito/prompts/oyabun.md:45`、`.yamibaito/prompts/oyabun.md:131`、`.yamibaito/prompts/waka.md:62`、`.yamibaito/prompts/waka.md:105`。

**どう直すか**  
共通仕様を `.yamibaito/config.yaml` の `protocols.send_keys` に集約し、prompt は参照のみとする。`method` は `two_step_send_keys` に統一する。

## 将来対応の詳細

### dashboard の状態モデル分離
**何が問題か**  
現在の dashboard 生成は Python 内で Markdown 文字列を組み立てる方式で、表示列追加や履歴検索を入れるたびに描画ロジックまで変更が必要になる。

**どこが該当するか**  
`scripts/yb_collect.sh:205`、`scripts/yb_collect.sh:219`、`scripts/yb_collect.sh:227`、`dashboard.md:4`。

**どう直すか**  
`state.json` を唯一の truth source にし、dashboard は renderer が描画する成果物へ分離する。履歴は `dashboard_history.jsonl` に append し、CLI フィルタは state 参照で実装する。

## 実行ロードマップ

1. Day 1-2: `yb_collect` 誤リセット防御と `yb_start` readiness check を実装し、既存運用での安全性を先に確保する。  
2. Day 3-4: `grep` shim 廃止、`panes.json` 正規化、`prompts` 単一ソース化を適用し、構成の破綻ポイントを減らす。  
3. Week 2: 構造化ログ、排他制御、stale cleanup、version 管理を導入し、運用トラブル時の復旧時間を短縮する。  
4. Week 3+: dashboard の state + renderer 分離と skill 運用高度化を進め、将来機能追加の変更コストを下げる。

## 参照レポート

- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_001_report.yaml`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_002_report.yaml`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_003_report.yaml`
- `/Users/makinokaedenari/yamk12nfu/dark-part-time-job/.yamibaito/queue_agile-improve/reports/worker_004_report.yaml`
