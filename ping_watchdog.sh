#!/bin/sh

PING_TARGETS="
gz.telecom.818198.xyz
gz.unicom.818198.xyz
gz.mobile.818198.xyz
"

PREFERRED_TCP_TARGETS="
sh-cm-v4.ip.zstaticcdn.com:80
sh-cu-v4.ip.zstaticcdn.com:80
sh-ct-v4.ip.zstaticcdn.com:80
bj-cm-v4.ip.zstaticcdn.com:80
bj-cu-v4.ip.zstaticcdn.com:80
bj-ct-v4.ip.zstaticcdn.com:80
gd-cm-v4.ip.zstaticcdn.com:80
gd-cu-v4.ip.zstaticcdn.com:80
gd-ct-v4.ip.zstaticcdn.com:80
"

INTERNATIONAL_TARGETS="${PING_WATCHDOG_INTERNATIONAL_TARGETS:-www.cloudflare.com:443 one.one.one.one:443}"
PROXY_PORTS="${PING_WATCHDOG_PROXY_PORTS:-5001 5002 5003 5004 5005}"

PING_COUNT="${PING_WATCHDOG_PING_COUNT:-3}"
PING_TIMEOUT="${PING_WATCHDOG_PING_TIMEOUT:-3}"
TCP_TIMEOUT="${PING_WATCHDOG_TCP_TIMEOUT:-3}"
TCP_MAX_TIME="${PING_WATCHDOG_TCP_MAX_TIME:-6}"
FAIL_THRESHOLD="${PING_WATCHDOG_FAIL_THRESHOLD:-2}"
COOLDOWN_SECONDS="${PING_WATCHDOG_COOLDOWN_SECONDS:-900}"
POST_CHANGE_WAIT="${PING_WATCHDOG_POST_CHANGE_WAIT:-20}"
MAX_ACTIVE_TCP_TARGETS="${PING_WATCHDOG_MAX_TCP_TARGETS:-9}"
MIN_ACTIVE_TCP_TARGETS="${PING_WATCHDOG_MIN_TCP_TARGETS:-3}"
MAX_PROBE_REFRESH_ATTEMPTS="${PING_WATCHDOG_MAX_PROBE_REFRESH_ATTEMPTS:-18}"
PROBE_CACHE_TTL="${PING_WATCHDOG_PROBE_CACHE_TTL:-86400}"
REQUIRE_PING_FAILURE="${PING_WATCHDOG_REQUIRE_PING_FAILURE:-0}"
ALLOW_UNVERIFIED_PROXY_PORTS="${PING_WATCHDOG_ALLOW_UNVERIFIED_PROXY_PORTS:-0}"
LOG_MAX_BYTES="${PING_WATCHDOG_LOG_MAX_BYTES:-262144}"
LOG_BACKUPS="${PING_WATCHDOG_LOG_BACKUPS:-1}"
LOCK_TTL="${PING_WATCHDOG_LOCK_TTL:-300}"

ZSTATIC_DATA_URL="${PING_WATCHDOG_ZSTATIC_DATA_URL:-https://lf3-ips.zstaticcdn.com/nodes_data.js}"
USER_TCP_TARGETS="${PING_WATCHDOG_TCP_TARGETS:-}"

CONFIG_DIR="${PING_WATCHDOG_CONFIG_DIR:-$HOME/.config/ping-watchdog}"
CONFIG_FILE="$CONFIG_DIR/api_url"
STATE_DIR="${PING_WATCHDOG_STATE_DIR:-$CONFIG_DIR/state}"
LOG_FILE="${PING_WATCHDOG_LOG_FILE:-$HOME/.ping-watchdog.log}"
CRON_TAG="# ping-watchdog-818198"

FAIL_COUNT_FILE="$STATE_DIR/fail_count"
LAST_API_FILE="$STATE_DIR/last_api_call"
LAST_IP_FILE="$STATE_DIR/last_ip"
TCP_CACHE_FILE="$STATE_DIR/tcp_targets"
TCP_CACHE_TIME_FILE="$STATE_DIR/tcp_targets_updated_at"
LOCK_DIR="$STATE_DIR/check.lock"
LOCK_TIME_FILE="$LOCK_DIR/created_at"

