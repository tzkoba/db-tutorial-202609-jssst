# デモ: MongoDB の可用性・一貫性

PostgreSQL の同期レプリカ 1 台停止（`postgres-availability` Phase 4）と対比する。
MongoDB は **PRIMARY + SECONDARY × 2** の 3 ノード replica set なので、多数派 2 台が残れば書き込みを継続できる。

このデモは **レプリカセットのフェイルオーバー** と、**write concern / read concern の組み合わせで見え方が変わること** を見せる。

## 所要時間の目安

| 項目 | 目安 |
| --- | --- |
| 初回イメージ取得 | 1〜3 分（回線次第） |
| Phase 1〜2（起動〜replica set） | 1〜2 分 |
| Phase 3（majority 書き込み） | 1 分弱 |
| Phase 3.5（ネットワーク分断） | 1〜2 分 |
| Phase 4（`w: 1` + `local`） | 1〜2 分 |
| Phase 5（`w: majority` + `majority`） | 1〜2 分 |
| 合計（イメージ取得除く） | **約 8〜12 分** |

## 事前条件

- Docker が動いていること（`docker info` が成功すること）
- このディレクトリで作業すること

```bash
cd demo/part2/mongo-availability-consistency
```

ホスト側の待受は `27021` / `27022` / `27023`。コンテナ名は `mongo1` / `mongo2` / `mongo3`。
replica set 名は `rs0`。

## 構成

```text
ホスト
  :27021 ── mongo1  (PRIMARY または SECONDARY)
  :27022 ── mongo2
  :27023 ── mongo3
        └── replica set rs0
```

## 見せたいこと

- replica set は PRIMARY が 1 台、SECONDARY が残り
- `w: majority` は多数派への複製完了を待ってから成功を返す
- ネットワーク分断で少数派側の PRIMARY は書き込みを止め、再接続後に多数派へ戻る
- PRIMARY を突然落とすと、残った 2 台が新しい PRIMARY を選ぶ
- `w: 1` + `local` は PRIMARY 単独確認なので、落とした瞬間の未複製分が消えることがある
- `w: majority` + `majority` は「成功した書き込み」が残りノードで読める

## 講義での見せ方

各 Phase は **目的 → 実際のコマンド（SQL / docker / JS）→ 見せること → 実行スクリプト** の順。
講義では下のコマンドブロックを見せ、スクリプトはそのコマンドを順番に流す。

クライアントはホストから `docker exec … mongosh` で各コンテナに入る。
接続先は `mongodb://127.0.0.1:27017/?directConnection=true`（コンテナ内の mongod）。
PRIMARY の判定や `insertOne` の再試行はスクリプト内のヘルパーが行う。講義では代表コマンドだけ見せる。

---

## Phase 1: 3 ノード起動

**目的**: replica set 用の mongod を 3 台立て、ホストから各ポートで触れるようにする。

```bash
docker run -d --name mongo1 -p 27021:27017 --hostname mongo1 \
  mongo:7 mongod --replSet rs0 --bind_ip_all

docker run -d --name mongo2 -p 27022:27017 --hostname mongo2 \
  mongo:7 mongod --replSet rs0 --bind_ip_all

docker run -d --name mongo3 -p 27023:27017 --hostname mongo3 \
  mongo:7 mongod --replSet rs0 --bind_ip_all
```

**見せること**: `mongo1` / `mongo2` / `mongo3` が running。この時点ではまだ replica set 未初期化。

```bash
./scripts/01-start-nodes.sh
```

---

## Phase 2: replica set 初期化

**目的**: 3 台を `rs0` として組む。PRIMARY が 1 台選ばれる。

```javascript
rs.initiate({
  _id: 'rs0',
  members: [
    { _id: 0, host: 'mongo1:27017' },
    { _id: 1, host: 'mongo2:27017' },
    { _id: 2, host: 'mongo3:27017' }
  ]
})
rs.status()
```

**見せること**: `rs.status()` で PRIMARY 1 + SECONDARY 2。`health: 1`。

```bash
./scripts/02-init-replicaset.sh
```

---

## Phase 3: majority 書き込み

**目的**: 定常時の書き込みが `w: majority` で成功することを確認する。

```javascript
db.getSiblingDB('demo').orders.insertOne(
  { tag: 'phase3-majority', at: new Date() },
  { writeConcern: { w: 'majority', wtimeout: 10000 } }
)
```

**見せること**: `acknowledged: true` と `_id`。3 台とも生きているので多数派書き込みが通る。

```bash
./scripts/03-baseline.sh
```

---

## Phase 3.5: ネットワーク分断（少数派 PRIMARY）

**目的**: PRIMARY をネットワークから切り離すと、残った 2 台が新 PRIMARY を選び、切り離された旧 PRIMARY は書き込みを拒否する。再接続後は旧 PRIMARY が SECONDARY に戻る。

```bash
# PRIMARY を Docker ネットワークから切り離す
docker network disconnect <network> <primary>

# 残った 2 台（多数派）へ
db.getSiblingDB('demo').orders.insertOne(
  { tag: 'phase35-majority', at: new Date() },
  { writeConcern: { w: 'majority', wtimeout: 15000 } }
)

# 切り離された旧 PRIMARY へ（失敗する）
db.getSiblingDB('demo').orders.insertOne(
  { tag: 'phase35-isolated', at: new Date() },
  { writeConcern: { w: 1, wtimeout: 8000 } }
)

# 再接続
docker network connect <network> <primary>
```

**見せること**:

- 残った 2 台: 新 PRIMARY が選ばれ、`w: majority` が成功
- 旧 PRIMARY: `NotWritablePrimary` / `NotPrimaryNoSecondaryOk` で失敗
- 再接続後: 旧 PRIMARY は SECONDARY に戻り、多数派側の書き込みが見える

