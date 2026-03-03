# 実装計画: エージェントCLIのコンフィグ対応 (v4)

## Context

現在、yamibaito オーケストレーターの各ロール（oyabun, waka, worker, plan）で使用するCLIツールがスクリプト内にハードコードされている:
- oyabun/waka/plan: `claude --dangerously-skip-permissions`
- worker/plan_review: `codex exec --sandbox ... -`

これを `config.yaml` で指定可能にし、Claude Code・Gemini CLI・Codex を切り替えられるようにする。将来的にはカスタムCLIにも対応できる設計とする。

## 設計方針

### Worker の実行モデル

全CLIの worker/plan_review を **stdin パイプ** で統一する。

| CLI | batch コマンド | stdin パイプの形 |
|-----|---------------|-----------------|
| Codex | `codex exec --sandbox {sandbox} -` | `proc.communicate(content)`（現行通り） |
| Claude Code | `claude --dangerously-skip-permissions` | `proc.communicate(content)` |
| Gemini CLI | `gemini` | `proc.communicate(content)` |

全CLIで `subprocess.Popen(cmd_list, stdin=subprocess.PIPE)` → `proc.communicate(content)` の統一パターンを使う。
`-p` フラグやシェル引数渡しは一切使わない。

**理由（ISSUE-05/05-R1 対応）**: タスクYAMLは長文・改行・特殊文字を含むため、シェル引数に直接渡すとクォート破壊リスクがある。stdin パイプなら全CLIで安全に渡せる。

これにより `yb_run_worker.sh` → waka通知の既存フローがそのまま維持される。
`dispatch.sh` に分岐は不要。

### config.yaml の新スキーマ

```yaml
# デフォルト値（現構成をそのまま再現）
agents:
  oyabun:
    cli: claude          # claude | gemini | codex | custom
  waka:
    cli: claude
  worker:
    cli: codex
    sandbox: workspace-write
    approval: on-request
    model: high
    web_search: false
  plan:
    cli: claude
  plan_review:
    cli: codex
```

**ISSUE-06 対応**: `options` 階層を廃止し、worker固有設定はロール直下にフラット配置。
パーサーは2階層対応のままで済む（`agents.worker.sandbox` 等）。

```yaml
# フルカスタマイズ時
agents:
  oyabun:
    cli: custom
    command: "my-cli --auto"
    mode: interactive              # interactive | batch_stdin
    initial_message: 'Please read file: "{prompt_path}" and follow it. You are the {role}.'
```

### 組み込みプリセット

| プリセット | interactive command | batch command (stdin) | mode |
|-----------|-------------------|----------------------|------|
| `claude` | `claude --dangerously-skip-permissions` | `claude --dangerously-skip-permissions` | `interactive` |
| `gemini` | `gemini --yolo` | `gemini` | `interactive` |
| `codex` | `codex --dangerously-bypass-approvals-and-sandbox` | `codex exec --sandbox {sandbox} -` | `batch_stdin` |
| `copilot` | `copilot --autopilot` | `copilot` | `interactive` |

- oyabun/waka/plan はプリセットの `interactive` コマンドを使用（tmux send-keys で起動）
- worker/plan_review はプリセットの `batch` コマンドを使用（全て stdin パイプ: `subprocess.Popen(cmd_list, stdin=PIPE)`）
- ロールごとにどちらを使うかは `agent_config.py` が自動判定
- initial_message（interactive 用）: `Please read file: "{prompt_path}" and follow it. You are the {role}.`

### 後方互換性

- `agents:` セクションが存在しない場合 → 現在と100%同一動作（claude + codex）
- **`agents:` セクション内で一部ロールのみ指定された場合** → 未指定ロールはレガシーデフォルトを使用（ISSUE-07 対応）:
  - oyabun, waka, plan → `claude`
  - worker, plan_review → `codex`
- `workers.codex_count` → `workers.count` の新キーを優先、旧キーもフォールバックで読む
- `codex:` トップレベルセクション → `agents.worker` の sandbox/model 等が未指定の場合のフォールバック

### CLIバイナリ事前チェック（Q4 対応）

`yb start` の冒頭で、config の `agents:` に指定されたCLIバイナリが存在するか `command -v` で確認。
未インストールの場合はエラーメッセージを出して起動中止。