TCP_METHOD=""
PING_STYLE=""
LAST_TCP_OK=""
LAST_TCP_FAILED=""
LAST_TCP_TARGETS=""
LAST_PING_OK=""
LAST_PING_FAILED=""
LOCAL_PROXY_OPEN=""
LOCAL_PROXY_CLOSED=""
LOCK_HELD=0

now_epoch() {
  date +%s 2>/dev/null || printf '0\n'
}

is_number() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

read_number_file() {
  file=$1
  value=0

  if [ -s "$file" ]; then
    IFS= read -r value < "$file" || value=0
  fi

  if is_number "$value"; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

normalize_runtime_config() {
  is_number "$PING_COUNT" || PING_COUNT=3
  is_number "$PING_TIMEOUT" || PING_TIMEOUT=3
  is_number "$TCP_TIMEOUT" || TCP_TIMEOUT=3
  is_number "$TCP_MAX_TIME" || TCP_MAX_TIME=6
  is_number "$FAIL_THRESHOLD" || FAIL_THRESHOLD=2
  is_number "$COOLDOWN_SECONDS" || COOLDOWN_SECONDS=900
  is_number "$POST_CHANGE_WAIT" || POST_CHANGE_WAIT=20
  is_number "$MAX_ACTIVE_TCP_TARGETS" || MAX_ACTIVE_TCP_TARGETS=9
  is_number "$MIN_ACTIVE_TCP_TARGETS" || MIN_ACTIVE_TCP_TARGETS=3
  is_number "$MAX_PROBE_REFRESH_ATTEMPTS" || MAX_PROBE_REFRESH_ATTEMPTS=18
  is_number "$PROBE_CACHE_TTL" || PROBE_CACHE_TTL=86400
  is_number "$LOG_MAX_BYTES" || LOG_MAX_BYTES=262144
  is_number "$LOG_BACKUPS" || LOG_BACKUPS=1
  is_number "$LOCK_TTL" || LOCK_TTL=300

  [ "$PING_COUNT" -ge 1 ] || PING_COUNT=1
  [ "$PING_TIMEOUT" -ge 1 ] || PING_TIMEOUT=1
  [ "$TCP_TIMEOUT" -ge 1 ] || TCP_TIMEOUT=1
  [ "$TCP_MAX_TIME" -ge "$TCP_TIMEOUT" ] || TCP_MAX_TIME="$TCP_TIMEOUT"
  [ "$FAIL_THRESHOLD" -ge 1 ] || FAIL_THRESHOLD=1
  [ "$MAX_ACTIVE_TCP_TARGETS" -ge 1 ] || MAX_ACTIVE_TCP_TARGETS=1
  [ "$MIN_ACTIVE_TCP_TARGETS" -ge 1 ] || MIN_ACTIVE_TCP_TARGETS=1
  [ "$MIN_ACTIVE_TCP_TARGETS" -le "$MAX_ACTIVE_TCP_TARGETS" ] || MIN_ACTIVE_TCP_TARGETS="$MAX_ACTIVE_TCP_TARGETS"
  [ "$MAX_PROBE_REFRESH_ATTEMPTS" -ge "$MAX_ACTIVE_TCP_TARGETS" ] || MAX_PROBE_REFRESH_ATTEMPTS="$MAX_ACTIVE_TCP_TARGETS"
  [ "$LOCK_TTL" -ge 60 ] || LOCK_TTL=60
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

rotate_log() {
  if ! is_number "$LOG_MAX_BYTES" || [ "$LOG_MAX_BYTES" -le 0 ]; then
    return 0
  fi

  if [ ! -f "$LOG_FILE" ]; then
    return 0
  fi

  bytes=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  if ! is_number "$bytes" || [ "$bytes" -le "$LOG_MAX_BYTES" ]; then
    return 0
  fi

  if is_number "$LOG_BACKUPS" && [ "$LOG_BACKUPS" -gt 0 ]; then
    mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || : > "$LOG_FILE"
  else
    : > "$LOG_FILE"
  fi
}

log_event() {
  level=$1
  shift

  log_dir=$(dirname "$LOG_FILE")
  mkdir -p "$log_dir" 2>/dev/null || :
  rotate_log
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || :
  rotate_log
}

cleanup_lock() {
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -f "$LOCK_TIME_FILE" 2>/dev/null || :
    rmdir "$LOCK_DIR" 2>/dev/null || :
    LOCK_HELD=0
  fi
}

clear_runtime_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || :
  rm -f "$FAIL_COUNT_FILE" "$LAST_API_FILE" "$LAST_IP_FILE" "$TCP_CACHE_FILE" "$TCP_CACHE_TIME_FILE" 2>/dev/null || :
  rm -f "$LOCK_TIME_FILE" 2>/dev/null || :
  rmdir "$LOCK_DIR" 2>/dev/null || :
}

acquire_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null || :

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    now_epoch > "$LOCK_TIME_FILE" 2>/dev/null || :
    trap 'cleanup_lock' EXIT HUP INT TERM
    return 0
  fi

  lock_time=$(read_number_file "$LOCK_TIME_FILE")
  now=$(now_epoch)

  if [ "$lock_time" -gt 0 ] && [ $((now - lock_time)) -gt "$LOCK_TTL" ]; then
    rm -f "$LOCK_TIME_FILE" 2>/dev/null || :
    rmdir "$LOCK_DIR" 2>/dev/null || :
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_HELD=1
      now_epoch > "$LOCK_TIME_FILE" 2>/dev/null || :
      trap 'cleanup_lock' EXIT HUP INT TERM
      log_event "WARN" "removed stale check lock older than ${LOCK_TTL}s"
      return 0
    fi
  fi

  log_event "WARN" "another check is already running; skip this round"
  return 1
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

detect_tcp_method() {
  if [ -n "$TCP_METHOD" ]; then
    return 0
  fi

  if command -v tcpping >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    if timeout "$TCP_MAX_TIME" tcpping -x 1 1.1.1.1 443 >/dev/null 2>&1; then
      TCP_METHOD="tcpping_x"
      return 0
    fi

    if timeout "$TCP_MAX_TIME" tcpping -c 1 1.1.1.1 443 >/dev/null 2>&1; then
      TCP_METHOD="tcpping_c"
      return 0
    fi
  fi

  if command -v nc >/dev/null 2>&1; then
    if nc -z -w "$TCP_TIMEOUT" 1.1.1.1 443 >/dev/null 2>&1; then
      TCP_METHOD="nc"
      return 0
    fi
  fi

  if command -v bash >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    if timeout "$TCP_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ 1.1.1.1 443 >/dev/null 2>&1; then
      TCP_METHOD="bash"
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -sS -o /dev/null --connect-timeout "$TCP_TIMEOUT" --max-time "$TCP_MAX_TIME" https://www.cloudflare.com/ >/dev/null 2>&1; then
      TCP_METHOD="curl"
      return 0
    fi
  fi

  TCP_METHOD="none"
  return 1
}

tcp_method_supports_generic_ports() {
  detect_tcp_method

  case "$TCP_METHOD" in
    tcpping_x|tcpping_c|nc|bash) return 0 ;;
    *) return 1 ;;
  esac
}

