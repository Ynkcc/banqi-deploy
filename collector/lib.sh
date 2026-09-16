#!/usr/bin/env bash
#
# deploy/collector 下各构建脚本的共用函数。
#

# 载入镜像仓库坐标：文件只提供默认值，已存在的 BANQI_REGISTRY /
# BANQI_REGISTRY_NAMESPACE（环境变量或命令行）优先。结果写入全局 REGISTRY / NAMESPACE。
load_registry_env() {
  local env_file="$1"
  if [ -f "$env_file" ]; then
    # shellcheck source=/dev/null
    . "$env_file"
  fi
  REGISTRY="${BANQI_REGISTRY:-}"
  NAMESPACE="${BANQI_REGISTRY_NAMESPACE:-}"
}

# 镜像仓库名（不含 tag）：<registry>/<namespace>/banqi-collector-<变体>。
# 未配置仓库时退化为本地短名，供只走 tar 分发的场景使用。
image_repo() {
  if [ -n "${REGISTRY:-}" ] && [ -n "${NAMESPACE:-}" ]; then
    printf '%s/%s/banqi-collector-%s' "$REGISTRY" "$NAMESPACE" "$1"
  else
    printf 'banqi-collector-%s' "$1"
  fi
}

# 产物实际要求的 glibc 版本：取二进制的动态库版本需求中的最高值。
# 依赖 binutils 的 readelf；无法解析时输出空串，由调用方决定如何处理。
detect_required_glibc() {
  local bin="$1"
  [ -f "$bin" ] || return 0
  readelf --version-info "$bin" 2>/dev/null \
    | grep -o 'GLIBC_[0-9]\+\(\.[0-9]\+\)*' \
    | sed 's/GLIBC_//' \
    | sort -V -u \
    | tail -n1
}
