# 動作確認手順: エージェントCLIコンフィグ対応

**PR**: #22
**ブランチ**: `yamibaito/configurable-agent-cli`

---

## 1. ユニットテスト（必須）

```bash
python3 scripts/lib/test_agent_config.py -v
```

**期待結果**: 18件全PASS

```
Ran 18 tests in 0.005s

OK
```

---

## 2. 後方互換テスト（必須）

`agents:` セクションなしの既存 config で現行と同一動作することを確認。

```bash
# バックアップ
cp .yamibaito/config.yaml .yamibaito/config.yaml.bak

# agents: セクションを除去（旧config相当にする）
grep -v -A 100 '^agents:' .yamibaito/config.yaml > /tmp/config_noagents.yaml
cp /tmp/config_noagents.yaml .yamibaito/config.yaml

# 起動
yb start --session test-compat
```

**期待結果**:
- oyabun / waka / plan ペイン → `claude --dangerously-skip-permissions` で起動
- worker / plan_review → `codex exec --sandbox workspace-write -` で実行

```bash
# 確認後に復元・停止
cp .yamibaito/config.yaml.bak .yamibaito/config.yaml
yb stop --session test-compat
```

---

## 3. 部分指定フォールバック（推奨）

oyabun だけ変更し、他ロールがデフォルト維持されることを確認。

```yaml
# .yamibaito/config.yaml に追記
agents:
  oyabun:
    cli: gemini
```

```bash
yb start --session test-partial
```

**期待結果**:

| ロール | 期待されるCLI |
|--------|-------------|
| oyabun | `gemini --yolo` |
| waka | `claude --dangerously-skip-permissions`（デフォルト） |
| worker | `codex exec --sandbox workspace-write -`（デフォルト） |
| plan | `claude --dangerously-skip-permissions`（デフォルト） |
| plan_review | `codex exec ...`（デフォルト） |

```bash
yb stop --session test-partial
```

---

## 4. Copilot CLI 切替テスト（任意 / copilot インストール済みの場合）

```yaml
agents:
  oyabun:
    cli: copilot
  worker:
    cli: copilot
```

```bash
yb start --session test-copilot
```

**期待結果**:
- oyabun ペイン → `copilot --autopilot` で起動
- worker タスク実行時 → `copilot` を stdin パイプで使用

```bash
yb stop --session test-copilot
```

---

## 5. CLIバイナリ事前チェック（推奨）

存在しないCLIを指定し、起動時にエラーで停止することを確認。

```yaml
agents:
  oyabun:
    cli: gemini   # gemini 未インストールの環境で実施
```

```bash
yb start --session test-check
```

**期待結果**:

```
ERROR: gemini が見つかりません。agents.oyabun.cli で指定されたCLIをインストールしてください。
```

起動中止（exit 1）。

---

## 6. Worker stdin パイプ動作確認（推奨）

既存セッションでタスクを1つ実行し、agent_config 経由のCLI構築 → stdin パイプ → waka 通知の一連フローを確認。

```bash
# セッション起動済みの状態で
yb run-worker --worker worker_001 --session <session-id>
```

**期待結果**:
- `agent_config.load_agent_config()` でCLI設定を解決
- `build_launch_command()` で `list[str]` を生成
- `subprocess.Popen(cmd, shell=False, stdin=PIPE)` で実行
- 完了後、waka ペインに通知が届く

---

## 確認優先度

| 優先度 | 手順 | 所要時間 |
|--------|------|----------|
| **必須** | 1. ユニットテスト | 1分 |
| **必須** | 2. 後方互換テスト | 5分 |
| **推奨** | 3. 部分指定フォールバック | 5分 |
| **推奨** | 5. バイナリ事前チェック | 2分 |
| **推奨** | 6. Worker stdin パイプ | 5分 |
| **任意** | 4. Copilot CLI 切替 | 5分 |