tcp_connect() {
  host=$1
  port=$2

  detect_tcp_method

  case "$TCP_METHOD" in
    tcpping_x)
      timeout "$TCP_MAX_TIME" tcpping -x 1 "$host" "$port" >/dev/null 2>&1
      ;;
    tcpping_c)
      timeout "$TCP_MAX_TIME" tcpping -c 1 "$host" "$port" >/dev/null 2>&1
      ;;
    nc)
      nc -z -w "$TCP_TIMEOUT" "$host" "$port" >/dev/null 2>&1
      ;;
    bash)
      timeout "$TCP_TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1
      ;;
    curl)
      case "$port" in
        80)
          curl -sS -o /dev/null --connect-timeout "$TCP_TIMEOUT" --max-time "$TCP_MAX_TIME" "http://$host/" >/dev/null 2>&1
          ;;
        443)
          curl -k -sS -o /dev/null --connect-timeout "$TCP_TIMEOUT" --max-time "$TCP_MAX_TIME" "https://$host/" >/dev/null 2>&1
          ;;
        *)
          return 2
          ;;
      esac
      ;;
    *)
      return 2
      ;;
  esac
}

tcp_endpoint_ok() {
  endpoint=$1
  host=${endpoint%:*}
  port=${endpoint##*:}

  if [ -z "$host" ] || [ -z "$port" ] || [ "$host" = "$port" ]; then
    return 1
  fi

  tcp_connect "$host" "$port"
}

fetch_zstatic_targets() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
    return 0
  fi

  curl -fsS --connect-timeout 5 --max-time 10 "$ZSTATIC_DATA_URL" 2>/dev/null |
    grep -Eo '[a-z0-9-]+\.ip\.zstaticcdn\.com:[0-9]+' 2>/dev/null || :
}

