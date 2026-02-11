## 1. 概要
現在の運用では「skill 候補の検出」まではできるが、その後のテンプレート生成・登録・検証の仕組みが無いため、候補が backlog 化して運用が閉じない。`yb collect` と prompt で定義済みの skill フローを接続し、`yb skill init` / `yb skill validate` / `index 管理` を最小構成で導入して、候補検出から登録完了までを 1 本の手順として実行可能にする。

## 2. 現状の問題
該当箇所は以下。

- `scripts/yb_collect.sh:167-180` は worker report から `skill_candidate_*` を読み込んでいる。
- `scripts/yb_collect.sh:199-201` で `skill_candidate_found=true` の候補を抽出している。
- `scripts/yb_collect.sh:241-249` は dashboard の「仕組み化のタネ」へ表示するだけで、登録状態の判定や永続管理がない。
- `.yamibaito/prompts/waka.md:91` は `skills_dir: ".yamibaito/skills"` を参照している。
- `.yamibaito/prompts/waka.md:337-343` は「承認後に `.yamibaito/skills/<name>/SKILL.md` を作成する」フローを要求している。
- `.yamibaito/prompts/oyabun.md:302-305` は「承認後に若頭が skill を作成する」運用を要求している。
- `bin/yb:11-21` の usage/case には `yb skill` サブコマンドが存在しない。

現状挙動では候補が dashboard に列挙され続けるだけで、登録済み判定・雛形生成・品質検証が自動化されない。障害シナリオは以下。

- 同じ候補が report に出るたびに「仕組み化のタネ」へ再掲され、重複候補の整理コストが増える。
- 承認後の作業が都度手作業になり、`SKILL.md` の構成揺れや記述漏れが発生する。
- 無効な skill（必須項目不足・重複名・壊れた参照）が混入しても検知できない。

## 3. ゴール
受け入れ条件:

- `.yamibaito/templates/skill/SKILL.md.tmpl` が追加され、skill 雛形の単一テンプレートとして利用できる。
- `.yamibaito/skills/index.yaml` を導入し、少なくとも `name/path/status/owner/created_at/updated_at` を管理できる。
- `yb skill init <name> --desc <description> [--owner <owner>]` で `.yamibaito/skills/<name>/SKILL.md` を生成し、`index.yaml` に登録できる。
- `yb skill validate` で index と実ファイルを照合し、必須項目不足・重複名・参照切れを検出して非0終了できる。
- `yb collect` が `skill_candidate_*` と `index.yaml` を突き合わせ、未登録候補のみを「要対応」として可視化できる。

非ゴール（スコープ外）:

- skill 承認フロー自体（誰が承認するか、承認 UI の追加）の自動化。
- Codex/Claude の外部 skill registry への公開連携。
- skill 本文品質の意味理解レビュー（LLM 評価）の自動化。

## 4. 設計方針
実装は「テンプレート」「CLI」「index」「collect 連携」を同時導入する。主な設計は以下。

- CLI:
`bin/yb` に `skill` サブコマンドを追加し、`scripts/yb_skill.sh` へ委譲する。`yb skill init` と `yb skill validate` を最小機能で先行実装する。

- データ構造（index）:
`index.yaml` は `schema_version` と `skills` 配列を持つ。1 エントリは `name/path/status/owner/created_at/updated_at/source` を保持する。

```yaml
schema_version: 1
skills:
  - name: "example-skill"
    path: ".yamibaito/skills/example-skill/SKILL.md"
    status: "draft"
    owner: "worker_004"
    created_at: "2026-02-12T01:00:00+09:00"
    updated_at: "2026-02-12T01:00:00+09:00"
    source:
      report: "worker_004_report.yaml"
      task_id: "cmd_0001_D"
```

- 関数設計（`scripts/yb_skill.sh`）:
`cmd_skill_init`（雛形生成 + index 追記）、`cmd_skill_validate`（index 構文/重複/ファイル整合性検査）、`load_skill_index`（index 読み込み）、`save_skill_index`（排他更新）を分離する。YAML 更新は Python ヘルパーを呼び出し、Bash の文字列処理依存を避ける。

