## 1. 概要
`stale queue/report` を手動で安全に掃除できる `yb cleanup` コマンドを追加する。現在の実装は `yb start` で queue/reports を生成するのみで寿命管理を持たず、`yb stop`/`yb restart` でも削除・退避されないため、古いセッション由来の状態が残留し続ける。これを「active session を保護しつつ、TTL で stale を検出し、dry-run と apply を分けて処理する」運用に変更し、誤読・誤収集・肥大化を抑止する。

## 2. 現状の問題
該当コードと現状挙動:

- `scripts/yb_start.sh:114-143`
  - `queue${session_suffix}` 配下の `tasks/` と `reports/` を作成し、ファイルがなければテンプレートを配置する。
  - 既存ファイルは再利用されるため、古い report/task が残っていても初期化されない。
- `scripts/yb_start.sh:124-128`
  - `reports/_index.json` は「なければ作る」だけで、stale path の掃除をしない。
- `scripts/yb_stop.sh:44-103`
  - tmux セッション停止と worktree 削除のみ。`queue*/reports`/`panes*.json` には触れない。
- `scripts/yb_restart.sh:82-186`
  - セッション再起動と start 呼び出しのみ。queue/report の寿命管理がない。
- `scripts/yb_init_repo.sh:23-25`, `scripts/yb_init_repo.sh:40-44`, `scripts/yb_init_repo.sh:60-72`
  - 初期 queue 雛形を作るが、古い report のローテーション・削除は未実装。
- `scripts/yb_collect.sh:166-183`, `scripts/yb_collect.sh:188-199`, `scripts/yb_collect.sh:309-313`
  - `reports_dir` 内の `*_report.yaml` を全走査し、`done/completed` を完了として扱う。
  - stale report が混在すると、現在の作業と無関係な完了情報を `done` 集計に載せるリスクがある。

障害シナリオ:

- 同一 `--session` を長期再利用すると、旧 report が残存し、`yb collect` の完了表示や task リセット判断が現行実行と混ざる。
- 古い `queue_<session>` が増え続け、運用者がどれを現役として扱うべきか判別しづらくなる。
- `_index.json` が stale report path を保持したままになり、可観測性と調査性が低下する。

## 3. ゴール
受け入れ条件:

- `bin/yb` に `cleanup` サブコマンドが追加され、`yb help` に使用方法が表示される。
- `scripts/yb_cleanup.sh` を新規実装し、以下の引数を持つ。
  - `--repo <path>`
  - `--session <id>`（指定時は対象をそのセッションに限定）
  - `--ttl-days <n>`（既定 7）
  - `--apply`（未指定時は dry-run）
- cleanup 対象は `.yamibaito/queue*` と対応する `panes*.json`。`tmux` で active なセッションは除外される。
- `--apply` 実行時は即時削除ではなく `.yamibaito/archive/<timestamp>/` へ退避し、実行結果サマリ（対象数・スキップ数・失敗数）を出力する。
- dry-run では変更を加えず、候補一覧のみ表示する。

非ゴール（スコープ外）:

- `yb collect` の task reset ロジック自体の改修。
- worktree/branch の削除方針変更（`yb stop --delete-branch` など）。
- `dashboard.md` のレンダリング設計変更。

## 4. 設計方針
実装アプローチ:

- 新規 `scripts/yb_cleanup.sh` で cleanup を一元化する。
- セッション名生成ロジックは `scripts/yb_common.sh` の共有関数 `build_session_name()` に集約し、`yb_start.sh` と `yb_cleanup.sh` で共通利用する。
- 設計根拠は `worker_002_report.yaml` の stale 寿命管理提案（TTL + active 判定 + archive 退避）を採用する。
- 判定フロー:
  - `queue*` ディレクトリを列挙。
  - ディレクトリ名から session suffix（`queue_<session>`）を抽出。
  - `tmux has-session -t "yamibaito_<repo>_<session>"` で active 判定。
  - `mtime` が `ttl_days` を超え、かつ active でないものを stale 候補とする。