candidate_tcp_targets() {
  seen=""

  for endpoint in $USER_TCP_TARGETS $PREFERRED_TCP_TARGETS $(fetch_zstatic_targets); do
    case "$endpoint" in
      *:*) ;;
      *) continue ;;
    esac

    case " $seen " in
      *" $endpoint "*) ;;
      *)
        printf '%s\n' "$endpoint"
        seen="$seen $endpoint"
        ;;
    esac
  done
}

refresh_probe_cache() {
  mkdir -p "$STATE_DIR" 2>/dev/null || :
  detect_tcp_method

  if [ "$TCP_METHOD" = "none" ]; then
    log_event "WARN" "no TCP probe method available; cannot refresh probe cache"
    return 1
  fi

  tmp_cache=$(mktemp 2>/dev/null) || return 1
  count=0
  attempted=0

  for endpoint in $(candidate_tcp_targets); do
    if [ "$count" -ge "$MAX_ACTIVE_TCP_TARGETS" ]; then
      break
    fi

    if [ "$attempted" -ge "$MAX_PROBE_REFRESH_ATTEMPTS" ]; then
      break
    fi

    attempted=$((attempted + 1))

    if tcp_endpoint_ok "$endpoint"; then
      printf '%s\n' "$endpoint" >> "$tmp_cache"
      count=$((count + 1))
    fi
  done

  if [ "$count" -ge "$MIN_ACTIVE_TCP_TARGETS" ]; then
    mv "$tmp_cache" "$TCP_CACHE_FILE"
    now_epoch > "$TCP_CACHE_TIME_FILE"
    log_event "INFO" "TCP probe cache refreshed: targets=$count method=$TCP_METHOD"
    return 0
  fi

  rm -f "$tmp_cache"
  log_event "WARN" "TCP probe cache refresh found only $count usable targets after $attempted attempts; keeping existing cache"
  return 1
}

probe_cache_stale() {
  if [ ! -s "$TCP_CACHE_FILE" ]; then
    return 0
  fi

  updated_at=$(read_number_file "$TCP_CACHE_TIME_FILE")
  now=$(now_epoch)

  if ! is_number "$PROBE_CACHE_TTL" || [ "$PROBE_CACHE_TTL" -le 0 ]; then
    return 1
  fi

  if [ $((now - updated_at)) -ge "$PROBE_CACHE_TTL" ]; then
    return 0
  fi

  return 1
}

get_active_tcp_targets() {
  if probe_cache_stale; then
    refresh_probe_cache >/dev/null 2>&1 || :
  fi

  if [ -s "$TCP_CACHE_FILE" ]; then
    cat "$TCP_CACHE_FILE"
    return 0
  fi

  count=0
  for endpoint in $USER_TCP_TARGETS $PREFERRED_TCP_TARGETS; do
    if [ "$count" -ge "$MAX_ACTIVE_TCP_TARGETS" ]; then
      break
    fi

    printf '%s\n' "$endpoint"
    count=$((count + 1))
  done
}

detect_ping_style() {
  if [ -n "$PING_STYLE" ]; then
    return 0
  fi

  if ! command -v ping >/dev/null 2>&1; then
    PING_STYLE="none"
    return 1
  fi

  if ping -4 -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
    PING_STYLE="linux4"
    return 0
  fi

  if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
    PING_STYLE="linux"
    return 0
  fi

  if ping -c 1 127.0.0.1 >/dev/null 2>&1; then
    PING_STYLE="basic"
    return 0
  fi

  PING_STYLE="none"
  return 1
}

ping_target_ok() {
  target=$1
  detect_ping_style || return 1

  case "$PING_STYLE" in
    linux4) ping -4 -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 ;;
    linux) ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1 ;;
    basic) ping -c "$PING_COUNT" "$target" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

ping_any_ok() {
  LAST_PING_OK=""
  LAST_PING_FAILED=""

  if ! detect_ping_style; then
    LAST_PING_FAILED="ping_unavailable"
    return 1
  fi

  for target in $PING_TARGETS; do
    if ping_target_ok "$target"; then
      LAST_PING_OK="$target"
      return 0
    fi

    LAST_PING_FAILED="$LAST_PING_FAILED $target"
  done

  return 1
}

