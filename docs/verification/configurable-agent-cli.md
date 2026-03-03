# 動作確認手順: エージェントCLIコンフィグ対応

**PR**: #22
**ブランチ**: `yamibaito/configurable-agent-cli`

## 前提

- worktree 環境で作業中のため、`.yamibaito/config.yaml` はメインリポへの **symlink**
- symlink 先を直接書き換えると他セッションに影響するため、**一時ファイルで検証**する
- `yb start` を使う統合テストは **マージ後にメインリポで実施**する

---

## Phase A: worktree 内で完結する確認（マージ前）

### 1. ユニットテスト（必須）

```bash
python3 scripts/lib/test_agent_config.py -v
```

**期待結果**: 18件全PASS

---

### 2. CLI ラッパーで設定解決を確認（必須）

`_agent_config_cli.py` と一時 config ファイルを使い、実際の `yb start` なしで各プリセットの解決結果を検証する。

#### 2-1. 後方互換（agents: セクションなし）

```bash
# agents: なしの旧config相当を作成
cat > /tmp/test_config_legacy.yaml <<'YAML'
workers:
  codex_count: 5
codex:
  sandbox: workspace-write
  model: high
YAML

# 各ロールの解決結果を確認
for role in oyabun waka worker plan plan_review; do
  echo "--- $role ---"
  python3 scripts/lib/_agent_config_cli.py \
    --config /tmp/test_config_legacy.yaml --role "$role" --field command
  python3 scripts/lib/_agent_config_cli.py \
    --config /tmp/test_config_legacy.yaml --role "$role" --field mode
done
```

**期待結果**:

| ロール | command | mode |
|--------|---------|------|
| oyabun | `claude --dangerously-skip-permissions` | interactive |
| waka | `claude --dangerously-skip-permissions` | interactive |
| worker | `codex exec --sandbox workspace-write -` | batch_stdin |
| plan | `claude --dangerously-skip-permissions` | interactive |
| plan_review | `codex exec --sandbox workspace-write -` | batch_stdin |

#### 2-2. 部分指定フォールバック（oyabun だけ gemini）

```bash
cat > /tmp/test_config_partial.yaml <<'YAML'
workers:
  codex_count: 5
codex:
  sandbox: workspace-write
  model: high
agents:
  oyabun:
    cli: gemini
YAML

for role in oyabun waka worker plan plan_review; do
  echo "--- $role ---"
  python3 scripts/lib/_agent_config_cli.py \
    --config /tmp/test_config_partial.yaml --role "$role" --field command
done
```

**期待結果**:

| ロール | command |
|--------|---------|
| oyabun | `gemini --yolo` |
| waka | `claude --dangerously-skip-permissions`（デフォルト） |
| worker | `codex exec --sandbox workspace-write -`（デフォルト） |
| plan | `claude --dangerously-skip-permissions`（デフォルト） |
| plan_review | `codex exec --sandbox workspace-write -`（デフォルト） |

#### 2-3. Copilot プリセット

```bash
cat > /tmp/test_config_copilot.yaml <<'YAML'
workers:
  count: 5
agents:
  oyabun:
    cli: copilot
  worker:
    cli: copilot
YAML

echo "--- oyabun (interactive) ---"
python3 scripts/lib/_agent_config_cli.py \
  --config /tmp/test_config_copilot.yaml --role oyabun --field command

echo "--- worker (batch) ---"
python3 scripts/lib/_agent_config_cli.py \
  --config /tmp/test_config_copilot.yaml --role worker --field command
```

**期待結果**:
- oyabun → `copilot --autopilot`
- worker → `copilot`

#### 2-4. 全プリセット一括確認

```bash
for cli in claude gemini codex copilot; do
  cat > /tmp/test_config_${cli}.yaml <<YAML
agents:
  oyabun:
    cli: ${cli}
  worker:
    cli: ${cli}
YAML
  echo "=== ${cli} ==="
  echo "  oyabun:  $(python3 scripts/lib/_agent_config_cli.py --config /tmp/test_config_${cli}.yaml --role oyabun --field command)"
  echo "  worker:  $(python3 scripts/lib/_agent_config_cli.py --config /tmp/test_config_${cli}.yaml --role worker --field command)"
done
```

