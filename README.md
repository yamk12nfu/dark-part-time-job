# Yamibaito Orchestrator

中央オーケストレータ（親分→若頭→若衆）を、各リポジトリから起動できるようにするための仕組み。

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

## サブコマンド

- `yb init` : 初期ファイル生成
- `yb start` : tmuxセッション生成 + 親分/若頭起動
- `yb dispatch` : 若衆へ割当済みタスクを起動（手動用）
- `yb collect` : `dashboard.md` を再生成
