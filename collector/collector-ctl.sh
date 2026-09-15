#!/usr/bin/env bash
#
# banqi-collector 后台运行控制（不依赖 systemd，适合无 root 场景）。
#
set -euo pipefail

BIN="${BANQI_COLLECTOR_BIN:-$(command -v banqi-collector 2>/dev/null || printf '%s' "$HOME/.local/bin/banqi-collector")}"
CONF_DIR="${BANQI_COLLECTOR_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/banqi-collector}"
STATE_DIR="${BANQI_COLLECTOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/banqi-collector}"
CONF="${BANQI_COLLECTOR_CONF:-$CONF_DIR/collector.toml}"
PID_FILE="$STATE_DIR/collector.pid"
LOG_FILE="$STATE_DIR/logs/collector.log"

usage() {
  cat <<'EOF'
banqi-collector 后台运行控制。

用法: banqi-collector-ctl <命令> [额外的 banqi-collector 参数]

  start     后台启动，日志写入 <state-dir>/logs/collector.log
  stop      停止（先 SIGTERM 等待退出，超时后 SIGKILL）
  restart   重启
  status    查看运行状态
  logs      实时查看日志（Ctrl-C 退出）
  run       前台运行（调试用）
  help      显示本帮助

环境变量（安装脚本已固化默认值）：
  BANQI_COLLECTOR_BIN        可执行文件路径
  BANQI_COLLECTOR_CONF       配置文件路径
  BANQI_COLLECTOR_CONF_DIR   配置目录
  BANQI_COLLECTOR_STATE_DIR  运行状态目录（pid / 日志 / 模型缓存）

注意：停止会中断在途的 episode 上报，建议在批次间隙操作。
EOF
}

die() {
  printf '[ctl] 错误: %s\n' "$*" >&2
  exit 1
}

ensure_dirs() {
  mkdir -p "$STATE_DIR/logs" "$CONF_DIR"
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start() {
  [ -x "$BIN" ] || die "未找到可执行文件: $BIN"
  [ -f "$CONF" ] || die "未找到配置文件: $CONF"
  if is_running; then
    printf '[ctl] 已在运行 (pid %s)\n' "$(cat "$PID_FILE")"
    return 0
  fi
  ensure_dirs
  cd "$STATE_DIR"
  nohup "$BIN" --config "$CONF" "$@" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  sleep 1
  is_running || die "启动失败，请查看日志: $LOG_FILE"
  printf '[ctl] 已启动 pid=%s\n[ctl] 日志: %s\n' "$pid" "$LOG_FILE"
}

stop() {
  if ! is_running; then
    rm -f "$PID_FILE"
    printf '[ctl] 未在运行\n'
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf '[ctl] 进程未在 30s 内退出，发送 SIGKILL\n'
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  printf '[ctl] 已停止 (pid %s)\n' "$pid"
}

status() {
  if is_running; then
    printf '[ctl] 运行中 (pid %s)\n' "$(cat "$PID_FILE")"
    printf '[ctl] 配置: %s\n[ctl] 日志: %s\n' "$CONF" "$LOG_FILE"
  else
    printf '[ctl] 未在运行\n'
    return 1
  fi
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  start) ensure_dirs; start "$@" ;;
  stop) stop ;;
  restart) stop; ensure_dirs; start "$@" ;;
  status) status ;;
  logs) [ -f "$LOG_FILE" ] || die "日志不存在: $LOG_FILE"; tail -f "$LOG_FILE" ;;
  run) ensure_dirs; cd "$STATE_DIR"; exec "$BIN" --config "$CONF" "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "未知命令: $cmd" ;;
esac
