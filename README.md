# deploy

各独立仓库的构建与部署入口。产物统一输出到 `deploy/dist/`。

| 子目录 | 目标仓库 | 主要产物 |
|---|---|---|
| `collector/` | banqi-collector | `banqi-collector-<版本>-linux-x86_64.tar.gz`（含 Arch/Ubuntu 安装与启动脚本）、`banqi-collector-<版本>-linux-x86_64.tar`（容器镜像） |
| `scheduler/` | banqi-scheduler | `banqi-scheduler-<版本>-linux-x86_64.tar.gz`（WebUI 已 embed 的 Go 二进制 + 示例环境文件） |
| `training/` | banqi-training | `banqi_training-<版本>-py3-none-any.whl` |

## 构建环境

- **collector**：Rust ≥ 1.88（edition 2024）、`protoc`（`tonic-build` 编译 proto 需要）。容器构建则只需 podman 或 docker。
- **scheduler**：Go 1.27、Node 22 + npm（WebUI 前端）。
- **training**：Python ≥ 3.10 与 pip。

## 目标平台

统一按 **x86_64 Linux** 产出。

collector 产物**最低要求 glibc 2.38**（ort 预编译的 ONNX Runtime 1.28 引用了 C23 的 `__isoc23_*` 符号），因此构建基线为 Debian 13（glibc 2.41），运行环境需 Debian 13+ / Ubuntu 24.04+ / Arch。Debian 12（2.36）、Ubuntu 22.04（2.35）既无法构建也无法运行，下调基础镜像无效。

## 常用命令

```bash
# 采集端：本地编译 + 打包安装包；容器镜像
deploy/collector/build.sh
deploy/collector/build.sh --cuda
deploy/collector/build-image.sh
deploy/collector/build-image.sh --cuda
deploy/collector/run-container.sh up        # 在目标机以容器方式运行

# 调度器：前端构建 + go build，产物复制到 dist/
deploy/scheduler/build.sh

# 训练端：构建 wheel 并分发安装
deploy/training/build.sh
deploy/training/deploy.sh --host colab
```

各子目录的 `README.md` 有完整的部署与运行说明，其中 `collector/README.md` 与 `scheduler/README.md` 同时会被复制进对应的安装包。
