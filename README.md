# Yamibaito Orchestrator

中央オーケストレータ（親分→若頭→若衆）を、各リポジトリから起動できるようにするための仕組み。

## 必要なパッケージ

- `tmux`
- `claude` CLI（Claude Code）
- `codex` CLI
- `python3`
- `git`

## 環境ごとに修正が必要な箇所

### 1) オーケストレータのパス

このREADMEの例は `<path-to-orchestrator>` を使っています。環境に合わせてパスを置き換えてください。

例:
- `/Users/<you>/path/to/dark-part-time-job/bin/yb`

### 2) `yb` をパス or エイリアス登録（推奨）

毎回フルパスで呼ぶのが面倒なら、`~/.zshrc` などに追加してください。

```bash
# どちらか片方でOK
export PATH="/Users/<you>/path/to/dark-part-time-job/bin:$PATH"
alias yb="/Users/<you>/path/to/dark-part-time-job/bin/yb"
```

### 3) リポジトリが別パスにある場合

`yb` コマンドは `--repo <path>` で対象リポジトリを指定できます。

例:
```
yb init --repo /path/to/your/repo
yb start --repo /path/to/your/repo
```

## 使い方（各リポジトリ側）

1) 初期化
```
<path-to-orchestrator>/bin/yb init
```

2) 起動（tmuxセッション作成）
```
<path-to-orchestrator>/bin/yb start
```

3) 参加
```
tmux attach -t yamibaito_<repo>
```

## リポジトリに作られるもの

- `dashboard.md`
- `.yamibaito/config.yaml`
- `.yamibaito/queue/`
  - `director_to_planner.yaml`
  - `tasks/worker_XXX.yaml`
  - `reports/worker_XXX_report.yaml`
  - `reports/_index.json`
- `.yamibaito/prompts/`

## 設定

`.yamibaito/config.yaml` の `workers.codex_count` を変えると若衆の人数が変わる。

## スキル化とペルソナ

- 若衆が `skill_candidate_found` を true にした場合、`dashboard.md` の「仕組み化のタネ」に候補が出る。
- 親分が承認したら、若頭に `SKILL.md` の作成を指示する（`.yamibaito/skills/<name>/SKILL.md`）。
- ペルソナは若頭がタスクに付与する（固定セットから選ぶ）。

固定ペルソナセット:
- development: senior_software_engineer, qa_engineer, sre_devops, senior_ui_designer, database_engineer
- documentation: technical_writer, business_writer, presentation_designer
- analysis: data_analyst, market_researcher, strategy_analyst, business_analyst
- other: professional_translator, professional_editor, ops_coordinator

## サブコマンド一覧

| コマンド | 概要 |
| --- | --- |
| `yb init` | 初期ファイル生成 |
| `yb start` | tmuxセッション生成 + 親分/若頭起動 |
| `yb restart` | 既存セッションを破棄して再起動 |
| `yb dispatch` | 若衆へ割当済みタスクを起動（手動用） |
| `yb collect` | `dashboard.md` を再生成 |

---

### `yb init`

リポジトリにオーケストレータの基盤ファイルを生成する。**最初に1回だけ実行する。**

```bash
yb init                        # カレントディレクトリを対象
yb init --repo /path/to/repo   # 別リポジトリを対象
```

**実行されること:**

1. `.yamibaito/` 配下にディレクトリ構造を作成
   - `queue/tasks/` / `queue/reports/` — タスク・レポート格納先
   - `prompts/` — 親分・若頭・若衆のプロンプト
   - `skills/` — スキル定義
2. テンプレートから設定ファイルをコピー（既存ファイルはスキップ）
   - `config.yaml`、`director_to_planner.yaml`、`dashboard.md`
3. オーケストレータからプロンプトファイルをコピー（常に最新版で上書き）
   - `oyabun.md`、`waka.md`、`wakashu.md`
4. `config.yaml` の `codex_count`（デフォルト 3）に応じてワーカーファイルを生成
   - `tasks/worker_001.yaml` 〜 `tasks/worker_XXX.yaml`
   - `reports/worker_001_report.yaml` 〜 `reports/worker_XXX_report.yaml`
   - `reports/_index.json`

