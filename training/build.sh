#!/usr/bin/env bash
#
# 构建 banqi-training 的 wheel 分发包。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
REPO_DIR="$REPO_ROOT/banqi-training"
OUT_DIR="$DEPLOY_DIR/dist"
PYTHON="${PYTHON:-python3}"

usage() {
  cat <<'EOF'
构建 banqi-training 的 wheel。

用法: deploy/training/build.sh [选项]

  --python PATH   指定 Python 解释器（默认 python3，也可用 PYTHON 环境变量）
  --out-dir DIR   产物输出目录（默认 deploy/dist）
  -h, --help      显示本帮助

产物: <out-dir>/banqi_training-<版本>-py3-none-any.whl
说明: wheel 不含 torch；部署时以 --no-deps 安装，torch 由目标机自行提供。
EOF
}

die() {
  printf '[build] 错误: %s\n' "$*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --python) [ $# -ge 2 ] || die "--python 缺少参数"; PYTHON="$2"; shift 2 ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir 缺少参数"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

command -v "$PYTHON" >/dev/null 2>&1 || die "未找到 Python 解释器: $PYTHON"
[ -f "$REPO_DIR/pyproject.toml" ] || die "未找到 $REPO_DIR/pyproject.toml"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/banqi_training-*.whl

echo "[build] 构建 wheel（$PYTHON）"
"$PYTHON" -m pip wheel --no-deps --wheel-dir "$OUT_DIR" "$REPO_DIR"

WHEEL="$(ls -1t "$OUT_DIR"/banqi_training-*.whl 2>/dev/null | head -n1)"
[ -n "$WHEEL" ] || die "未生成 wheel"

# config.default.yaml 是 config.py --write-template 的模板来源，必须进包
if command -v unzip >/dev/null 2>&1; then
  unzip -l "$WHEEL" | grep -q 'banqi_training/config.default.yaml' \
    || die "wheel 中缺少 banqi_training/config.default.yaml"
fi

printf '[build] wheel: %s\n' "$WHEEL"
printf '[build] sha256: %s\n' "$(sha256sum "$WHEEL" | cut -d' ' -f1)"