```bash
# 例: agents.oyabun.cli=gemini の場合
if ! command -v gemini &>/dev/null; then
  echo "ERROR: gemini が見つかりません。agents.oyabun.cli で指定されたCLIをインストールしてください。" >&2
  exit 1
fi
```

### 軽量YAMLパーサー仕様（ISSUE-04 対応）

`agent_config.py` 内の軽量パーサーがサポートする構文:

- **対応**: `key: value`（スカラー値）、2階層ネスト（インデントベース）、ダブル/シングルクオート除去、`# comment` のインラインコメント除去、`true`/`false` の bool 変換
- **非対応**: YAML アンカー/エイリアス、フロースタイル `{}`/`[]`、複数行値 `|`/`>`、マージキー `<<`
- 非対応構文が検出された場合は警告をstderrに出力し、そのキーをスキップ

ISSUE-06 対応により config スキーマが最大2階層に収まるため、このパーサーで全設定を読み取れる。

---

## 変更ファイル一覧

### Phase 1: コア抽象レイヤー（新規ファイル3つ + テスト1つ）

#### 1-1. `scripts/lib/agent_config.py`（新規）
エージェント設定の解決ロジック。PyYAML不使用（環境にない）、既存の行ベース解析パターンに合わせる。

主要関数:
- `load_agent_config(config_path, role)` → `dict` (command, mode, initial_message, sandbox 等)
- `get_worker_count(config_path)` → `int` (workers.count → workers.codex_count → 3)
- `build_launch_command(agent_cfg, **kwargs)` → `list[str]` (テンプレート変数を展開。`shlex.split()` でリスト化)
- `build_initial_message(agent_cfg, **kwargs)` → `str`
- `get_cli_binary(agent_cfg)` → `str` (コマンドの先頭トークン。バイナリチェック用)

**ISSUE-08 対応**: `build_launch_command()` は `list[str]` を返す。
呼び出し側は `subprocess.Popen(cmd_list, shell=False, stdin=subprocess.PIPE, ...)` で実行する。
`shell=True` は使わない（コマンドインジェクション防止）。
内部では `shlex.split()` でコマンド文字列をトークン分割する。

config.yaml の `agents:` セクションをインデントベースで解析する軽量パーサーを実装。
対応構文: スカラー値、2階層ネスト、クオート除去、インラインコメント除去、bool変換。

フォールバック解決順序:
1. `agents.<role>` の明示指定
2. `CLI_PRESETS[agents.<role>.cli]` のプリセットデフォルト
3. レガシーデフォルト（oyabun/waka/plan=claude、worker/plan_review=codex）
4. worker の sandbox/model 等 → `codex:` トップレベルセクションからフォールバック

#### 1-2. `scripts/lib/_agent_config_cli.py`（新規）
シェルスクリプトから呼べるCLIラッパー。argparse で `--config`, `--role`, `--field`, `--prompt-path`, `--role-label`, `--sandbox`, `--output-path` を受け取り、結果を stdout に出力。

#### 1-3. `scripts/lib/agent_config_shell.sh`（新規）
シェル関数ラッパー。Pythonモジュールを呼び出す薄いラッパー関数群:
- `agent_get_command(config_path, role)`
- `agent_get_mode(config_path, role)`
- `agent_get_initial_message(config_path, role, prompt_path, role_label)`
- `agent_get_worker_count(config_path)`
- `agent_get_cli_binary(config_path, role)` — バイナリ名のみ返す（チェック用）

#### 1-4. `scripts/lib/test_agent_config.py`（新規）
ユニットテスト:
- プリセット解決テスト（claude, gemini, codex）
- agents未指定時のレガシーフォールバックテスト
- **部分指定テスト**: oyabunだけ gemini にして、未指定の waka/worker/plan/plan_review が各デフォルト（claude/codex）になるか確認
- worker_count の新旧キー対応テスト（workers.count 優先、codex_count フォールバック）
- テンプレート変数展開テスト（`{prompt_path}`, `{role}`, `{sandbox}`）
- カスタムCLI設定テスト（`cli: custom` + `command:` 指定）
- `get_cli_binary` テスト（コマンド文字列から先頭バイナリ名を抽出）
- codex フォールバック（agents.worker 未指定 → `codex:` セクションから sandbox/model 取得）
- 軽量パーサーのエッジケース（クオート、インラインコメント、空値、不正インデント）
- **stdin パイプコマンド生成テスト**: 各プリセットの batch コマンドが stdin 対応であること

