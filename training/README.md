# banqi-training 部署

分布式训练器，经 gRPC 从 `banqi-scheduler` 拉取 episode 批次并训练，导出的网络经预签名直传登记。

采用 **wheel 分发包**方式部署：产物可归档，目标机不需要 git 与外网 PyPI 访问。

## 一、构建（在开发机）

```bash
deploy/training/build.sh
```

产物：`deploy/dist/banqi_training-<版本>-py3-none-any.whl`

wheel 的**默认依赖不含 torch**：目标机（GPU 容器）的 CUDA 版 torch 由其自身保障，从 PyPI 安装会覆盖既有安装。需要时可用 `pip install "banqi-training[torch]"`。

## 二、分发与安装

```bash
deploy/training/deploy.sh --host colab
```

脚本依次执行：
1. 上传 wheel 到目标机 `/tmp/`；
2. `pip install --no-deps --force-reinstall`（不动目标机已有的 torch 等依赖）；
3. 上传本地配置 `banqi-training/banqi_training/config.local.yaml` 到目标机 `~/.config/banqi-training/config.yaml`（源文件不存在则跳过，可用 `--config` 指定其他文件）。

常用参数：`--remote-python /opt/conda/bin/python3`（非交互 ssh 下 conda 环境通常不在 PATH 中）、`--no-install`（只上传）。

## 三、目标机配置与启动

`config.py` 默认只从**包目录内**读取 `config.local.yaml`，安装为 wheel 后该位置在 site-packages 下，因此启动时必须用 `BANQI_CONFIG` 指向外部配置：

```bash
export BANQI_CONFIG=$HOME/.config/banqi-training/config.yaml
export SCHEDULER_ENDPOINT=http://<调度器地址>:50051
python -m banqi_training.trainer_cli 4x8
```

- 变体 id 以调度器 `GetInfo` 下发为准，命令行位置参数仅作默认值。
- 配置中的路径字段（`OUTPUT_DIR` / `MODEL_PATH` / `TENSORBOARD_LOG_DIR` 等）若写相对路径，会相对 **site-packages** 解析，因此请使用绝对路径。
- 配置模板可用 `python -m banqi_training.config --write-template` 生成（写入包目录），或直接复制仓库内的 `banqi_training/config.default.yaml` 后填写。

## 四、开发机本地安装

```bash
cd banqi-training
pip install -e .              # 非 torch 依赖
pip install -e ".[torch]"     # 需要 torch 时
pip install -e ".[proto]"     # 需要重新生成 pb2 时
```