tcp_any_ok() {
  for endpoint in $1; do
    if tcp_endpoint_ok "$endpoint"; then
      return 0
    fi
  done

  return 1
}

domestic_tcp_any_ok() {
  LAST_TCP_OK=""
  LAST_TCP_FAILED=""
  LAST_TCP_TARGETS=""
  targets=$(get_active_tcp_targets)

  if [ -z "$targets" ]; then
    LAST_TCP_FAILED="no_targets"
    return 1
  fi

  for endpoint in $targets; do
    LAST_TCP_TARGETS="$LAST_TCP_TARGETS $endpoint"

    if tcp_endpoint_ok "$endpoint"; then
      LAST_TCP_OK="$endpoint"
      return 0
    fi

    LAST_TCP_FAILED="$LAST_TCP_FAILED $endpoint"
  done

  return 1
}

international_ok() {
  tcp_any_ok "$INTERNATIONAL_TARGETS"
}

port_listening_by_command() {
  port=$1

  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep "[.:]$port[[:space:]]" >/dev/null 2>&1
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep "[.:]$port[[:space:]]" >/dev/null 2>&1
    return $?
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  return 2
}

local_proxy_ports_ok() {
  LOCAL_PROXY_OPEN=""
  LOCAL_PROXY_CLOSED=""
  supported=0

  for port in $PROXY_PORTS; do
    port_listening_by_command "$port"
    status=$?

    if [ "$status" -eq 2 ]; then
      if tcp_method_supports_generic_ports; then
        supported=1
        if tcp_connect 127.0.0.1 "$port"; then
          LOCAL_PROXY_OPEN="$LOCAL_PROXY_OPEN $port"
        else
          LOCAL_PROXY_CLOSED="$LOCAL_PROXY_CLOSED $port"
        fi
      else
        return 2
      fi
    else
      supported=1
      if [ "$status" -eq 0 ]; then
        LOCAL_PROXY_OPEN="$LOCAL_PROXY_OPEN $port"
      else
        LOCAL_PROXY_CLOSED="$LOCAL_PROXY_CLOSED $port"
      fi
    fi
  done

  if [ "$supported" -eq 0 ]; then
    return 2
  fi

  if [ -n "$LOCAL_PROXY_OPEN" ]; then
    return 0
  fi

  return 1
}

get_fail_count() {
  read_number_file "$FAIL_COUNT_FILE"
}

set_fail_count() {
  mkdir -p "$STATE_DIR" 2>/dev/null || :
  printf '%s\n' "$1" > "$FAIL_COUNT_FILE"
}

reset_fail_count() {
  old_count=$(get_fail_count)
  set_fail_count 0
  printf '%s\n' "$old_count"
}

increment_fail_count() {
  old_count=$(get_fail_count)
  new_count=$((old_count + 1))
  set_fail_count "$new_count"
  printf '%s\n' "$new_count"
}

cooldown_remaining() {
  last_api=$(read_number_file "$LAST_API_FILE")
  now=$(now_epoch)

  if [ "$last_api" -le 0 ] || ! is_number "$COOLDOWN_SECONDS" || [ "$COOLDOWN_SECONDS" -le 0 ]; then
    return 1
  fi

  elapsed=$((now - last_api))
  if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
    printf '%s\n' $((COOLDOWN_SECONDS - elapsed))
    return 0
  fi

  return 1
}

get_public_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip; do
    ip=$(curl -fsS --connect-timeout 3 --max-time 8 "$url" 2>/dev/null | tr -d ' \r\n')

    case "$ip" in
      ''|*[!0-9a-fA-F:.]*) ;;
      *.*.*.*|*:*)
        printf '%s\n' "$ip"
        return 0
        ;;
      *)
        ;;
    esac
  done

  return 1
}

