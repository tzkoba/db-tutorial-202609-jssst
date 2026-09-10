# デモ

講義用の段階実行スクリプトです。実行は **bash + Docker** 前提です。

Windows では PowerShell から `.sh` を直接実行せず、[WSL2 + Docker Desktop](WINDOWS.md) を使います。セットアップと確認コマンドは同ファイルにあります。

※2026/9/9時点で、WSL2＋Docker Desktop環境で動作確認済み

| Part | デモ |
|------|------|
| 1 | [PostgreSQL 可用性](part1/postgres-availability/README.md) |
| 1 | [PostgreSQL 信頼性](part1/postgres-reliability/README.md) |
| 2 | [jsonb vs MongoDB](part2/json-postgres-vs-mongo/README.md) |
| 2 | [MongoDB 可用性・一貫性](part2/mongo-availability-consistency/README.md) |
| 3 | [YugabyteDB 可用性・信頼性](part3/yugabyte-availability-reliability/README.md) |
