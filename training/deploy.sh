#!/usr/bin/env bash
#
# 把 banqi-training 的 wheel 分发到目标机并安装（无需目标机具备 git 与外网 PyPI 访问）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
REPO_DIR="$REPO_ROOT/banqi-training"
OUT_DIR="$DEPLOY_DIR/dist"

HOST=""
WHEEL=""
CONFIG="$REPO_DIR/banqi_training/config.local.yaml"
REMOTE_PYTHON="python3"
REMOTE_CONF_DIR=".config/banqi-training"

usage() {
  cat <<'EOF'
分发并安装 banqi-training wheel。

用法: deploy/training/deploy.sh --host <ssh目标> [选项]

  --host HOST      目标机（ssh 目标，如 colab 或 user@1.2.3.4），必填
  --wheel FILE     指定 wheel（默认为 dist/ 下最新的 banqi_training-*.whl）
  --config FILE    上传的本地配置（默认 banqi-training/banqi_training/config.local.yaml，
                   不存在则跳过配置上传）
  --remote-python  目标机 Python 解释器（默认 python3，GPU 容器常用 /opt/conda/bin/python3）
  --no-install     只上传，不执行 pip install
  -h, --help       显示本帮助

说明: wheel 以 `pip install --no-deps --force-reinstall` 安装，torch 等依赖由目标机自行保障。
      配置上传到 ~/.config/banqi-training/config.yaml，启动时需设置 BANQI_CONFIG 指向它
      （config.py 默认只从包目录读 config.local.yaml）。
EOF
}

die() {
  printf '[deploy] 错误: %s\n' "$*" >&2
  exit 1
}

DO_INSTALL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host) [ $# -ge 2 ] || die "--host 缺少参数"; HOST="$2"; shift 2 ;;
    --wheel) [ $# -ge 2 ] || die "--wheel 缺少参数"; WHEEL="$2"; shift 2 ;;
    --config) [ $# -ge 2 ] || die "--config 缺少参数"; CONFIG="$2"; shift 2 ;;
    --remote-python) [ $# -ge 2 ] || die "--remote-python 缺少参数"; REMOTE_PYTHON="$2"; shift 2 ;;
    --no-install) DO_INSTALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; die "必须指定 --host"; }
command -v ssh >/dev/null 2>&1 || die "未找到 ssh"
command -v scp >/dev/null 2>&1 || die "未找到 scp"

if [ -z "$WHEEL" ]; then
  WHEEL="$(ls -1t "$OUT_DIR"/banqi_training-*.whl 2>/dev/null | head -n1 || true)"
fi
[ -n "$WHEEL" ] || die "未找到 wheel，请先执行 deploy/training/build.sh"
[ -f "$WHEEL" ] || die "wheel 不存在: $WHEEL"

WHEEL_NAME="$(basename "$WHEEL")"
REMOTE_WHEEL="/tmp/$WHEEL_NAME"

echo "[deploy] 上传 $WHEEL_NAME → $HOST:$REMOTE_WHEEL"
scp -q "$WHEEL" "$HOST:$REMOTE_WHEEL"

if [ "$DO_INSTALL" -eq 1 ]; then
  echo "[deploy] 安装到 $HOST（$REMOTE_PYTHON，--no-deps）"
  ssh "$HOST" "'$REMOTE_PYTHON' -m pip install --no-deps --force-reinstall --no-cache-dir '$REMOTE_WHEEL'"
fi

if [ -f "$CONFIG" ]; then
  echo "[deploy] 上传配置 $CONFIG → $HOST:~/$REMOTE_CONF_DIR/config.yaml"
  ssh "$HOST" "mkdir -p ~/$REMOTE_CONF_DIR"
  scp -q "$CONFIG" "$HOST:~/$REMOTE_CONF_DIR/config.yaml"
else
  printf '[deploy] 未找到配置 %s，跳过上传\n' "$CONFIG"
fi

printf '\n[deploy] 完成。目标机启动命令：\n'
printf '  export BANQI_CONFIG=$HOME/%s/config.yaml\n' "$REMOTE_CONF_DIR"
printf '  export SCHEDULER_ENDPOINT=http://<调度器地址>:50051\n'
printf '  %s -m banqi_training.trainer_cli 4x8\n' "$REMOTE_PYTHON"
printf '\n注意: 配置中 OUTPUT_DIR / MODEL_PATH 等路径字段若为相对路径，会相对 site-packages 解析，请使用绝对路径。\n'