remember_public_ip() {
  ip=$1

  if [ -n "$ip" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || :
    printf '%s\n' "$ip" > "$LAST_IP_FILE"
  fi
}

trigger_change_api() {
  old_ip=$1
  now=$(now_epoch)

  mkdir -p "$STATE_DIR" 2>/dev/null || :
  printf '%s\n' "$now" > "$LAST_API_FILE"

  log_event "FAIL" "suspected blocked confirmed: fail_count=$(get_fail_count) ip=${old_ip:-unknown}; calling API"

  if curl -fsS --max-time 30 "$API_URL" >/dev/null 2>&1; then
    log_event "INFO" "API call succeeded"

    if is_number "$POST_CHANGE_WAIT" && [ "$POST_CHANGE_WAIT" -gt 0 ]; then
      sleep "$POST_CHANGE_WAIT"
    fi

    new_ip=$(get_public_ip || :)
    if [ -n "$new_ip" ]; then
      remember_public_ip "$new_ip"

      if [ -n "$old_ip" ] && [ "$old_ip" != "$new_ip" ]; then
        log_event "INFO" "public IP changed: $old_ip -> $new_ip"
      elif [ -n "$old_ip" ]; then
        log_event "WARN" "API call finished but public IP is unchanged: $new_ip"
      else
        log_event "INFO" "current public IP after API call: $new_ip"
      fi
    else
      log_event "WARN" "API call finished but current public IP could not be detected"
    fi

    set_fail_count 0
    return 0
  fi

  status=$?
  log_event "ERROR" "API call failed: curl_exit=$status"
  exit "$status"
}

install_cron() {
  self=$(script_path)
  cron_cmd="*/2 * * * * /bin/sh \"$self\" --check $CRON_TAG"
  old_cron_tag="# ping-watchdog-183.47.126.35"

  require_command curl
  require_command crontab
  require_command mktemp
  require_command grep

  mkdir -p "$STATE_DIR"
  detect_tcp_method

  current_cron=$(mktemp)
  next_cron=$(mktemp)
  trap 'rm -f "$current_cron" "$next_cron"' EXIT HUP INT TERM

  crontab -l > "$current_cron" 2>/dev/null || :
  grep -F -v "$CRON_TAG" "$current_cron" | grep -F -v "$old_cron_tag" > "$next_cron" || :
  printf '%s\n' "$cron_cmd" >> "$next_cron"
  crontab "$next_cron"

  clear_runtime_state
  refresh_probe_cache >/dev/null 2>&1 || :

  printf '已部署：每 2 分钟检查一次，连续 %s 次疑似被墙时 curl 配置的 API。\n' "$FAIL_THRESHOLD"
  printf '代理端口：%s\n' "$PROXY_PORTS"
  printf 'TCP 探测方式：%s\n' "$TCP_METHOD"
  printf 'API 配置文件：%s\n' "$CONFIG_FILE"
  printf '状态目录：%s\n' "$STATE_DIR"
  printf '日志文件：%s（超过 %s 字节自动滚动）\n' "$LOG_FILE" "$LOG_MAX_BYTES"
}

check_once() {
  load_api_url
  require_command curl
  mkdir -p "$STATE_DIR" 2>/dev/null || :
  acquire_lock || exit 0
  detect_tcp_method

  local_proxy_ports_ok
  proxy_status=$?
  case "$proxy_status" in
    0)
      ;;
    1)
      old_count=$(reset_fail_count)
      log_event "WARN" "proxy ports not listening: ports=$PROXY_PORTS closed=$LOCAL_PROXY_CLOSED; skip block decision"
      if [ "$old_count" -gt 0 ]; then
        log_event "INFO" "failure counter reset because local proxy ports are unavailable"
      fi
      exit 0
      ;;
    2)
      old_count=$(reset_fail_count)
      log_event "WARN" "no local port checker available for proxy ports=$PROXY_PORTS; skip block decision"
      if [ "$old_count" -gt 0 ]; then
        log_event "INFO" "failure counter reset because local proxy ports cannot be verified"
      fi

      if [ "$ALLOW_UNVERIFIED_PROXY_PORTS" = "1" ]; then
        log_event "WARN" "PING_WATCHDOG_ALLOW_UNVERIFIED_PROXY_PORTS=1; continuing without local proxy verification"
      else
        exit 0
      fi
      ;;
  esac

  if ! international_ok; then
    old_count=$(reset_fail_count)
    log_event "WARN" "international connectivity failed: targets=$INTERNATIONAL_TARGETS; skip block decision"
    if [ "$old_count" -gt 0 ]; then
      log_event "INFO" "failure counter reset because international connectivity is unavailable"
    fi
    exit 0
  fi

  ping_ok=1
  if ping_any_ok; then
    ping_ok=0
  fi

  tcp_ok=1
  if domestic_tcp_any_ok; then
    tcp_ok=0
  fi

  suspected=0
  if [ "$tcp_ok" -ne 0 ]; then
    suspected=1
    if [ "$REQUIRE_PING_FAILURE" = "1" ] && [ "$ping_ok" -eq 0 ]; then
      suspected=0
    fi
  fi

  if [ "$suspected" -eq 0 ]; then
    old_count=$(reset_fail_count)

    if [ "$old_count" -gt 0 ]; then
      current_ip=$(get_public_ip || :)
      remember_public_ip "$current_ip"
      log_event "INFO" "connectivity recovered: fail_count_was=$old_count tcp_ok=${LAST_TCP_OK:-none} ping_ok=${LAST_PING_OK:-none} ip=${current_ip:-unknown}"
    fi

    exit 0
  fi

  fail_count=$(increment_fail_count)
  current_ip=$(get_public_ip || :)
  remember_public_ip "$current_ip"
  log_event "WARN" "suspected blocked: fail_count=$fail_count threshold=$FAIL_THRESHOLD ip=${current_ip:-unknown} tcp_failed=\"$LAST_TCP_FAILED\" ping_ok=${LAST_PING_OK:-none} ping_failed=\"$LAST_PING_FAILED\" proxy_open=\"$LOCAL_PROXY_OPEN\" method=$TCP_METHOD"

  if [ "$fail_count" -lt "$FAIL_THRESHOLD" ]; then
    exit 0
  fi

  remaining=$(cooldown_remaining || :)
  if [ -n "$remaining" ]; then
    log_event "WARN" "cooldown active: remaining=${remaining}s; skip API call"
    exit 0
  fi

  trigger_change_api "$current_ip"
}