**注意:** 設定ファイル（`config.yaml`、`director_to_planner.yaml`、`dashboard.md` 等）やワーカーファイルは、既に存在する場合スキップされる。ただし **プロンプトファイル（`oyabun.md`、`waka.md`、`wakashu.md`）は毎回オーケストレータの最新版で上書きされる。**

---

### `yb start`

tmux セッションを作成し、親分・若頭の Claude インスタンスを起動する。

```bash
yb start                        # カレントディレクトリを対象
yb start --repo /path/to/repo   # 別リポジトリを対象
```

**前提条件:**

- `yb init` が実行済みであること（`.yamibaito/config.yaml` が存在する必要がある）
- 同名の tmux セッションが存在しないこと

**実行されること:**

1. `yamibaito_<リポジトリ名>` という tmux セッションを作成
2. 左右 50:50 の2カラムレイアウトでペインを配置（左カラム内は oyabun 60% / waka 40% で縦分割、右カラムはワーカーを等分割）

```
┌───────────────────┬────────────────┐
│                   │  worker_001    │
│  oyabun (60%)     ├────────────────┤
│                   │  worker_002    │
├───────────────────┤────────────────┤
│                   │  worker_003    │
│  waka   (40%)     │  ...           │
└───────────────────┴────────────────┘
```

3. 各ペインに背景色・タイトルを設定
   - 親分ペイン: 暗い赤系 (`#2f1b1b`)
   - 若頭ペイン: 暗い緑系 (`#1b2f2a`)
   - 若衆ペイン: 各若衆に和名（銀次、龍、影、蓮 など）を割り当て
4. `.yamibaito/panes.json` にペインマッピングを保存
5. 全ペインの環境を初期化（`PATH` にオーケストレータの `bin` を追加、リポジトリルートへ `cd`、画面クリア）
6. 親分 → 若頭の順に `claude --dangerously-skip-permissions` を起動し、それぞれのプロンプトファイルを読み込ませる
7. tmux 外から実行した場合、自動的にセッションにアタッチ

**起動後の参加方法:**

```bash
tmux attach -t yamibaito_<repo>
```

---

### `yb restart`

既存の tmux セッションを破棄し、`yb start` と同じ手順でゼロから再構築する。

```bash
yb restart                        # カレントディレクトリを対象
yb restart --repo /path/to/repo   # 別リポジトリを対象
```

**実行されること:**

1. `yamibaito_<リポジトリ名>` セッションが存在すれば `tmux kill-session` で終了
2. `yb start` を呼び出して新しいセッションを構築

**注意:** セッション内の全プロセス（Claude インスタンス含む）が強制終了される。キュー（`.yamibaito/queue/`）やレポート等のファイルは保持される。

---

### `yb restart` を使うべきケース

| ケース | 説明 |
| --- | --- |
| **Claude がハングした** | 親分・若頭の Claude インスタンスが応答しなくなった場合。ペインが固まっているときはリスタートが手っ取り早い |
| **ペイン構成が壊れた** | 手動でペインを閉じたり分割したりして、レイアウトが崩れた場合 |
| **config.yaml を変更した** | ワーカー数（`codex_count`）を変更した後、新しい構成を反映したい場合 |
| **プロンプトを更新した** | `prompts/oyabun.md` や `prompts/waka.md` を編集した後、新しいプロンプトで起動し直したい場合 |
| **セッション内のエラーを一掃したい** | 若衆の状態がおかしくなった、キューの処理が詰まった等、クリーンな状態から再開したい場合 |
| **長時間稼働後のリフレッシュ** | Claude インスタンスのコンテキストが膨らみすぎてパフォーマンスが落ちた場合 |

**`yb restart` と `yb start` の違い:**

- `yb start` は既存セッションがあるとエラーで終了する
- `yb restart` は既存セッションがあれば自動的に破棄してから起動する

つまり「今のセッションを一旦壊してやり直したい」ときは `yb restart`、「まだセッションがない状態から新規に立ち上げる」ときは `yb start` を使う。
