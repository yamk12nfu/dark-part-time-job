## 1. 概要
`panes*.json` の `worktree_root` / `worktree_branch` が `null` を取り得るため、読み取り側スクリプトごとに null 防御と推定フォールバックが散在している。`schema_version` 付きの非 nullable 構造へ統一し、`yb_start` / `yb_restart` / `yb_stop` / `yb_worktree_list` が同じ正規化ロジックを使う設計に改める。

## 2. 現状の問題
該当箇所:

- `scripts/yb_start.sh:255` と `scripts/yb_start.sh:257` が `worktree_root` / `worktree_branch` を `None` で書き出している。
- `scripts/yb_restart.sh:55-60` は読み取り時に `isinstance(..., str)` 判定で `''` へ落とし、`scripts/yb_restart.sh:114` で branch 推定へフォールバックする。
- `scripts/yb_stop.sh:62-66` も `worktree_branch` の型チェックに失敗すると `scripts/yb_stop.sh:72-89` の prefix 推定削除へフォールバックする。
- `scripts/yb_worktree_list.sh:37` は `worktree_branch` が falsy だとセッション表示対象から除外され、`scripts/yb_worktree_list.sh:41` は `worktree_root` に空文字を入れている。

現状挙動と障害シナリオ:

- `panes.json` の null/空文字/欠落が混在すると、再起動時に「本来再利用できる worktree なのに推定 branch で削除」が発生し得る。
- 一部スクリプトだけ防御が増え、別スクリプトは旧前提のまま残るため、修正のたびに挙動差が再発する。

## 3. ゴール
受け入れ条件:

- `panes*.json` に `schema_version`（例: `2`）を付与し、`worktree` を非 nullable で保持する:
  - `worktree.enabled: bool`
  - `worktree.root: string`（未使用時は `""`）
  - `worktree.branch: string`（未使用時は `""`）
- `yb_restart.sh` / `yb_stop.sh` / `yb_worktree_list.sh` は共通ローダー経由で正規化済み値を取得し、個別の null 判定を削減する。
- 既存の `schema_version` 未設定ファイル（旧 panes）も読み取り時に正規化して動作継続できる。

非ゴール（スコープ外）:

- worktree 作成・削除アルゴリズム自体の変更（`gtr new/rm` 戦略変更）。
- `panes.json` の全キー再設計（worker 名や pane index 構造の刷新）。
- tmux セッション命名規則の変更。

## 4. 設計方針
実装アプローチ:

- 共通 Python ヘルパー（例: `scripts/lib/panes.py`）を追加し、以下を提供する:
  - `load_panes(path) -> dict`: JSON 読み取り + schema 判定 + v2 正規化
  - `normalize_panes(data) -> dict`: 欠落/None/型不一致を `{"enabled": False, "root": "", "branch": ""}` へ補正
  - `dump_panes_v2(...)`: `yb_start` 用の書き出しユーティリティ
- `yb_start.sh` の埋め込み Python (`scripts/yb_start.sh:194-279`) は v2 構造を書き出す。移行期間の互換性確保が必要なら `worktree_root/worktree_branch` を空文字で併記し、`None` は禁止する。
- `yb_restart.sh` / `yb_stop.sh` / `yb_worktree_list.sh` の `data.get("worktree_root")` / `data.get("worktree_branch")` 直接参照を共通ローダー呼び出しへ置換する。

関数/構造設計（例）:

- `panes["worktree"]["enabled"]`: `bool`
- `panes["worktree"]["root"]`: `str`
- `panes["worktree"]["branch"]`: `str`
- 旧 schema 入力時:
  - `worktree_root` が文字列なら `worktree.root` へ移送
  - `worktree_branch` が文字列なら `worktree.branch` へ移送
  - `enabled` は `root` または `branch` が非空なら `True`

エラー時挙動:

- JSON 破損時は warning を出してデフォルト構造にフォールバック（即終了しない）。
- `worktree.enabled == false` のときは root/branch の値に依存せず「worktree 未使用」として扱う。

影響範囲:

- 主変更: `scripts/yb_start.sh`, `scripts/yb_restart.sh`, `scripts/yb_stop.sh`, `scripts/yb_worktree_list.sh`
- 新規: `scripts/lib/panes.py`（想定）
- 間接影響: `panes*.json` を外部参照する補助ツール（存在する場合）は schema_version 判定が必要

## 5. 実装ステップ
1. `scripts/lib/panes.py` を追加し、v1/v2 両対応の `load_panes()` と `normalize_panes()` を実装する。
2. `scripts/yb_start.sh` の panes 出力部（`scripts/yb_start.sh:252-265`）を v2 構造へ変更し、`None` 出力を廃止する。
3. `scripts/yb_restart.sh` の panes 読み取り部（`scripts/yb_restart.sh:49-67`）を共通ローダー利用へ置換する。
4. `scripts/yb_stop.sh` の panes 読み取り部（`scripts/yb_stop.sh:56-70`）を共通ローダー利用へ置換する。
5. `scripts/yb_worktree_list.sh` のセッション収集部（`scripts/yb_worktree_list.sh:33-43`）を共通ローダー利用へ置換する。
6. 旧 panes ファイル読み込み時の互換性（schema_version 未設定）を手動確認し、必要な warning 文言を整える。

## 6. テスト方針
正常系:

- `yb start --session <id>` 実行後の `panes_<id>.json` が `schema_version: 2` と非 nullable `worktree` 構造を持つ。
- `yb restart --session <id>` と `yb stop --session <id>` が、worktree 情報を推定に頼らず復元できる。
- `yb worktree-list --repo <repo>` で active/stopped/orphaned 表示が従来通り出る。

異常系:

- `panes*.json` 破損時にスクリプトが異常終了せず、warning + 安全側フォールバックになる。
- 旧 schema（`worktree_root: null`, `worktree_branch: null`）を読み込んでも例外なく正規化される。
- `worktree.enabled: false` かつ root/branch 空文字のケースで削除処理が誤発火しない。

手動テスト手順:

1. 新規セッションで `yb start --session panes-v2-test` を実行し、生成 JSON を確認。
2. そのまま `yb restart --session panes-v2-test` を実行し、同一 branch/worktree が再利用されることを確認。
3. `panes` を旧形式（schema_version なし + flat key）に書き換えて `yb stop/yb restart` を実行し、互換動作を確認。
4. `yb worktree-list` の表示で、session/branch/path/status が欠落しないことを確認。

## 7. リスクと注意点
- 後方互換性: 既存ツールが `worktree_root`/`worktree_branch` 直読みしている場合、v2 導入で壊れる。移行期間は flat key 併記または読み取り互換レイヤーを維持する。
- 他スクリプト波及: panes 読み取りロジックを個別に持つ別スクリプトが残ると再発するため、共通ローダーを唯一の入口として徹底する。
- 依存関係: Python 埋め込みから `scripts/lib/panes.py` を import するため、`sys.path` 解決（`ORCH_ROOT` 基準）を統一しないと環境差で失敗する。