---

### Phase 2: シェルスクリプトの接続（既存ファイル修正）

#### 2-1. `scripts/yb_start.sh`
- **L5付近**: `source "$ORCH_ROOT/scripts/lib/agent_config_shell.sh"` 追加
- **L51**: `grep "codex_count:"` → `agent_get_worker_count "$config_file"` に置換
- **L345-347**: ハードコード `claude --dangerously-skip-permissions` → `agent_get_command` で動的取得
- **L350-352**: ハードコードの初期メッセージ → `agent_get_initial_message` で動的取得、`mode == interactive` の場合のみ送信
- **CLIバイナリ事前チェック追加**: config読み取り直後に、oyabun/waka/worker の各CLIバイナリを `command -v` で確認。未インストール時はエラー終了。

#### 2-2. `scripts/yb_init_repo.sh`
- **L23付近**: `source "$ORCH_ROOT/scripts/lib/agent_config_shell.sh"` 追加
- **L105**: `grep "codex_count:"` → `agent_get_worker_count "$config_dir/config.yaml"` に置換

#### 2-3. `scripts/yb_plan.sh`
- **L5付近**: `source "$ORCH_ROOT/scripts/lib/agent_config_shell.sh"` 追加
- **L82**: コメント `# Split a small bottom pane for Codex.` → `# Split a small bottom pane for review CLI.`
- **L85**: ペインタイトル `"codex"` → config の plan_review CLI名に動的化
- **L88**: panes.json の `"codex"` キー → `"review"` にリネーム
- **L93**: `claude --dangerously-skip-permissions` → `agent_get_command "$config_file" "plan"` で動的取得
- **L94**: `yb plan-review` のエコーメッセージは変更なし（CLI非依存）
- **L96**: 初期メッセージを `agent_get_initial_message` で動的取得
- **L98**: `review_prompt.md is for Codex review` → `review_prompt.md is for LLM review` に修正

#### 2-4. `scripts/yb_plan_review.sh`
- config_file の読み込みを追加（`$repo_root/.yamibaito/config.yaml`）
- **L82**: コメント `# Write static validation result first (always preserved even if Codex fails)` → `# ...even if LLM review fails`
- **L94**: `(Codex による LLM レビュー実行中...)` → `(LLM レビュー実行中...)`
- **L103,110**: panes.json の `"codex"` キー参照 → `"review"` に合わせる
- **L147-149**: `codex exec` → config から動的取得。全て stdin パイプ方式（`cat prompt | cli-command`）
- **L152**: エコーメッセージ `Codex ペイン` → `レビューペイン`

#### 2-5. `scripts/yb_dispatch.sh`
- 変更なし。worker は全て batch（stdin パイプ）なので分岐不要。

#### 2-6. `scripts/yb_run_worker.sh`
- **L75内のPython**: `agent_config` をimport
- **L104**: `codex exec --sandbox ... -` → `load_agent_config` + `build_launch_command` で動的構築
- `build_launch_command()` は `list[str]` を返すため、`subprocess.Popen(cmd_list, shell=False, stdin=subprocess.PIPE, ...)` → `proc.communicate(content)` で実行。`shell=True` は使わない。

#### 2-7. `scripts/yb_collect.sh`
- **L855**: `codex_count:` の行パース → `agent_config.get_worker_count()` を呼び出し
- **L1390-1395**: IDLE_TASK_TEMPLATE内の `codex:` ブロック → そのまま残す（後方互換）

---

### Phase 3: Config・テンプレート更新

#### 3-1. `templates/config.yaml`
- `agents:` セクション追加（現構成をデフォルト実値として配置）
- `workers.count: 5` 追加（`codex_count` と並存、count を優先）
- `codex.model: high` に変更

#### 3-2. `.yamibaito/config.yaml`（実稼働config）
- 同上の変更

