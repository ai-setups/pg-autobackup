# pg-autobackup

官方 `postgres:17-alpine` 镜像加上 [pgBackRest](https://pgbackrest.org/)：数据库运行时持续把 WAL 归档到 S3 兼容的对象存储（如 Cloudflare R2），并定时做全量备份，可以恢复到最近 7 天内的任意时间点。

```
ghcr.io/ai-setups/pg-autobackup:17
```

## 备份策略

| 项目 | 取值 |
|---|---|
| WAL 归档 | 每写满一个 16 MB 的 WAL 段，或有写入后最多 `PG_ARCHIVE_TIMEOUT` 秒（默认 `1800`，即 30 分钟），上传一个对象 |
| 全量备份 | 仓库为空时立即一次；每次启动后 `BACKUP_AFTER_START_SECONDS`（默认 600 秒）一次；每天 `BACKUP_CRON`（默认 `0 19 * * *`，UTC）一次 |
| 保留 | 7 天，过期的全量和 WAL 在每次备份后自动删除 |
| 压缩 | zstd；小文件合并上传 |

启动时如果备份仓库无法写入，或者调度进程退出，容器会直接停止，不会出现「数据库在跑、备份已断」的情况。

## 使用

```yaml
services:
  db:
    image: ghcr.io/ai-setups/pg-autobackup:17
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
      PGBACKREST_REPO1_S3_ENDPOINT: <account-id>.r2.cloudflarestorage.com
      PGBACKREST_REPO1_S3_BUCKET: <bucket>
      PGBACKREST_REPO1_PATH: /<project>/<env>
      PGBACKREST_REPO1_S3_KEY: ${BACKUP_ACCESS_KEY_ID}
      PGBACKREST_REPO1_S3_KEY_SECRET: ${BACKUP_SECRET_ACCESS_KEY}
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

| 环境变量 | 必填 | 说明 |
|---|---|---|
| `PGBACKREST_REPO1_S3_ENDPOINT` | 是 | S3 endpoint，不带 `https://` |
| `PGBACKREST_REPO1_S3_BUCKET` | 是 | 私有 bucket |
| `PGBACKREST_REPO1_PATH` | 是 | 备份仓库路径，每个数据库实例独占一个 |
| `PGBACKREST_REPO1_S3_KEY`、`PGBACKREST_REPO1_S3_KEY_SECRET` | 是 | 对该 bucket 有读写权限的 Access Key |
| `PG_ARCHIVE_TIMEOUT` | 否 | 有写入后最多多少秒归档一次 WAL，也是整机丢失时最多丢失的数据量；默认 `1800`，取值无效时数据库拒绝启动 |
| `BACKUP_AFTER_START_SECONDS` | 否 | 启动后多久做一次全量，默认 `600` |
| `BACKUP_CRON` | 否 | 定时全量的 crontab 表达式（UTC），默认 `0 19 * * *` |
| `PGBACKREST_REPO1_RETENTION_FULL` | 否 | 保留天数，默认 `7` |

不要覆盖容器的 `command`：WAL 归档参数就在默认命令里。调整归档间隔用 `PG_ARCHIVE_TIMEOUT`。

## 三种启动场景

| 场景 | 数据卷 | 做法 |
|---|---|---|
| 首次创建 | 空 | 直接启动；自动初始化数据库并开始备份 |
| 清空数据（Reset） | 保留 | 在数据库里 `DROP DATABASE` 再 `CREATE DATABASE`；同一实例的备份不断，清空前的数据 7 天内仍可恢复 |
| 恢复 | 空 | 见下文 |

不要通过删除数据卷来清空数据：新初始化的实例身份与备份仓库不一致，容器会拒绝启动。确实要从零开始时，换一个新的 `PGBACKREST_REPO1_PATH`。

## 恢复

```bash
docker compose down
docker volume rm <数据卷>
# 恢复到最新
docker compose run --rm --no-deps --entrypoint pg-restore db latest
# 或恢复到指定时间点
docker compose run --rm --no-deps --entrypoint pg-restore db "2026-10-18 12:00:00+00"
docker compose up -d
```

`pg-restore` 的参数是一个时刻：`latest` 表示备份中的最新状态，或保留期内一个带时区的时间。只需给出时刻，pgBackRest 自动选出该时刻之前最近的一次全量备份；数据库启动后回放 WAL 到该时刻，再开始接受写入。数据卷不为空时 `pg-restore` 拒绝执行。

恢复到时间点后，数据库进入新的时间线；之后再执行 `pg-restore ... latest` 得到的是新时间线上的最新状态。

恢复要求 PostgreSQL 大版本与备份时一致，所以镜像标签按大版本区分（`17`）。

## 开发

```bash
bash tests/smoke.sh
```

冒烟测试用本地目录代替对象存储，验证首次备份、启动后备份、WAL 归档、归档间隔的默认值与环境变量、拒绝向非空卷恢复、恢复到最新和按时间点恢复。推送到任意分支会发布 `sha-<commit>` 标签，合入 `main` 后更新 `17` 标签。
