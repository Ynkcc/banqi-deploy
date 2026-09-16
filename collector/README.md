# banqi-collector 部署

分布式自对弈采集进程，作为 gRPC 客户端对接 `banqi-scheduler`，episode 经 R2 预签名直传。

- **ONNX Runtime 已静态链接进二进制**，运行时不依赖 `libonnxruntime.so`，动态依赖仅 glibc / libstdc++。
- 目标平台为 x86_64 Linux。**产物最低要求 glibc 2.38**：ort 预编译的 ONNX Runtime 1.28 引用了 `__isoc23_strtoll` 等 C23 符号，debian 12（2.36）与 ubuntu 22.04（2.35）均无法链接。运行环境需 Debian 13+ / Ubuntu 24.04+ / Arch。

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

裸机编译的产物，其 glibc 需求等于**编译机**的 glibc（开发机是 Arch，当前为 2.44→产物需求 2.43），只适合分发到同代或更新的系统；要分发给 Debian 13 / Ubuntu 24.04 这类较旧的发行版，请用容器镜像（构建基线固定为 Debian 13）。

`build.sh` 会实测产物的 glibc 需求并把它注入 `install.sh`；`build-image.sh` 同样会报告该值。

容器构建默认以 `podman` 为引擎（回退 `docker`，可用 `ENGINE=` 或 `--engine` 指定）。
编译缓存在宿主目录 `deploy/.build/collector-target-<变体>` 中，首次构建需下载依赖与 ONNX Runtime 并全量编译，耗时较长；后续构建复用该目录。使用 docker 时该目录会留下 root 属主文件，清理需要 sudo。

基础镜像从 `docker.io` 拉取，国内网络建议配置 registry 镜像加速，或在构建前通过 `HTTP_PROXY` / `HTTPS_PROXY` 走代理（podman 会自动把宿主代理变量传入构建过程）：

```bash
HTTPS_PROXY=http://127.0.0.1:8080 deploy/collector/build-image.sh
```

基础镜像可通过 `--build-arg` 覆盖（见 `Containerfile` 顶部）：

| 变体 | builder | runtime |
|---|---|---|
| CPU（默认） | `debian:13-slim` | `debian:13-slim` |
| CUDA | `nvidia/cuda:13.0.3-devel-ubuntu24.04` | `nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04` |

CPU 的 builder 没有用 `rust:1.93-trixie`（体积 1.6GB），而是用 `debian:13-slim` 加容器内 rustup 安装工具链；rustup 的安装在 `COPY` 源码之前，构建层缓存可复用。

CUDA 变体（`--cuda`）**尚未在本机实测**（无 GPU 环境），基础镜像 tag 与 `CARGO_FEATURES=onnx-cuda` 已按 ONNX Runtime 的下载矩阵（`cuda13`）配置，首次使用前建议先在目标机验证。

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
- 本机 glibc 是否满足产物的实测需求（该基线由 `build.sh` 从二进制中读出后注入安装脚本，不是固定值），低于需求时直接报错退出，避免运行期出现难以定位的符号错误。

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

完整字段说明见仓库 `banqi-collector/collector.example.toml`，或 `banqi-collector/ARCHITECTURE.md`。

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
