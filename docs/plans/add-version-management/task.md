## 1. 概要
オーケストレータ本体のバージョン情報を一元管理し、CLI で参照可能にすると同時に、生成物へ `orchestrator_version` を埋め込む。現状は `yb --version` がなく、`panes*.json` や queue 生成物にも実装バージョンが残らないため、障害時に「どのコードで生成された状態か」を追跡できない。`VERSION` を single source of truth にして、表示・記録・互換判断の基盤を整える。

## 2. 現状の問題
該当コードと現状挙動:

- `bin/yb:10-22`, `bin/yb:28-77`
  - usage と dispatch に `--version` / `version` が存在しない。
- `scripts/yb_start.sh:252-262`
  - `panes*.json` 生成時の `mapping` に orchestrator version が含まれない。
- `scripts/yb_plan.sh:82-84`
  - plan 用 `panes.json` も `session/plan/codex` のみで version 不在。
- `scripts/yb_init_repo.sh:36-38`, `scripts/yb_init_repo.sh:40-44`
  - `director_to_planner.yaml` や `_index.json` 初期化時に実装 version を記録しない。
- `.yamibaito/config.yaml:1-13`
  - worker 数と codex 実行設定のみで、orchestrator version 情報を保持していない。

障害シナリオ:

- 障害調査時、手元の `bin/yb` と対象 repo の `.yamibaito/*` 生成物の対応関係が分からず、再現に時間がかかる。
- 複数バージョンが混在する運用で、古いスキーマ生成物を新コードが読む際の互換判定基準がない。
- レポート共有時に「修正済み/未修正」の判別がコミット推測に依存し、運用ミスを誘発する。

## 3. ゴール
受け入れ条件:

- オーケストレータの source-of-truth として `VERSION` ファイルを導入し、SemVer 形式 (`MAJOR.MINOR.PATCH`) で管理する。
- `bin/yb` が `yb --version` と `yb version` の両方に対応し、現在バージョンを表示する。
- `scripts/yb_start.sh` が生成する `panes*.json` に `orchestrator_version` を追加する。
- `scripts/yb_plan.sh` が生成する `plan_dir/panes.json` に `orchestrator_version` を追加する。
- `scripts/yb_init_repo.sh` が初期作成する `queue/director_to_planner.yaml` に `orchestrator_version` を記録する。
- 既存生成物（version 欠落）を読む場合は warning のみで継続し、即時 break しない。

非ゴール（スコープ外）:

- 自動リリース（tag 作成、CHANGELOG 自動生成）。
- 既存全アーカイブの一括マイグレーション。
- `schema_version` の全面刷新（今回は orchestrator version 追加のみ）。

## 4. 設計方針
実装アプローチ:

- `VERSION` を `ORCH_ROOT/VERSION` に配置し、`bin/yb` の `read_orchestrator_version()` で読み込む。
- `worker_003_report.yaml` の提案（`yb --version` 追加と生成物への `orchestrator_version` 埋め込み）を基準に、追跡可能性を優先する。
- `bin/yb` は dispatch 前に `YB_ORCHESTRATOR_VERSION` 環境変数を export して各スクリプトへ渡す。
- 各生成処理は受け取った `YB_ORCHESTRATOR_VERSION` を成果物に埋め込む。

関数/構造体設計:

- `read_orchestrator_version()`（`bin/yb`）
  - 入力: なし（`$ORCH_ROOT/VERSION` を読む）
  - 出力: バージョン文字列
  - 異常時: `0.0.0-dev` を返し warning。
- `print_version()`（`bin/yb`）
  - `yb <version>` 系コマンドで呼び出し。
- `build_panes_mapping(...)`（`scripts/yb_start.sh` の Python ブロック）
  - `mapping["orchestrator_version"]` を追加。
- `write_plan_panes_json(...)`（`scripts/yb_plan.sh`）
  - 既存 JSON に version キー追加。
- `initialize_director_queue(...)`（`scripts/yb_init_repo.sh`）
  - `director_to_planner.yaml` 初期内容へ `orchestrator_version` を埋める。

