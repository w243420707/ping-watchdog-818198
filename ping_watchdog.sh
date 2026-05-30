#!/bin/sh

TARGETS="
gz.telecom.818198.xyz
gz.unicom.818198.xyz
gz.mobile.818198.xyz
"
PING_COUNT=3
PING_TIMEOUT=3
CONFIG_DIR="${PING_WATCHDOG_CONFIG_DIR:-$HOME/.config/ping-watchdog}"
CONFIG_FILE="$CONFIG_DIR/api_url"
LOG_FILE="${PING_WATCHDOG_LOG_FILE:-$HOME/.ping-watchdog.log}"
CRON_TAG="# ping-watchdog-818198"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

script_path() {
  case "$0" in
    /*) printf '%s\n' "$0" ;;
    *)
      script_dir=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
      printf '%s/%s\n' "$script_dir" "$(basename "$0")"
      ;;
  esac
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '未找到 %s，请先安装后重新运行。\n' "$1" >&2
    exit 1
  fi
}

save_api_url() {
  api_url=$1

  if [ -z "$api_url" ]; then
    printf 'API 不能为空。\n' >&2
    exit 1
  fi

  mkdir -p "$CONFIG_DIR"
  umask 077
  printf '%s\n' "$api_url" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

load_api_url() {
  if [ ! -s "$CONFIG_FILE" ]; then
    printf '未找到 API 配置，请先运行：sh %s\n' "$(script_path)" >&2
    exit 1
  fi

  IFS= read -r API_URL < "$CONFIG_FILE"
  if [ -z "$API_URL" ]; then
    printf 'API 配置为空，请删除 %s 后重新运行脚本。\n' "$CONFIG_FILE" >&2
    exit 1
  fi
}

install_cron() {
  self=$(script_path)
  cron_cmd="*/2 * * * * /bin/sh \"$self\" --check $CRON_TAG"
  old_cron_tag="# ping-watchdog-183.47.126.35"

  require_command ping
  require_command curl
  require_command crontab
  require_command mktemp

  current_cron=$(mktemp)
  next_cron=$(mktemp)
  trap 'rm -f "$current_cron" "$next_cron"' EXIT HUP INT TERM

  crontab -l > "$current_cron" 2>/dev/null || :
  grep -F -v "$CRON_TAG" "$current_cron" | grep -F -v "$old_cron_tag" > "$next_cron" || :
  printf '%s\n' "$cron_cmd" >> "$next_cron"
  crontab "$next_cron"

  printf '已部署：每 2 分钟 ping 检查 3 个地址，全部不通时 curl 配置的 API。\n'
  printf 'API 配置文件：%s\n' "$CONFIG_FILE"
  printf '日志文件：%s\n' "$LOG_FILE"
}

check_once() {
  load_api_url

  for target in $TARGETS; do
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
      log "OK ping $target"
      exit 0
    fi

    log "FAIL ping $target"
  done

  log "FAIL all targets, calling API"
  if curl -fsS --max-time 30 "$API_URL" >> "$LOG_FILE" 2>&1; then
    log "API call succeeded"
  else
    status=$?
    log "API call failed, curl exit code: $status"
    exit "$status"
  fi
}

main() {
  case "${1:-}" in
    --check)
      check_once
      ;;
    --install|"")
      if [ ! -s "$CONFIG_FILE" ]; then
        printf '请输入 ping 不通时要 curl 的 API URL：'
        IFS= read -r api_url
        save_api_url "$api_url"
      else
        printf '已存在 API 配置：%s\n' "$CONFIG_FILE"
      fi
      install_cron
      ;;
    --reset-api)
      printf '请输入新的 API URL：'
      IFS= read -r api_url
      save_api_url "$api_url"
      install_cron
      ;;
    --help|-h)
      cat <<EOF
用法：
  sh $(basename "$0")           首次配置 API，并部署每 2 分钟执行一次
  sh $(basename "$0") --install 重新部署 cron，不重复询问已保存的 API
  sh $(basename "$0") --check   执行一次检查，供 cron 调用
  sh $(basename "$0") --reset-api 修改 API 并重新部署 cron
EOF
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      printf '运行 sh %s --help 查看用法。\n' "$(basename "$0")" >&2
      exit 1
      ;;
  esac
}

main "$@"
