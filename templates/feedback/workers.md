# Workers Feedback

このファイルは、若衆由来の改善知見を若頭が集約して蓄積するための台帳です。
worker report の `feedback` から再利用価値のある内容を追記します。

> append-only: 既存エントリの削除・改変禁止。

## 追記テンプレート
推奨ID形式: `### WKR-<worker_number>-YYYYMMDDHHMMSS`

```markdown
### <ID>
- **datetime**: YYYY-MM-DDTHH:MM:SS
- **role**: worker | waka
- **target**: cmd_XXXX
- **issue**: 何が問題だったか
- **root_cause**: 根本原因
- **action**: 取った/取るべきアクション
- **expected_metric**: 期待される改善指標
- **evidence**: 根拠となるファイルパスやログ
```

---
## 運用ルール
- このファイルが未作成の場合、初回追記時に本雛形を自動生成する
- append-only: 既存エントリの削除・改変は禁止
- 追記は必ず `cat <<'EOF'` でシェル展開を無効化して行う
- 追記直後に `tail` とフォーマット検証を実施する