- 処理モード:
  - dry-run: `[DRY-RUN]` プレフィックスで候補を表示。
  - apply: `.yamibaito/archive/<timestamp>/queue...` へ `mv` し、同 suffix の `panes*.json` も同時退避。

関数/構造体設計（シェル関数 + 補助 Python 可）:

- `parse_args()`
  - 引数の妥当性検証を担当。`ttl_days` が正整数でない場合は終了コード `2`。
- `build_session_name(repo_name, session_id)`
  - `scripts/yb_common.sh` に定義する共有関数。`yb_start.sh` と同形式のセッション名を生成する。
- `is_session_active(session_name)`
  - active 判定を返す（0/1）。`tmux` 未導入時は警告を出し「非 active 扱い」で継続。
- `collect_cleanup_targets()`
  - `queue_path`, `panes_path`, `session_id`, `reason` を持つ候補集合を構築。
- `archive_target(target)`
  - 退避処理。失敗時は警告し、他ターゲットは継続（best effort）。
- `print_summary()`
  - `candidates/applied/skipped/failed` を最終表示。

エラー時挙動:

- 引数不正: 即時失敗（非0終了）。
- 個別ファイルの移動失敗: 警告して続行し、最終的に非0終了。
- archive ディレクトリ作成失敗: 即時失敗。

影響範囲:

- `bin/yb`: コマンドルーティングと usage 文言追加。
- `scripts/yb_cleanup.sh`: 新規。
- 既存 `yb_start/stop/restart/init` の主要ロジックは変更しない（呼び出し契約のみ維持）。

## 5. 実装ステップ
1. `scripts/yb_cleanup.sh` を新規作成し、引数解析 (`--repo/--session/--ttl-days/--apply`) と dry-run 出力を実装する。変更ファイル: `scripts/yb_cleanup.sh`。
2. stale 判定ロジック（session suffix 抽出、`tmux has-session`、TTL 判定）を実装し、候補収集関数を作る。変更ファイル: `scripts/yb_cleanup.sh`。
3. archive 退避処理（queue + panes の同時移動）と結果サマリ出力を実装する。変更ファイル: `scripts/yb_cleanup.sh`。
4. `bin/yb` に `cleanup` サブコマンドと help 文言を追加する。変更ファイル: `bin/yb`。
5. 最低限の運用手順を task 実装 PR に記載（dry-run 実行例、apply 実行例、失敗時の確認方法）。変更ファイル: 実装 PR 説明（コード外）。

## 6. テスト方針
正常系:

- `yb cleanup --repo <path>` で候補一覧だけ表示され、ファイルが移動されないこと。
- `yb cleanup --repo <path> --apply` で stale `queue_<session>` と対応 `panes_<session>.json` が archive へ移動されること。
- active な tmux セッションに対応する queue はスキップされること。

異常系:

- `--ttl-days abc` のような不正値で非0終了し、使い方が表示されること。
- archive 先作成不可（権限不足等）で非0終了し、失敗理由が標準エラーに出ること。
- `tmux` が利用不可の環境で警告を出しつつ実行継続できること。

手動テスト手順:

1. テスト用に `queue_oldsession` と `panes_oldsession.json` を作成し、`mtime` を過去日に調整する。
2. `yb cleanup --repo <path> --ttl-days 1` を実行し、dry-run 表示を確認。
3. `yb cleanup --repo <path> --ttl-days 1 --apply` を実行し、archive へ移動されたことを確認。
4. 同名 session の tmux を起動した状態で再実行し、active 対象がスキップされることを確認。

## 7. リスクと注意点
- 後方互換性: 既存運用では `queue` を手で参照している可能性があるため、初期段階は delete ではなく archive 移動を必須とする。
- 他スクリプト波及: `yb_collect.sh` は queue パス前提で動くため、cleanup 実行中に collect を並行実行しない運用ガードが必要。
- 依存関係: `tmux`, `find`, `stat`, `mv` の挙動差（macOS/Linux）に注意し、`stat` は移植可能な実装にする（必要なら Python で epoch 取得）。
- 誤判定リスク: セッション名生成規則が `yb_start.sh` とずれると active 保護が壊れるため、命名規則を共通化すること。