#### 3-3. `templates/queue/tasks/worker_task.yaml`
- `codex:` ブロックはそのまま残す（後方互換）
- `codex.model: high` に変更

---

### Phase 4: プロンプト更新（CLI名の汎用化）

#### 4-1. `.yamibaito/prompts/waka.md` (+ `prompts/waka.md`)
- L273: `若衆の codex は` → `若衆の worker CLI は` に変更

#### 4-2. `.yamibaito/prompts/wakashu.md` (+ `prompts/wakashu.md`)
- L381: `codex の cwd は` → `worker CLI の cwd は` に変更

#### 4-3. `.yamibaito/prompts/plan.md` (+ `prompts/plan.md`)
- L28: `"Codexレビュー指摘を無視"` → `"LLMレビュー指摘を無視"` に変更
- L121: `静的検査 + Codex レビュー` → `静的検査 + LLM レビュー` に変更

---

## 実装順序

```
Phase 1: コア抽象レイヤー
  1-1 → 1-2 → 1-3 → 1-4（テスト）
  ※ この時点で既存動作に一切影響なし

Phase 2: シェルスクリプト接続
  2-2 (init) → 2-1 (start) → 2-3 (plan) → 2-4 (plan-review) → 2-6 (run-worker) → 2-7 (collect)
  ※ 2-5 (dispatch) は変更不要
  ※ 各ステップで agents: 未指定時は旧動作を維持

Phase 3: Config・テンプレート
  3-1 → 3-2 → 3-3

Phase 4: プロンプト更新
  4-1 → 4-2 → 4-3
```

## 検証方法

### ユニットテスト（`python3 scripts/lib/test_agent_config.py`）
1. プリセット解決: claude/gemini/codex の各プリセットが正しいコマンドを返す
2. レガシーフォールバック: agents セクション未指定時に claude + codex のデフォルト値
3. **部分指定フォールバック**: oyabun だけ gemini にして、waka=claude / worker=codex / plan=claude / plan_review=codex が維持される
4. worker_count 優先: `workers.count` が `workers.codex_count` より優先される
5. codex フォールバック: `agents.worker` の sandbox 未指定時に `codex:` セクションから取得
6. テンプレート展開: `{prompt_path}`, `{role}`, `{sandbox}` の置換
7. カスタムCLI: `cli: custom` + `command:` 指定時の動作
8. `get_cli_binary`: コマンド文字列から先頭バイナリ名を抽出
9. 軽量パーサー: クオート除去、インラインコメント、空値、不正インデント
10. stdin パイプコマンド: 各プリセットの batch コマンドが stdin 対応であること

### 統合テスト（手動）
1. **後方互換**: `agents:` なしの既存config → `yb start` で claude + codex 起動を確認
2. **Gemini切替**: `agents.oyabun.cli: gemini` → oyabunペインで `gemini --yolo` 起動を確認
3. **部分指定**: oyabun だけ gemini にして、waka/worker/plan/plan_review が既定値（claude/codex）で動くことを確認
4. **mixed構成**: oyabun=gemini, waka=claude, worker=codex → 全フロー動作確認
5. **CLIバイナリチェック**: 存在しないCLI名を指定 → `yb start` がエラーで停止
6. **plan_review CLI切替**: `agents.plan_review.cli: claude` → stdin パイプでレビュー実行
7. **worker CLI切替**: `agents.worker.cli: claude` → stdin パイプでタスク実行、waka通知が正常
8. **codex.model: high 確認**: テンプレートから生成されるタスクYAMLの model 値が high
9. **codex フォールバック実動**: agents.worker の sandbox 未指定 + codex: セクションに sandbox 指定 → 正しく読み取れる

## 変更履歴

- **v1**: 初版
- **v2**: ISSUE-01〜04 対応（バッチモード統一、変更漏れ追記、テスト拡充、パーサー仕様明記）
- **v3**: ISSUE-05〜07 対応（stdin パイプ統一、options 階層廃止しフラット化、部分指定時フォールバック明文化）
- **v4**: ISSUE-05-R1/08/09 対応（batch コマンドの自己矛盾解消、`build_launch_command()` を `list[str]` 型に変更し `shell=False` 明記、plan/plan_review の部分指定テスト追加）