エラー時挙動:

- `VERSION` 不在/不正形式: warning を出し `0.0.0-dev` 継続。
- 生成物への書き込み失敗: 該当コマンドは非0終了（中途半端な状態を残さない）。
- 既存生成物に version 欠落: 読み取り側は後方互換モードで処理継続し、stderr に warning。

影響範囲:

- `bin/yb`: CLI オプションと共通 version 読み出し。
- `scripts/yb_start.sh`: panes メタデータ拡張。
- `scripts/yb_plan.sh`: plan panes メタデータ拡張。
- `scripts/yb_init_repo.sh`: queue 初期 YAML への version 付与。
- `.yamibaito/config.yaml`: `orchestrator_version`（または `orchestrator` セクション）追加方針の明記。

## 5. 実装ステップ
1. `ORCH_ROOT/VERSION` を追加し、初期値を `x.y.z` 形式で定義する。変更ファイル: `VERSION`。
2. `bin/yb` に `read_orchestrator_version()` / `print_version()` を追加し、`--version` と `version` サブコマンドを実装する。変更ファイル: `bin/yb`。
3. `bin/yb` から各サブコマンド実行時に `YB_ORCHESTRATOR_VERSION` を環境変数で渡す。変更ファイル: `bin/yb`。
4. `scripts/yb_start.sh` の `mapping` 生成に `orchestrator_version` を追加する。変更ファイル: `scripts/yb_start.sh`。
5. `scripts/yb_plan.sh` の `plan_dir/panes.json` へ `orchestrator_version` を追加する。変更ファイル: `scripts/yb_plan.sh`。
6. `scripts/yb_init_repo.sh`（および必要なら `templates/queue/director_to_planner.yaml`）で `director_to_planner.yaml` 初期データへ `orchestrator_version` を記録する。変更ファイル: `scripts/yb_init_repo.sh`, `templates/queue/director_to_planner.yaml`。
7. `.yamibaito/config.yaml` に version 関連設定（例: `orchestrator.version_policy: semver`）を追記し、運用規約を明示する。変更ファイル: `.yamibaito/config.yaml`。

## 6. テスト方針
正常系:

- `yb --version` と `yb version` が同じ値を返すこと。
- `yb start --session <id>` 後の `.yamibaito/panes_<id>.json` に `orchestrator_version` が入ること。
- `yb plan --title <t>` 後の `plan_dir/panes.json` に `orchestrator_version` が入ること。
- 新規 `yb init` 後の `.yamibaito/queue/director_to_planner.yaml` に `orchestrator_version` が入ること。

異常系:

- `VERSION` を一時的に欠落させた状態で `yb --version` を実行し、warning + `0.0.0-dev` になること。
- `VERSION` の形式が不正（例 `v1`）でも CLI が落ちず、warning を出すこと。
- 既存の version 無し `panes*.json` を `yb collect` が読んでも処理継続できること。

手動テスト手順:

1. `yb --version` を実行し、表示値を確認。
2. `yb start --session ver-test` 実行後に `.yamibaito/panes_ver-test.json` を確認し、version 埋め込みを確認。
3. `yb plan --title version-check` 実行後に生成 `panes.json` を確認。
4. 新規 repo で `yb init` を実行し、`director_to_planner.yaml` の version を確認。
5. `VERSION` を意図的に不正化し、warning とフォールバック挙動を確認。

## 7. リスクと注意点
- 後方互換性: 既存生成物に `orchestrator_version` が無い状態は必ず想定し、読み取り側を strict にしすぎない。
- 他スクリプト波及: `bin/yb` の dispatch 変更で全サブコマンドの呼び出し形式が変わるため、引数透過 (`"$@"`) が壊れないよう注意。
- 依存関係: version 文字列をロジック分岐に使い始めると比較実装が必要になる。今回の範囲は「表示・記録」に限定し、比較ロジックは次フェーズで導入する。
- 運用注意: `VERSION` 更新ルール（MAJOR/MINOR/PATCH）を決めずに運用すると逆に混乱するため、PR テンプレートか運用手順に更新責務を明記する。
