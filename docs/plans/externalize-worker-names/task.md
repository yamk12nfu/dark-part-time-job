## 1. 概要
worker 表示名（例: 銀次、龍）が `yb_start.sh` の固定配列に埋め込まれているため、命名ポリシー変更のたびにコード変更と再デプロイが必要になっている。これを `.yamibaito/config.yaml` の設定値から読み込む方式へ変更し、表示名ポリシーを運用設定として管理できるようにする。目的は、コード改修なしで名称変更できる運用柔軟性と、pane タイトル・dashboard 表示の一貫性を確保すること。

## 2. 現状の問題
該当コードと現状挙動:

- `scripts/yb_start.sh:206-217`
  - Python 埋め込み部で `worker_names` 配列（10件）がハードコードされている。
- `scripts/yb_start.sh:249-250`
  - `worker_name_map[wid] = worker_names[i]` として `panes*.json` に表示名を保存。
- `scripts/yb_start.sh:277-278`
  - pane タイトル表示時に `worker_names[idx]` を使い、範囲外は `worker_id` フォールバック。
- `.yamibaito/config.yaml:1-2`
  - `workers.codex_count` のみ定義され、表示名の設定項目が存在しない。
- `scripts/yb_collect.sh:71-83`, `scripts/yb_collect.sh:91-96`
  - `panes*.json` の `worker_names` を参照して dashboard 表示名を組み立てるため、起動時マッピングが唯一の表示ソースになる。

障害シナリオ:

- 表示名を変えるたびに `scripts/yb_start.sh` の改修が必要になり、運用変更のリードタイムが長い。
- `worker_count` が 10 を超えると `scripts/yb_start.sh:277` のフォールバックで一部のみ `worker_00x` 表示となり、名称体系が混在する。
- 環境ごとに別命名ルールを使いたくても、設定ファイルで吸収できない。

## 3. ゴール
受け入れ条件:

- `.yamibaito/config.yaml` に `workers.display_names`（配列）を追加できる。
- `scripts/yb_start.sh` が `workers.display_names` を読み込み、`worker_name_map` と pane タイトル生成に利用する。
- 設定未指定時は既存既定名（銀次/龍/影/…）へフォールバックし、現行互換を維持する。
- 設定配列が `worker_count` より短い場合は不足分を既定名または `worker_id` で埋める。
- 空文字・不正値は警告のうえ無視し、`yb start` は継続する。

非ゴール（スコープ外）:

- `worker_id` の命名規則変更（`worker_001` 形式の廃止など）。
- dashboard の表示フォーマット変更（`<name>(worker_id)` 形式そのもの）。
- worker runtime 選択機能（codex/claude 切替）追加。

## 4. 設計方針
実装アプローチ:

- `scripts/yb_start.sh` で `codex_count` と同様に config を読み取るが、表示名は YAML 配列対応が必要なため専用パーサを追加する。
- 方針は `worker_003_report.yaml` の提案（`workers.display_names` 追加 + 未指定時フォールバック）に合わせる。
- パーサ実装は `python3` 埋め込みで行い、`workers.display_names` を JSON 配列として Bash 側へ返す（PyYAML 非依存）。
- 既存 Python ブロック (`scripts/yb_start.sh:194-279`) へ `WORKER_DISPLAY_NAMES_JSON` を環境変数で渡し、`worker_name_map` と pane タイトル決定を統一ロジックで処理する。

関数/構造体設計:

- `load_display_names_json(config_file)`（Bash関数）
  - 戻り値: JSON 配列文字列（例 `[
"銀次","龍"
]`）
  - 失敗時: `[]` を返却し警告。
- Python 側関数 `resolve_worker_label(index, worker_id, configured_names, default_names)`
  - 優先順位: `configured_names[index]` -> `default_names[index]` -> `worker_id`
  - 空文字/非文字列は無効として次候補へフォールバック。
- `worker_name_map` は従来どおり `worker_id -> display_name` の dict を維持し、`panes*.json` スキーマ互換を保つ。

エラー時挙動:

- 設定解析失敗時: `stderr` に warning を出し、既定名で継続。
- 設定値が配列でない場合: warning を出し、既定名で継続。
- 名前重複は許容（動作継続）し、必要なら warning のみ出す。

影響範囲:

- `scripts/yb_start.sh`: 表示名取得と pane タイトル設定ロジック。
- `.yamibaito/config.yaml`: `workers.display_names` 追加。
- `scripts/yb_collect.sh`: コード変更不要（`panes.worker_names` 読み取りを継続）。

## 5. 実装ステップ
1. `.yamibaito/config.yaml` に `workers.display_names` のサンプル定義を追加する（既存 `codex_count` と同階層）。変更ファイル: `.yamibaito/config.yaml`。
2. `scripts/yb_start.sh` に `load_display_names_json()` を追加し、config から表示名配列を取得できるようにする。変更ファイル: `scripts/yb_start.sh`。
3. `scripts/yb_start.sh` の Python 実行環境変数に `WORKER_DISPLAY_NAMES_JSON` を追加する。変更ファイル: `scripts/yb_start.sh`。
4. `scripts/yb_start.sh` の Python ブロック（現 `worker_names` 固定配列部分）を、設定値 + 既定値フォールバック方式へ置換する。変更ファイル: `scripts/yb_start.sh`。
5. pane タイトル設定と `worker_name_map` 生成が同一決定関数を使うよう整理し、表示不一致を防ぐ。変更ファイル: `scripts/yb_start.sh`。

## 6. テスト方針
正常系:

- `workers.display_names` を `worker_count` 件ちょうど設定し、`tmux` pane タイトルと `panes*.json.worker_names` が一致すること。
- `workers.display_names` 未設定時に、現行と同じ既定名が使われること。
- `yb collect` 後の `dashboard.md` 担当表示が期待する表示名になること。

異常系:

- `workers.display_names` が文字列や数値など配列以外の場合、warning 出力のうえ起動継続すること。
- 配列が短い場合に不足分がフォールバックされること。
- 配列要素に空文字が含まれる場合、当該 worker がフォールバックされること。

手動テスト手順:

1. `.yamibaito/config.yaml` に 5件の `display_names` を設定して `yb start --session names-a` を実行。
2. `tmux list-panes` と `.yamibaito/panes_names-a.json` を確認し、`worker_names` が設定値になっていることを確認。
3. `display_names` を 2件だけにして再実行し、3件目以降のフォールバック動作を確認。
4. 不正設定（`display_names: "foo"`）で再実行し、warning + 起動継続を確認。

## 7. リスクと注意点
- 後方互換性: `panes*.json` の `worker_names` 形式を変えると `yb_collect.sh` 側表示が壊れるため、dict 形式を維持する。
- 他スクリプト波及: `yb_collect.sh` は `worker_names` を信用して表示するため、起動時に壊れた map を書くと dashboard 全体の可読性が落ちる。
- 依存関係: YAML 解析を外部ライブラリに依存すると配布性が下がる。標準 `python3` のみで解析可能な実装を採用する。
- 運用注意: 絵文字や制御文字を表示名に入れると tmux タイトル表示が崩れる場合があるため、入力値の許容文字をガイド化する。
- 入力バリデーション: `workers.display_names` の各要素は「非空の文字列」かつ許可文字のみを受け付け、絵文字・制御文字（`\n`, `\r`, `\t` 等）・シェルメタ文字（例: `` ` ``, `$`, `;`, `|`, `&`, `>`, `<`）を含む値は warning を出してフォールバックする。これにより表示崩れとシェル解釈由来の事故リスクを抑える。
