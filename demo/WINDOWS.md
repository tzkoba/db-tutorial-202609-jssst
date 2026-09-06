# Windows でのデモ実行（WSL2 + Docker Desktop）

講義デモのスクリプトはすべて bash（`.sh`）です。Windows の PowerShell / cmd から直接は実行しません。  
**WSL2 上の Linux シェル**から、既存の手順どおり動かします。

## 全体像

```
Windows ホスト
  ├─ Docker Desktop（エンジン）
  └─ WSL2（Ubuntu など）
        ├─ bash / git
        ├─ docker CLI  ← Desktop と連携
        └─ このリポジトリ（Linux 側のホームに clone）
```

## 1. WSL2 を入れる

PowerShell（管理者）:

```powershell
wsl --install
```

既定では WSL2 と Ubuntu が入ります。完了後に再起動します。

確認:

```powershell
wsl --status
wsl --list --verbose
```

- Default Version が `2`
- Ubuntu（または使用するディストリ）の STATE が `Running`、VERSION が `2`

仮想化が無効だと失敗します。BIOS / Windows の「仮想マシン プラットフォーム」「Linux 用 Windows サブシステム」を有効にしてください。

Ubuntu を初回起動したら UNIX ユーザ名とパスワードを作成します。以降の作業は **Ubuntu ターミナル**（Windows Terminal で Ubuntu プロファイル）で行います。

## 2. Docker Desktop を入れる

1. [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) をインストールする
2. 起動し、サインインは任意
3. **Settings → General**
   - **Use the WSL 2 based engine** をオン
4. **Settings → Resources → WSL Integration**
   - **Enable integration with my default WSL distro** をオン
   - 使うディストリ（Ubuntu）のトグルをオン
5. Apply & Restart

Rancher Desktop でも同じです。WSL 連携を有効にし、Ubuntu から `docker version` で Server が見えれば十分です。

## 3. WSL 内で Docker が見えること

Ubuntu ターミナル:

```bash
uname -a
# Linux であること（Microsoft のカーネル文字列が付く）

bash --version

docker version
# Client と Server の両方に Version が出ること
# Server が出ない → Desktop が起動していない／WSL Integration がオフ

docker info
docker run --rm hello-world
```

`hello-world` が動けば、この先の `docker run` / `docker exec` / `docker network` は同じ経路です。

## 4. リポジトリを Linux 側に置く

`/mnt/c/Users/...` 配下だとファイル I/O が遅く、権限や改行コードでコケることがあります。ホームに clone します。

```bash
cd ~
git clone <このリポジトリの URL> intro2databases
cd ~/intro2databases
git config core.autocrlf input
```

Windows 側で既に clone している場合は、WSL からそのパス（`/mnt/c/...`）を使わず、上記のように作り直すか、`git clone` し直してください。

改行が CRLF だと `.sh` が `bad interpreter` になります。疑わしいとき:

```bash
file demo/part1/postgres-availability/scripts/00-preflight.sh
# "Bourne-Again shell script" であり、CRLF と出ないこと
```

## 5. 環境確認チェックリスト

Ubuntu で、すべて成功することを確認します。

```bash
# OS
uname -s
# 期待: Linux

# bash
command -v bash && bash --version | head -1

# Docker（Client + Server）
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'

# ネットワーク操作（分断デモで使う）
docker network ls >/dev/null && echo "docker network: ok"

# 作業ディレクトリ
pwd
# 期待: /home/<user>/intro2databases など、/mnt/c で始まらないこと
```

任意（ホストに `psql` が無くてもよい。各 README どおり `docker exec` で代替可能）:

```bash
command -v psql || echo "psql なし（docker exec で代替）"
```

Yugabyte デモだけメモリ目安が大きいです（3 ノードで合計 5.5GB 程度）。WSL のメモリ上限は Windows 側の `.wslconfig` で決まります。足りないと OOM で落ちます。

## 6. デモを動かす

以降は各 README の Phase 0 と同じです。**必ず Ubuntu 上で** `cd` してから実行します。

| デモ | ディレクトリ |
|------|----------------|
| PostgreSQL 可用性 | [`part1/postgres-availability`](part1/postgres-availability/README.md) |
| PostgreSQL 信頼性 | [`part1/postgres-reliability`](part1/postgres-reliability/README.md) |
| jsonb vs Mongo | [`part2/json-postgres-vs-mongo`](part2/json-postgres-vs-mongo/README.md) |
| MongoDB 可用性・一貫性 | [`part2/mongo-availability-consistency`](part2/mongo-availability-consistency/README.md) |
| YugabyteDB 可用性・信頼性 | [`part3/yugabyte-availability-reliability`](part3/yugabyte-availability-reliability/README.md) |

例:

```bash
cd ~/intro2databases/demo/part1/postgres-availability/scripts
./00-preflight.sh
```

PowerShell で `./00-preflight.sh` や `bash 00-preflight.sh` をホストから叩く想定はしません。

## うまくいかないとき

| 症状 | 見ること |
|------|----------|
| `docker: command not found` | Desktop の WSL Integration。ターミナルを開き直す |
| `Cannot connect to the Docker daemon` | Desktop が起動しているか。`docker context ls` |
| `exec format error` / `$'\r': command not found` | CRLF。Linux 側で clone し直すか `sed -i 's/\r$//' scripts/*.sh` |
| `hello-world` は動くがコンテナ間不通 | Yugabyte README の `bridge-nf-call-iptables` トラブルシュート |
| `/mnt/c` 上で極端に遅い・ファイルが見えない | リポジトリを `~/intro2databases` に移す |
| ポート使用中 | 他デモのコンテナが残っていないか。各 `cleanup.sh` |

## 採用しなかったもの

- **PowerShell 版スクリプト**: 50 本近い `.sh` の二重管理になるため置いていません
- **Git Bash のみ**: 動くこともありますが、パス変換と分断デモで欠けるため本線にしません
