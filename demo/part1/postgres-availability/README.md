# PostgreSQL Streaming Replication 段階構築手順（Docker）

講義デモ用。まずプライマリ 1 台を起動し、後からスタンバイを追加して Streaming Replication を step by step で構築する。

**Docker Compose YAML は用意していません。** 本デモは段階理解のため `docker run` と各 Phase 用シェルスクリプト（`scripts/`）で構成しています。

詳細手順は [outline/detail/20260907_JSSST_detail_part1_rdb.md](../../../outline/detail/20260907_JSSST_detail_part1_rdb.md) の「デモ > 可用性」も参照。

## 構成

| 要素 | 値 |
|------|-----|
| Docker network | `pgnet` |
| Primary コンテナ | `pg-primary`（ホスト `localhost:5432`） |
| Standby コンテナ | `pg-standby`（ホスト `localhost:5433`） |
| PostgreSQL イメージ | `postgres:18`（データ volume は `/var/lib/postgresql`。実体は `/var/lib/postgresql/18/docker`） |
| 管理ユーザ | `postgres` / `postgres` |
| レプリケーション ユーザ | `replicator` / `replicator` |
| Replication slot | `standby_slot` |

```mermaid
flowchart LR
  subgraph dockerNet [pgnet]
    Primary[pg-primary:5432]
    Standby[pg-standby:5432]
  end
  Host[Host]
  Host -->|"localhost:5432"| Primary
  Host -->|"localhost:5433"| Standby
  Primary -->|"WAL stream"| Standby
```

## 前提

- Docker が利用可能であること
- ホストから `psql` が使えること（なくても `docker exec` で代替可能）
- Windows では [WSL2 + Docker Desktop](../../WINDOWS.md) 上で実行する（PowerShell から `.sh` は実行しない）

## Phase 0: 事前準備

```bash
docker version
docker network create pgnet 2>/dev/null || true
docker volume create pg-primary-data
docker volume create pg-standby-data
```

または:

```bash
./scripts/00-preflight.sh
```

## Phase 1: シングルインスタンス（Primary）の起動

**目的**: 通常の PostgreSQL 1 台として起動し、接続確認まで行う。

```bash
docker run -d --name pg-primary --network pgnet \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -v pg-primary-data:/var/lib/postgresql \
  postgres:18
```

接続確認:

```bash
psql "postgresql://postgres:postgres@localhost:5432/postgres" -c "SELECT version();"
```

デモ用テーブル:

```sql
CREATE TABLE demo_items (
  id serial PRIMARY KEY,
  name text,
  created_at timestamptz DEFAULT now()
);
INSERT INTO demo_items (name) VALUES ('before_replication');
```

**見せること**: まずは単一 DB として動いている状態。

```bash
./scripts/01-start-primary.sh
```

## Phase 2: Primary をレプリケーション可能に設定

**目的**: WAL 送出・接続受付・認可を primary 側で有効化する。

### 2-1. postgresql.conf の変更

| パラメータ | 値 | 理由 |
|-----------|-----|------|
| `listen_addresses` | `'*'` | Docker network 内から standby が接続するため |
| `wal_level` | `replica` | 物理レプリケーションに必要 |
| `max_wal_senders` | `10` | WAL 送信プロセス用 |
| `max_replication_slots` | `10` | replication slot 利用時 |
| `hot_standby` | `on` | standby 側で Hot Standby を有効化 |

```bash
docker exec pg-primary psql -U postgres -c "
  ALTER SYSTEM SET listen_addresses TO '*';
  ALTER SYSTEM SET wal_level TO 'replica';
  ALTER SYSTEM SET max_wal_senders TO 10;
  ALTER SYSTEM SET max_replication_slots TO 10;
  ALTER SYSTEM SET hot_standby TO on;
"
docker restart pg-primary
```

### 2-2. レプリケーション ユーザ作成

```sql
CREATE USER replicator WITH REPLICATION PASSWORD 'replicator' LOGIN;
```

### 2-3. pg_hba.conf に replication 接続を許可

`pg_hba.conf` に以下を追加（Docker bridge の典型レンジ）:

```
host replication replicator 172.16.0.0/12 scram-sha-256
```

```bash
docker exec pg-primary bash -c "echo 'host replication replicator 172.16.0.0/12 scram-sha-256' >> /var/lib/postgresql/18/docker/pg_hba.conf"
docker restart pg-primary
```

### 2-4. Replication slot 作成

