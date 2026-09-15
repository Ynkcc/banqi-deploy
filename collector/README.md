# banqi-collector 部署

分布式自对弈采集进程，作为 gRPC 客户端对接 `banqi-scheduler`，episode 经 R2 预签名直传。

- **ONNX Runtime 已静态链接进二进制**，运行时不依赖 `libonnxruntime.so`，动态依赖仅 glibc / libstdc++。
- 目标平台为 x86_64 Linux，构建基线 glibc 2.36（Debian 12）。更旧的发行版需下调 `Containerfile` 基础镜像。

## 一、构建（在开发机）

```bash
deploy/collector/build.sh                 # CPU 变体
deploy/collector/build.sh --cuda          # CUDA 变体（需本机 CUDA 13 工具链）
deploy/collector/build-image.sh           # 容器镜像（无需宿主 Rust 工具链）
deploy/collector/build-image.sh --cuda
```

产物位于 `deploy/dist/`：

```
banqi-collector-<版本>-linux-x86_64.tar.gz     安装包（含安装与启动脚本）
banqi-collector-<变体>-<版本>-linux-x86_64.tar 容器镜像
```

容器构建默认以 `podman` 为引擎（回退 `docker`，可用 `ENGINE=` 或 `--engine` 指定）。
依赖编译缓存保存在命名卷 `banqi-collector-buildcache` 中，首次构建需下载依赖与 ONNX Runtime（约数百 MB）。

## 二、裸机部署

```bash
scp deploy/dist/banqi-collector-<版本>-linux-x86_64.tar.gz <目标机>:
ssh <目标机>
tar -xzf banqi-collector-<版本>-linux-x86_64.tar.gz
cd banqi-collector-<版本>-linux-x86_64
./install.sh
```

安装脚本不需要 root，默认布局：

| 路径 | 内容 |
|---|---|
| `~/.local/bin/banqi-collector` | 可执行文件 |
| `~/.local/bin/banqi-collector-ctl` | 后台运行控制脚本 |
| `~/.local/share/banqi-collector/collector-ctl.sh` | 控制脚本本体 |
| `~/.config/banqi-collector/collector.toml` | 配置（已存在时保留，`--force` 覆盖） |
| `~/.local/state/banqi-collector/` | pid、日志、模型缓存 |

可选参数：`--prefix`、`--conf-dir`、`--state-dir`、`--force`。

安装脚本会校验：
- 动态依赖是否齐全（缺失时按发行版给出 `pacman` / `apt` 安装命令）；
- 本机 glibc 是否 ≥ 2.36，低于基线时直接报错退出，避免运行期出现难以定位的符号错误。

### 运行

```bash
banqi-collector-ctl start      # 后台启动
banqi-collector-ctl status
banqi-collector-ctl logs
banqi-collector-ctl stop
banqi-collector-ctl run        # 前台运行，便于调试
```

启动时进程工作目录为状态目录，因此配置中的相对路径（如 `cache_dir`）落在状态目录下。
额外的 collector 参数可追加在命令之后，例如 `banqi-collector-ctl start --threads 12`。

停止会中断在途的 episode 上报，建议在批次间隙操作。

### 配置

编辑 `~/.config/banqi-collector/collector.toml`，至少设置：

```toml
[scheduler]
endpoint = "http://<调度器地址>:50051"
```

完整字段说明见同目录下的 `collector.example.toml`，或仓库 `banqi-collector/ARCHITECTURE.md`。

## 三、容器部署

```bash
# 开发机导出镜像后在目标机加载
deploy/collector/build-image.sh --cuda
scp deploy/dist/banqi-collector-cuda-<版本>-linux-x86_64.tar <目标机>:
ssh <目标机> podman load --input banqi-collector-cuda-<版本>-linux-x86_64.tar

# 目标机运行
./run-container.sh up --cuda
./run-container.sh logs
./run-container.sh down
```

容器内以 `--config /etc/banqi/collector.toml` 启动，宿主配置文件只读挂载；宿主状态目录挂载为容器内 `/home/banqi`，模型缓存因此可以跨容器重建保留。

CUDA 变体需要目标机具备 NVIDIA 驱动 + NVIDIA Container Toolkit；podman 使用 `--device nvidia.com/gpu=all`，docker 使用 `--gpus all`（脚本按引擎自动选择）。

镜像内已安装 `ca-certificates`：采集端经 HTTPS 访问 R2，缺失会导致模型下载与上报全部失败。
