#!/usr/bin/env bash
#
# 编译 banqi-collector 并打包为可直接分发到目标机的安装包（含 Arch/Ubuntu 安装与启动脚本）。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
CRATE_DIR="$REPO_ROOT/banqi-collector"
OUT_DIR="$DEPLOY_DIR/dist"
FEATURES="onnx"

usage() {
  cat <<'EOF'
编译 banqi-collector 并打包为安装包。

用法: deploy/collector/build.sh [选项]

  --cuda           使用 onnx-cuda（需本机 CUDA 13 工具链；产物要求目标机有对应 CUDA 运行库）
  --out-dir DIR    产物输出目录（默认 deploy/dist）
  -h, --help       显示本帮助

产物: <out-dir>/banqi-collector-<版本>-linux-x86_64.tar.gz
EOF
}

die() {
  printf '[build] 错误: %s\n' "$*" >&2
  exit 1
}

# 产物实际要求的 glibc 版本（取动态库版本需求中的最高值），写入安装脚本供目标机前置校验。
detect_required_glibc() {
  local bin="$1" ver
  ver="$(readelf --version-info "$bin" 2>/dev/null \
    | grep -o 'GLIBC_[0-9]\+\(\.[0-9]\+\)*' \
    | sed 's/GLIBC_//' \
    | sort -V -u \
    | tail -n1)"
  if [ -z "$ver" ]; then
    ver="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
    printf '[build] 未能从二进制解析 glibc 需求，回退为构建机版本 %s\n' "$ver" >&2
  fi
  printf '%s' "$ver"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cuda) FEATURES="onnx-cuda"; shift ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir 缺少参数"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

[ -f "$CRATE_DIR/Cargo.toml" ] || die "未找到 $CRATE_DIR/Cargo.toml"
[ -f "$SCRIPT_DIR/collector-ctl.sh" ] || die "缺少 collector-ctl.sh"
[ -f "$SCRIPT_DIR/install.sh" ] || die "缺少 install.sh"
command -v cargo >/dev/null 2>&1 || die "未找到 cargo"

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$CRATE_DIR/Cargo.toml" | head -n1)"
[ -n "$VERSION" ] || die "无法从 Cargo.toml 解析版本号"

echo "[build] banqi-collector v$VERSION  features=$FEATURES"
cargo build --release --manifest-path "$CRATE_DIR/Cargo.toml" --features "$FEATURES"

BIN="$CRATE_DIR/target/release/banqi-collector"
[ -x "$BIN" ] || die "编译产物缺失: $BIN"

# ONNX Runtime 由 ort 静态链接进二进制（ldd 无 libonnxruntime）。
# 若这里报错，说明链接方式变了，安装包会缺少 .so 而无法在目标机启动。
if ldd "$BIN" | grep -q 'libonnxruntime'; then
  die "产物动态依赖 libonnxruntime.so，安装包不完整（检查 ort 的 download-binaries / 链接配置）"
fi

PKG="banqi-collector-${VERSION}-linux-x86_64"
STAGE="$OUT_DIR/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
install -m 0755 "$BIN" "$STAGE/bin/banqi-collector"
install -m 0755 "$SCRIPT_DIR/collector-ctl.sh" "$STAGE/bin/banqi-collector-ctl"
REQ_GLIBC="$(detect_required_glibc "$BIN")"
[ -n "$REQ_GLIBC" ] || die "无法确定产物所需的 glibc 版本"
install -m 0755 "$SCRIPT_DIR/install.sh" "$STAGE/install.sh"
sed -i "s|^REQUIRED_GLIBC=.*|REQUIRED_GLIBC=\"$REQ_GLIBC\"|" "$STAGE/install.sh"
grep -Fq "REQUIRED_GLIBC=\"$REQ_GLIBC\"" "$STAGE/install.sh" \
  || die "写入安装脚本的 glibc 校验基线失败"
install -m 0644 "$SCRIPT_DIR/collector.example.toml" "$STAGE/collector.example.toml"
install -m 0644 "$SCRIPT_DIR/README.md" "$STAGE/README.md"

TARBALL="$OUT_DIR/$PKG.tar.gz"
tar -C "$OUT_DIR" -czf "$TARBALL" "$PKG"

printf '[build] 产物所需最低 glibc: %s\n' "$REQ_GLIBC"
printf '[build] 安装包: %s (%s)\n' "$TARBALL" "$(du -h "$TARBALL" | cut -f1)"
printf '[build] sha256: %s\n' "$(sha256sum "$TARBALL" | cut -d' ' -f1)"
if [ -n "$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')" ]; then
  printf '[build] 目标机 glibc 低于 %s 时无法运行，请改用容器构建（deploy/collector/build-image.sh）\n' "$REQ_GLIBC"
fi