- YAML 更新時の排他制御:
`index.yaml` の更新は `save_skill_index` 内で `"$skills_dir/.index.lock"` に対する `flock` を取得して単一 writer 化し、書き込みは同一ディレクトリの一時ファイルへ `flush + fsync` 後に `os.replace` で置換する。`flock` が使えない環境では `os.replace` の atomic replace を最低保証として partial write を防ぐ。

- collect 連携:
`scripts/yb_collect.sh:199-201` の候補抽出後に `index.yaml` を読み、`skill_candidate_name` 正規化名で登録済み照合する。未登録候補のみ dashboard の「仕組み化のタネ」に表示し、登録済み候補は `done` 側へ簡易注記する。

- エラー時挙動:
`yb skill init` は重複名/不正名で非0終了。`yb skill validate` は違反一覧を標準エラーへ出し非0終了。`yb collect` は index 読み込み失敗時に warning を出し、候補表示は従来互換モード（全候補表示）で継続する。

影響範囲:

- 追加: `.yamibaito/templates/skill/SKILL.md.tmpl`, `.yamibaito/skills/index.yaml`, `scripts/yb_skill.sh`
- 変更: `bin/yb`, `scripts/yb_collect.sh`
- 間接影響: `dashboard.md` の「仕組み化のタネ」表示内容

## 5. 実装ステップ
1. `.yamibaito/templates/skill/SKILL.md.tmpl` を追加し、必須セクション（概要・入出力・手順・制約）を定義する。変更ファイル: `.yamibaito/templates/skill/SKILL.md.tmpl`
2. 初期 `index.yaml` を追加し、空配列を持つ schema を定義する。変更ファイル: `.yamibaito/skills/index.yaml`
3. skill CLI スクリプトを実装し、`init/validate` の引数処理・エラーコード・index 更新を実装する。変更ファイル: `scripts/yb_skill.sh`
4. `bin/yb` に `skill` サブコマンドを追加し、`yb skill init` / `yb skill validate` を公開する。変更ファイル: `bin/yb`
5. `scripts/yb_collect.sh` に index 照合ロジックを追加し、未登録候補のみ dashboard へ表示する。変更ファイル: `scripts/yb_collect.sh`
6. `yb skill init` と `yb skill validate` の実行例を運用ドキュメントへ最小追記する。変更ファイル: `.yamibaito/prompts/waka.md`（必要最小限）

## 6. テスト方針
正常系:

- `yb skill init test-skill --desc "..." --owner worker_004` 実行で `SKILL.md` と `index.yaml` エントリが生成される。
- `yb skill validate` が正常データで 0 終了し、違反なしを報告する。
- `skill_candidate_found=true` の report があっても、登録済み `skill_candidate_name` は dashboard の候補一覧から除外される。

異常系:

- 同名 skill を `init` した場合に重複エラーで非0終了する。
- index から参照される `SKILL.md` を削除した状態で `validate` を実行すると参照切れを検出して非0終了する。
- テンプレート欠落時に `init` が失敗し、原因を明示する。

手動テスト手順:

1. `yb skill init sample-skill --desc "sample"` を実行し、`.yamibaito/skills/sample-skill/SKILL.md` と `index.yaml` 追記を確認する。
2. `yb skill validate` を実行し、0 終了を確認する。
3. `index.yaml` の `path` を意図的に壊して再度 `yb skill validate` を実行し、非0終了とエラー詳細を確認する。
4. `skill_candidate_found=true` を含む report を置いて `yb collect` 実行し、未登録候補のみ表示されることを確認する。

## 7. リスクと注意点
- 後方互換性: `yb collect` が index 読み込みを前提にすると既存環境で失敗しうるため、index 不在時は従来挙動へフォールバックする。
- 命名衝突: skill 名の正規化ルールが曖昧だと重複登録や誤判定が起きる。`[a-z0-9-]+` に制限し、case-insensitive で重複検査する。
- 共有ファイル競合: `index.yaml` は複数実行で競合するため、更新時ロック（`flock` もしくは atomic replace）を必須にする。
- 他スクリプト波及: `bin/yb` のサブコマンド追加は help/usage を更新しないと運用者に発見されない。usage と README を同期する。
