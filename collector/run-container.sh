#!/usr/bin/env bash
#
# 在目标机以容器方式运行 banqi-collector。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/banqi-collector"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/banqi-collector"
CONF="$CONF_DIR/collector.toml"
NAME="banqi-collector"
VARIANT="cpu"
ENGINE="${ENGINE:-}"
IMAGE=""

usage() {
  cat <<'EOF'
以容器方式运行 banqi-collector。

用法: deploy/collector/run-container.sh <命令> [选项]

命令:
  up        创建并启动容器
  pull      从镜像仓库拉取镜像（需先 podman/docker login）
  down      停止并删除容器
  restart   重启容器
  logs      实时查看日志
  status    查看容器状态

选项:
  --cuda              使用 CUDA 变体镜像（nvidia 运行时）
  --image TAG         指定镜像（默认 <registry>/<namespace>/banqi-collector-<变体>:latest）
  --conf FILE         宿主配置文件（默认 ~/.config/banqi-collector/collector.toml）
  --state-dir DIR     宿主运行目录，挂载为容器内 /home/banqi（默认 ~/.local/state/banqi-collector）
  --engine NAME       容器引擎 podman / docker（默认自动探测）
  -h, --help          显示本帮助

说明: 容器内以 --config /etc/banqi/collector.toml 启动，配置文件以只读方式挂载；
      模型缓存落在挂载的运行目录下（配置中 cache_dir 为相对路径时）。
      默认镜像名取自 deploy/registry.env（仓库限定名）；只走 tar 分发时用
      `podman load` 载入的也是同一个名字，无需另行指定 --image。
EOF
}

die() {
  printf '[run] 错误: %s\n' "$*" >&2
  exit 1
}

cmd="${1:-help}"
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --cuda) VARIANT="cuda"; shift ;;
    --image) [ $# -ge 2 ] || die "--image 缺少参数"; IMAGE="$2"; shift 2 ;;
    --conf) [ $# -ge 2 ] || die "--conf 缺少参数"; CONF="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || die "--state-dir 缺少参数"; STATE_DIR="$2"; shift 2 ;;
    --engine) [ $# -ge 2 ] || die "--engine 缺少参数"; ENGINE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

if [ -z "$ENGINE" ]; then
  if command -v podman >/dev/null 2>&1; then
    ENGINE="podman"
  elif command -v docker >/dev/null 2>&1; then
    ENGINE="docker"
  else
    die "未找到 podman 或 docker"
  fi
fi
load_registry_env "$SCRIPT_DIR/../registry.env"
[ -n "$IMAGE" ] || IMAGE="$(image_repo "$VARIANT"):latest"

gpu_args() {
  [ "$VARIANT" = "cuda" ] || return 0
  if [ "$ENGINE" = "podman" ]; then
    printf '%s' "--device nvidia.com/gpu=all"
  else
    printf '%s' "--gpus all"
  fi
}

case "$cmd" in
  up)
    [ -f "$CONF" ] || die "配置文件不存在: $CONF
  可先执行: $ENGINE run --rm $IMAGE cat /etc/banqi/collector.example.toml > $CONF"
    mkdir -p "$STATE_DIR/logs"
    "$ENGINE" rm --force "$NAME" >/dev/null 2>&1 || true
    # --pull=missing：本地已有（如 tar load 来的）就不联网，否则从仓库拉取
    # shellcheck disable=SC2046
    "$ENGINE" run --detach \
      --name "$NAME" \
      --restart unless-stopped \
      --pull=missing \
      $(gpu_args) \
      --volume "$CONF:/etc/banqi/collector.toml:ro" \
      --volume "$STATE_DIR:/home/banqi" \
      "$IMAGE"
    printf '[run] 已启动容器 %s（镜像 %s）\n' "$NAME" "$IMAGE"
    printf '[run] 日志: %s logs -f %s\n' "$ENGINE" "$NAME"
    ;;
  pull)
    "$ENGINE" pull "$IMAGE" \
      || die "拉取失败: $IMAGE
  私有仓库需先登录（凭证由引擎保存，不写入本项目）: $ENGINE login $REGISTRY"
    ;;
  down)
    "$ENGINE" rm --force "$NAME"
    ;;
  restart)
    "$ENGINE" restart "$NAME"
    ;;
  logs)
    "$ENGINE" logs --follow "$NAME"
    ;;
  status)
    "$ENGINE" ps --filter "name=^${NAME}$"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "未知命令: $cmd"
    ;;
esac