```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

**見せること**: primary はまだ 1 台だが、レプリケーション待ち受け状態になった。

```bash
./scripts/02-configure-primary.sh
```

## Phase 3: Standby 用データディレクトリの初期化

**目的**: primary の物理ベースバックアップで standby の複製起点を作る。

standby 用 Postgres はまだ起動しない。一時コンテナから `pg_basebackup` を実行する。

```bash
docker run --rm --network pgnet \
  -e PGPASSWORD=replicator \
  -v pg-standby-data:/var/lib/postgresql \
  --entrypoint bash \
  postgres:18 \
  -c 'pg_basebackup -h pg-primary -p 5432 -U replicator \
        -D /var/lib/postgresql/18/docker -Fp -Xs -P -R -S standby_slot
      chown -R postgres:postgres /var/lib/postgresql
      chmod 0755 /var/lib/postgresql /var/lib/postgresql/18
      chmod 0700 /var/lib/postgresql/18/docker'
```

`-R` により以下が自動設定される（PostgreSQL 12 以降）:

- `standby.signal` の作成
- `postgresql.auto.conf` への `primary_conninfo` 書き込み

**見せること**: standby のデータディレクトリは primary の物理コピー + 追従設定が入った状態。

```bash
./scripts/03-init-standby.sh
```

## Phase 4: Standby インスタンスの起動

```bash
docker run -d --name pg-standby --network pgnet \
  -p 5433:5432 \
  -v pg-standby-data:/var/lib/postgresql \
  postgres:18
```

確認:

```sql
-- standby
SELECT pg_is_in_recovery();  -- true

-- primary
SELECT pid, usename, application_name, state, sync_state
FROM pg_stat_replication;

-- standby
SELECT status, written_lsn, flushed_lsn, latest_end_lsn
FROM pg_stat_wal_receiver;
```

**見せること**: WAL ストリームが張られ、standby が primary を追従開始。

```bash
./scripts/04-start-standby.sh
```

## Phase 5: 複製と Hot Standby の確認

Primary に書き込み:

```sql
INSERT INTO demo_items (name) VALUES ('after_replication');
```

Standby（`localhost:5433`）で読み取り:

```sql
SELECT * FROM demo_items ORDER BY id;
```

Standby への書き込みが拒否されることを確認:

```sql
INSERT INTO demo_items (name) VALUES ('should_fail');  -- エラー
```

（任意）レプリケーション遅延:

```sql
-- primary
SELECT pg_current_wal_lsn();
-- standby
SELECT pg_last_wal_replay_lsn();
```

**見せること**: データ反映と Hot Standby での SELECT を実演完了。

```bash
./scripts/05-verify-replication.sh
```

## Phase 6: Failover デモ

1. プライマリ停止:

```bash
docker stop pg-primary
```

2. Standby を昇格:

```sql
SELECT pg_promote();
-- または: docker exec pg-standby pg_ctl promote -D /var/lib/postgresql/18/docker
```

3. 昇格確認:

```sql
SELECT pg_is_in_recovery();  -- false
INSERT INTO demo_items (name) VALUES ('after_failover');
SELECT * FROM demo_items ORDER BY id;
```

**見せること**: プライマリ障害後も standby 昇格で書き込みを継続できる。

```bash
./scripts/06-failover.sh
```

## クリーンアップ

```bash
./scripts/cleanup.sh
```

## つまずきやすい点

1. **postgres:18 の volume**: `/var/lib/postgresql/data` に載せると起動時に `pg_ctlcluster` のエラーで Exit(1) になる。`/var/lib/postgresql` に載せる
2. **pg_basebackup 後の権限**: 公式イメージは `CMD postgres` のときだけ `gosu postgres` する。`pg_basebackup` をそのまま渡すと root で走り、親ディレクトリ `/var/lib/postgresql/18` が mode 0700 になる。standby 起動時に `mkdir: cannot create directory '/var/lib/postgresql/18': Permission denied` となるので、バックアップ後に `chown -R postgres:postgres /var/lib/postgresql` する
3. **pg_hba.conf の CIDR**: Docker network のサブネットと合わないと standby 接続不可
4. **wal_level 変更**: `replica` への変更後は restart が必要
5. **standby データ dir**: 空でないと `pg_basebackup` 先として使えない
6. **ポート**: primary `5432` / standby `5433` を明示する
7. **standby.signal**: 手動設定する場合は `primary_conninfo` も必要（`-R` 推奨）
8. **pg_stat_wal_receiver**: PostgreSQL 13 以降は `received_lsn` が無く、`written_lsn` / `flushed_lsn` を使う

## デモ時間の目安

| Phase | 内容 | 目安 |
|-------|------|------|
| 1 | Primary 起動 | 3–5 分 |
| 2 | Primary 設定 | 5–8 分 |
| 3–4 | pg_basebackup + standby 起動 | 5–10 分 |
| 5 | 動作確認 | 3–5 分 |
| 6 | Failover（任意） | 5 分 |

合計 20–30 分（説明込み）。
