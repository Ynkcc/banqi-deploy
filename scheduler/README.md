# banqi-scheduler 部署

分布式自对弈训练的中心调度器。单一 Go 二进制，WebUI 前端已 `go:embed` 进二进制，**不需要额外的静态文件**。

## 一、构建（在开发机）

```bash
deploy/scheduler/build.sh
```

前置：Go 1.27、Node 22 + npm、`protoc` + `protoc-gen-go` + `protoc-gen-go-grpc`。

脚本依次执行：
1. `webui/` 前端构建（`npm ci && npm run build` → `internal/api/dist`）；
2. 由 `proto/scheduler.proto` 重新生成 `pb/`；
3. `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" ./cmd/scheduler`；
4. 产物复制到 `deploy/dist/banqi-scheduler-<版本>-linux-x86_64.tar.gz`。

只改了 Go 代码时可跳过前两步：`build.sh --skip-webui --skip-proto`。

## 二、部署

```bash
scp deploy/dist/banqi-scheduler-<版本>-linux-x86_64.tar.gz <目标机>:
ssh <目标机>
tar -xzf banqi-scheduler-<版本>-linux-x86_64.tar.gz
cd banqi-scheduler-<版本>-linux-x86_64
install -Dm755 bin/scheduler ~/.local/bin/scheduler
install -Dm644 scheduler.example.env ~/.config/banqi-scheduler/scheduler.env
```

安装包内容：

| 文件 | 说明 |
|---|---|
| `bin/scheduler` | 调度器二进制 |
| `scheduler.example.env` | 环境变量配置示例（源自 `banqi-scheduler/config.example.env`） |
| `README.md` | 本文件 |

## 三、配置与启动

配置全部来自环境变量，按下表编辑 `scheduler.env` 后启动：

```bash
set -a; source ~/.config/banqi-scheduler/scheduler.env; set +a
scheduler
```

关键变量（完整说明见 `scheduler.example.env`）：

| 变量 | 说明 |
|---|---|
| `SCHEDULER_LISTEN` | gRPC 监听地址。**示例文件为 `:50051`，而代码内置默认值是 `:50052`**，不显式设置会与采集端/训练端的 `50051` 不一致 |
| `SCHEDULER_DB` | SQLite 路径，需保证目录可写 |
| `SCHEDULER_R2_BUCKET` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_ENDPOINT_URL_S3` | R2 桶与凭据；**仅调度器持有凭据**，worker 与 trainer 零存储配置 |
| `SCHEDULER_HTTP_ADDR` | WebUI 监听地址，默认 `127.0.0.1:8080`，无鉴权，勿暴露到公网 |
| `SCHEDULER_VARIANT` / `SCHEDULER_GAMES_PER_TASK` / `SCHEDULER_INITIAL_REVEALED` | 变体、每批局数、课程阶段 |

后台运行（不依赖 systemd）：

```bash
nohup env $(grep -v '^#' scheduler.env | xargs) scheduler >>scheduler.log 2>&1 &
```

收到 SIGINT / SIGTERM 后调度器会先 `GracefulStop` gRPC 再关闭 WebUI，停止时请使用 `kill`（而非 `kill -9`）以等待在飞请求完成。

## 四、注意事项

- `banqi-scheduler/config.env` 中含真实 R2 凭据且已被 git 忽略，**不要**复制进任何安装包或提交。
- 数据库为单文件 SQLite（WAL 模式），备份时需同时处理 `-wal` / `-shm` 文件。
- 升级只需替换二进制并重启；数据库结构变更由启动时的迁移逻辑自动完成。
