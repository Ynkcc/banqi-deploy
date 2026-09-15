#!/usr/bin/env bash
#
# deploy/collector 下各构建脚本的共用函数。
#

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
