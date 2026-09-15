#!/usr/bin/env bash
#
# 构建 banqi-collector 容器镜像（多阶段全容器构建，不依赖宿主 Rust 工具链）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
CRATE_DIR="$REPO_ROOT/banqi-collector"
OUT_DIR="$DEPLOY_DIR/dist"
CTX_DIR="$DEPLOY_DIR/.build/collector-context"
CACHE_VOL="banqi-collector-buildcache"

CPU_BUILDER="rust:1.93-bookworm"
CPU_RUNTIME="debian:12-slim"
CUDA_BUILDER="nvidia/cuda:13.0.0-devel-ubuntu24.04"
CUDA_RUNTIME="nvidia/cuda:13.0.0-runtime-ubuntu24.04"

VARIANT="cpu"
ENGINE="${ENGINE:-}"

usage() {
  cat <<'EOF'
构建 banqi-collector 容器镜像。

用法: deploy/collector/build-image.sh [选项]

  --cuda           构建 CUDA 变体（onnx-cuda，基础镜像为 CUDA 13）
  --engine NAME    指定容器引擎 podman / docker（默认自动探测）
  --out-dir DIR    镜像 tar 输出目录（默认 deploy/dist）
  -h, --help       显示本帮助

产物: <out-dir>/banqi-collector-<变体>-<版本>-linux-x86_64.tar
环境: ENGINE=<podman|docker> 等价于 --engine
EOF
}

die() {
  printf '[image] 错误: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cuda) VARIANT="cuda"; shift ;;
    --engine) [ $# -ge 2 ] || die "--engine 缺少参数"; ENGINE="$2"; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir 缺少参数"; OUT_DIR="$2"; shift 2 ;;
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
command -v "$ENGINE" >/dev/null 2>&1 || die "未找到容器引擎: $ENGINE"

[ -f "$CRATE_DIR/Cargo.toml" ] || die "未找到 $CRATE_DIR/Cargo.toml"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$CRATE_DIR/Cargo.toml" | head -n1)"
[ -n "$VERSION" ] || die "无法从 Cargo.toml 解析版本号"

if [ "$VARIANT" = "cuda" ]; then
  BUILDER_IMAGE="$CUDA_BUILDER"
  RUNTIME_IMAGE="$CUDA_RUNTIME"
  CARGO_FEATURES="onnx-cuda"
else
  BUILDER_IMAGE="$CPU_BUILDER"
  RUNTIME_IMAGE="$CPU_RUNTIME"
  CARGO_FEATURES="onnx"
fi

# 构建上下文：三个 crate 去掉 target/.git 后平铺到临时目录，避免把数 GB 的
# target 传给构建守护进程。
echo "[image] 准备构建上下文: $CTX_DIR"
rm -rf "$CTX_DIR"
mkdir -p "$CTX_DIR"
tar -C "$REPO_ROOT" --exclude='target' --exclude='.git' -cf - \
  banqi-core banqi-engine banqi-collector | tar -C "$CTX_DIR" -xf -
install -m 0644 "$SCRIPT_DIR/collector.example.toml" "$CTX_DIR/collector.example.toml"

IMAGE_NAME="banqi-collector-${VARIANT}"
IMAGE_TAG="${IMAGE_NAME}:${VERSION}"

echo "[image] 引擎=$ENGINE  变体=$VARIANT  features=$CARGO_FEATURES"
echo "[image] builder=$BUILDER_IMAGE"
echo "[image] runtime=$RUNTIME_IMAGE"

# target 走命名卷缓存：首次构建需下载依赖与 ONNX Runtime，后续复用
"$ENGINE" build \
  --file "$SCRIPT_DIR/Containerfile" \
  --tag "$IMAGE_TAG" \
  --tag "${IMAGE_NAME}:latest" \
  --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" \
  --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
  --build-arg "CARGO_FEATURES=$CARGO_FEATURES" \
  --mount "type=volume,source=${CACHE_VOL},destination=/src/banqi-collector/target" \
  "$CTX_DIR"

mkdir -p "$OUT_DIR"
IMAGE_TAR="$OUT_DIR/${IMAGE_NAME}-${VERSION}-linux-x86_64.tar"
"$ENGINE" save --output "$IMAGE_TAR" "$IMAGE_TAG" "${IMAGE_NAME}:latest"

printf '[image] 镜像: %s\n' "$IMAGE_TAG"
printf '[image] 导出: %s (%s)\n' "$IMAGE_TAR" "$(du -h "$IMAGE_TAR" | cut -f1)"
printf '[image] 分发后在目标机执行: %s load --input %s\n' "$ENGINE" "$(basename "$IMAGE_TAR")"