**期待結果**:

| プリセット | oyabun (interactive) | worker (batch) |
|-----------|---------------------|----------------|
| claude | `claude --dangerously-skip-permissions` | `claude --dangerously-skip-permissions` |
| gemini | `gemini --yolo` | `gemini` |
| codex | `codex exec --sandbox workspace-write -` | `codex exec --sandbox workspace-write -` |
| copilot | `copilot --autopilot` | `copilot` |

---

### 3. worker_count 解決の確認（推奨）

```bash
# workers.count 優先
cat > /tmp/test_wc1.yaml <<'YAML'
workers:
  count: 7
  codex_count: 5
YAML
python3 scripts/lib/_agent_config_cli.py --config /tmp/test_wc1.yaml --role worker --field worker_count
# → 7

# codex_count フォールバック
cat > /tmp/test_wc2.yaml <<'YAML'
workers:
  codex_count: 5
YAML
python3 scripts/lib/_agent_config_cli.py --config /tmp/test_wc2.yaml --role worker --field worker_count
# → 5
```

---

### 4. CLIバイナリ名の抽出確認（推奨）

```bash
for cli in claude gemini codex copilot; do
  cat > /tmp/test_bin_${cli}.yaml <<YAML
agents:
  oyabun:
    cli: ${cli}
YAML
  echo "${cli}: $(python3 scripts/lib/_agent_config_cli.py --config /tmp/test_bin_${cli}.yaml --role oyabun --field cli_binary)"
done
```

**期待結果**: `claude`, `gemini`, `codex`, `copilot` がそれぞれ返る（`command -v` チェック用のバイナリ名）。

---

### 5. シェルラッパーの確認（推奨）

```bash
source scripts/lib/agent_config_shell.sh

agent_get_command /tmp/test_config_partial.yaml oyabun
# → gemini --yolo

agent_get_command /tmp/test_config_partial.yaml waka
# → claude --dangerously-skip-permissions

agent_get_worker_count /tmp/test_wc1.yaml
# → 7

agent_get_cli_binary /tmp/test_config_partial.yaml oyabun
# → gemini
```

---

## Phase B: マージ後の統合テスト（メインリポで実施）

マージ後、メインリポで `yb start` を使った実動確認を行う。

### 6. 後方互換（yb start）

```bash
# agents: セクションなしの config で起動
yb start --session test-compat
# → oyabun/waka/plan が claude、worker が codex で起動することを確認
yb stop --session test-compat
```

### 7. CLI切替（yb start）

```bash
# config.yaml を一時変更して起動
# agents.oyabun.cli: gemini に変更 → oyabun ペインで gemini --yolo が起動
yb start --session test-gemini
yb stop --session test-gemini
```

### 8. CLIバイナリ事前チェック（yb start）

```bash
# 未インストールのCLIを指定 → yb start がエラーで停止
# agents.oyabun.cli: gemini（未インストール環境で）
yb start --session test-check
# → ERROR メッセージ + exit 1
```

### 9. Worker stdin パイプ（yb run-worker）

```bash
# セッション起動済みの状態で
yb run-worker --worker worker_001 --session <session-id>
# → agent_config 経由でCLI構築 → stdin パイプ実行 → waka 通知
```

---

## 確認優先度まとめ

| 優先度 | 手順 | 実施環境 | 所要時間 |
|--------|------|----------|----------|
| **必須** | 1. ユニットテスト | worktree | 1分 |
| **必須** | 2. CLI ラッパーで設定解決 | worktree | 3分 |
| **推奨** | 3. worker_count 解決 | worktree | 1分 |
| **推奨** | 4. CLIバイナリ名抽出 | worktree | 1分 |
| **推奨** | 5. シェルラッパー | worktree | 1分 |
| **推奨** | 6-9. 統合テスト | メインリポ（マージ後） | 15分 |
