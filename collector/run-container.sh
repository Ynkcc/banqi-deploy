#!/usr/bin/env bash
#
# 在目标机以容器方式运行 banqi-collector。
#
set -euo pipefail

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
  down      停止并删除容器
  restart   重启容器
  logs      实时查看日志
  status    查看容器状态

选项:
  --cuda              使用 CUDA 变体镜像（nvidia 运行时）
  --image TAG         指定镜像（默认 banqi-collector-<变体>:latest）
  --conf FILE         宿主配置文件（默认 ~/.config/banqi-collector/collector.toml）
  --state-dir DIR     宿主运行目录，挂载为容器内 /home/banqi（默认 ~/.local/state/banqi-collector）
  --engine NAME       容器引擎 podman / docker（默认自动探测）
  -h, --help          显示本帮助

说明: 容器内以 --config /etc/banqi/collector.toml 启动，配置文件以只读方式挂载；
      模型缓存落在挂载的运行目录下（配置中 cache_dir 为相对路径时）。
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
[ -n "$IMAGE" ] || IMAGE="banqi-collector-${VARIANT}:latest"

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
    # shellcheck disable=SC2046
    "$ENGINE" run --detach \
      --name "$NAME" \
      --restart unless-stopped \
      $(gpu_args) \
      --volume "$CONF:/etc/banqi/collector.toml:ro" \
      --volume "$STATE_DIR:/home/banqi" \
      "$IMAGE"
    printf '[run] 已启动容器 %s（镜像 %s）\n' "$NAME" "$IMAGE"
    printf '[run] 日志: %s logs -f %s\n' "$ENGINE" "$NAME"
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
