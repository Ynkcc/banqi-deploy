#!/usr/bin/env bash
#
# 编译 banqi-scheduler（WebUI 前端 + Go 二进制）并把产物复制到 deploy/dist/。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
REPO_DIR="$REPO_ROOT/banqi-scheduler"
OUT_DIR="$DEPLOY_DIR/dist"
GOOS="linux"
GOARCH="amd64"

usage() {
  cat <<'EOF'
编译 banqi-scheduler 并打包。

用法: deploy/scheduler/build.sh [选项]

  --skip-webui     跳过前端构建（复用 internal/api/dist 现有产物）
  --skip-proto     跳过 pb 重新生成（复用 pb/ 现有产物）
  --out-dir DIR    产物输出目录（默认 deploy/dist）
  -h, --help       显示本帮助

前提: Go 1.27、Node 22 + npm、protoc + protoc-gen-go + protoc-gen-go-grpc。
产物: <out-dir>/banqi-scheduler-<版本>-linux-x86_64.tar.gz
EOF
}

die() {
  printf '[build] 错误: %s\n' "$*" >&2
  exit 1
}

SKIP_WEBUI=0
SKIP_PROTO=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-webui) SKIP_WEBUI=1; shift ;;
    --skip-proto) SKIP_PROTO=1; shift ;;
    --out-dir) [ $# -ge 2 ] || die "--out-dir 缺少参数"; OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数: $1" ;;
  esac
done

[ -f "$REPO_DIR/go.mod" ] || die "未找到 $REPO_DIR/go.mod"
command -v go >/dev/null 2>&1 || die "未找到 go"

WEBUI_DIR="$REPO_DIR/webui"
DIST_DIR="$REPO_DIR/internal/api/dist"

if [ "$SKIP_WEBUI" -eq 0 ]; then
  command -v npm >/dev/null 2>&1 || die "未找到 npm（或用 --skip-webui 复用已有前端产物）"
  [ -f "$WEBUI_DIR/package-lock.json" ] || die "缺少 webui/package-lock.json"
  echo "[build] 构建 WebUI 前端"
  (cd "$WEBUI_DIR" && npm ci && npm run build)
fi

[ -f "$DIST_DIR/index.html" ] || die "前端产物缺失: $DIST_DIR/index.html（internal/api 通过 go:embed 内嵌该目录）"

if [ "$SKIP_PROTO" -eq 0 ]; then
  for tool in protoc protoc-gen-go protoc-gen-go-grpc; do
    command -v "$tool" >/dev/null 2>&1 || die "未找到 $tool（或用 --skip-proto 复用已有 pb/）"
  done
  echo "[build] 重新生成 pb/"
  (cd "$REPO_DIR" && protoc --proto_path=proto --go_out=. --go_opt=module=banqi/server \
    --go-grpc_out=. --go-grpc_opt=module=banqi/server proto/scheduler.proto)
fi

[ -f "$REPO_DIR/pb/scheduler.pb.go" ] || die "pb/ 产物缺失，请先执行 protoc 生成"

if git -C "$REPO_DIR" describe --tags --always --dirty >/dev/null 2>&1; then
  VERSION="$(git -C "$REPO_DIR" describe --tags --always --dirty)"
else
  VERSION="$(date +%Y%m%d)"
fi

PKG="banqi-scheduler-${VERSION}-linux-x86_64"
STAGE="$OUT_DIR/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"

echo "[build] banqi-scheduler $VERSION  ${GOOS}/${GOARCH}"
(cd "$REPO_DIR" && CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" \
  go build -trimpath -ldflags "-s -w" -o "$STAGE/bin/scheduler" ./cmd/scheduler)

[ -x "$STAGE/bin/scheduler" ] || die "编译产物缺失"

install -m 0644 "$REPO_DIR/config.example.env" "$STAGE/scheduler.example.env"
install -m 0644 "$SCRIPT_DIR/README.md" "$STAGE/README.md"

TARBALL="$OUT_DIR/$PKG.tar.gz"
tar -C "$OUT_DIR" -czf "$TARBALL" "$PKG"

printf '[build] 二进制: %s (%s)\n' "$STAGE/bin/scheduler" "$(du -h "$STAGE/bin/scheduler" | cut -f1)"
printf '[build] 安装包: %s\n' "$TARBALL"
printf '[build] sha256: %s\n' "$(sha256sum "$TARBALL" | cut -d' ' -f1)"
