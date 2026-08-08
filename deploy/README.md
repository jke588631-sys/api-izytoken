# 生产部署配置

本目录是 **43.225.196.34** 这台服务器上全部生产部署配置的版本化副本。
在此之前这些配置只存在于服务器上，没有任何备份 —— 服务器一挂就得从零重建。

> **本目录不含任何密钥。** 所有敏感值都是 `${VAR}` 引用或 `.env.example` 占位符。
> 真实的 `.env` 与 `/etc/new-api-monitor.conf` **永远不要提交**（已在 `.gitignore` 中排除）。

## 这台服务器上跑着什么

一台机器，三个互相独立的项目 + 一层共享入口：

```
                    公网 :80 / :443
                          │
                 ┌────────▼─────────┐
                 │  new-api-caddy   │  外层 Caddy（TLS 终止 + 按域名分流）
                 │  caddy:2-alpine  │  同时接入两个 docker 网络
                 └───┬──────────┬───┘
       api.izytoken  │          │  na.izytoken / studio.izytoken
       izytoken.com  │          │
                     ▼          ▼
        ┌────────────────┐   ┌──────────────────────┐
        │ new-api-       │   │ na-izytoken-caddy    │ 内层 Caddy
        │ migrated-pg    │   │ izytoken-caddy:custom│ (带 replace-response 插件)
        │ new-api:rc20   │   └──┬────────┬────────┬─┘
        └───┬────────────┘      │        │        │
            │                   ▼        ▼        ▼
     ┌──────▼──────┐      whatsapp   creator   studio
     │ postgres:15 │      -overlay    :3200     :3000
     │ redis:7     │         │
     └─────────────┘         ▼
                        na-izytoken-new-api
                        + postgres:15 + redis:7

    网络: new-api-net          网络: na-izytoken-net
    （两个网络彼此隔离，仅外层 Caddy 同时接入两边）
```

| 项目 | 域名 | 目录 | 数据库 |
|---|---|---|---|
| api-izytoken | api.izytoken.com, izytoken.com | `/opt/new-api-migrated` | PostgreSQL 15 + Redis 7 |
| na-izytoken | na.izytoken.com | `/opt/na-izytoken` | PostgreSQL 15 + Redis 7（独立实例） |
| izytoken-studio | studio.izytoken.com | `/opt/izytoken-studio` | 无（SQL_DSN 为空，用本地存储） |

**三套数据完全独立**，不共享任何用户、令牌、渠道或余额。

## ⚠️ 两条踩过坑的硬规矩

### 1. `reverse_proxy` 必须用 `container_name`，绝不能用服务名

两个项目的 compose 里**都有一个叫 `new-api` 的服务**，Docker 会把服务名注册成网络别名。
外层 Caddy 同时接在两个网络上时，`reverse_proxy new-api:3000` 会**随机解析到错误的后端**。

2026-08-05 因此发生过生产事故：api.izytoken.com 的登录请求被转发到了 na 的数据库
（那边只有 61 个用户，api 有 264 个），导致所有老账号登录失败约 40 分钟。

正确写法：
```
reverse_proxy new-api-migrated-pg:3000   # ✅ 容器名，全局唯一
reverse_proxy new-api:3000               # ❌ 服务名，跨项目重名时解析不确定
```
已知重名的服务名：`new-api`、`caddy`、`postgres`、`redis`。

### 2. 改 Caddyfile 一律 `validate` → `reload`，不要 `restart`

```bash
docker exec new-api-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec new-api-caddy caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
```
`reload` 不重启容器、不中断在飞请求。改前先 `cp Caddyfile Caddyfile.bak-<用途>-<时间戳>`。

## 目录说明

```
deploy/
├── api-izytoken/           api.izytoken.com（主业务中转站）
│   ├── docker-compose.yml  PG 架构；旧 SQLite 服务保留为 profiles:[rollback]
│   ├── Caddyfile           含 /assets/ 前端覆盖规则 + na/studio 转发块
│   ├── Dockerfile.rc19/20  把预编译二进制打进镜像
│   ├── purge_logs.sh       SQLite 时代的日志清理（PG 后已由 migrate/cleanup_logs.sh 取代）
│   ├── .env.example
│   └── migrate/            2026-08-06 SQLite → PostgreSQL 迁移工具
│       ├── sqlite_to_pg.py   full / delta 两种模式
│       ├── delta_loop.sh     切换前每 10 分钟增量同步
│       └── cleanup_logs.sh   每天清理 PG 中 30 天前的 logs
├── na-izytoken/            na.izytoken.com（2026-08-05 从 167.172.147.152 迁入）
├── izytoken-studio/        studio.izytoken.com
└── system/                 系统级（宿主机，非容器）
    ├── new-api-monitor.*     每 5 分钟巡检：内存/重启/健康/上游超时
    ├── new-api-monitor.conf.example
    └── thp-madvise.service   开机把 THP 设为 madvise（抑制 Go 进程 RSS 虚高）
```

## 恢复部署（服务器重建时）

```bash
# 1. 目录与配置
mkdir -p /opt/new-api-migrated && cd /opt/new-api-migrated
# 从本仓库 deploy/api-izytoken/ 复制全部文件到此
cp .env.example .env && chmod 600 .env && vi .env    # 填入真实密钥

# 2. 镜像（new-api:rc20 需用 Dockerfile.rc20 + 对应二进制自行构建）
docker build -f Dockerfile.rc20 -t new-api:rc20 .

# 3. 启动（默认只起 PG 架构，rollback profile 不会启动）
docker compose up -d

# 4. 系统级
cp <repo>/deploy/system/new-api-monitor.sh /usr/local/bin/ && chmod +x /usr/local/bin/new-api-monitor.sh
cp <repo>/deploy/system/*.service <repo>/deploy/system/*.timer /etc/systemd/system/
cp <repo>/deploy/system/new-api-monitor.conf.example /etc/new-api-monitor.conf && chmod 600 /etc/new-api-monitor.conf
systemctl daemon-reload && systemctl enable --now new-api-monitor.timer thp-madvise.service
```

## 回滚到 SQLite

`docker-compose.yml` 里保留了 SQLite 时代的 `new-api` 服务，标记为 `profiles: [rollback]`，
默认不启动。若 PG 出问题需要回退：

```bash
cd /opt/new-api-migrated
docker compose stop new-api-pg
docker compose --profile rollback up -d new-api
# 再把 Caddyfile 的 reverse_proxy 目标改回 new-api-migrated:3000 并 reload
```
⚠️ SQLite 快照定格在 **2026-08-06 18:13** 的切换时刻，之后所有写入都只在 PG 里。
回退等于丢弃切换后的全部新数据，仅作为紧急手段。

## 内存上限（吸取过宕机教训）

2026-07-31 曾因上游挂死导致在飞请求堆积，new-api 进程内存冲到 23GB 把整机拖垮
（详见 `/opt/new-api-migrated/PROGRESS.md`）。此后所有容器都设了上限：

| 容器 | 上限 |
|---|---|
| new-api-migrated-pg | 4g |
| new-api-migrated-postgres | 2g |
| new-api-migrated-redis | 512m |
| new-api-migrated（rollback） | 16g |
| na-izytoken-new-api | 4g |
| na-izytoken-postgres | 2g |
| izytoken-creator / studio / whatsapp-overlay | 各 1g |
| na-izytoken-caddy | 512m |

宿主总内存 30G。
