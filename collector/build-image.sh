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
CACHE_ROOT="$DEPLOY_DIR/.build/collector-target"

# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# 构建基线取 Debian 13（glibc 2.41）：ort 预编译的 ONNX Runtime 1.28 引用了
# glibc 2.38 起才提供的 __isoc23_* 符号，Debian 12（2.36）无法链接。
# builder 用 debian:13-slim 而非 rust 官方镜像（后者体积 1.6GB），
# rust 工具链由 Containerfile 内 rustup 安装。
CPU_BUILDER="debian:13-slim"
CPU_RUNTIME="debian:13-slim"
# CUDA 变体：runtime 需带 cuDNN（ONNX Runtime 的 CUDA EP 依赖）
CUDA_BUILDER="nvidia/cuda:13.0.3-devel-ubuntu24.04"
CUDA_RUNTIME="nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04"

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

# 编译缓存按变体分开：feature 不同，制品不通用
CACHE_DIR="$CACHE_ROOT-$VARIANT"

# 构建上下文：三个 crate 去掉 target/.git 后平铺到临时目录，避免把数 GB 的
# target 传给构建守护进程。
echo "[image] 准备构建上下文: $CTX_DIR"
rm -rf "$CTX_DIR"
mkdir -p "$CTX_DIR" "$CACHE_DIR"
tar -C "$REPO_ROOT" --exclude='target' --exclude='.git' -cf - \
  banqi-core banqi-engine banqi-collector | tar -C "$CTX_DIR" -xf -
install -m 0644 "$SCRIPT_DIR/collector.example.toml" "$CTX_DIR/collector.example.toml"

IMAGE_NAME="banqi-collector-${VARIANT}"
IMAGE_TAG="${IMAGE_NAME}:${VERSION}"

echo "[image] 引擎=$ENGINE  变体=$VARIANT  features=$CARGO_FEATURES"
echo "[image] builder=$BUILDER_IMAGE"
echo "[image] runtime=$RUNTIME_IMAGE"

# target 目录持久化在宿主：首次构建需下载依赖与 ONNX Runtime 并全量编译，后续复用。
# 注意 docker 的构建守护以 root 运行，会在该目录留下 root 属主文件。
# --network=host 让构建过程直接使用宿主网络栈：容器内的 127.0.0.1 才是宿主的
# 回环地址，宿主代理（HTTP_PROXY/HTTPS_PROXY）因此可用。
"$ENGINE" build \
  --file "$SCRIPT_DIR/Containerfile" \
  --network=host \
  --tag "$IMAGE_TAG" \
  --tag "${IMAGE_NAME}:latest" \
  --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" \
  --build-arg "RUNTIME_IMAGE=$RUNTIME_IMAGE" \
  --build-arg "CARGO_FEATURES=$CARGO_FEATURES" \
  --volume "$CACHE_DIR:/src/banqi-collector/target" \
  "$CTX_DIR"

mkdir -p "$OUT_DIR"
IMAGE_TAR="$OUT_DIR/${IMAGE_NAME}-${VERSION}-linux-x86_64.tar"
"$ENGINE" save --output "$IMAGE_TAR" "$IMAGE_TAG" "${IMAGE_NAME}:latest"

printf '[image] 镜像: %s\n' "$IMAGE_TAG"
printf '[image] 导出: %s (%s)\n' "$IMAGE_TAR" "$(du -h "$IMAGE_TAR" | cut -f1)"
printf '[image] 分发后在目标机执行: %s load --input %s\n' "$ENGINE" "$(basename "$IMAGE_TAR")"

# target 目录 bind 在宿主上，可直接对编译产物做依赖检查
BUILT_BIN="$CACHE_DIR/release/banqi-collector"
REQ_GLIBC="$(detect_required_glibc "$BUILT_BIN")"
[ -n "$REQ_GLIBC" ] || die "无法解析容器内编译产物的 glibc 需求: $BUILT_BIN"
printf '[image] 产物所需最低 glibc: %s\n' "$REQ_GLIBC"