force_change() {
  load_api_url
  require_command curl
  mkdir -p "$STATE_DIR" 2>/dev/null || :
  current_ip=$(get_public_ip || :)
  set_fail_count "$FAIL_THRESHOLD"
  trigger_change_api "$current_ip"
}

show_status() {
  detect_tcp_method

  printf '配置文件：%s\n' "$CONFIG_FILE"
  printf '状态目录：%s\n' "$STATE_DIR"
  printf '日志文件：%s\n' "$LOG_FILE"
  printf '代理端口：%s\n' "$PROXY_PORTS"
  printf '连续失败阈值：%s\n' "$FAIL_THRESHOLD"
  printf '冷却时间：%s 秒\n' "$COOLDOWN_SECONDS"
  printf 'TCP 探测方式：%s\n' "$TCP_METHOD"
  printf '当前失败计数：%s\n' "$(get_fail_count)"

  if [ -s "$TCP_CACHE_FILE" ]; then
    printf '已缓存 TCP 探测点：\n'
    sed 's/^/  /' "$TCP_CACHE_FILE"
  else
    printf '已缓存 TCP 探测点：无\n'
  fi
}

main() {
  normalize_runtime_config

  case "${1:-}" in
    --check)
      check_once
      ;;
    --install|"")
      if [ ! -s "$CONFIG_FILE" ]; then
        printf '请输入疑似被墙时要 curl 的 API URL：'
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
    --refresh-probes)
      require_command curl
      require_command mktemp
      refresh_probe_cache
      ;;
    --force-change)
      force_change
      ;;
    --status)
      show_status
      ;;
    --help|-h)
      cat <<EOF
用法：
  sh $(basename "$0")                 首次配置 API，并部署每 2 分钟执行一次
  sh $(basename "$0") --install        重新部署 cron，不重复询问已保存的 API
  sh $(basename "$0") --check          执行一次检查，供 cron 调用
  sh $(basename "$0") --reset-api      修改 API 并重新部署 cron
  sh $(basename "$0") --refresh-probes 刷新 zstaticcdn TCP 探测点缓存
  sh $(basename "$0") --force-change   立刻调用 API 换 IP
  sh $(basename "$0") --status         查看当前配置与状态

常用环境变量：
  PING_WATCHDOG_PROXY_PORTS="5001 5002 5003 5004 5005"
  PING_WATCHDOG_FAIL_THRESHOLD=2
  PING_WATCHDOG_COOLDOWN_SECONDS=900
  PING_WATCHDOG_LOG_MAX_BYTES=262144
  PING_WATCHDOG_REQUIRE_PING_FAILURE=1  # 启用更严格模式：TCP 和 ping 都全失败才换 IP
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
