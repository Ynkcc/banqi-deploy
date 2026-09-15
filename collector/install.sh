#!/usr/bin/env bash
#
# banqi-collector 安装脚本（Arch Linux / Ubuntu / Debian，无需 root）。
# 在解包后的安装包目录中执行。
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-$HOME/.local}"
CONF_DIR="${BANQI_COLLECTOR_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/banqi-collector}"
STATE_DIR="${BANQI_COLLECTOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/banqi-collector}"
FORCE=0

# 由 deploy/collector/build.sh 打包时替换为产物实际的 glibc 需求
REQUIRED_GLIBC="2.36"

usage() {
  cat <<'EOF'
安装 banqi-collector。

用法: ./install.sh [选项]

  --prefix DIR      安装前缀（默认 ~/.local）
  --conf-dir DIR    配置目录（默认 $XDG_CONFIG_HOME/banqi-collector）
  --state-dir DIR   运行状态目录，存放 pid / 日志 / 模型缓存
                    （默认 $XDG_STATE_HOME/banqi-collector）
  --force           覆盖已存在的 collector.toml
  -h, --help        显示本帮助
EOF
}

die() {
  printf '[install] 错误: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix 缺少参数"; PREFIX="$2"; shift 2 ;;
    --conf-dir) [ $# -ge 2 ] || die "--conf-dir 缺少参数"; CONF_DIR="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || die "--state-dir 缺少参数"; STATE_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

[ -x "$PKG_DIR/bin/banqi-collector" ] || die "安装包不完整：缺少 bin/banqi-collector"

distro_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

DISTRO="$(distro_id)"

# 运行库检查：ONNX Runtime 已静态链接，动态依赖仅 glibc / libstdc++。
MISSING_LIBS="$(ldd "$PKG_DIR/bin/banqi-collector" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')"
if [ -n "$MISSING_LIBS" ]; then
  case "$DISTRO" in
    arch) hint="sudo pacman -S --needed glibc gcc-libs" ;;
    ubuntu|debian) hint="sudo apt-get install -y libstdc++6 ca-certificates" ;;
    *) hint="请手动安装: $MISSING_LIBS" ;;
  esac
  die "缺少运行时依赖: $MISSING_LIBS
  $hint"
fi

HAVE_GLIBC="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
if [ -n "$HAVE_GLIBC" ]; then
  if [ "$(printf '%s\n%s\n' "$REQUIRED_GLIBC" "$HAVE_GLIBC" | sort -V | head -n1)" != "$REQUIRED_GLIBC" ]; then
    die "本机 glibc $HAVE_GLIBC 低于产物构建基线 $REQUIRED_GLIBC，无法运行。
  请使用与本机匹配的构建环境重新构建（见 deploy/collector/Containerfile 的 BUILDER_IMAGE）。"
  fi
fi

mkdir -p "$PREFIX/bin" "$PREFIX/share/banqi-collector" "$CONF_DIR" "$STATE_DIR/logs"
install -m 0755 "$PKG_DIR/bin/banqi-collector" "$PREFIX/bin/banqi-collector"
install -m 0755 "$PKG_DIR/bin/banqi-collector-ctl" "$PREFIX/share/banqi-collector/collector-ctl.sh"
install -m 0644 "$PKG_DIR/collector.example.toml" "$CONF_DIR/collector.example.toml"

# 控制脚本路径写死为本次安装的实际位置，避免依赖运行时环境变量
cat >"$PREFIX/bin/banqi-collector-ctl" <<EOF
#!/usr/bin/env bash
export BANQI_COLLECTOR_BIN="$PREFIX/bin/banqi-collector"
export BANQI_COLLECTOR_CONF_DIR="$CONF_DIR"
export BANQI_COLLECTOR_STATE_DIR="$STATE_DIR"
exec "$PREFIX/share/banqi-collector/collector-ctl.sh" "\$@"
EOF
chmod 0755 "$PREFIX/bin/banqi-collector-ctl"

if [ -f "$CONF_DIR/collector.toml" ] && [ "$FORCE" -eq 0 ]; then
  printf '[install] 保留已有配置: %s\n' "$CONF_DIR/collector.toml"
else
  install -m 0644 "$PKG_DIR/collector.example.toml" "$CONF_DIR/collector.toml"
  printf '[install] 已写入配置: %s\n' "$CONF_DIR/collector.toml"
fi

printf '\n[install] 安装完成\n'
printf '  可执行文件 : %s\n' "$PREFIX/bin/banqi-collector"
printf '  控制脚本   : %s\n' "$PREFIX/bin/banqi-collector-ctl"
printf '  配置       : %s\n' "$CONF_DIR/collector.toml"
printf '  运行目录   : %s\n' "$STATE_DIR"
printf '\n后续步骤：\n'
printf '  1. 编辑 %s，至少设置 [scheduler] endpoint\n' "$CONF_DIR/collector.toml"
printf '  2. 启动：banqi-collector-ctl start\n'
printf '  3. 查看日志：banqi-collector-ctl logs\n'
if ! command -v banqi-collector-ctl >/dev/null 2>&1; then
  printf '\n提示：%s 不在 PATH 中，请执行 export PATH="%s/bin:$PATH"\n' "$PREFIX/bin" "$PREFIX"
fi