PostgreSQL の同期レプリカ切断（`postgres-availability` Phase 3.5）と対比する。
Postgres は同期スタンバイが消えるとプライマリのコミットが止まる。MongoDB は多数派が残れば書き込みを継続し、少数派側だけが止まる。

```bash
./scripts/03b-partition-demo.sh
```

---

## Phase 4: `w: 1` + `readConcern: local`

**目的**: PRIMARY 単独確認の書き込みは、PRIMARY を突然落とすと未複製分が消えることがある、を見せる。

クライアントはホストから各コンテナへ `mongosh` する（コンテナ同士の名前解決に依存しない）。
PRIMARY 判定と `insertOne` の再試行はスクリプト側。講義では代表コマンドだけ見せる。

```javascript
db.getSiblingDB('demo').orders.insertOne(
  { tag: 'phase4-w1', at: new Date() },
  { writeConcern: { w: 1, wtimeout: 5000 } }
)
```

```bash
docker kill -s KILL <primary>
```

```javascript
db.getSiblingDB('demo').orders.countDocuments(
  { _id: ObjectId('…') },
  { readConcern: { level: 'local' } }
)
```

**見せること**:

| 集計 | 意味 |
| --- | --- |
| ACKED | `w: 1` で成功した件数 |
| FOUND | 残ったノードの `local` 読みで見えた件数 |
| MISSING | `ACKED - FOUND`（未複製のまま消えた分） |

- 残った 2 台が新 PRIMARY を選ぶ（可用性）
- `MISSING > 0` になり得る（一貫性を緩めた代償）
- `ACKED = FOUND + MISSING`（漏れなく分類できていること）

`w: 1` は PRIMARY のメモリ反映だけで成功を返す。SECONDARY へ届く前に PRIMARY を `KILL` すると、その分は新しい PRIMARY 側に無い。

```bash
./scripts/04-w1-loss-demo.sh
```

スクリプトは起動時に `docker start mongo1 mongo2 mongo3` で 3 台を起こしてから書き込む。
Phase 3.5 や前回の Phase 4/5 のあとでも、止められたノードを起こしてから測れる。

---

## Phase 5: `w: majority` + `readConcern: majority`

**目的**: 多数派に複製されてから成功した書き込みは、PRIMARY を落としても残る、を見せる。

```javascript
db.getSiblingDB('demo').orders.insertOne(
  { tag: 'phase5-majority', at: new Date() },
  { writeConcern: { w: 'majority', wtimeout: 10000 } }
)
```

```bash
docker kill -s KILL <primary>
```

```javascript
db.getSiblingDB('demo').orders.countDocuments(
  { _id: ObjectId('…') },
  { readConcern: { level: 'majority' } }
)
```

**見せること**:

| 集計 | 意味 |
| --- | --- |
| ACKED | `w: majority` で成功した件数 |
| FOUND | 残ったノードの `majority` 読みで見えた件数 |
| MISSING | `ACKED - FOUND`（0 でも 1 以上でもあり得る。下の説明） |

- `ACKED = FOUND + MISSING`
- **MISSING = 0 のとき**: 残ノードの majority スナップショットが追いついている。`w: majority` で成功した行が、majority 読みでも見える（このデモの主メッセージ）。
- **MISSING ≥ 1 のとき**: acked な行が消えた、ではない。PRIMARY 停止直後は、残ノードの `readConcern: majority` が見る確定スナップショットがまだ古いことがある。local にはあっても majority 読みでは未検出。書き込み自体は majority 確定済み。読みの断面が後追いになる（見かけ上 eventual）。Phase 4 の Missing（複製前に PRIMARY が落ちた本物の欠落）とは意味が違う。スクリプトは同じ ACKED 集合を **10 秒後にもう一度だけ** majority 読みする。2 回目で 0 になればスナップショットが追いついた印。残ってもその回は仕方なし（Phase 5 全体のやり直しはしない）。

`w: majority` は多数派（PRIMARY + SECONDARY のうち 2 台）への複製完了を待ってから成功を返す。
その後に PRIMARY を落としても、残った SECONDARY 側にデータがある。

読み取り側の走査は、残ったノードの `majority` 読みをユニオンして数える。
新しい PRIMARY の選出を待たず、「残ったノードのどこかで committed として見えるか」を測る。
（新しい PRIMARY 1 台だけを読むと、選出直後に majority 読みが追いつかず、誤って Missing に見えることがある。）

```bash
./scripts/05-majority-contrast.sh
```

Phase 4 と同様、起動時に 3 台を `docker start` してから書き込む。

---

## 後始末

```bash
./scripts/cleanup.sh
```

`mongo1` / `mongo2` / `mongo3` を stop / rm する。ボリュームは使っていないので、コンテナ削除でデータも消える。

## つまずきやすいところ

- **PRIMARY がすぐ決まらない**: Phase 2 のあとに数秒待つ。`rs.status()` で `stateStr` を見る。
- **ホスト名 `mongo1` が解決できない**: replica set の member はコンテナホスト名。クライアントは `docker exec` で各コンテナに入る。
- **Phase 4 で Missing が 0**: `w: 1` でも複製が間に合うことがある。そのときは「運が良かった」と説明し、再実行するか件数を増やす。
- **Phase 5 で Missing > 0**: 消えたのではなく、majority 読みの断面が未更新なことが多い。スクリプトは 10 秒後に同じ ACKED 集合を majority 読みし直す（1 回だけ）。それでも残ればその回は仕方なし。Phase 4 の欠落とは別。
- **ポート衝突**: 27021-27023 が空いていること。
