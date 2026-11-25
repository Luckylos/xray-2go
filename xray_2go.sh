#!/usr/bin/env bash
# ==============================================================================
# xray-2go — 插件化代理管理脚本
# 安全基线：输入校验 · 敏感文件保护 · 原子写入 · 服务互斥 · 可回滚清理
# 协议支持：Argo · FreeFlow · Reality · VLESS-TCP · SOCKS5 · HTTP · Shadowsocks 2022 · VLESS-XHTTP-H3（均以插件形式加载）
# 平台支持：Debian/Ubuntu/RHEL系 (systemd) · Alpine (OpenRC；Argo/cloudflared 需用户预装官方 cloudflared)
# ==============================================================================
set -uo pipefail  # 交互菜单使用显式返回值处理，避免 set -e 造成误退出
[ "${BASH_VERSINFO[0]}" -ge 4 ] \
    || { printf '\033[1;91m[ERR ] 需要 bash 4.0 或更高版本\033[0m\n' >&2; exit 1; }

# 在部分 curl/进程替换执行环境中，HOME 可能未导出；统一在脚本最早阶段回退，避免 set -u 下访问 HOME 直接中断。
if [ -z "${HOME:-}" ]; then
    _DETECTED_HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
    [ -n "${_DETECTED_HOME:-}" ] || _DETECTED_HOME=$(awk -F: -v uid="$(id -u)" '$3==uid{print $6; exit}' /etc/passwd 2>/dev/null || true)
    [ -n "${_DETECTED_HOME:-}" ] || _DETECTED_HOME="/root"
    export HOME="${_DETECTED_HOME}"
fi
unset _DETECTED_HOME 2>/dev/null || true

# ==============================================================================
# Global constants
# ==============================================================================
# 仅在显式测试模式下允许 runtime probe 注入临时 root；生产默认值保持不变。
if [ "${X2G_TEST_MODE:-0}" = "1" ]; then
    [ -n "${X2G_TEST_ROOT:-}" ] || {
        printf '%s\n' '[ERR ] X2G_TEST_MODE=1 时必须提供 X2G_TEST_ROOT' >&2
        exit 2
    }
    case "${X2G_TEST_ROOT}" in
        /*) : ;;
        *) printf '%s\n' '[ERR ] X2G_TEST_ROOT 必须是绝对路径' >&2; exit 2 ;;
    esac
    _X2G_ROOT="${X2G_TEST_ROOT%/}"
    [ -n "${_X2G_ROOT}" ] && [ "${_X2G_ROOT}" != "/" ] || {
        printf '%s\n' '[ERR ] X2G_TEST_ROOT 不得指向宿主根目录' >&2
        exit 2
    }
else
    _X2G_ROOT=""
fi
readonly _X2G_ROOT

readonly WORK_DIR="${_X2G_ROOT}/etc/xray2go"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly PLUGIN_DIR="${WORK_DIR}/plugins"
readonly SHORTCUT="${_X2G_ROOT}/usr/local/bin/s"
readonly SELF_DEST="${_X2G_ROOT}/usr/local/bin/xray2go"

readonly _LOCK_FILE="${WORK_DIR}.lock"
readonly _UNINSTALL_PENDING="${WORK_DIR}/.uninstall_pending"
readonly _FW_PORTS_FILE="${WORK_DIR}/.fw_ports"
readonly _FW_RULES_FILE="${WORK_DIR}/.fw_rules"
readonly _CONFIG_HASH_FILE="${WORK_DIR}/.config.sha256"
readonly _SYSCTL_FILE="${_X2G_ROOT}/etc/sysctl.d/99-xray2go.conf"
readonly _SVC_SYSTEMD_DIR="${_X2G_ROOT}/etc/systemd/system"
readonly _SVC_OPENRC_DIR="${_X2G_ROOT}/etc/init.d"
readonly _HOSTS_BAK="${WORK_DIR}/.hosts.bak"
readonly _HOSTS_FILE="${_X2G_ROOT}/etc/hosts"
readonly _ARGO_ENV_FILE="${WORK_DIR}/.argo_env"
readonly _ACME_ENV_FILE="${WORK_DIR}/.acme_env"
readonly _CERT_DIR="${WORK_DIR}/certs"

readonly _SVC_XRAY="xray2go"
readonly _SVC_TUNNEL="tunnel2go"

readonly _XRAY_MIRRORS=(
    "https://github.com/XTLS/Xray-core/releases/download"
)

readonly _XPAD_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"X-Cache","xPaddingKey":"_Luckylos"}'

# 动态插件注册表（由 plugin_load_all 填充，非 readonly）
_PLUGIN_REGISTRY=()
declare -A _PLUGIN_FUNCTIONS=()
readonly -a _BUILTIN_PLUGINS=(argo ff reality vltcp socks ss2022 http vlquic cforigin)
# 插件快照缓存（按当前 state stamp 复用，避免重复遍历 registry）
_PLUGIN_SNAPSHOT_STAMP=""
_PLUGIN_SNAPSHOT_PORTS=""
_PLUGIN_SNAPSHOT_INBOUNDS=""

# ==============================================================================
# Temporary workspace
# ==============================================================================
_G_TMP_DIR=""
_TXN_ACTIVE=0
_TXN_DIR=""
_TXN_LOCK_FD=""
_TXN_PRE_STATE=""
_TXN_PRE_STATE_BASE=""
_TXN_PRE_STATE_DISK=""
_TXN_PRE_XRAY_ACTIVE=0
_TXN_XRAY_RESTART_ATTEMPTED=0
_TXN_PRE_TUNNEL_ACTIVE=0
_TXN_TUNNEL_RESTART_ATTEMPTED=0
_TXN_PRE_XRAY_ENABLED=0
_TXN_PRE_TUNNEL_ENABLED=0
_FW_SCOPE_DIR=""
declare -A _FW_LEDGER_STATE=()
_FW_SEQUENCE=0
_FW_RECORD_FAILED=0
_TXN_ARTIFACT_PATHS=()
_UPDATE_PID=""

trap '_trap_exit' EXIT
trap '_trap_int'  INT TERM

_trap_exit() {
    if [ -n "${_TXN_DIR:-}" ]; then log_warn "事务快照保留于：${_TXN_DIR}"; fi
    [ -n "${_G_TMP_DIR:-}" ] && rm -rf "${_G_TMP_DIR}" 2>/dev/null || true
    [ -t 1 ] && tput cnorm 2>/dev/null || true
}
_trap_int() {
    if [ -n "${_UPDATE_PID}" ]; then
        trap '' INT TERM
        kill -TERM "${_UPDATE_PID}" 2>/dev/null || true
        wait "${_UPDATE_PID}" 2>/dev/null || true
    fi
    if [ "${_TXN_ACTIVE:-0}" -eq 1 ]; then
        local _keep_snapshot=0
        trap '' INT TERM
        _transaction_rollback || _keep_snapshot=1
        _transaction_end "${_keep_snapshot}"
    fi
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

_ensure_tmp_dir() {
    if [ -z "${_G_TMP_DIR:-}" ]; then
        mkdir -p "${WORK_DIR}" 2>/dev/null || true
        _G_TMP_DIR=$(mktemp -d "${WORK_DIR}/.tmp_XXXXXX") \
            || { printf '\033[1;91m[ERR ] 无法在 %s 创建临时目录\033[0m\n' "${WORK_DIR}" >&2; exit 1; }
    fi
}

tmp_file() { _ensure_tmp_dir; mktemp "${_G_TMP_DIR}/${1:-tmp_XXXXXX}"; }

# ==============================================================================
# Logging and string utilities
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf '%s[INFO]%s %s\n'  "${C_CYN}" "${C_RST}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'  "${C_GRN}" "${C_RST}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "${C_YLW}" "${C_RST}" "$*" >&2; }
log_error() { printf '%s[ERR ]%s %s\n'  "${C_RED}" "${C_RST}" "$*" >&2; }
log_step()  { printf '%s[....] %s%s\n'  "${C_PUR}" "$*" "${C_RST}"; }
log_title() { printf '\n%s%s%s\n'       "${C_BOLD}${C_PUR}" "$*" "${C_RST}"; }
die()       { log_error "$1"; exit "${2:-1}"; }

prompt() {
    printf '%s%s%s' "${C_RED}" "$1" "${C_RST}" >&2
    if [ "$#" -ge 3 ]; then
        read -e -r -i "$3" "$2" </dev/tty
    else
        read -r "$2" </dev/tty
    fi
}

prompt_secret() {
    local _prompt_status=0
    read -r -s -p "${C_RED}$1${C_RST}" "$2" </dev/tty || _prompt_status=$?
    printf '\n' >&2
    return "${_prompt_status}"
}

redact_sensitive() {
    python3 -c '
import re, sys
text = sys.stdin.read()
patterns = [
    (r"(Authorization:\\s*Bearer\\s+)[^\\s\"'"'"']+", r"\\1<redacted>"),
    (r"(CF_Token=)['"'"']?[^\\s'"'"']+['"'"']?", r"\\1<redacted>"),
    (r"(CF_Key=)['"'"']?[^\\s'"'"']+['"'"']?", r"\\1<redacted>"),
    (r"(TUNNEL_TOKEN=)[A-Za-z0-9_=.-]{20,}", r"\\1<redacted>"),
    (r"(token[\"'"'"'=:\\s]+)[A-Za-z0-9_=.-]{20,}", r"\\1<redacted>"),
]
for pattern, repl in patterns:
    text = re.sub(pattern, repl, text, flags=re.I)
sys.stdout.write(text)
'
}
_pause() {
    local _d
    printf '%s按回车键继续...%s' "${C_RED}" "${C_RST}" >&2
    read -r _d </dev/tty || true
}
_hr() { printf '%s  ──────────────────────────────────%s\n' "${C_PUR}" "${C_RST}"; }

_print_link() {
    local _link="$1"
    [ -n "${_link:-}" ] && printf '%s%s%s\n' "${C_CYN}" "${_link}" "${C_RST}"
}

urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;
         s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;
         s/\[/%5B/g;s/\]/%5D/g;s|/|%2F|g'
}

# ==============================================================================
# Platform detection and package helpers
# ==============================================================================
_G_INIT_SYS="" _G_ARCH_CF="" _G_ARCH_XRAY="" _G_CACHED_REALIP=""

platform_detect_init() {
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
        log_warn "检测到容器环境，服务管理功能可能受限"
    fi
    local _pid1_comm
    _pid1_comm=$(cat /proc/1/comm 2>/dev/null | tr -d '\n' || printf 'unknown')
    if [ "${_pid1_comm}" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        _G_INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _G_INIT_SYS="openrc"
    else
        die "不支持的 init 系统（PID 1: ${_pid1_comm}）"
    fi
}
is_systemd() { [ "${_G_INIT_SYS}" = "systemd" ]; }
is_openrc()  { [ "${_G_INIT_SYS}" = "openrc"  ]; }

platform_detect_arch() {
    [ -n "${_G_ARCH_XRAY:-}" ] && return 0
    case "$(uname -m)" in
        x86_64)        _G_ARCH_CF="amd64";  _G_ARCH_XRAY="64"        ;;
        x86|i686|i386) _G_ARCH_CF="386";    _G_ARCH_XRAY="32"        ;;
        aarch64|arm64) _G_ARCH_CF="arm64";  _G_ARCH_XRAY="arm64-v8a" ;;
        armv7l)        _G_ARCH_CF="armv7";  _G_ARCH_XRAY="arm32-v7a" ;;
        s390x)         _G_ARCH_CF="s390x";  _G_ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

platform_pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    local _rc=0
    if command -v apt-get >/dev/null 2>&1; then
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null; then
            log_step "刷新 APT 软件包索引后重试: ${_pkg}"
            if DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null || _rc=$?
            else
                log_error "APT 软件包索引刷新失败"
                _rc=1
            fi
        fi
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null || _rc=$?
    elif command -v yum >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null || _rc=$?
    elif command -v apk >/dev/null 2>&1; then apk add       "${_pkg}" >/dev/null || _rc=$?
    else
        log_error "未找到包管理器"
        return 1
    fi
    hash -r 2>/dev/null || true
    [ "${_rc}" -eq 0 ] || { log_error "${_pkg} 安装失败"; return 1; }
    command -v "${_bin}" >/dev/null 2>&1 || { log_error "${_bin} 安装后仍不可用"; return 1; }
    log_ok "${_pkg} 已就绪"
}

platform_preflight() {
    log_step "依赖预检..."
    local _d
    for _d in curl unzip jq; do platform_pkg_require "${_d}" || return 1; done
    command -v xxd    >/dev/null 2>&1 || platform_pkg_require "xxd" "xxd" 2>/dev/null \
        || log_info "xxd 未安装，shortId 将使用内置随机源"
    command -v openssl >/dev/null 2>&1 || log_info "openssl 未安装，shortId 将使用内置随机源"
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已设置 xray 可执行权限"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏"
    fi
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已设置 cloudflared 可执行权限"; }
    log_ok "依赖预检通过"
}

platform_get_realip() {
    [ -n "${_G_CACHED_REALIP:-}" ] && { printf '%s' "${_G_CACHED_REALIP}"; return 0; }
    local _ip _org _v6 _result=""
    _ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${_ip:-}" ]; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && _result="[${_v6}]"
    else
        _org=$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null) || true
        if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
            _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
            [ -n "${_v6:-}" ] && _result="[${_v6}]" || _result="${_ip}"
        else
            _result="${_ip}"
        fi
    fi
    _G_CACHED_REALIP="${_result}"
    printf '%s' "${_G_CACHED_REALIP}"
}

platform_fix_time_sync() {
    [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || return 0
    local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
    log_step "RHEL 系：修正时间同步..."
    ${_pm} install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    ${_pm} update -y ca-certificates >/dev/null 2>&1 || true
    log_ok "时间同步已修正"
}

check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

# ==============================================================================
# §L_PORT  Port Manager — 精确端口检测唯一入口
# ==============================================================================
port_mgr_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    local _hex; _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" \
        'NR>1{n=split($2,a,":");if(a[n]==h){found=1;exit}}END{exit !found}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

port_mgr_in_use_udp() {
    local _p="${1}"
    if command -v ss >/dev/null 2>&1; then
        ss -ulnH 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ulnp 2>/dev/null | awk -v p="${_p}" \
            'BEGIN{r=0}{split($4,a,":");if(a[length(a)]==p){r=1;exit}}END{exit !r}'
        return $?
    fi
    local _hex; _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" \
        'NR>1{n=split($2,a,":");if(a[n]==h){found=1;exit}}END{exit !found}' \
        /proc/net/udp /proc/net/udp6 2>/dev/null
}

# SS2022 binds the same number in both TCP and UDP; a port is available only
# when neither protocol currently has a listener.
port_mgr_in_use_both() {
    local _p="${1}"
    port_mgr_in_use "${_p}" && return 0
    port_mgr_in_use_udp "${_p}"
}

port_mgr_random() {
    port_mgr_random_proto tcp
}

port_mgr_random_proto() {
    local _proto="${1:-tcp}"
    local _i=0 _p
    case "${_proto}" in tcp|udp|both) : ;; *) log_error "未知端口协议: ${_proto}"; return 1 ;; esac
    while true; do
        _p=$(shuf -i 10000-60000 -n 1 2>/dev/null \
             || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
        _i=$(( _i + 1 ))
        case "${_proto}" in
            udp) port_mgr_in_use_udp "${_p}" || { printf '%s' "${_p}"; return 0; } ;;
            tcp) port_mgr_in_use     "${_p}" || { printf '%s' "${_p}"; return 0; } ;;
            both) port_mgr_in_use_both "${_p}" || { printf '%s' "${_p}"; return 0; } ;;
        esac
        [ "${_i}" -gt 30 ] && { log_error "无法找到空闲 ${_proto^^} 端口"; return 1; }
    done
}

# ==============================================================================
# State management
# ==============================================================================
_G_STATE=""
_G_STATE_DISK=""
_G_STATE_BASE=""
_CFORIGIN_ISSUE=()
_VLQUIC_ISSUE=()

# 当前 state schema：端口和协议状态集中管理
# 加载 state 时自动规范化 schema
readonly _STATE_DEFAULT='{
  "uuid": "",
  "ports": {
    "argo":    18888,
    "ff":      8080,
    "reality": 443,
    "vltcp":   1234,
    "vlquic":  443,
    "cforigin": 28888,
    "socks":   1080,
    "http":    1081,
    "ss2022": 8388
  },
  "argo": {
    "enabled":  true,
    "protocol": "ws",
    "auth_protocol": "vless",
    "trojan_password": "",
    "mode":     "fixed",
    "domain":   null,
    "token":    null
  },
  "ff": {
    "enabled":  false,
    "protocol": "none",
    "path":     "/",
    "host":     ""
  },
  "reality": {
    "enabled": false,
    "sni":     "addons.mozilla.org",
    "network": "tcp",
    "pbk":     null,
    "pvk":     null,
    "sid":     null
  },
  "vltcp": {
    "enabled": false,
    "listen":  "0.0.0.0"
  },
  "socks": {
    "enabled": false,
    "listen":  "0.0.0.0",
    "user":    "xray2go",
    "pass":    "xray2go"
  },
  "http": {
    "enabled": false,
    "listen":  "0.0.0.0",
    "user":    "xray2go",
    "pass":    "xray2go"
  },
  "ss2022": {
    "enabled": false,
    "listen":  "0.0.0.0",
    "method":  "2022-blake3-aes-256-gcm",
    "key_mode": "single",
    "server_key": "",
    "user_key":   ""
  },
  "vlquic": {
    "enabled": false,
    "listen":  "0.0.0.0",
    "domain":  "",
    "cert":    "",
    "key":     "",
    "acme_method": "manual"
  },
  "cforigin": {
    "enabled": false,
    "domain":  "",
    "protocol": "ws",
    "path":    "/origin",
    "listen":  "::",
    "edge_port": 443,
    "edge_h3": false,
    "xhttp": null,
    "origin_tls": true,
    "cert":    "",
    "key":     "",
    "acme_method": "manual"
  },
  "xpad": {
    "argo":    true,
    "ff":      true,
    "reality": true
  },
  "cfip":   "cf.tencentapp.cn",
  "cfport": "443"
}'

# ── 原子写入（同 FS tmp → rename）─────────────────────────────────────────────
atomic_write() {
    local _dest="$1" _content="$2"
    mkdir -p "$(dirname "${_dest}")" 2>/dev/null || true
    local _t; _t=$(tmp_file "aw_XXXXXX") || return 1
    printf '%s' "${_content}" > "${_t}" || { rm -f "${_t}"; return 1; }
    mv "${_t}" "${_dest}"              || { rm -f "${_t}"; return 1; }
}

atomic_write_with_backup() {
    local _dest="$1" _content="$2" _keep="${3:-3}"
    if [ -f "${_dest}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${_dest}" "${_dest}.${_ts}.bak" 2>/dev/null || true
        ls -t "${_dest}".*.bak 2>/dev/null \
            | tail -n "+$(( _keep + 1 ))" | xargs rm -f 2>/dev/null || true
    fi
    atomic_write "${_dest}" "${_content}"
}

# 写入敏感文件：同 FS 原子替换 + 强制 0600，避免 state/token/凭证泄露。
atomic_write_secret() {
    local _dest="$1" _content="$2"
    local _old_umask _rc
    _ensure_tmp_dir || return 1
    _old_umask=$(umask)
    umask 077
    atomic_write "${_dest}" "${_content}"
    _rc=$?
    umask "${_old_umask}"
    [ "${_rc}" -eq 0 ] || return "${_rc}"
    chmod 600 "${_dest}" 2>/dev/null || true
}

atomic_write_secret_with_backup() {
    local _dest="$1" _content="$2" _keep="${3:-3}"
    if [ -f "${_dest}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${_dest}" "${_dest}.${_ts}.bak" 2>/dev/null || true
        chmod 600 "${_dest}.${_ts}.bak" 2>/dev/null || true
        ls -t "${_dest}".*.bak 2>/dev/null \
            | tail -n "+$(( _keep + 1 ))" | xargs rm -f 2>/dev/null || true
    fi
    atomic_write_secret "${_dest}" "${_content}"
}

# ── 文件锁（串行化所有 read-modify-write）────────────────────────────────────
with_lock() {
    local _fn="$1"; shift
    if [ "${_TXN_ACTIVE:-0}" -eq 1 ] || [ -n "${_TXN_LOCK_FD}" ]; then
        "${_fn}" "$@"
        return $?
    fi
    command -v flock >/dev/null 2>&1 || { log_error "flock 不可用，拒绝无锁写入"; return 1; }
    mkdir -p "$(dirname "${_LOCK_FILE}")" || return 1
    (
        flock -x 9 || { log_error "获取文件锁失败"; exit 1; }
        _G_TMP_DIR=""
        trap '_trap_exit' EXIT
        "${_fn}" "$@"
    ) 9>"${_LOCK_FILE}"
}


# 修改端口：事务在写 state 之前开始，失败时内存/磁盘状态、配置、服务与防火墙一并回滚。
_commit_port_change_inner() {
    local _proto="$1" _new_port="$2"
    st_set ".ports.${_proto} = (\$p|tonumber)" --arg p "${_new_port}" || return 1
    _commit_inner
}

_commit_port_change() {
    local _proto="$1" _new_port="$2" _net_label="${3:-}"
    _transaction_run "端口更新" _commit_port_change_inner "${_proto}" "${_new_port}" || return 1
    log_ok "$(module_label "${_proto}") 端口已更新: $(port_of "${_proto}")${_net_label:+（${_net_label^^}）}"
    config_print_nodes "${_proto}" || true
}

# ── State 读/写 ───────────────────────────────────────────────────────────────
st_get() {
    local _f="$1" _v
    shift
    _v=$(printf '%s' "${_G_STATE}" | jq -r "$@" "if (${_f}) == null then empty else (${_f}) end" 2>/dev/null) || true
    printf '%s' "${_v}"
}

st_set() {
    local _f="$1"; shift
    local _n
    _n=$(printf '%s' "${_G_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "st_set 失败: ${_f}"; return 1; }
    [ -n "${_n:-}" ] && _G_STATE="${_n}" \
        || { log_error "st_set 返回空 JSON"; return 1; }
}

xpad_of() {
    case "${1:-}" in
        argo|ff|reality) : ;;
        *) log_error "未知 xPadding 目标: ${1:-}"; return 1 ;;
    esac
    local _v
    _v=$(printf '%s' "${_G_STATE}" | jq -r --arg k "${1}" '
        if .xpad[$k] == true then "true"
        elif .xpad[$k] == false then "false"
        else empty end
    ' 2>/dev/null) || true
    [ -n "${_v:-}" ] && printf '%s' "${_v}" || printf 'true'
}

# 统一端口读取接口（单一数据源）
# 所有模块禁止硬编码端口，必须调用此函数
port_of() {
    # 用法：port_of argo / ff / reality / vltcp / vlquic / cforigin / socks / http
    local _v; _v=$(st_get '.ports[$name]' --arg name "$1")
    [ -n "${_v:-}" ] && [ "${_v}" != "null" ] && printf '%s' "${_v}" || printf '0'
}

# ── 输入校验层 ───────────────────────────────────────────────────────────────
# val_port: 限制端口为纯数字 1-65535，防止配置注入
val_port() {
    local _p="$1"
    case "${_p}" in
        ''|*[!0-9]*) log_error "非法端口值: ${_p}"; return 1 ;;
    esac
    [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]         || { log_error "端口超出范围: ${_p}"; return 1; }
    printf '%s' "${_p}"
}

# val_uuid: 严格匹配 UUID v4 格式，防止 JSON 注入
val_uuid() {
    printf '%s' "${1:-}" | grep -qiE         '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'         || { log_error "非法 UUID 格式: ${1:-}"; return 1; }
    printf '%s' "${1}"
}

# val_domain: 防止域名字段注入 YAML 特殊字符
val_domain() {
    printf '%s' "${1:-}" | grep -qE         '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'         || { log_error "非法域名格式: ${1:-}"; return 1; }
    printf '%s' "${1}"
}

# val_path: 路径只允许 / 开头的 URL-safe 字符串
val_path() {
    local _p="${1:-/}"
    case "${_p}" in /*) : ;; *) _p="/${_p}" ;; esac
    printf '%s' "${_p}" | grep -qE '^[/a-zA-Z0-9_.~-]+$'         || { log_error "非法 path 格式: ${_p}"; return 1; }
    printf '%s' "${_p}"
}

# val_listen_addr: 限制 Xray listen 为明确的 IP 监听地址，避免坏 state 导致配置失败
val_listen_addr() {
    local _a="${1:-}"
    case "${_a}" in
        0.0.0.0|127.0.0.1|::|::1) printf '%s' "${_a}"; return 0 ;;
    esac
    if printf '%s' "${_a}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        local IFS=. _o
        for _o in ${_a}; do
            [ "${_o}" -ge 0 ] 2>/dev/null && [ "${_o}" -le 255 ] 2>/dev/null || { log_error "非法监听地址: ${_a}"; return 1; }
        done
        printf '%s' "${_a}"; return 0
    fi
    if printf '%s' "${_a}" | grep -qE '^[0-9A-Fa-f:]+$' && printf '%s' "${_a}" | grep -q ':'; then
        printf '%s' "${_a}"; return 0
    fi
    log_error "非法监听地址: ${_a}"
    return 1
}

val_plugin_name() {
    printf '%s' "${1:-}" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$' \
        || { log_error "插件文件名不合法: ${1:-}"; return 1; }
    printf '%s' "${1}"
}

val_argo_token() {
    local _token="${1:-}"
    [ -z "${_token}" ] || [ "${_token}" = "null" ] && return 0
    printf '%s' "${_token}" | grep -qE '^[A-Za-z0-9=_-]{20,}$' \
        || { log_error "Argo token 格式异常，拒绝写入 env"; return 1; }
    printf '%s' "${_token}"
}

val_argo_auth_state() {
    local _token _cred_b64 _cred
    _token=$(st_get '.argo.token')
    _cred_b64=$(st_get '.argo.cred_b64')
    if [ -n "${_cred_b64:-}" ] && [ "${_cred_b64}" != "null" ]; then
        _cred=$(printf '%s' "${_cred_b64}" | base64 -d 2>/dev/null) \
            || { log_error "Argo JSON 凭证不是合法 Base64"; return 1; }
        printf '%s' "${_cred}" | jq -e '
            type == "object" and
            (((.TunnelID? // "") != "") or ((.AccountTag? // "") != ""))
        ' >/dev/null 2>&1 || {
            log_error "Argo JSON 凭证缺少 TunnelID/AccountTag"; return 1;
        }
        return 0
    fi
    [ -n "${_token:-}" ] && [ "${_token}" != "null" ] \
        || { log_error "Argo 未配置 Tunnel token 或 JSON 凭证"; return 1; }
    val_argo_token "${_token}" >/dev/null || return 1
}

# Trojan 密码字符集的单一真相源：只允许 URL-safe 字符，因此密码不会破坏
# trojan:// 分享链接的 URI 结构（# ? @ & = : / 等都被拒绝）。
trojan_password_is_valid() {
    printf '%s' "${1:-}" | grep -qE '^[A-Za-z0-9._~-]{8,128}$'
}

val_trojan_password() {
    local _password="${1:-}"
    trojan_password_is_valid "${_password}" \
        || { log_error "Trojan 密码格式异常，需为 8-128 位 URL-safe 字符"; return 1; }
    printf '%s' "${_password}"
}

ss2022_method_is_valid() {
    ss2022_key_bytes "$1" >/dev/null
}

val_ss2022_method() {
    ss2022_method_is_valid "$1" \
        || { log_error "SS2022 加密方法不受支持: $1"; return 1; }
    printf '%s' "$1"
}

ss2022_key_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) printf '16' ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) printf '32' ;;
        *) return 1 ;;
    esac
}

val_ss2022_key() {
    local _method="$1" _key="$2" _expected _decoded_bytes
    _expected=$(ss2022_key_bytes "$_method") || {
        log_error "SS2022 加密方法不受支持"; return 1;
    }
    [ -n "$_key" ] && printf '%s' "$_key" | grep -qE '^[A-Za-z0-9+/]+={0,2}$' || {
        log_error "SS2022 密钥格式异常"; return 1;
    }
    _decoded_bytes=$(printf '%s' "$_key" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]') || {
        log_error "SS2022 密钥不是合法 Base64"; return 1;
    }
    [ "$_decoded_bytes" = "$_expected" ] || {
        log_error "SS2022 密钥长度异常（需要 $_expected 字节）"; return 1;
    }
    printf '%s' "$_key"
}

cf_edge_port_valid() {
    case "${1:-}" in
        80|8080|8880|2052|2082|2086|2095|443|2053|2083|2087|2096|8443) return 0 ;;
        *) log_error "Cloudflare 入口端口不在普通橙云支持列表: ${1:-}"; return 1 ;;
    esac
}

cforigin_print_cloudflare_hint() {
    [ "$(st_get '.cforigin.enabled')" = "true" ] || return 0
    local _domain _edge _origin _path _tls _proto _edge_h3
    _domain=$(st_get '.cforigin.domain')
    _edge=$(st_get '.cforigin.edge_port')
    _origin=$(port_of cforigin)
    _path=$(st_get '.cforigin.path')
    _tls=$(st_get '.cforigin.origin_tls')
    _proto=$(st_get '.cforigin.protocol')
    _edge_h3=$(st_get '.cforigin.edge_h3')
    echo ""
    log_title "Cloudflare Origin 回源配置提示"
    printf "  DNS: %s -> VPS IP，Proxy status: Proxied / 橙云\n" "${_domain:-<你的域名>}"
    printf "  Origin Rule: Hostname equals %s -> Destination Port Override: %s\n" "${_domain:-<你的域名>}" "${_origin}"
    printf "  客户端入口端口: %s；Xray 源站回源端口: %s；path: %s\n" "${_edge}" "${_origin}" "${_path}"
    if [ "${_tls}" = "true" ]; then
        printf "  SSL/TLS: 建议 Full 或 Full strict；源站 Xray 已按 TLS 回源生成配置。\n"
    else
        printf "  SSL/TLS: 当前为明文 HTTP 回源，需要 Flexible 或等效配置，不推荐。\n"
    fi
    if [ "${_proto}" = "xhttp" ] && [ "${_edge_h3}" = "true" ]; then
        printf "  HTTP/3: 已生成客户端到 Cloudflare Edge 的实验性 HTTP/3 链接参数；需 Cloudflare Network 启用 HTTP/3，且客户端支持 XHTTP H3 extra。\n"
        printf "  注意: 这不是 H3/QUIC 源站回源；Cloudflare 到源站仍按普通 HTTP 代理回源处理。失败可回退普通 XHTTP/WS。\n"
    fi
    printf "  注意: 节点链接端口写 %s，不要写源站回源端口 %s。\n" "${_edge}" "${_origin}"
}

_st_persist_inner() {
    local _json
    [ ! -e "${_UNINSTALL_PENDING}" ] || { log_error "卸载待继续，拒绝写入状态"; return 1; }
    _st_check_disk_state || return 1
    _json=$(printf '%s\n' "${_G_STATE}" | jq . 2>/dev/null) \
        || { log_error "state 序列化失败"; return 1; }
    atomic_write_secret_with_backup "${STATE_FILE}" "${_json}" 2 || return 1
    # state.json 含 token 等敏感数据，严格限制权限
    chmod 600 "${STATE_FILE}" 2>/dev/null || true
}

# Legacy ownership is proven by an ACME method and the exact managed pair.
_managed_certificate_domains() {
    jq -c --arg dir "${_CERT_DIR}" '
        (._managed_cert_domains | arrays // []) +
        [(.vlquic, .cforigin) | objects |
            select(.acme_method == "dns_cf_token" or .acme_method == "dns_cf_key" or .acme_method == "http01") |
            select((.domain | type) == "string" and .domain != "") |
            ($dir + "/" + .domain) as $path |
            select(.cert == ($path + "/fullchain.pem") and .key == ($path + "/privkey.pem")) | .domain] |
        map(strings) | unique
    '
}

_st_track_managed_certificates() {
    local _domains
    _domains=$(_managed_certificate_domains <<< "${_G_STATE}") || return 1
    [ "${_domains}" = '[]' ] || st_set '._managed_cert_domains = $domains' --argjson domains "${_domains}"
}

st_persist() {
    local _saved
    _st_track_managed_certificates || return 1
    _saved=$(jq -c . <<< "${_G_STATE}") || return 1
    with_lock _st_persist_inner || return 1
    _G_STATE_DISK="${_saved}"
    _G_STATE_BASE="${_G_STATE}"
}

# State schema 规范化
# 将可识别的既有字段归一到当前 schema，并补齐缺失默认值
_st_normalize_schema() {

    # 规范化端口字段到顶层 ports
    local _ap _rp _vp _qp _fp _cp _sp _hp _ssp
    _ap=$(st_get '.argo.port    // empty')
    _rp=$(st_get '.reality.port // empty')
    _vp=$(st_get '.vltcp.port   // empty')
    _qp=$(st_get '.vlquic.port  // empty')
    _fp=$(st_get '.ff.port      // empty')
    _cp=$(st_get '.cforigin.port // empty')
    _sp=$(st_get '.socks.port   // empty')
    _hp=$(st_get '.http.port    // empty')
    _ssp=$(st_get '.ss2022.port  // empty')

    # 若 .ports 不存在则初始化
    local _ports; _ports=$(st_get '.ports')
    if [ -z "${_ports:-}" ] || [ "${_ports}" = "null" ]; then
        st_set '.ports = {"argo":18888,"ff":8080,"reality":443,"vltcp":1234,"vlquic":443,"cforigin":28888,"socks":1080,"http":1081}'
        st_set '.ports.ss2022 = 8388'
    fi

    _st_migrate_port() {
        local _legacy_path="$1" _target_path="$2" _value="$3" _vp
        [ -n "${_value:-}" ] && [ "${_value}" != "null" ] || return 0
        if _vp=$(val_port "${_value}" 2>/dev/null); then
            st_set "${_target_path} = (\$p|tonumber)" --arg p "${_vp}" || return 1
        else
            log_warn "legacy 端口字段非法，已忽略并使用默认值: ${_legacy_path}=${_value}"
        fi
        st_set "del(${_legacy_path})" 2>/dev/null || true
    }

    # 将分散端口字段归一到 .ports（仅当字段存在时；坏值显式告警并回退默认值）
    _st_migrate_port '.argo.port' '.ports.argo' "${_ap}"
    _st_migrate_port '.reality.port' '.ports.reality' "${_rp}"
    _st_migrate_port '.vltcp.port' '.ports.vltcp' "${_vp}"
    _st_migrate_port '.vlquic.port' '.ports.vlquic' "${_qp}"
    _st_migrate_port '.ff.port' '.ports.ff' "${_fp}"
    _st_migrate_port '.cforigin.port' '.ports.cforigin' "${_cp}"
    _st_migrate_port '.socks.port' '.ports.socks' "${_sp}"
    _st_migrate_port '.http.port' '.ports.http' "${_hp}"
    _st_migrate_port '.ss2022.port' '.ports.ss2022' "$_ssp"

    # 补全缺失/损坏端口字段，避免菜单显示 0 或修改端口后写入无效路径
    local _c
    _c=$(st_get '.ports.argo')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.argo = 18888'
    _c=$(st_get '.ports.ff')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.ff = 8080'
    _c=$(st_get '.ports.reality')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.reality = 443'
    _c=$(st_get '.ports.vltcp')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.vltcp = 1234'
    _c=$(st_get '.ports.vlquic')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.vlquic = 443'
    _c=$(st_get '.ports.cforigin')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.cforigin = 28888'
    _c=$(st_get '.ports.socks')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.ports.socks = 1080'
    _c=$(st_get '.ports.http')
    { [ -z "$_c" ] || [ "$_c" = "null" ] || [ "$_c" = "0" ]; } && st_set '.ports.http = 1081'
    _c=$(st_get '.ports.ss2022')
    { [ -z "$_c" ] || [ "$_c" = "null" ] || [ "$_c" = "0" ]; } && st_set '.ports.ss2022 = 8388'

    _c=$(st_get '.reality.network')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.reality.network = "tcp"'
    _c=$(st_get '.cfip')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfip = "cf.tencentapp.cn"'
    _c=$(st_get '.cfport')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfport = "443"'
    _c=$(st_get '.argo.auth_protocol')
    case "${_c:-}" in vless|trojan) : ;; *) st_set '.argo.auth_protocol = "vless"' ;; esac
    _c=$(st_get '.argo.trojan_password')
    if [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; then
        st_set '.argo.trojan_password = ""'
    elif ! trojan_password_is_valid "${_c}"; then
        # 非法存量密码会生成结构损坏的 trojan:// 链接，清空后回退使用 UUID
        log_warn "检测到非法 Trojan 密码，已清空并回退为使用 UUID"
        st_set '.argo.trojan_password = ""'
    fi
    # Trojan Argo 仅支持 WS：修复非法组合，避免 inbound fail-closed 锁死 config_apply
    if [ "$(st_get '.argo.auth_protocol')" = "trojan" ] \
       && [ "$(st_get '.argo.protocol')" != "ws" ]; then
        log_warn "检测到非法组合 (Trojan + 非 WS)，已将 Argo 入站认证回落为 VLESS"
        st_set '.argo.auth_protocol = "vless"'
    fi
    _c=$(st_get '.ff.host')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.host = ""'
    # 规范化 xPadding 开关结构。
    local _global_xpad
    _global_xpad=$(printf '%s' "${_G_STATE}" | jq -r '
        if .xpad.enabled == true then "true"
        elif .xpad.enabled == false then "false"
        else empty end
    ' 2>/dev/null) || true
    case "${_global_xpad}" in
        true|false)
            st_set '.xpad.argo = $v | .xpad.ff = $v | .xpad.reality = $v | del(.xpad.enabled)' --argjson v "${_global_xpad}" ;;
    esac
    printf '%s' "${_G_STATE}" | jq -e '.xpad.argo == null' >/dev/null 2>&1 && \
        st_set '.xpad.argo = true'
    printf '%s' "${_G_STATE}" | jq -e '.xpad.ff == null' >/dev/null 2>&1 && \
        st_set '.xpad.ff = true'
    printf '%s' "${_G_STATE}" | jq -e '.xpad.reality == null' >/dev/null 2>&1 && \
        st_set '.xpad.reality = true'
    _c=$(st_get '.vltcp.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vltcp.listen = "0.0.0.0"'
    _c=$(st_get '.socks.enabled')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.socks.enabled = false'
    _c=$(st_get '.socks.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.socks.listen = "0.0.0.0"'
    _c=$(st_get '.socks.user')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.socks.user = "xray2go"'
    _c=$(st_get '.socks.pass')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.socks.pass = "xray2go"'
    _c=$(st_get '.http.enabled')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.http.enabled = false'
    _c=$(st_get '.http.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.http.listen = "0.0.0.0"'
    _c=$(st_get '.http.user')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.http.user = "xray2go"'
    _c=$(st_get '.http.pass')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.http.pass = "xray2go"'
    _c=$(st_get '.ss2022.enabled')
    { [ -z "$_c" ] || [ "$_c" = "null" ]; } && st_set '.ss2022.enabled = false'
    _c=$(st_get '.ss2022.listen')
    { [ -z "$_c" ] || [ "$_c" = "null" ]; } && st_set '.ss2022.listen = "0.0.0.0"'
    _c=$(st_get '.ss2022.method')
    ss2022_method_is_valid "$_c" || st_set '.ss2022.method = "2022-blake3-aes-256-gcm"'
    case "$(st_get '.ss2022.key_mode')" in
        single|dual) : ;;
        *)
            # 旧状态只支持双密钥。保留已有节点以及暂时禁用但仍有密钥的节点。
            st_set '.ss2022 |= (.key_mode = (if .enabled == true or (.user_key // "") != "" then "dual" else "single" end))' ;;
    esac
    _c=$(st_get '.ss2022.server_key')
    { [ "$_c" = "null" ] || [ -z "$_c" ]; } && st_set '.ss2022.server_key = ""'
    _c=$(st_get '.ss2022.user_key')
    { [ "$_c" = "null" ] || [ -z "$_c" ]; } && st_set '.ss2022.user_key = ""'
    _c=$(st_get '.vlquic.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vlquic.listen = "0.0.0.0"'
    _c=$(st_get '.vlquic.domain')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.domain = ""'
    _c=$(st_get '.vlquic.cert')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.cert = ""'
    _c=$(st_get '.vlquic.key')
    { [ "${_c}" = "null" ]; } && st_set '.vlquic.key = ""'
    _c=$(st_get '.vlquic.acme_method')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.vlquic.acme_method = "manual"'
    _c=$(st_get '.ff.path')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.path = "/"'
    _c=$(st_get '.ff.protocol')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.protocol = "none"'
    _c=$(st_get '.cforigin.enabled')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.enabled = false'
    _c=$(st_get '.cforigin.domain')
    { [ "${_c}" = "null" ]; } && st_set '.cforigin.domain = ""'
    _c=$(st_get '.cforigin.protocol')
    case "${_c:-}" in ws|httpupgrade|xhttp) : ;; *) st_set '.cforigin.protocol = "ws"' ;; esac
    _c=$(st_get '.cforigin.path')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.path = "/origin"'
    _c=$(st_get '.cforigin.listen')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.listen = "::"'
    _c=$(st_get '.cforigin.edge_port')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ] || [ "${_c}" = "0" ]; } && st_set '.cforigin.edge_port = 443'
    _c=$(st_get '.cforigin.edge_h3')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.edge_h3 = false'
    _c=$(st_get '.cforigin.origin_tls')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.origin_tls = true'
    _c=$(st_get '.cforigin.cert')
    { [ "${_c}" = "null" ]; } && st_set '.cforigin.cert = ""'
    _c=$(st_get '.cforigin.key')
    { [ "${_c}" = "null" ]; } && st_set '.cforigin.key = ""'
    _c=$(st_get '.cforigin.acme_method')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cforigin.acme_method = "manual"'

    _st_track_managed_certificates
}

_st_read_object() {
    jq -ces 'if length == 1 and (.[0] | type == "object") then .[0] else error("invalid state") end' "$1" 2>/dev/null
}

_st_restore_backup() {
    local _backup="$1" _restored _damaged
    [ ! -e "${_UNINSTALL_PENDING}" ] || return 1
    if _st_read_object "${STATE_FILE}" >/dev/null; then
        log_error "状态文件已被其他进程恢复，请重新运行"
        return 1
    fi
    _restored=$(_st_read_object "${_backup}") || { log_error "备份读取失败"; return 1; }
    _damaged=$(mktemp "${STATE_FILE}.corrupt.XXXXXX") || return 1
    if ! cat -- "${STATE_FILE}" > "${_damaged}"; then
        rm -f -- "${_damaged}"
        log_error "无法保留损坏的状态文件"
        return 1
    fi
    atomic_write_secret "${STATE_FILE}" "${_restored}" || { log_error "恢复状态文件失败"; return 1; }
    log_ok "状态已从备份恢复，损坏文件保存在 ${_damaged}"
}

_st_offer_recovery() {
    local _file _choice _backups=()
    log_error "state.json 损坏，已保留原文件"
    for _file in "${STATE_FILE}".*.bak "${STATE_FILE}.bak"; do
        [ -f "${_file}" ] && _st_read_object "${_file}" >/dev/null || continue
        _backups+=("${_file}")
        printf '  %s. %s\n' "${#_backups[@]}" "${_file}"
    done
    if [ "${#_backups[@]}" -eq 0 ]; then
        log_error "没有找到可读取的状态备份"
        return 1
    fi
    ( : </dev/tty ) 2>/dev/null || return 1
    prompt "输入备份编号以确认恢复（回车退出）: " _choice || return 1
    [[ "${_choice:-}" =~ ^[1-9][0-9]{0,5}$ ]] && [ "${_choice}" -le "${#_backups[@]}" ] || return 1
    with_lock _st_restore_backup "${_backups[_choice - 1]}"
}

_st_read_optional_disk_state() {
    if [ -e "${STATE_FILE}" ] || [ -L "${STATE_FILE}" ]; then
        _st_read_object "${STATE_FILE}" || { log_error "无法读取当前状态文件"; return 1; }
    fi
}

_st_check_disk_state() {
    [ -n "${_G_STATE_BASE}" ] || return 0
    local _disk
    _disk=$(_st_read_optional_disk_state) || return 1
    if [ "${_disk}" != "${_G_STATE_DISK}" ]; then
        log_error "状态已被其他会话修改，请重新载入后重试"
        return 1
    fi
}

_st_refresh_transaction_state() {
    [ -n "${_G_STATE_BASE}" ] || return 0
    local _disk
    _disk=$(_st_read_optional_disk_state) || return 1
    [ "${_disk}" != "${_G_STATE_DISK}" ] || return 0
    if [ -z "${_disk}" ] || [ "${_G_STATE}" != "${_G_STATE_BASE}" ]; then
        log_error "状态已被其他会话修改，请重新载入后重试"
        return 1
    fi
    _G_STATE="${_disk}"
    _st_normalize_schema
    if [ -z "$(st_get '.uuid')" ]; then
        local _uuid
        _uuid=$(crypto_gen_uuid) && st_set '.uuid = $u' --arg u "${_uuid}" || return 1
    fi
    _G_STATE_DISK="${_disk}"
    _G_STATE_BASE="${_G_STATE}"
}

st_init() {
    local _u
    if [ -e "${STATE_FILE}" ] || [ -L "${STATE_FILE}" ]; then
        if ! _G_STATE=$(_st_read_object "${STATE_FILE}"); then
            _st_offer_recovery || return 1
            _G_STATE=$(_st_read_object "${STATE_FILE}") || { log_error "无法读取恢复后的状态文件"; return 1; }
        fi
        _G_STATE_DISK="${_G_STATE}"
        _st_normalize_schema
        _u=$(st_get '.uuid')
        if [ -z "${_u:-}" ]; then
            _u=$(crypto_gen_uuid) && st_set '.uuid = $u' --arg u "${_u}" || return 1
        fi
        _G_STATE_BASE="${_G_STATE}"
        return 0
    fi
    _G_STATE_DISK=""
    _G_STATE="${_STATE_DEFAULT}"
    _st_normalize_schema
    _u=$(st_get '.uuid')
    if [ -z "${_u:-}" ]; then
        _u=$(crypto_gen_uuid) && st_set '.uuid = $u' --arg u "${_u}" || return 1
    fi
    _G_STATE_BASE="${_G_STATE}"
    if [ -d "${WORK_DIR}" ]; then
        st_persist || { log_error "状态初始化写入失败"; return 1; }
        log_info "状态已初始化"
    fi
}

# ==============================================================================
# Plugin runtime
# ==============================================================================
# 插件接口契约（每个插件文件必须实现）：
#   plugin_inbound  — 输出单个 inbound JSON（或空字符串表示禁用）
#   plugin_link     — 每行输出一个无空白或控制字符的 scheme:// 分享链接（或空）
#   plugin_ports    — 每行输出一个端口号或 port/tcp、port/udp（或空）
#   plugin_enabled  — 返回 0=启用 / 1=禁用
#
# 插件文件约定：
#   PLUGIN_DIR/<name>.sh
#   所有函数以 _plg_<name>_<method> 命名，避免全局污染
#   注册后通过 plugin_call <name> <method> [args] 调用

_plugin_path_safe() {
    local _path="$1" _meta _uid _gid _mode
    [ -e "${_path}" ] || { log_warn "插件路径不存在: ${_path}"; return 1; }
    _meta=$(stat -c '%u:%g:%a' "${_path}" 2>/dev/null) || { log_warn "插件路径无法 stat: ${_path}"; return 1; }
    IFS=: read -r _uid _gid _mode <<EOF
${_meta}
EOF
    [ "${_uid}" = "0" ] && [ "${_gid}" = "0" ] || { log_warn "插件路径所有者不安全，已拒绝加载: ${_path}"; return 1; }
    [ $(( 8#${_mode} & 8#022 )) -eq 0 ] || { log_warn "插件路径权限不安全，已拒绝加载: ${_path}"; return 1; }
}

_plugin_stage_functions() (
    local _stage="$1" _name="$2" _prefix="_plg_${2}_" _fn _method
    local -a _new_functions=()
    local -A _other_functions=()
    for _fn in ${_PLUGIN_FUNCTIONS[${_name}]:-}; do unset -f -- "${_fn}" || exit 1; done
    while IFS= read -r _fn; do
        _other_functions["${_fn}"]=1
    done < <(compgen -A function)
    for _method in inbound link ports enabled; do
        unset -f -- "${_prefix}${_method}" || exit 1
    done
    # 校验与发布使用同一次隔离加载产生的函数。
    # shellcheck source=/dev/null
    source "${_stage}" >/dev/null 2>&1 || exit 1
    for _method in inbound link ports enabled; do
        declare -F "${_prefix}${_method}" >/dev/null || exit 1
        [ -z "${_other_functions[${_prefix}${_method}]:-}" ] || exit 1
    done
    while IFS= read -r _fn; do
        [ -z "${_other_functions[${_fn}]:-}" ] || continue
        [[ "${_fn}" =~ ^[A-Za-z0-9_-]+$ ]] || exit 1
        _new_functions+=("${_fn}")
    done < <(compgen -A function)
    printf '%s\n' "${_new_functions[*]}"
    declare -f -- "${_new_functions[@]}"
)

_plugin_drop_functions() {
    local _name="$1" _fn
    for _fn in ${_PLUGIN_FUNCTIONS[${_name}]:-}; do unset -f -- "${_fn}" || return 1; done
    unset '_PLUGIN_FUNCTIONS[${_name}]'
}

_plugin_stage_file() {
    local _file="$1" _name="$2" _stage="$3"
    if [[ " ${_BUILTIN_PLUGINS[*]} " == *" ${_name} "* ]]; then
        # 保留名始终使用脚本自带模板。
        "_plugin_write_${_name}" > "${_stage}"
    else
        [ -f "${_file}" ] && _plugin_path_safe "${_file}" && cat -- "${_file}" > "${_stage}"
    fi
}

# 已存在的插件逐个发布或保留上一套完整实现。
plugin_load_all() {
    mkdir -p "${PLUGIN_DIR}" || return 1
    chmod 755 "${WORK_DIR}" "${PLUGIN_DIR}" 2>/dev/null || true
    _plugin_path_safe "${WORK_DIR}" || return 1
    _plugin_path_safe "${PLUGIN_DIR}" || return 1
    local _f _name _stage _loaded
    local -a _next_registry=()
    local -A _present=()
    _stage=$(mktemp "${PLUGIN_DIR}/.load_XXXXXX") || return 1
    for _f in "${PLUGIN_DIR}"/*.sh; do
        [ -e "${_f}" ] || [ -L "${_f}" ] || continue
        _name=$(basename "${_f}" .sh)
        val_plugin_name "${_name}" >/dev/null || { log_warn "插件文件名不合法，已跳过且未加载: ${_f}"; continue; }
        _present["${_name}"]=1
        if _plugin_stage_file "${_f}" "${_name}" "${_stage}" &&
           bash -n "${_stage}" >/dev/null 2>&1 &&
           _loaded=$(_plugin_stage_functions "${_stage}" "${_name}") && [[ "${_loaded}" == *$'\n'* ]]; then
            _plugin_drop_functions "${_name}" || { rm -f -- "${_stage}"; return 1; }
            # 只发布 Bash 从已校验函数生成的定义，不重复执行插件顶层代码。
            eval "${_loaded#*$'\n'}" || { rm -f -- "${_stage}"; return 1; }
            _PLUGIN_FUNCTIONS["${_name}"]="${_loaded%%$'\n'*}"
            _next_registry+=("${_name}")
            log_info "插件已加载: ${_name}"
        elif [ -n "${_PLUGIN_FUNCTIONS[${_name}]:-}" ]; then
            _next_registry+=("${_name}")
            log_warn "插件 ${_name} 刷新失败，继续使用上一版"
        else
            log_warn "插件 ${_name} 无法加载或接口不完整，已跳过且未加载"
        fi
    done
    rm -f -- "${_stage}" || return 1
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        if [ -z "${_present[${_name}]:-}" ]; then
            _plugin_drop_functions "${_name}" || return 1
        fi
    done
    _PLUGIN_REGISTRY=("${_next_registry[@]}")
    _PLUGIN_SNAPSHOT_STAMP=""
}

# 调用插件方法
plugin_call() {
    local _name="$1" _method="$2"; shift 2
    local _fn="_plg_${_name}_${_method}"
    declare -f "${_fn}" >/dev/null 2>&1 \
        || { log_error "插件方法未找到: ${_fn}"; return 1; }
    "${_fn}" "$@"
}

plugin_filter_links() {
    local _name="$1" _line _invalid=0 _uri='^[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:][:cntrl:]]+$'
    while IFS= read -r _line; do
        [ -n "${_line}" ] || continue
        if [[ "${_line}" =~ ${_uri} ]]; then
            printf '%s\n' "${_line}"
        else
            _invalid=1
        fi
    done
    if [ "${_invalid}" -eq 1 ]; then
        log_warn "插件 ${_name} 返回了无效的分享链接格式"
    fi
}

plugin_refresh_runtime() {
    plugin_install_builtins || return 1
    plugin_load_all || return 1
    _PLUGIN_SNAPSHOT_STAMP=""
    _PLUGIN_SNAPSHOT_PORTS=""
    _PLUGIN_SNAPSHOT_INBOUNDS=""
}

_plugin_snapshot_stamp() {
    printf '%s|%s' "${_PLUGIN_REGISTRY[*]}" "${_G_STATE}"
}

_plugin_port_rules() {
    local _name="$1" _ports _rule _port _proto
    _ports=$(plugin_call "${_name}" ports) || { log_error "插件 ports 失败: ${_name}"; return 1; }
    while IFS= read -r _rule; do
        [ -n "${_rule}" ] || continue
        _port="${_rule%/*}"
        _proto="${_rule#*/}"
        [[ "${_rule}" == */* ]] || _proto=tcp
        if [[ ! "${_port}" =~ ^[0-9]+$ ]] || [[ "${_proto}" != tcp && "${_proto}" != udp ]]; then
            log_error "插件端口格式无效: ${_name}"
            return 1
        fi
        printf '%s/%s\n' "${_port}" "${_proto}"
    done <<< "${_ports}"
}

_plugin_snapshot_rebuild() {
    local _uuid_check _name _p _ibs='[]' _ib _rows _port _listen _proto _transports _key _socket
    local -A _used_ports=() _used_wild_ports=() _used_exact_keys=()
    _PLUGIN_SNAPSHOT_STAMP=""
    _uuid_check=$(st_get '.uuid')
    if ! val_uuid "${_uuid_check}" >/dev/null 2>&1; then
        log_error "UUID 格式异常，拒绝生成插件快照: ${_uuid_check}"
        return 1
    fi
    _PLUGIN_SNAPSHOT_PORTS=""

    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        _p=$(_plugin_port_rules "${_name}") || return 1
        [ -z "${_p}" ] || _PLUGIN_SNAPSHOT_PORTS+="${_p}"$'\n'

        _ib=$(plugin_call "${_name}" inbound 2>/dev/null) || {
            log_error "插件 inbound 失败: ${_name}"; return 1; }
        [ -n "${_ib}" ] || continue

        _rows=$(jq -c 'if type == "array" then .[] else . end' <<< "${_ib}") || {
            log_error "inbounds 组装失败: ${_name}"; return 1; }
        [ -n "${_rows}" ] || continue
        while IFS= read -r _ib; do
            _port=$(jq -r '.port // empty' <<< "${_ib}") || return 1
            _listen=$(jq -r '.listen // "0.0.0.0"' <<< "${_ib}") || return 1
            if [ -n "${_port}" ]; then
                # 未在插件中声明的监听（例如本地回源）按 TCP 处理。
                _transports=$(awk -F/ -v port="${_port}" '$1 == port {print $2}' <<< "${_p}" | sort -u)
                for _proto in ${_transports:-tcp}; do
                    _socket="${_port}/${_proto}"
                    _key="${_listen}:${_socket}"
                    if [ -n "${_used_wild_ports[$_socket]:-}" ] || [ -n "${_used_exact_keys[$_key]:-}" ] ||
                       { _is_wild_listen "${_listen}" && [ -n "${_used_ports[$_socket]:-}" ]; }; then
                        log_error "端口冲突: ${_key}，插件 [${_name}] 与已启用入站冲突"
                        return 1
                    fi
                    _used_ports["${_socket}"]=1
                    if _is_wild_listen "${_listen}"; then
                        _used_wild_ports["${_socket}"]=1
                    else
                        _used_exact_keys["${_key}"]=1
                    fi
                done
            fi

            _ibs=$(jq --argjson ib "${_ib}" '. + [$ib]' <<< "${_ibs}") \
                || { log_error "inbounds 组装失败: ${_name}"; return 1; }
        done <<< "${_rows}"
    done

    _PLUGIN_SNAPSHOT_INBOUNDS="${_ibs}"
    _PLUGIN_SNAPSHOT_STAMP=$(_plugin_snapshot_stamp)
}

_plugin_snapshot_ensure() {
    local _stamp
    _stamp=$(_plugin_snapshot_stamp)
    if [ "${_PLUGIN_SNAPSHOT_STAMP}" != "${_stamp}" ]; then
        _plugin_snapshot_rebuild || return 1
    fi
}

plugin_collect_ports_raw() {
    local _name _ports
    if [ "${1:-}" = preview ]; then
        for _name in "${_PLUGIN_REGISTRY[@]}"; do
            _ports=$(_plugin_port_rules "${_name}") || return 1
            [ -z "${_ports}" ] || printf '%s\n' "${_ports}"
        done
        return 0
    fi
    _plugin_snapshot_ensure || return 1
    printf '%s' "${_PLUGIN_SNAPSHOT_PORTS}"
}

plugin_is_loaded() {
    local _name
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        [ "${_name}" = "$1" ] && return 0
    done
    return 1
}

plugin_collect_links() {
    local _mod="${1:-}" _links _name
    if [ -n "${_mod}" ]; then
        plugin_is_loaded "${_mod}" || return 0
        _links=$(plugin_call "${_mod}" link) || return 1
        plugin_filter_links "${_mod}" <<< "${_links}"
        return
    fi
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        _links=$(plugin_call "${_name}" link 2>/dev/null) || continue
        plugin_filter_links "${_name}" <<< "${_links}"
    done
}

plugin_collect_inbounds() {
    _plugin_snapshot_ensure || return 1
    printf '%s' "${_PLUGIN_SNAPSHOT_INBOUNDS}"
}

_plugin_is_managed_builtin() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        grep -Eq "^# xray-2go plugin: $2( |$)" "$1"
}

plugin_install_builtins() {
    local _name _path _tmp _replace
    mkdir -p "${PLUGIN_DIR}" || return 1
    [ ! -L "${PLUGIN_DIR}" ] && _plugin_path_safe "${PLUGIN_DIR}" || return 1
    for _name in "${_BUILTIN_PLUGINS[@]}"; do
        _path="${PLUGIN_DIR}/${_name}.sh"
        _replace=-nT
        if [ -e "${_path}" ] || [ -L "${_path}" ]; then
            if ! _plugin_is_managed_builtin "${_path}" "${_name}"; then
                log_warn "保留归属未确认的插件文件: ${_path}（内置实现仍可用）"
                continue
            fi
            _replace=-fT
        fi
        _tmp=$(mktemp "${PLUGIN_DIR}/.builtin.XXXXXX") || return 1
        if ! "_plugin_write_${_name}" > "${_tmp}" || ! chmod 644 "${_tmp}" ||
           ! mv "${_replace}" -- "${_tmp}" "${_path}"; then
            rm -f -- "${_tmp}"
            return 1
        fi
        [ ! -f "${_tmp}" ] || rm -f -- "${_tmp}" || return 1
    done
}

# ==============================================================================
# Built-in protocol plugins
# ==============================================================================
# 设计原则：
#   - 插件只读 state，不写 state
#   - 插件不调用 svc_* 或 fw_*（由主程序调度）
#   - 端口全部通过 port_of <name> 读取，不硬编码

# Argo 分离节点沿用 Argo 的回源路径。额外的 REALITY 监听仅负责回落到该入站。
_argo_xhttp_split_active() {
    st_get '.argo.enabled == true and .argo.auth_protocol == "vless" and
        .argo.protocol == "xhttp" and .reality.enabled == true and
        (.argo.xhttp.split | type == "object")' | grep -qx true
}

_xhttp_server_extra() {
    local _module="$1" _legacy='{}'
    case "${_module}" in
        argo|reality|ff) [ "$(xpad_of "${_module}")" != true ] || _legacy="${_XPAD_JSON}" ;;
    esac
    st_get '.[$id].xhttp.server // $legacy' --arg id "${_module}" --argjson legacy "${_legacy}"
}

_xhttp_client_visible_server_extra() {
    jq -c 'with_entries(select(.key | IN(
        "xPaddingBytes", "xPaddingObfsMode", "xPaddingKey", "xPaddingHeader",
        "xPaddingPlacement", "xPaddingMethod", "scMaxEachPostBytes", "sessionPlacement", "sessionKey",
        "seqPlacement", "seqKey", "uplinkDataPlacement", "uplinkDataKey", "uplinkChunkSize", "uplinkHTTPMethod"
    )))'
}

_argo_xhttp_download_settings() {
    local _profile="$1" _host="$2" _server
    _server=$(_xhttp_server_extra argo) || return 1
    _server=$(_xhttp_client_visible_server_extra <<< "${_server}") || return 1
    if jq -e '.split.download.port == false' <<< "${_profile}" >/dev/null; then
        log_warn "历史 Argo 下行端口为 false，已使用 CDN 端口；请在高级配置中修正"
    fi
    jq -ce --arg address "$(st_get '.cfip')" --argjson port "$(st_get '.cfport')" \
        --arg host "${_host}" --argjson server "${_server}" '
        (.split.download // {} | del(.security) |
         if .port == false then del(.port) else . end | with_entries(select(.value != null))) as $override |
        ({address:$address,port:$port,network:"xhttp",security:"tls",
          tlsSettings:{serverName:$host,fingerprint:"chrome"},
          xhttpSettings:{path:"/argo",host:$host,extra:$server}} * $override) |
        .address = ((.address | select(length > 0)) // $address | ltrimstr("[") | rtrimstr("]")) |
        .xhttpSettings.path //= "/argo" | .xhttpSettings.host //= $host |
        .xhttpSettings.extra //= $server | .tlsSettings.serverName //= $host
    ' <<< "${_profile}"
}

_argo_xhttp_client_stream() {
    local _kind="$1" _profile _settings _host _down _public
    _host=$(st_get '.argo.domain') || return 1
    [ -n "${_host}" ] && [ "${_host}" != null ] || return 1
    _settings=$(_xhttp_client_settings argo /argo "${_host}") || return 1
    if [ "${_kind}" = split ]; then
        _argo_xhttp_split_active || return 1
        _public=$(st_get '.reality.pbk') || return 1
        [ -n "${_public}" ] && [ "${_public}" != null ] || return 1
        _profile=$(_xhttp_saved_profile argo) || return 1
        _down=$(_argo_xhttp_download_settings "${_profile}" "${_host}") || return 1
        jq -c --arg mode "$(jq -r '.split.mode // "packet-up"' <<< "${_profile}")" --argjson down "${_down}" \
            --arg sni "$(st_get '.reality.sni')" --arg public "${_public}" --arg sid "$(st_get '.reality.sid')" '
            {network:"xhttp",security:"reality",
             realitySettings:{serverName:$sni,fingerprint:"chrome",password:$public,shortId:$sid},
             xhttpSettings:(.mode = $mode | .extra.downloadSettings = $down)}
        ' <<< "${_settings}"
    else
        jq -c --arg host "${_host}" '
            {network:"xhttp",security:"tls",tlsSettings:{serverName:$host,fingerprint:"chrome"},xhttpSettings:.}
        ' <<< "${_settings}"
    fi
}

_xhttp_client_settings() {
    local _module="$1" _path="$2" _host="${3:-}" _mode=stream-one _profile _server
    [ "${_module}" != argo ] || _mode=auto
    _profile=$(st_get '.[$id].xhttp // {}' --arg id "${_module}") || return 1
    _server=$(_xhttp_server_extra "${_module}") || return 1
    _server=$(_xhttp_client_visible_server_extra <<< "${_server}") || return 1
    jq -c --arg path "${_path}" --arg host "${_host}" --arg mode "${_mode}" --argjson server "${_server}" '
        {path:$path, mode:(.mode // $mode), extra:($server * (.client // {}))} |
        if $host == "" then . else .host = $host end |
        if .extra == {} then del(.extra) else . end
    ' <<< "${_profile}"
}


_ff_xhttp_client_stream() {
    local _settings
    _settings=$(_xhttp_client_settings ff "$(st_get '.ff.path')" "$1") || return 1
    jq -c '{network:"xhttp",security:"none",xhttpSettings:.}' <<< "${_settings}"
}

_ff_xhttp_link() {
    _xhttp_link ff
}

_vlquic_xhttp_client_stream() {
    local _settings
    _settings=$(_xhttp_client_settings vlquic / "$1") || return 1
    jq -c --arg domain "$1" '
        {network:"xhttp",security:"tls",tlsSettings:{serverName:$domain,fingerprint:"chrome",alpn:["h3"]},xhttpSettings:.}
    ' <<< "${_settings}"
}

_vlquic_xhttp_link() {
    _xhttp_link vlquic
}

_reality_xhttp_client_stream() {
    local _settings _public
    _public=$(st_get '.reality.pbk')
    if [ -z "${_public}" ] || [ "${_public}" = null ]; then
        log_warn "请先生成 Reality 密钥，再导出节点"
        return 1
    fi
    _settings=$(_xhttp_client_settings reality /) || return 1
    jq -c --arg sni "$(st_get '.reality.sni')" --arg public "${_public}" --arg sid "$(st_get '.reality.sid')" '
        {network:"xhttp", security:"reality",
         realitySettings:{serverName:$sni,fingerprint:"chrome",password:$public,shortId:$sid},xhttpSettings:.}
    ' <<< "${_settings}"
}

_reality_xhttp_link() {
    _xhttp_link reality
}

_cforigin_xhttp_client_stream() {
    local _settings _host
    _host=$(st_get '.cforigin.domain') || return 1
    _settings=$(_xhttp_client_settings cforigin "$(st_get '.cforigin.path')" "${_host}") || return 1
    jq -c --arg host "${_host}" --arg edge_h3 "$(st_get '.cforigin.edge_h3')" '
        {network:"xhttp",security:"tls",tlsSettings:{serverName:$host,fingerprint:"chrome"},xhttpSettings:.} |
        if $edge_h3 == "true" then .tlsSettings.alpn = ["h3"] else . end
    ' <<< "${_settings}"
}

_cforigin_xhttp_link() {
    _xhttp_link cforigin
}

_argo_xhttp_link() {
    _xhttp_link argo "$1"
}

_xhttp_link() {
    local _module="$1" _outbound
    _outbound=$("_${_module}_xhttp_export_json" "${2:-}") || return 1
    _xhttp_link_from_outbound "${_module}" "${_outbound}"
}

_xhttp_link_from_outbound() {
    jq -r --arg id "$1" '
        .settings.vnext[0] as $peer | .streamSettings as $stream | $stream.xhttpSettings as $xhttp |
        ($peer.address | if contains(":") then "[" + . + "]" else . end) as $address |
        ($stream.realitySettings // $stream.tlsSettings) as $security |
        ($stream.tlsSettings.alpn == ["h3"]) as $h3 |
        (if $id == "argo" then
            if $stream.security == "reality" then "Argo-XHTTP-Split" else "Argo-XHTTP" end
         elif $id == "reality" then "Reality-XHTTP"
         elif $id == "ff" then "FreeFlow-XHTTP"
         elif $id == "vlquic" then "VLESS-XHTTP-H3"
         elif $h3 then "CF-Origin-XHTTP-H3-Experimental"
         else "CF-Origin-XHTTP" end) as $tag |
        "vless://\($peer.users[0].id)@\($address):\($peer.port)?encryption=none&security=\($stream.security)" +
        (if $security then "&sni=\($security.serverName | @uri)&fp=chrome" else "" end) +
        (if $id == "reality" then "&pbk=\($security.password | @uri)&sid=\($security.shortId | @uri)" else "" end) +
        (if $id == "vlquic" then "&alpn=h3" else "" end) +
        "&type=xhttp" +
        (if $xhttp.host != null then "&host=\($xhttp.host | if $id == "ff" then . else @uri end)" else "" end) +
        "&path=\($xhttp.path | @uri)&mode=\($xhttp.mode)" +
        (if $id == "argo" and $stream.security == "reality" then
            "&pbk=\($security.password | @uri)&sid=\($security.shortId | @uri)&support-x25519mlkem768=true"
        else "" end) +
        (if $h3 and $id == "cforigin" then "&alpn=h3" else "" end) +
        (if $h3 then "&extra=\(($xhttp.extra // {}) + {xhttpModeH3:true} | @uri)&xhttpModeH3=true"
         elif $xhttp.extra then "&extra=\($xhttp.extra | @uri)" else "" end) +
        (if $id == "reality" then "&support-x25519mlkem768=true" else "" end) +
        "#\($tag)"
    ' <<< "${2}"
}

_argo_xhttp_split_inbound() {
    local _private
    _private=$(st_get '.reality.pvk')
    [ -n "${_private}" ] && [ "${_private}" != null ] || return 0
    jq -n --argjson port "$(st_get '.argo.xhttp.split.port')" \
        --arg dest "127.0.0.1:$(port_of argo)" --arg uuid "$(st_get '.uuid')" \
        --arg sni "$(st_get '.reality.sni')" --arg private "${_private}" --arg sid "$(st_get '.reality.sid')" '
        {listen:"::",port:$port,protocol:"vless",
         settings:{clients:[{id:$uuid}],decryption:"none",fallbacks:[{dest:$dest,xver:0}]},
         streamSettings:{network:"raw",security:"reality",
             realitySettings:{target:($sni+":443"),serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}}'
}

_plugin_write_argo() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: argo
# 接口：_plg_argo_inbound / _plg_argo_link / _plg_argo_ports / _plg_argo_enabled

_plg_argo_enabled() {
    [ "$(st_get '.argo.enabled')" = "true" ]
}

_plg_argo_ports() {
    _plg_argo_enabled || return 0
    port_of argo
    if _argo_xhttp_split_active; then
        printf '\n%s/tcp\n' "$(st_get '.argo.xhttp.split.port')"
    fi
}

_plg_argo_inbound() {
    _plg_argo_enabled || return 0
    local _port _proto _auth _uuid _password
    _port=$(port_of argo)
    _proto=$(st_get '.argo.protocol')
    _auth=$(st_get '.argo.auth_protocol')
    _uuid=$(st_get '.uuid')
    _password=$(st_get '.argo.trojan_password')
    [ -n "${_password:-}" ] || _password="${_uuid}"
    local _xpad _origin _split
    case "${_auth}:${_proto}" in
        trojan:ws)
            jq -n --argjson port "${_port}" --arg password "${_password}" '{
                port:$port, listen:"127.0.0.1", protocol:"trojan",
                settings:{clients:[{password:$password}]},
                streamSettings:{network:"ws", wsSettings:{path:"/argo"}}}' ;;
        trojan:*)
            log_error "Trojan Argo 当前仅支持 WS 传输"; return 1 ;;
        vless:xhttp)
            _xpad=$(_xhttp_server_extra argo) || return 1
            _origin=$(jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --argjson x "${_xpad}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:"/argo", mode:"auto"} +
                        (if ($x|length)>0 then {extra:$x} else {} end))}}') || return 1
            if _argo_xhttp_split_active; then
                _split=$(_argo_xhttp_split_inbound) || return 1
            fi
            if [ -n "${_split:-}" ]; then
                jq -n --argjson origin "${_origin}" --argjson split "${_split}" '[$origin, $split]'
            else
                printf '%s\n' "${_origin}"
            fi ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:"/argo"}}}' ;;
    esac
}

_plg_argo_link() {
    _plg_argo_enabled || return 0
    local _domain _proto _auth _uuid _password _cfip _cfport
    _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    _proto=$(st_get '.argo.protocol')
    _auth=$(st_get '.argo.auth_protocol')
    _uuid=$(st_get '.uuid')
    _password=$(st_get '.argo.trojan_password')
    [ -n "${_password:-}" ] || _password="${_uuid}"
    _cfip=$(st_get '.cfip')
    _cfport=$(st_get '.cfport')
    if [ "${_auth}" = "trojan" ]; then
        [ "${_proto}" = "ws" ] || return 0
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-Trojan\n' \
            "${_password}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}"
        return 0
    fi
    case "${_proto}" in
        xhttp)
            _argo_xhttp_link normal || return 1
            if _argo_xhttp_split_active; then
                _argo_xhttp_link split || log_warn "Argo XHTTP 分离节点暂不可导出，请检查 Reality 公钥和公网地址"
            fi ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
    esac
}
PLUGIN_EOF
}

_plugin_write_ff() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: ff (FreeFlow)

_plg_ff_enabled() {
    [ "$(st_get '.ff.enabled')" = "true" ] && \
    [ "$(st_get '.ff.protocol')" != "none" ]
}

_plg_ff_ports() {
    _plg_ff_enabled || return 0
    port_of ff
}

_plg_ff_inbound() {
    _plg_ff_enabled || return 0
    local _proto _path _uuid _port
    _proto=$(st_get '.ff.protocol')
    _path=$(st_get '.ff.path')
    _uuid=$(st_get '.uuid')
    _port=$(port_of ff)
    local _mode _extra
    case "${_proto}" in
        ws)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:$path}}}' ;;
        httpupgrade)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"httpupgrade",
                    httpupgradeSettings:{path:$path}}}' ;;
        xhttp)
            _mode=$(st_get '.ff.xhttp.mode // "stream-one"') || return 1
            _extra=$(_xhttp_server_extra ff) || return 1
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg path "${_path}" \
                   --arg mode "${_mode}" --argjson x "${_extra}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:$path, mode:$mode} + $x)}}' ;;
        tcphttp)
            local _host; _host=$(st_get '.ff.host')
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" --arg host "${_host}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"tcp",
                    tcpSettings:{header:{type:"http",request:{
                        version:"1.1", method:"GET", path:["/"],
                        headers:{
                            Host:[$host],
                            "User-Agent":["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"],
                            "Accept-Encoding":["gzip, deflate"],
                            Connection:["keep-alive"], Pragma:["no-cache"]
                        }}}}}}' ;;
        *) log_error "_plg_ff_inbound: 未知协议 ${_proto}"; return 1 ;;
    esac
}

_plg_ff_link() {
    _plg_ff_enabled || return 0
    local _proto _uuid _ip _penc _port
    _proto=$(st_get '.ff.protocol')
    if [ "${_proto}" = xhttp ]; then
        _ff_xhttp_link
        return $?
    fi
    _uuid=$(st_get '.uuid')
    _port=$(port_of ff)
    _ip=$(platform_get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 0; }
    _penc=$(urlencode_path "$(st_get '.ff.path')")
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_ip}" "${_penc}" ;;
        tcphttp)
            local _host _henc
            _host=$(st_get '.ff.host')
            _henc=$(urlencode_path "${_host}")
            printf 'vless://%s@%s:%s?encryption=none&security=none&type=tcp&headerType=http&host=%s&path=%%2F#FreeFlow-TCP-HTTP\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_henc}" ;;
    esac
}
PLUGIN_EOF
}

_plugin_write_reality() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: reality

_plg_reality_enabled() {
    [ "$(st_get '.reality.enabled')" = "true" ]
}

_plg_reality_ports() {
    _plg_reality_enabled || return 0
    port_of reality
}

_plg_reality_inbound() {
    _plg_reality_enabled || return 0
    local _pvk; _pvk=$(st_get '.reality.pvk')
    if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
        log_warn "Reality 密钥未就绪，已跳过"; return 0
    fi
    local _port _sni _sid _net _uuid _mode _extra
    _port=$(port_of reality)
    _sni=$(st_get '.reality.sni')
    _sid=$(st_get '.reality.sid')
    _net=$(st_get '.reality.network'); _net="${_net:-tcp}"
    _uuid=$(st_get '.uuid')
    case "${_net}" in
        xhttp)
            _mode=$(st_get '.reality.xhttp.mode // "stream-one"') || return 1
            _extra=$(_xhttp_server_extra reality) || return 1
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" \
                   --arg mode "${_mode}" --argjson x "${_extra}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]},
                    xhttpSettings:($x + {path:"/", mode:$mode})}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                streamSettings:{network:"tcp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]}}}' ;;
    esac
}

_plg_reality_link() {
    _plg_reality_enabled || return 0
    local _rpbk _ip
    _rpbk=$(st_get '.reality.pbk')
    [ -n "${_rpbk:-}" ] && [ "${_rpbk}" != "null" ] || return 0
    if [ "$(st_get '.reality.network')" = xhttp ]; then
        _reality_xhttp_link
        return $?
    fi
    _ip=$(platform_get_realip)
    [ -n "${_ip}" ] || { log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 0; }
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none&support-x25519mlkem768=true#Reality-Vision\n' \
        "$(st_get '.uuid')" "${_ip}" "$(port_of reality)" "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')"
}
PLUGIN_EOF
}

_plugin_write_vltcp() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: vltcp

_plg_vltcp_enabled() {
    [ "$(st_get '.vltcp.enabled')" = "true" ]
}

_plg_vltcp_ports() {
    _plg_vltcp_enabled || return 0
    port_of vltcp
}

_plg_vltcp_inbound() {
    _plg_vltcp_enabled || return 0
    local _port _listen _uuid
    _port=$(port_of vltcp)
    _listen=$(st_get '.vltcp.listen')
    _uuid=$(st_get '.uuid')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"}}'
}

_plg_vltcp_link() {
    _plg_vltcp_enabled || return 0
    local _listen _vhost _uuid _port
    _listen=$(st_get '.vltcp.listen')
    _uuid=$(st_get '.uuid')
    _port=$(port_of vltcp)
    [ "${_listen}" = "0.0.0.0" ] || [ "${_listen}" = "::" ] \
        && _vhost=$(platform_get_realip) || _vhost="${_listen}"
    [ -z "${_vhost:-}" ] && { log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"; return 0; }
    printf 'vless://%s@%s:%s?encryption=none&type=tcp&security=none#VLESS-TCP\n' \
        "${_uuid}" "${_vhost}" "${_port}"
}
PLUGIN_EOF
}


_plugin_write_ss2022() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: ss2022 (Xray-core built-in Shadowsocks 2022)

_plg_ss2022_enabled() {
    [ "$(st_get '.ss2022.enabled')" = "true" ]
}

_plg_ss2022_ports() {
    _plg_ss2022_enabled || return 0
    local _port
    _port=$(port_of ss2022)
    printf '%s/tcp\n%s/udp\n' "$_port" "$_port"
}

_plg_ss2022_inbound() {
    _plg_ss2022_enabled || return 0
    local _port _listen _method _key_mode _server _user
    _port=$(port_of ss2022)
    _listen=$(st_get '.ss2022.listen')
    _method=$(st_get '.ss2022.method')
    _key_mode=$(st_get '.ss2022.key_mode')
    _server=$(st_get '.ss2022.server_key')
    _user=$(st_get '.ss2022.user_key')
    _ss2022_validate_credentials "$_method" "$_key_mode" "$_server" "$_user" || return 1
    jq -n --argjson port "$_port" --arg listen "$_listen" --arg method "$_method" \
        --arg server "$_server" --arg user "$_user" --arg key_mode "$_key_mode" '{
        port:$port, listen:$listen, protocol:"shadowsocks",
        settings: ({method:$method, password:$server, network:"tcp,udp"} +
            if $key_mode == "dual" then {clients:[{password:$user, email:"xray2go-ss2022", level:0}]} else {} end)
    }'
}

_plg_ss2022_link() {
    _plg_ss2022_enabled || return 0
    local _listen _host _port _method _key_mode _server _user _raw _encoded
    _listen=$(st_get '.ss2022.listen')
    _method=$(st_get '.ss2022.method')
    _server=$(st_get '.ss2022.server_key')
    _user=$(st_get '.ss2022.user_key')
    _key_mode=$(st_get '.ss2022.key_mode')
    _ss2022_validate_credentials "$_method" "$_key_mode" "$_server" "$_user" || return 1
    _port=$(port_of ss2022)
    if [ "$_listen" = "0.0.0.0" ] || [ "$_listen" = "::" ]; then
        _host=$(platform_get_realip)
    else
        _host=$_listen
    fi
    [ -n "$_host" ] || { log_warn "无法获取服务器 IP，SS2022 节点已跳过"; return 0; }
    case "$_host" in
        *:*)
            case "$_host" in
                \[*\]*) : ;;
                *) _host="[$_host]" ;;
            esac
            ;;
    esac
    if [ "$_key_mode" = dual ]; then
        # 保留存量双密钥节点的分享格式。
        _raw=$(printf '%s:%s:%s' "$_method" "$_server" "$_user")
        _encoded=$(printf '%s' "$_raw" | base64 | tr '+/' '-_' | tr -d '=\n')
    else
        _encoded="$_method:$(urlencode_path "$_server")"
    fi
    printf 'ss://%s@%s:%s#Shadowsocks-2022\n' "$_encoded" "$_host" "$_port"
}
PLUGIN_EOF
}

_plugin_write_socks() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: socks (SOCKS5 inbound)

_plg_socks_enabled() {
    [ "$(st_get '.socks.enabled')" = "true" ]
}

_plg_socks_ports() {
    _plg_socks_enabled || return 0
    port_of socks
}

_plg_socks_inbound() {
    _plg_socks_enabled || return 0
    local _port _listen _user _pass
    _port=$(port_of socks)
    _listen=$(st_get '.socks.listen')
    _user=$(st_get '.socks.user')
    _pass=$(st_get '.socks.pass')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg user "${_user}" --arg pass "${_pass}" '{
        port:$port, listen:$listen, protocol:"socks",
        settings:{auth:"password", accounts:[{user:$user, pass:$pass}], udp:false}
    }'
}

_plg_socks_link() {
    _plg_socks_enabled || return 0
    local _ip _port _auth
    _ip=$(platform_get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，SOCKS5 节点已跳过"; return 0; }
    _port=$(port_of socks)
    _auth=$(printf '%s:%s' "$(st_get '.socks.user')" "$(st_get '.socks.pass')" | base64 | tr '+/' '-_' | tr -d '=\n')
    printf 'socks://%s@%s:%s#SOCKS5\n' "${_auth}" "${_ip}" "${_port}"
}
PLUGIN_EOF
}

_plugin_write_http() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: http (HTTP proxy inbound)

_plg_http_enabled() {
    [ "$(st_get '.http.enabled')" = "true" ]
}

_plg_http_ports() {
    _plg_http_enabled || return 0
    port_of http
}

_plg_http_inbound() {
    _plg_http_enabled || return 0
    local _port _listen _user _pass
    _port=$(port_of http)
    _listen=$(st_get '.http.listen')
    _user=$(st_get '.http.user')
    _pass=$(st_get '.http.pass')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg user "${_user}" --arg pass "${_pass}" '{
        port:$port, listen:$listen, protocol:"http",
        settings:{users:[{user:$user, pass:$pass}], allowTransparent:false, userLevel:0}
    }'
}

_plg_http_link() {
    _plg_http_enabled || return 0
    local _ip _port _user _pass
    _ip=$(platform_get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，HTTP 代理节点已跳过"; return 0; }
    _port=$(port_of http)
    _user=$(urlencode_path "$(st_get '.http.user')")
    _pass=$(urlencode_path "$(st_get '.http.pass')")
    printf 'http://%s:%s@%s:%s#HTTP-Proxy\n' "${_user}" "${_pass}" "${_ip}" "${_port}"
}
PLUGIN_EOF
}

_plugin_write_cforigin() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: cforigin (Cloudflare Origin Rule / Destination Port)

_cf_origin_tls_json() {
    local _domain _cert _key
    _domain=$(st_get '.cforigin.domain')
    _cert=$(st_get '.cforigin.cert')
    _key=$(st_get '.cforigin.key')
    [ "$(st_get '.cforigin.origin_tls')" = "true" ] || { printf '{}'; return 0; }
    [ -n "${_domain:-}" ] && [ -n "${_cert:-}" ] && [ -n "${_key:-}" ] || {
        log_error "CF Origin 已启用 TLS 回源但缺少域名或证书路径"; return 1; }
    jq -n --arg domain "${_domain}" --arg cert "${_cert}" --arg key "${_key}" '{
        security:"tls",
        tlsSettings:{serverName:$domain, certificates:[{certificateFile:$cert, keyFile:$key}]}
    }'
}

_plg_cforigin_enabled() {
    [ "$(st_get '.cforigin.enabled')" = "true" ]
}

_plg_cforigin_ports() {
    _plg_cforigin_enabled || return 0
    port_of cforigin
}

_plg_cforigin_inbound() {
    _plg_cforigin_enabled || return 0
    local _port _listen _uuid _proto _path _tls _profile
    _port=$(port_of cforigin)
    _listen=$(st_get '.cforigin.listen')
    _uuid=$(st_get '.uuid')
    _proto=$(st_get '.cforigin.protocol')
    _path=$(st_get '.cforigin.path')
    _tls=$(_cf_origin_tls_json) || return 1
    case "${_proto}" in
        ws)
            jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" \
                  --arg path "${_path}" --argjson tls "${_tls}" '{
                port:$port, listen:$listen, protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:({network:"ws", wsSettings:{path:$path}} + $tls)}' ;;
        httpupgrade)
            jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" \
                  --arg path "${_path}" --argjson tls "${_tls}" '{
                port:$port, listen:$listen, protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:({network:"httpupgrade", httpupgradeSettings:{path:$path}} + $tls)}' ;;
        xhttp)
            _profile=$(st_get '.cforigin.xhttp // {}') || return 1
            jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" \
                  --arg path "${_path}" --argjson tls "${_tls}" --argjson profile "${_profile}" '
                ({path:$path, mode:($profile.mode // "stream-one")} +
                  (if ($profile.server // {}) == {} then {} else {extra:$profile.server} end)) as $xhttp |
                {port:$port, listen:$listen, protocol:"vless",
                 settings:{clients:[{id:$uuid}], decryption:"none"},
                 streamSettings:({network:"xhttp", xhttpSettings:$xhttp} + $tls)}' ;;
        *) log_error "_plg_cforigin_inbound: 未知协议 ${_proto}"; return 1 ;;
    esac
}

_plg_cforigin_link() {
    _plg_cforigin_enabled || return 0
    local _domain _proto _uuid _edge_port _penc
    _domain=$(st_get '.cforigin.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    _proto=$(st_get '.cforigin.protocol')
    _uuid=$(st_get '.uuid')
    _edge_port=$(st_get '.cforigin.edge_port')
    _penc=$(urlencode_path "$(st_get '.cforigin.path')")
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&host=%s&path=%s#CF-Origin-WS\n' \
                "${_uuid}" "${_domain}" "${_edge_port}" "${_domain}" "${_domain}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&type=httpupgrade&host=%s&path=%s#CF-Origin-HTTPUpgrade\n' \
                "${_uuid}" "${_domain}" "${_edge_port}" "${_domain}" "${_domain}" "${_penc}" ;;
        xhttp) _cforigin_xhttp_link ;;
    esac
}
PLUGIN_EOF
}

_plugin_write_vlquic() {
cat << 'PLUGIN_EOF'
# xray-2go plugin: vlquic (VLESS + XHTTP stream-one H3)

_plg_vlquic_enabled() {
    [ "$(st_get '.vlquic.enabled')" = "true" ]
}

_plg_vlquic_ports() {
    _plg_vlquic_enabled || return 0
    printf '%s/udp\n' "$(port_of vlquic)"
}

_plg_vlquic_inbound() {
    _plg_vlquic_enabled || return 0
    local _port _listen _uuid _domain _cert _key _mode _extra
    _port=$(port_of vlquic)
    _listen=$(st_get '.vlquic.listen')
    _uuid=$(st_get '.uuid')
    _domain=$(st_get '.vlquic.domain')
    _cert=$(st_get '.vlquic.cert')
    _key=$(st_get '.vlquic.key')
    [ -n "${_domain:-}" ] && [ -n "${_cert:-}" ] && [ -n "${_key:-}" ] || {
        log_error "VLESS-XHTTP-H3 缺少域名或证书路径"; return 1; }
    _mode=$(st_get '.vlquic.xhttp.mode // "stream-one"') || return 1
    _extra=$(_xhttp_server_extra vlquic) || return 1
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" \
          --arg domain "${_domain}" --arg cert "${_cert}" --arg key "${_key}" \
          --arg mode "${_mode}" --argjson server "${_extra}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"},
        streamSettings:{
            network:"xhttp",
            security:"tls",
            tlsSettings:{serverName:$domain, alpn:["h3"], certificates:[{certificateFile:$cert, keyFile:$key}]},
            xhttpSettings:($server + {path:"/", mode:$mode})
        }}'
}

_plg_vlquic_link() {
    _plg_vlquic_enabled || return 0
    _vlquic_xhttp_link
}
PLUGIN_EOF
}

# ==============================================================================
# Firewall reconciliation
# ==============================================================================

# 汇总所有插件的期望防火墙规则（格式：port/proto）
fw_desired_rules() {
    local _rules
    _rules=$(plugin_collect_ports_raw "$@") || return 1
    [ -z "${_rules}" ] || sort -u <<< "${_rules}"
}

fw_desired_ports() {
    local _rules
    _rules=$(fw_desired_rules "$@") || return 1
    [ -z "${_rules}" ] || cut -d/ -f1 <<< "${_rules}" | sort -un
}

_fw_read_managed() {
    grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null | sort -un || true
}

_fw_read_managed_rules() {
    grep -E '^[a-z0-9_]+:[0-9]+/(tcp|udp)$' "${_FW_RULES_FILE}" 2>/dev/null | sort -u || true
}

_fw_mark_rule() {
    local _backend="$1" _port="$2" _proto="${3:-tcp}"
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if ! grep -qx "${_backend}:${_port}/${_proto}" "${_FW_RULES_FILE}" 2>/dev/null; then
        printf '%s:%s/%s\n' "${_backend}" "${_port}" "${_proto}" >> "${_FW_RULES_FILE}" 2>/dev/null || return 1
    fi
}

_fw_unmark_rule() {
    local _backend="$1" _port="$2" _proto="${3:-tcp}" _tmp
    [ -f "${_FW_RULES_FILE}" ] || return 0
    _tmp=$(tmp_file "fw_rules_XXXXXX") || return 1
    grep -Fvx "${_backend}:${_port}/${_proto}" "${_FW_RULES_FILE}" > "${_tmp}" 2>/dev/null || [ "$?" -eq 1 ] || return 1
    mv "${_tmp}" "${_FW_RULES_FILE}" 2>/dev/null
}

_fw_has_nftables() {
    command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1
}

_fw_select_backend() {
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then printf 'ufw'; return 0; fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then printf 'firewalld'; return 0; fi
    if _fw_has_nftables; then printf 'nft'; return 0; fi
    if command -v iptables >/dev/null 2>&1; then printf 'iptables'; return 0; fi
    printf 'none'
}

_fw_nft_handles() {
    awk -v protocol="$1" -v port="$2" '
        $1 == "chain" { input = ($2 == "input") }
        input && $1 == protocol && $2 == "dport" && $3 == port && $4 == "accept" &&
        NF == 7 && $5 == "#" && $6 == "handle" { print $7 }
    '
}

_fw_rule_state() {
    local _backend="$1" _layer="$2" _port="$3" _proto="$4" _listing _matches
    local -a _flags=()
    case "${_backend}" in
        nft)
            _listing=$(nft list tables 2>/dev/null) || return 1
            if ! grep -Fxq 'table inet xray2go' <<< "${_listing}"; then printf 0; return; fi
            if [ "${_layer}" = table ]; then printf 1; return; fi
            _listing=$(nft -a -nn list table inet xray2go 2>/dev/null) || return 1
            if [ "${_layer}" = chain ]; then
                if grep -Eq '^[[:space:]]*chain input[[:space:]]*\{' <<< "${_listing}"; then printf 1; else printf 0; fi
                return
            fi
            _matches=$(_fw_nft_handles "${_proto}" "${_port}" <<< "${_listing}") || return 1
            if [ -z "${_matches}" ]; then printf 0
            elif [[ "${_matches}" =~ ^[0-9]+$ ]]; then printf 'handle:%s' "${_matches}"
            else printf ambiguous; fi ;;
        ufw)
            _listing=$(LC_ALL=C ufw status 2>/dev/null) || return 1
            if grep -q '^Status: active$' <<< "${_listing}"; then
                awk -v rule="${_port}/${_proto}" '
                    { sub(/^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*/, "") }
                    $1 == rule {
                        action = ($2 == "(v6)" ? 3 : 2)
                        source = action + ($(action + 1) == "IN" ? 2 : 1)
                        last = source + (action == 3 ? 1 : 0)
                        if ($source == "Anywhere" && (action == 2 || $(last) == "(v6)")) {
                            if ($action == "ALLOW" && NF == last) {
                                if (action == 2) v4++; else v6++
                            } else if ($action == "ALLOW" && $(last + 1) == "#") external=1
                            else if ($action ~ /^(DENY|REJECT|LIMIT)$/) blocked=1
                        }
                    }
                    END {
                        if (v4 > 1 || v6 > 1 || (external && (v4 || v6))) print "ambiguous"
                        else if (v4 && v6) print "dual"
                        else if (v4) print "v4"
                        else if (v6) print "v6"
                        else if (blocked) print "blocked"
                        else if (external) print "external"
                        else print 0
                    }
                ' <<< "${_listing}"
            else
                grep -q '^Status: inactive$' <<< "${_listing}" || return 1
                _listing=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
                if grep -Fxq "ufw allow ${_port}/${_proto}" <<< "${_listing}"; then printf configured
                elif grep -Eq "^ufw (deny|reject|limit) ${_port}/${_proto}( |$)" <<< "${_listing}"; then printf blocked
                elif grep -Fq "ufw allow ${_port}/${_proto} " <<< "${_listing}"; then printf external
                else printf 0; fi
            fi ;;
        firewalld)
            [ "${_layer}" != permanent ] || _flags+=(--permanent)
            _listing=$(firewall-cmd "${_flags[@]}" --list-ports 2>/dev/null) || return 1
            awk -v rule="${_port}/${_proto}" '{ for (i=1; i<=NF; i++) if ($i == rule) found=1 } END { print found+0 }' \
                <<< "${_listing}" ;;
        iptables|ip6tables6)
            _listing=$("${_backend%6}" -S INPUT 2>/dev/null) || return 1
            _matches=$(grep -Ec -- "^-A INPUT -p ${_proto}( -m ${_proto})? --dport ${_port} -j ACCEPT$" <<< "${_listing}") || [ "$?" -eq 1 ] || return 1
            if [ "${_matches}" -le 1 ]; then printf '%s' "${_matches}"; else printf ambiguous; fi ;;
        *) return 1 ;;
    esac
}

_fw_nft_remove_empty() {
    local _object="$1" _listing
    if [ "${_object}" = chain ]; then
        _listing=$(nft -nn list chain inet xray2go input 2>/dev/null) || return 1
        awk 'NF { n++ }
            /^[[:space:]]*chain input[[:space:]]*\{[[:space:]]*$/ { chain=1 }
            $0 ~ /^[[:space:]]*type filter hook input priority (filter|0); policy accept;[[:space:]]*$/ { hook=1 }
            END { exit !(n==5 && chain && hook) }
        ' <<< "${_listing}" || return 1
        nft delete chain inet xray2go input 2>/dev/null
    else
        _listing=$(nft -nn list table inet xray2go 2>/dev/null) || return 1
        awk 'NF { n++ } END { exit !(n==2) }' <<< "${_listing}" || return 1
        nft delete table inet xray2go 2>/dev/null
    fi
}

_fw_change_backend() {
    local _backend="$1" _layer="$2" _port="$3" _proto="$4" _before="$5" _target="$6"
    local _rule="${_port}/${_proto}" _operation _handle _range
    local -a _flags=()
    case "${_backend}:${_layer}:${_target}" in
        nft:table:present) nft add table inet xray2go 2>/dev/null ;;
        nft:chain:present)
            nft add chain inet xray2go input '{ type filter hook input priority 0; policy accept; }' 2>/dev/null ;;
        nft:table:0|nft:chain:0) _fw_nft_remove_empty "${_layer}" ;;
        nft:rule:0)
            _handle=${_before#handle:}
            [[ "${_handle}" =~ ^[0-9]+$ ]] || return 1
            nft delete rule inet xray2go input handle "${_handle}" 2>/dev/null ;;
        nft:rule:*) nft add rule inet xray2go input "${_proto}" dport "${_port}" accept 2>/dev/null ;;
        ufw:*:0) LC_ALL=C ufw --force delete allow "${_rule}" >/dev/null 2>&1 ;;
        ufw:*:v4|ufw:*:v6)
            if [ "${_target}" = v4 ]; then _range=0.0.0.0/0; else _range=::/0; fi
            LC_ALL=C ufw allow proto "${_proto}" from "${_range}" to "${_range}" port "${_port}" >/dev/null 2>&1 ;;
        ufw:*) LC_ALL=C ufw allow "${_rule}" >/dev/null 2>&1 ;;
        firewalld:*)
            [ "${_layer}" != permanent ] || _flags+=(--permanent)
            if [ "${_target}" = 0 ]; then _operation=remove; else _operation=add; fi
            firewall-cmd "${_flags[@]}" "--${_operation}-port=${_rule}" >/dev/null 2>&1 ;;
        iptables:*|ip6tables6:*)
            if [ "${_target}" = 0 ]; then _operation=-D; else _operation=-I; fi
            "${_backend%6}" "${_operation}" INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null ;;
        *) return 1 ;;
    esac
}

_fw_state_matches() {
    case "$2" in
        present) [[ $1 != 0 && $1 != ambiguous && $1 != blocked && $1 != external ]] ;;
        *) [ "$1" = "$2" ] ;;
    esac
}

_fw_apply_step() {
    local _backend="$1" _layer="$2" _port="$3" _proto="$4" _before="$5" _target="$6"
    local _entry _state _step
    _fw_state_matches "${_before}" "${_target}" && return 0
    [ "${_before}" != ambiguous ] || return 1
    _state=$(_fw_rule_state "${_backend}" "${_layer}" "${_port}" "${_proto}") || return 1
    [ "${_state}" = "${_before}" ] || return 1
    _step=$((_FW_SEQUENCE + 1))
    _entry="${_FW_SCOPE_DIR}/firewall.${_step}"
    if ! printf '%s %s %s %s %s %s\n' "$@" > "${_entry}.before"; then
        _FW_RECORD_FAILED=1
        return 1
    fi
    _FW_SEQUENCE=${_step}
    _fw_change_backend "$@" || return 1
    if ! _state=$(_fw_rule_state "${_backend}" "${_layer}" "${_port}" "${_proto}") ||
       ! _fw_state_matches "${_state}" "${_target}" ||
       ! printf '%s\n' "${_state}" > "${_entry}.after"; then
        _FW_RECORD_FAILED=1
        return 1
    fi
}

_fw_ledger_snapshot_state() {
    local _snapshot="$1" _marker="$1.state" _expected _digest
    _expected="${_FW_LEDGER_STATE[${_snapshot##*/}]-}"
    [ -d "${_snapshot%/*}" ] && [ ! -L "${_snapshot%/*}" ] || return 1
    [ -f "${_marker}" ] && [ ! -L "${_marker}" ] || return 1
    [ -n "${_expected}" ] && cmp -s -- "${_marker}" <(printf '%s\n' "${_expected}") || return 1
    if [ "${_expected}" = absent ]; then
        [ ! -e "${_snapshot}" ] && [ ! -L "${_snapshot}" ] || return 1
        printf 'absent\n'
    else
        [ -f "${_snapshot}" ] && [ ! -L "${_snapshot}" ] || return 1
        _digest=$(sha256sum < "${_snapshot}") || return 1
        _digest=${_digest%% *}
        [ "present ${_digest}" = "${_expected}" ] || return 1
        printf '%s\n' "${_digest}"
    fi
}

_fw_restore_removed_rule_record() {
    local _rule="$1:$2/$3" _snapshot="${_FW_SCOPE_DIR}/firewall-ledgers/${_FW_RULES_FILE##*/}" _state
    _state=$(_fw_ledger_snapshot_state "${_snapshot}") || return 1
    [ "${_state}" != absent ] && grep -Fxq -- "${_rule}" "${_snapshot}" || return 1
    _fw_mark_rule "$@"
}

_fw_undo_step() {
    local _entry="$1" _backend _layer _port _proto _before _target _state _after
    read -r _backend _layer _port _proto _before _target < "${_entry}.before" || return 1
    # Restore ownership before recreating a formerly managed rule.
    if [ "${_target}" = 0 ]; then
        _fw_restore_removed_rule_record "${_backend}" "${_port}" "${_proto}" || return 1
    fi
    _state=$(_fw_rule_state "${_backend}" "${_layer}" "${_port}" "${_proto}") || return 1
    _fw_state_matches "${_state}" "${_before}" && return 0
    if [ -f "${_entry}.after" ] && [ -s "${_entry}.after" ]; then
        _after=$(<"${_entry}.after")
        _fw_state_matches "${_state}" "${_after}" || return 1
    elif [[ ${_backend}:${_before} == nft:0 ]]; then
        # A matching nft object may have been created by a concurrent writer.
        return 1
    elif ! _fw_state_matches "${_state}" "${_target}"; then
        # UFW may have removed just one address family before returning failure.
        [[ ${_backend}:${_before}:${_state}:${_target} == ufw:dual:v[46]:0 ]] || return 1
    fi
    _fw_change_backend "${_backend}" "${_layer}" "${_port}" "${_proto}" "${_state}" "${_before}" || return 1
    _state=$(_fw_rule_state "${_backend}" "${_layer}" "${_port}" "${_proto}") || return 1
    if [[ ${_before} == handle:* ]]; then
        [[ ${_state} == handle:* ]]
    else
        _fw_state_matches "${_state}" "${_before}"
    fi
}

_fw_scope_begin() {
    local _dir="$1" _file _snapshot _digest _state
    shift
    mkdir "${_dir}/firewall-ledgers" || return 1
    _FW_LEDGER_STATE=()
    for _file in "${_FW_RULES_FILE}" "$@"; do
        _snapshot="${_dir}/firewall-ledgers/${_file##*/}"
        if [ -e "${_file}" ] || [ -L "${_file}" ]; then
            [ -f "${_file}" ] && [ ! -L "${_file}" ] || return 1
            _digest=$(sha256sum < "${_file}") || return 1
            cp -a -- "${_file}" "${_snapshot}" || return 1
            _state="present ${_digest%% *}"
        else
            _state=absent
        fi
        _FW_LEDGER_STATE["${_file##*/}"]="${_state}"
        printf '%s\n' "${_state}" > "${_snapshot}.state" || return 1
        _fw_ledger_snapshot_state "${_snapshot}" >/dev/null || return 1
    done
    _FW_SCOPE_DIR="${_dir}"
    _FW_SEQUENCE=0
    _FW_RECORD_FAILED=0
}

_fw_keep_snapshot() {
    [ "${_FW_RECORD_FAILED}" -eq 1 ] || return 1
    log_error "防火墙变更记录失败，事务快照保留于：${_FW_SCOPE_DIR}"
    return 0
}

_fw_finish_standalone() {
    local _dir="${_FW_SCOPE_DIR}" _keep=0
    [ -n "${_dir}" ] || return 0
    if [ "$1" -ne 0 ] && ! _fw_restore_managed_snapshot; then
        log_error "防火墙回滚未完全成功，快照保留于：${_dir}"
        _keep=1
    elif _fw_keep_snapshot; then
        _keep=1
    fi
    _FW_SCOPE_DIR=""
    if [ "${_keep}" -eq 0 ] && ! rm -rf -- "${_dir}"; then
        log_warn "防火墙快照清理失败：${_dir}"
    fi
}

# Uninstall holds its own lock. Keep each successful removal on retry.
_fw_run() {
    if [ -n "${_FW_SCOPE_DIR}" ]; then "$@"; return $?; fi
    local _FW_SCOPE_DIR="" _FW_SEQUENCE=0 _FW_RECORD_FAILED=0
    local -A _FW_LEDGER_STATE=()
    local _dir _rc=0 _traps
    mkdir -p "${WORK_DIR}" || return 1
    _dir=$(mktemp -d "${WORK_DIR}/.txn_XXXXXX") || return 1
    if ! _fw_scope_begin "${_dir}"; then
        log_error "创建防火墙快照失败，快照保留于：${_dir}"
        return 1
    fi
    _traps=$(trap -p INT TERM)
    trap 'trap "" INT TERM; _fw_finish_standalone 130; _trap_int' INT TERM
    "$@" || _rc=$?
    _fw_finish_standalone "${_rc}"
    trap - INT TERM
    eval "${_traps}"
    return "${_rc}"
}

_fw_open_port_backend() { _fw_run _fw_open_port_inner "$@"; }

_fw_open_port_inner() {
    local _backend="$1" _port="$2" _proto="${3:-tcp}" _state _permanent
    if [ "${_backend}" = firewalld ]; then
        _permanent=$(_fw_rule_state firewalld permanent "${_port}" "${_proto}") || return 1
        _state=$(_fw_rule_state firewalld runtime "${_port}" "${_proto}") || return 1
        if ! _fw_read_managed_rules | grep -Fxq "firewalld:${_port}/${_proto}" &&
           { [ "${_permanent}" = 1 ] || [ "${_state}" = 1 ]; }; then
            log_info "防火墙端口已存在（未纳入托管）: ${_port}/${_proto} (${_backend})"
            return 0
        fi
        _fw_apply_step firewalld permanent "${_port}" "${_proto}" "${_permanent}" present || return 1
        _fw_apply_step firewalld runtime "${_port}" "${_proto}" "${_state}" present || return 1
    else
        _state=$(_fw_rule_state "${_backend}" rule "${_port}" "${_proto}") || return 1
        if [ "${_state}" = blocked ]; then
            log_warn "UFW 已有拒绝或限流规则：${_port}/${_proto}"
            return 1
        fi
        if [ "${_state}" != 0 ]; then
            log_info "防火墙端口已存在（未纳入托管）: ${_port}/${_proto} (${_backend})"
            return 0
        fi
        if [ "${_backend}" = nft ]; then
            local _layer _exists
            for _layer in table chain; do
                _exists=$(_fw_rule_state nft "${_layer}" 0 tcp) || return 1
                _fw_apply_step nft "${_layer}" 0 tcp "${_exists}" present || return 1
            done
        fi
        _fw_apply_step "${_backend}" rule "${_port}" "${_proto}" "${_state}" present || return 1
    fi
    if ! _fw_mark_rule "${_backend}" "${_port}" "${_proto}"; then
        _FW_RECORD_FAILED=1
        return 1
    fi
    log_ok "防火墙已开放: ${_port}/${_proto} (${_backend})"
}

_fw_open_port() {
    local _port="$1" _proto="${2:-tcp}" _backend
    _backend=$(_fw_select_backend)
    [ "${_backend}" != "none" ] || { log_info "未检测到可用防火墙后端，跳过: ${_port}/${_proto}"; return 0; }
    if ! _fw_open_port_backend "${_backend}" "${_port}" "${_proto}"; then
        log_warn "防火墙开放失败: ${_port}/${_proto} (${_backend})"
        return 1
    fi
}

_fw_close_port() {
    local _port="$1" _proto="$2" _backend="$3"
    if ! _fw_run _fw_close_port_inner "${_port}" "${_proto}" "${_backend}"; then
        log_warn "防火墙规则待清理: ${_port}/${_proto} (${_backend})"
        return 1
    fi
    log_info "防火墙托管规则已清理: ${_port}/${_proto} (${_backend})"
}

_fw_close_port_inner() {
    local _port="$1" _proto="$2" _backend="$3" _permanent _state
    if [ "${_backend}" = firewalld ]; then
        _permanent=$(_fw_rule_state firewalld permanent "${_port}" "${_proto}") || return 1
        _state=$(_fw_rule_state firewalld runtime "${_port}" "${_proto}") || return 1
        _fw_apply_step firewalld permanent "${_port}" "${_proto}" "${_permanent}" 0 || return 1
        _fw_apply_step firewalld runtime "${_port}" "${_proto}" "${_state}" 0 || return 1
    else
        _state=$(_fw_rule_state "${_backend}" rule "${_port}" "${_proto}") || return 1
        if [[ ${_state} != blocked && ${_state} != external ]]; then
            _fw_apply_step "${_backend}" rule "${_port}" "${_proto}" "${_state}" 0 || return 1
        fi
    fi
    if ! _fw_unmark_rule "${_backend}" "${_port}" "${_proto}"; then
        _FW_RECORD_FAILED=1
        return 1
    fi
}

fw_reconcile() {
    log_step "同步防火墙规则..."
    mkdir -p "${WORK_DIR}"
    local _expected_rules _expected_ports _rule _rp _rb _rproto _want _failed=0
    _expected_rules=$(fw_desired_rules) || return 1
    _expected_ports=$(printf '%s\n' "${_expected_rules}" | cut -d/ -f1 | grep -E '^[0-9]+$' | sort -un || true)

    for _rule in $(_fw_read_managed_rules); do
        _rb=${_rule%%:*}
        _rp=${_rule#*:}; _rproto=${_rp#*/}; _rp=${_rp%/*}
        _want="${_rp}/${_rproto}"
        printf '%s\n' "${_expected_rules}" | grep -qx "${_want}" || \
            _fw_close_port "${_rp}" "${_rproto}" "${_rb}" || _failed=1
    done

    while IFS= read -r _rule; do
        [ -n "${_rule:-}" ] || continue
        _rp=${_rule%/*}; _rproto=${_rule#*/}
        _fw_open_port "${_rp}" "${_rproto}" || _failed=1
    done <<EOF
${_expected_rules}
EOF

    if [ "${_failed}" -eq 0 ]; then
        if [ -n "${_expected_ports:-}" ]; then
            printf '%s\n' "${_expected_ports}" > "${_FW_PORTS_FILE}" 2>/dev/null || _failed=1
        else
            rm -f "${_FW_PORTS_FILE}" 2>/dev/null || _failed=1
        fi
        [ "${_failed}" -eq 0 ] || _FW_RECORD_FAILED=1
    fi
    [ "${_failed}" -eq 0 ] || { log_error "部分防火墙规则同步失败"; return 1; }
}

_fw_restore_ledger() {
    local _file="$1" _snapshot="${_FW_SCOPE_DIR}/firewall-ledgers/${1##*/}" _state _staged _digest
    _state=$(_fw_ledger_snapshot_state "${_snapshot}") || return 1
    if [ "${_state}" = absent ]; then
        rm -f -- "${_file}"
        return $?
    fi
    # Stage the verified copy so a failed copy leaves the current ledger intact.
    _staged=$(mktemp "${_snapshot}.restore_XXXXXX") || return 1
    cp -a -- "${_snapshot}" "${_staged}" || return 1
    [ -f "${_staged}" ] && [ ! -L "${_staged}" ] || return 1
    _digest=$(sha256sum < "${_staged}") || return 1
    [ "${_digest%% *}" = "${_state}" ] || return 1
    mv -fT -- "${_staged}" "${_file}"
}

_fw_restore_managed_snapshot() {
    local _step _entry _failed=0 _file
    for ((_step=_FW_SEQUENCE; _step>0; _step--)); do
        _entry="${_FW_SCOPE_DIR}/firewall.${_step}"
        if ! _fw_undo_step "${_entry}"; then
            log_warn "无法恢复防火墙变更：${_entry}.before"
            _failed=1
        fi
    done
    # Keep current ownership evidence if any live change could not be undone.
    if [ "${_failed}" -eq 0 ] && ! _fw_restore_ledger "${_FW_RULES_FILE}"; then
        log_warn "无法恢复防火墙账本：${_FW_RULES_FILE}"
        _failed=1
    fi
    for _file; do
        if ! _fw_restore_ledger "${_file}"; then
            log_warn "无法恢复防火墙账本：${_file}"
            _failed=1
        fi
    done
    [ "${_failed}" -eq 0 ]
}

fw_force_cleanup() {
    log_step "清理 xray2go 托管防火墙规则..."
    local _rule _rp _rb _rproto _failed=0
    if [ -s "${_FW_PORTS_FILE}" ] && [ ! -s "${_FW_RULES_FILE}" ]; then
        log_warn "旧端口记录无法确认规则归属，已保留对应的防火墙规则"
    fi
    for _rule in $(_fw_read_managed_rules); do
        _rb=${_rule%%:*}
        _rp=${_rule#*:}; _rproto=${_rp#*/}; _rp=${_rp%/*}
        _fw_close_port "${_rp}" "${_rproto}" "${_rb}" || _failed=1
    done
    [ "${_failed}" -eq 0 ] || return 1
    rm -f "${_FW_PORTS_FILE}" "${_FW_RULES_FILE}" || return 1
    log_ok "防火墙规则清理完成"
}

# ==============================================================================
# §L_LIFECYCLE  系统变更生命周期（可追踪、可回滚）
# ==============================================================================
lifecycle_apply_sysctl() {
    is_openrc || return 0
    log_step "持久化内核参数..."
    local _content
    _content=$(printf '# xray2go managed - do not edit manually\nnet.ipv4.ping_group_range = 0 0\n')
    atomic_write "${_SYSCTL_FILE}" "${_content}" || {
        log_warn "sysctl drop-in 写入失败"; return 0; }
    sysctl -p "${_SYSCTL_FILE}" >/dev/null 2>&1 || true
    log_ok "sysctl 已持久化: ${_SYSCTL_FILE}"
}
lifecycle_rollback_sysctl() {
    [ -f "${_SYSCTL_FILE}" ] || return 0
    grep -Fxq '# xray2go managed - do not edit manually' "${_SYSCTL_FILE}" || return 0
    rm -f "${_SYSCTL_FILE}" || { log_error "sysctl drop-in 清理失败"; return 1; }
    log_info "sysctl drop-in 已清除"
}
lifecycle_apply_hosts_patch() {
    is_openrc || return 0
    [ -f "${_HOSTS_FILE}" ] && [ ! -L "${_HOSTS_FILE}" ] || return 1
    local _tmp _mapping _rc _added=0
    _tmp=$(mktemp "${_HOSTS_FILE}.xray2go.XXXXXX") || return 1
    cp -p "${_HOSTS_FILE}" "${_tmp}" || { rm -f "${_tmp}"; return 1; }
    for _mapping in '127.0.0.1 localhost' '::1 localhost'; do
        _rc=0
        awk -v ip="${_mapping% *}" '
            { sub(/#.*/, "") }
            $1 == ip { for (i=2; i<=NF; i++) if (tolower($i) == "localhost") found=1 }
            END { exit !found }
        ' "${_tmp}" && continue || _rc=$?
        [ "${_rc}" -eq 1 ] || { rm -f "${_tmp}"; return 1; }
        if [ "${_added}" -eq 0 ] && [ -s "${_tmp}" ] && [ -n "$(tail -c 1 "${_tmp}")" ]; then
            printf '\n' >> "${_tmp}" || { rm -f "${_tmp}"; return 1; }
        fi
        printf '%s\n' "${_mapping} # xray2go-managed" >> "${_tmp}" || { rm -f "${_tmp}"; return 1; }
        _added=1
    done
    if [ "${_added}" -eq 0 ]; then rm -f "${_tmp}"; return $?; fi
    mv -f -- "${_tmp}" "${_HOSTS_FILE}" || { rm -f "${_tmp}"; return 1; }
    log_ok "hosts 已补齐必要映射"
}
lifecycle_rollback_hosts() {
    if [ -f "${_HOSTS_BAK}" ]; then
        log_warn "检测到旧版 hosts 备份 ${_HOSTS_BAK}；未覆盖当前 hosts，备份已保留，请人工核对"
    fi
    [ -f "${_HOSTS_FILE}" ] && [ ! -L "${_HOSTS_FILE}" ] || return 0
    local _tmp _rc=0
    grep -Eq '^(127\.0\.0\.1|::1) localhost # xray2go-managed$' "${_HOSTS_FILE}" || _rc=$?
    [ "${_rc}" -eq 0 ] || return "$(( _rc != 1 ))"
    _tmp=$(mktemp "${_HOSTS_FILE}.xray2go.XXXXXX") || return 1
    cp -p "${_HOSTS_FILE}" "${_tmp}" && awk '
        $0 == "127.0.0.1 localhost # xray2go-managed" { next }
        $0 == "::1 localhost # xray2go-managed" { next }
        { print }
    ' "${_HOSTS_FILE}" > "${_tmp}" && mv -f -- "${_tmp}" "${_HOSTS_FILE}" || {
        rm -f "${_tmp}"
        return 1
    }
}

# ==============================================================================
# Service adapter
# ==============================================================================
_G_SYSD_DIRTY=0

svc_exec() {
    local _act="$1" _name="$2" _rc=0
    if is_systemd; then
        case "${_act}" in
            enable)  systemctl enable  "${_name}" >/dev/null 2>&1; _rc=$? ;;
            disable) systemctl disable "${_name}" >/dev/null 2>&1; _rc=$? ;;
            status)  systemctl is-active --quiet "${_name}" 2>/dev/null; _rc=$? ;;
            *)       systemctl "${_act}" "${_name}" >/dev/null 2>&1; _rc=$? ;;
        esac
    else
        case "${_act}" in
            enable)  rc-update add "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            disable) rc-update del "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            status)  rc-service "${_name}" status >/dev/null 2>&1; _rc=$? ;;
            *)       rc-service "${_name}" "${_act}" >/dev/null 2>&1; _rc=$? ;;
        esac
    fi
    return "${_rc}"
}

# 0 active, 1 stopped, 2 unknown, 3 service absent.
_svc_runtime_state() {
    local _name="$1" _rc=0
    svc_exec status "${_name}" >/dev/null 2>&1 || _rc=$?
    case "${_rc}" in
        0) return 0 ;;
        3) return 1 ;;
    esac
    if is_systemd; then
        [ "${_rc}" -eq 4 ] && return 3
    elif is_openrc; then
        if [ "${_rc}" -eq 1 ] &&
            [ ! -e "${_SVC_OPENRC_DIR}/${_name}" ] && [ ! -L "${_SVC_OPENRC_DIR}/${_name}" ]; then
            return 3
        fi
    elif [ "${_rc}" -eq 1 ]; then
        return 1
    fi
    return 2
}

svc_status() {
    local _status=0
    _svc_runtime_state "$1" || _status=$?
    case "${_status}" in
        3) return 1 ;;
        *) return "${_status}" ;;
    esac
}

svc_enabled_status() {
    local _name="$1" _rc
    _rc=0
    svc_is_enabled "${_name}" >/dev/null 2>&1 || _rc=$?
    [ "${_rc}" -eq 0 ] && return 0
    if is_systemd && [ "${_rc}" -eq 4 ]; then return 1; fi
    [ "${_rc}" -eq 1 ] && return 1
    return 2
}

svc_is_enabled() {
    local _name="$1"
    if is_systemd; then
        systemctl is-enabled --quiet "${_name}" >/dev/null 2>&1
    elif is_openrc; then
        local _runlevel
        _runlevel=$(rc-update show default 2>/dev/null) || return 2
        awk -v n="${_name}" '$1 == n { found=1 } END { exit(found ? 0 : 1) }' <<< "${_runlevel}"
    else
        return 2
    fi
}

svc_reload_daemon() {
    is_systemd && [ "${_G_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || { log_error "刷新 systemd 服务单元失败"; return 1; }
    _G_SYSD_DIRTY=0
}

# 服务状态变更互斥锁：start/stop/restart/enable/disable 统一通过此接口
# 只读状态查询不加锁，避免死锁
_SVC_LOCK_FILE="${WORK_DIR}/.svc_lock"
svc_exec_mut() {
    # 用法同 svc_exec，但对 mutating 操作加独立锁
    local _act="$1"
    case "${_act}" in
        status) svc_exec "$@"; return $? ;;  # 只读不加锁
    esac
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9 || { log_error "获取 svc 锁失败"; exit 1; }
          svc_exec "$@"
        ) 9>"${_SVC_LOCK_FILE}"
    else
        svc_exec "$@"
    fi
}

_svc_write_file() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    if [ "${_cur}" != "${_content}" ]; then
        atomic_write "${_dest}" "${_content}" || return 1
        is_systemd && _G_SYSD_DIRTY=1
    fi
    return 0
}

# ── 配置重载策略 ──────────────────────────────────────────────────────────────
# 遵循保守、可验证的服务管理路径：不依赖未确认的信号重载契约，统一通过 init 系统 restart。
svc_reload_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在"; return 1; }

    local _new_hash
    _new_hash=$(sha256sum "${CONFIG_FILE}" 2>/dev/null | awk '{print $1}') || \
        _new_hash=$(md5sum  "${CONFIG_FILE}" 2>/dev/null | awk '{print $1}') || \
        _new_hash="unknown"

    local _old_hash=""
    [ -f "${_CONFIG_HASH_FILE}" ] && _old_hash=$(cat "${_CONFIG_HASH_FILE}" 2>/dev/null || true)

    if [ "${1:-}" != force ] && [ "${_new_hash}" = "${_old_hash}" ] && [ "${_new_hash}" != "unknown" ]; then
        log_info "config.json 未变化，跳过 restart"
        return 0
    fi

    log_step "重启 xray2go 以加载新配置..."
    # 兼容旧版本/异常中断造成的 systemd active(not-found) 状态：
    # 进程仍在运行，但 unit 文件不存在时，systemctl restart 会直接失败。
    # 因此每次重载配置前都先确保托管服务单元存在并刷新 daemon。
    svc_apply_xray || { log_error "xray2go 服务单元写入失败"; return 1; }
    svc_reload_daemon || return 1
    if [ "${_TXN_ACTIVE}" -eq 1 ]; then
        _TXN_XRAY_RESTART_ATTEMPTED=1
    fi
    svc_exec_mut restart "${_SVC_XRAY}" || { log_error "xray restart 失败"; return 1; }
    svc_verify_health "${_SVC_XRAY}" 6 || { log_error "xray 重载后未确认运行，未更新配置哈希"; return 1; }
    printf '%s' "${_new_hash}" > "${_CONFIG_HASH_FILE}" 2>/dev/null || return 1
    log_ok "xray 已重启并加载新配置"
}

# ── 服务单元模板 ──────────────────────────────────────────────────────────────

_svc_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray2go Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectHome=yes\nProtectSystem=full\nReadWritePaths=%s\nExecStart=%s run -c %s\nRestart=always\nRestartSec=3\nRestartPreventExitStatus=23\nLimitNOFILE=1048576\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${WORK_DIR}" "${XRAY_BIN}" "${CONFIG_FILE}"
}

_svc_tpl_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray2go service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\noutput_log="/dev/null"\nerror_log="/dev/null"\npidfile="/var/run/xray2go.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

# tunnel 服务：按 Cloudflare 官方两类运行方式区分：
#   - token/remote-managed tunnel：cloudflared tunnel run --token <token>
#   - credentials/local-managed tunnel：cloudflared tunnel --config <config.yml> run
_svc_tpl_tunnel_systemd() {
    local _token; _token=$(st_get '.argo.token')
    if [ -n "${_token:-}" ] && [ "${_token}" != "null" ] && [ ! -f "${WORK_DIR}/tunnel.json" ]; then
        # token 模式采用 Cloudflare 官方 --token 参数；token 通过 0600 EnvironmentFile 注入，避免写入 unit 和 tunnel.yml。
        # 注意：官方 token CLI 模式会把 token 展开到进程 argv；若本机多用户不可信，请优先使用 credentials/local-managed 模式或加固 /proc 可见性。
        printf '[Unit]\nDescription=Cloudflare Tunnel2go (token mode)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectHome=yes\nProtectSystem=full\nReadWritePaths=%s\nTimeoutStartSec=0\nEnvironmentFile=%s\nExecStart=%s tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}\nRestart=on-failure\nRestartSec=5\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' \
            "${WORK_DIR}" "${_ARGO_ENV_FILE}" "${ARGO_BIN}"
    else
        printf '[Unit]\nDescription=Cloudflare Tunnel2go (credentials mode)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nPrivateTmp=yes\nProtectHome=yes\nProtectSystem=full\nReadWritePaths=%s\nTimeoutStartSec=0\nEnvironmentFile=-%s\nExecStart=%s tunnel --no-autoupdate --config %s run\nRestart=on-failure\nRestartSec=5\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' \
            "${WORK_DIR}" "${_ARGO_ENV_FILE}" "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    fi
}

_svc_tpl_tunnel_openrc() {
    local _token; _token=$(st_get '.argo.token')
    if [ -n "${_token:-}" ] && [ "${_token}" != "null" ] && [ ! -f "${WORK_DIR}/tunnel.json" ]; then
        # 不 source env 文件，避免把动态文件作为 shell 代码执行；只解析固定 TUNNEL_TOKEN 键。
        printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go (token mode)"\ndepend() { need net; }\nstart() {\n    if [ -f %s ]; then\n        TUNNEL_TOKEN=$(grep -m1 "^TUNNEL_TOKEN=" %s | cut -d= -f2-)\n        export TUNNEL_TOKEN\n    fi\n    ebegin "Starting tunnel2go"\n    start-stop-daemon --start --background \\\n        --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n        --exec %s -- tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}"\n    eend $?\n}\nstop() { start-stop-daemon --stop --pidfile /var/run/tunnel2go.pid; }\n' \
            "${_ARGO_ENV_FILE}" "${_ARGO_ENV_FILE}" "${ARGO_BIN}"
    else
        printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go (credentials mode)"\ndepend() { need net; }\nstart() {\n    ebegin "Starting tunnel2go"\n    start-stop-daemon --start --background \\\n        --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n        --exec %s -- tunnel --no-autoupdate --config %s run\n    eend $?\n}\nstop() { start-stop-daemon --stop --pidfile /var/run/tunnel2go.pid; }\n' \
            "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    fi
}

_svc_write_argo_env() {
    local _token; _token=$(st_get '.argo.token')
    # token 写入 env file 前做最终格式校验，防止 state 被手工篡改后落盘异常 token。
    # credentials 模式下 token 为空/null，写入空 env 值即可。
    # env file 格式：KEY=VALUE（不加引号，cloudflared 直接读）。
    local _safe_token="${_token:-}"
    _safe_token=$(printf '%s' "${_safe_token}" | tr -d '\n\r')
    val_argo_token "${_safe_token}" >/dev/null || return 1
    [ "${_safe_token}" = "null" ] && _safe_token=""
    atomic_write_secret "${_ARGO_ENV_FILE}" "$(printf 'ARGO_TOKEN=%s\nTUNNEL_TOKEN=%s\n' "${_safe_token}" "${_safe_token}")" \
        || { log_error "Argo env 写入失败"; return 1; }
    chmod 600 "${_ARGO_ENV_FILE}" 2>/dev/null || true
}

svc_apply_xray() {
    if is_systemd; then
        _svc_write_file "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service" "$(_svc_tpl_xray_systemd)" || return 1
    else
        local _f="${_SVC_OPENRC_DIR}/${_SVC_XRAY}"
        _svc_write_file "${_f}" "$(_svc_tpl_xray_openrc)" || return 1
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_apply_tunnel() {
    _svc_write_argo_env || return 1
    if is_systemd; then
        _svc_write_file "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service" "$(_svc_tpl_tunnel_systemd)" || return 1
    else
        local _f="${_SVC_OPENRC_DIR}/${_SVC_TUNNEL}"
        _svc_write_file "${_f}" "$(_svc_tpl_tunnel_openrc)" || return 1
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_restart_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在"; return 1; }
    svc_apply_xray || { log_error "xray2go 服务单元写入失败"; return 1; }
    svc_reload_daemon || return 1
    if [ "${_TXN_ACTIVE}" -eq 1 ]; then
        _TXN_XRAY_RESTART_ATTEMPTED=1
    fi
    svc_exec_mut restart "${_SVC_XRAY}" \
        && { log_ok "${_SVC_XRAY} 已重启"; svc_verify_health "${_SVC_XRAY}" 6; } \
        || { log_error "${_SVC_XRAY} 重启失败"; return 1; }
}

svc_enable_start_verify() {
    local _svc="$1" _max="${2:-0}" _mode="${3:-required}"
    local _enable_rc=0
    svc_exec_mut enable "${_svc}" || _enable_rc=$?
    if [ "${_enable_rc}" -ne 0 ] && [ "${_mode}" = "required" ]; then
        log_error "${_svc} 开机启用失败"
        return 1
    elif [ "${_enable_rc}" -ne 0 ]; then
        log_warn "${_svc} 开机启用失败（可稍后检查）"
    fi
    if ! svc_exec_mut start  "${_svc}"; then
        if [ "${_mode}" = "optional" ]; then
            log_warn "${_svc} 启动失败（可稍后在对应管理菜单重新检查配置）"
            return 0
        fi
        log_error "${_svc} 启动命令失败"
        return 1
    fi
    if [ "${_max}" -gt 0 ]; then
        svc_verify_health "${_svc}" "${_max}" || return 1
    fi
    log_ok "${_svc} 已启动"
}

svc_verify_health() {
    local _svc="${1:-${_SVC_XRAY}}" _max="${2:-8}"
    log_step "验证服务 ${_svc} 就绪（最长 ${_max}s）..."
    local _i=0
    while [ "${_i}" -lt "${_max}" ]; do
        sleep 1; _i=$(( _i + 1 ))
        svc_exec status "${_svc}" >/dev/null 2>&1 && {
            log_ok "${_svc} 运行正常 (${_i}s 内就绪)"; return 0; }
    done
    log_error "${_svc} 启动失败"
    # systemd status and journal output may include the tunnel token.
    if [ "${_svc}" = "${_SVC_TUNNEL}" ]; then
        log_warn "请检查本地 Tunnel 服务和认证配置"
    elif is_systemd; then
        journalctl -u "${_svc}" --no-pager -n 20 2>/dev/null >&2 || true
        systemctl status "${_svc}" --no-pager -l 2>/dev/null >&2 || true
    fi
    return 1
}

# ==============================================================================
# Crypto helpers
# ==============================================================================
crypto_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0;printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

crypto_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; return 1; }
    local _out; _out=$("${XRAY_BIN}" x25519 2>&1) || { log_error "xray x25519 失败"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')
    [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ] && { log_error "密钥解析失败"; return 1; }
    printf '%s' "${_pvk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "私钥格式异常"; return 1; }
    printf '%s' "${_pbk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "公钥格式异常"; return 1; }
    st_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}"
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

crypto_gen_reality_sid() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    command -v xxd    >/dev/null 2>&1 && { head -c 8 /dev/urandom | xxd -p | tr -d '\n'; return; }
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# Trojan 密码：32 位十六进制，字符集是 val_trojan_password 允许集合的子集，
# 因此生成值永远不会破坏分享链接的 URI 结构。
crypto_gen_trojan_password() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 16 2>/dev/null; return; }
    command -v xxd    >/dev/null 2>&1 && { head -c 16 /dev/urandom | xxd -p | tr -d '\n'; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
crypto_gen_ss2022_key() {
    local _method="${1}" _bytes _key
    _bytes=$(ss2022_key_bytes "${_method}") || {
        log_error "无法为未知 SS2022 方法生成密钥"; return 1;
    }
    if command -v openssl >/dev/null 2>&1; then
        _key=$(openssl rand -base64 "${_bytes}" 2>/dev/null) || {
            log_error "SS2022 密钥生成命令失败"; return 1;
        }
    else
        _key=$(head -c "${_bytes}" /dev/urandom | base64 2>/dev/null) || {
            log_error "系统随机源不可用，无法生成 SS2022 密钥"; return 1;
        }
    fi
    _key=$(printf '%s' "${_key}" | tr -d '\n') || return 1
    [ -n "${_key}" ] || {
        log_error "SS2022 密钥生成结果为空"; return 1;
    }
    val_ss2022_key "${_method}" "${_key}" >/dev/null 2>&1 || {
        log_error "SS2022 密钥生成结果格式无效"; return 1;
    }
    printf '%s' "${_key}"
}

# ==============================================================================
# Config synthesis and apply
# ==============================================================================

# 遍历插件注册表，收集所有 inbound → JSON 数组
_is_wild_listen() {
    case "${1:-}" in
        ::|0.0.0.0) return 0 ;;
        *) return 1 ;;
    esac
}

config_build_inbounds() {
    plugin_collect_inbounds
}

config_synthesize() {
    local _ibs
    _ibs=$(config_build_inbounds) || return 1
    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行"
    jq -n --argjson inbounds "${_ibs}" '{
        log: {loglevel:"none", access:"none", error:"none"},
        inbounds: $inbounds,
        outbounds: [{protocol:"freedom", settings:{domainStrategy:"AsIs"}}],
        policy: {
            levels: {"0": {connIdle:300, uplinkOnly:1, downlinkOnly:1,
                statsUserUplink:false, statsUserDownlink:false}},
            system: {statsInboundUplink:false, statsInboundDownlink:false}
        }
    }' || { log_error "config JSON 合成失败"; return 1; }
}

_config_apply_inner() {
    local _mode="${1:-}" _reload="${2:-}" _t _json _failed_config="${WORK_DIR}/config_failed.json"
    _ensure_tmp_dir
    _t=$(tmp_file "xray_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    if [ "${_TXN_ACTIVE:-0}" -eq 1 ]; then
        _st_track_managed_certificates && _plugin_snapshot_ensure || { rm -f -- "${_t}"; return 1; }
    fi
    config_synthesize > "${_t}" || { rm -f -- "${_t}"; return 1; }

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            if chmod 600 "${_t}" && mv -fT -- "${_t}" "${_failed_config}"; then
                log_error "config 验证失败！已保留: ${_failed_config}"
            else
                log_error "config 验证失败，config_failed.json 保存失败: ${_failed_config}"
                rm -f -- "${_t}"
            fi
            return 1
        fi
        log_ok "config 验证通过"
    elif [ "${_mode}" = tls ]; then
        log_error "xray 未就绪，无法验证换证后的配置"
        rm -f -- "${_t}"
        return 1
    else
        log_warn "xray 未就绪，跳过预检（安装阶段正常）"
    fi

    _json=$(cat "${_t}") || { rm -f -- "${_t}"; return 1; }
    atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 2 || {
        rm -f -- "${_t}"
        log_error "config 写入失败"; return 1; }
    rm -f "${_t}" 2>/dev/null || true
    log_ok "config.json 已原子更新"

    # 管理菜单换证可强制加载新 TLS 材料，其他配置更新仍仅重启运行中的服务。
    if [ "${_reload}" = force ] || svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1; then
        svc_reload_xray "${_reload}" || return 1
    fi
}

config_apply() { with_lock _config_apply_inner "$@"; }

config_print_nodes() {
    [ "${_MENU_HIDE_LINKS:-0}" -eq 0 ] || return 0
    local _links
    _links=$(plugin_collect_links "${1:-}") || return 1

    if [ -z "${_links:-}" ]; then
        echo ""; log_warn "暂无可用节点"; return 1
    fi
    echo ""
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        _print_link "${_l}"
    done
    echo ""
}

# ==============================================================================
# 统一事务：锁定、快照、应用失败回滚
# ==============================================================================
_transaction_collect_artifacts() {
    _TXN_ARTIFACT_PATHS=(
        "${CONFIG_FILE}"
        "${STATE_FILE}"
        "${_CONFIG_HASH_FILE}"
        "${_ARGO_ENV_FILE}"
        "${ARGO_BIN}"
        "${_ACME_ENV_FILE}"
        "${WORK_DIR}/tunnel.yml"
        "${WORK_DIR}/tunnel.json"
        "${_SVC_SYSTEMD_DIR}/${_SVC_XRAY}.service"
        "${_SVC_SYSTEMD_DIR}/${_SVC_TUNNEL}.service"
        "${_SVC_OPENRC_DIR}/${_SVC_XRAY}"
        "${_SVC_OPENRC_DIR}/${_SVC_TUNNEL}"
        "${_SYSCTL_FILE}"
        "${_cert_artifacts[@]}"
    )
    local _p
    for _p in "${STATE_FILE}".*.bak "${CONFIG_FILE}".*.bak; do
        [ -e "${_p}" ] || continue
        _TXN_ARTIFACT_PATHS+=("${_p}")
    done
}

_transaction_lock_acquire() {
    command -v flock >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "${_LOCK_FILE}")" || return 1
    exec {_TXN_LOCK_FD}>"${_LOCK_FILE}" || return 1
    flock -x "${_TXN_LOCK_FD}" || {
        eval "exec ${_TXN_LOCK_FD}>&-" 2>/dev/null || true
        _TXN_LOCK_FD=""
        return 1
    }
}

_transaction_lock_release() {
    [ -n "${_TXN_LOCK_FD:-}" ] || return 0
    flock -u "${_TXN_LOCK_FD}" 2>/dev/null || true
    eval "exec ${_TXN_LOCK_FD}>&-" 2>/dev/null || true
    _TXN_LOCK_FD=""
}

_transaction_snapshot_file() {
    local _p="$1" _i="$2" _exists=0
    if [ -e "${_p}" ] || [ -L "${_p}" ]; then
        _exists=1
        cp -a -- "${_p}" "${_TXN_DIR}/files/${_i}" || return 1
    fi
    printf '%s\t%s\t%s\n' "${_i}" "${_exists}" "${_p}" >> "${_TXN_DIR}/manifest"
}

_transaction_snapshot_files() {
    local _i=0 _p
    _transaction_collect_artifacts
    mkdir -p "${_TXN_DIR}/files"
    : > "${_TXN_DIR}/manifest"
    for _p in "${_TXN_ARTIFACT_PATHS[@]}"; do
        _transaction_snapshot_file "${_p}" "${_i}" || return 1
        _i=$(( _i + 1 ))
    done
}

_transaction_begin() {
    _transaction_lock_acquire || {
        log_error "获取事务锁失败"
        return 1
    }
    if [ -e "${_UNINSTALL_PENDING}" ]; then
        log_error "卸载未完成，请先用首页继续卸载"
        _transaction_lock_release
        return 1
    fi
    if [ "${_install_transaction:-0}" -eq 1 ]; then
        if ! _require_first_deploy; then
            _transaction_lock_release
            return 1
        fi
        _st_check_disk_state || { _transaction_lock_release; return 1; }
    else
        _st_refresh_transaction_state || { _transaction_lock_release; return 1; }
    fi
    if [ "$#" -gt 0 ]; then
        local _check_rc=0
        "$@" || _check_rc=$?
        if [ "${_check_rc}" -ne 0 ]; then
            _transaction_lock_release
            return "${_check_rc}"
        fi
    fi
    mkdir -p "${WORK_DIR}" || { _transaction_lock_release; return 1; }
    _TXN_DIR=$(mktemp -d "${WORK_DIR}/.txn_XXXXXX") || {
        _transaction_lock_release
        log_error "创建事务快照目录失败"
        return 1
    }
    _TXN_PRE_STATE="${_G_STATE}"
    _TXN_PRE_STATE_BASE="${_G_STATE_BASE}"
    _TXN_PRE_STATE_DISK="${_G_STATE_DISK}"
    { _transaction_snapshot_files && _fw_scope_begin "${_TXN_DIR}" "${_FW_PORTS_FILE}"; } || {
        rm -rf "${_TXN_DIR}" 2>/dev/null || true
        _TXN_DIR=""
        _transaction_lock_release
        log_error "创建事务文件快照失败"
        return 1
    }
    _TXN_PRE_XRAY_ACTIVE=0
    _TXN_XRAY_RESTART_ATTEMPTED=0
    _TXN_PRE_TUNNEL_ACTIVE=0
    _TXN_TUNNEL_RESTART_ATTEMPTED=0
    _TXN_PRE_XRAY_ENABLED=0
    _TXN_PRE_TUNNEL_ENABLED=0
    _TXN_PRE_XRAY_ACTIVE=$(_transaction_service_snapshot svc_status "${_SVC_XRAY}")
    _TXN_PRE_TUNNEL_ACTIVE=$(_transaction_service_snapshot svc_status "${_SVC_TUNNEL}")
    _TXN_PRE_XRAY_ENABLED=$(_transaction_service_snapshot svc_enabled_status "${_SVC_XRAY}")
    _TXN_PRE_TUNNEL_ENABLED=$(_transaction_service_snapshot svc_enabled_status "${_SVC_TUNNEL}")
    _TXN_ACTIVE=1
}

_transaction_restore_files() {
    local _p _i _exists
    _transaction_collect_artifacts
    for _p in "${_TXN_ARTIFACT_PATHS[@]}"; do
        if ! awk -F '\t' -v p="${_p}" '$2 == 1 && $3 == p { found=1 } END { exit(found ? 0 : 1) }' \
            "${_TXN_DIR}/manifest"; then
            rm -rf -- "${_p}" 2>/dev/null || return 1
        fi
    done
    while IFS=$'\t' read -r _i _exists _p; do
        [ -n "${_p:-}" ] || continue
        rm -rf -- "${_p}" 2>/dev/null || return 1
        [ "${_exists}" = 1 ] || continue
        mkdir -p "$(dirname "${_p}")" 2>/dev/null || return 1
        cp -a -- "${_TXN_DIR}/files/${_i}" "${_p}" || return 1
    done < "${_TXN_DIR}/manifest"
}

_transaction_service_snapshot() {
    local _query="$1" _name="$2" _rc=0
    "${_query}" "${_name}" || _rc=$?
    case "${_rc}" in 0) printf 1 ;; 1) printf 0 ;; *) printf 2 ;; esac
}

_transaction_restore_service() {
    local _name="$1" _was_active="$2" _was_enabled="$3" _reload="${4:-0}" _is_active _is_enabled
    _is_active=$(_transaction_service_snapshot svc_status "${_name}")
    _is_enabled=$(_transaction_service_snapshot svc_enabled_status "${_name}")
    if [[ ${_was_active}${_was_enabled}${_is_active}${_is_enabled} == *2* ]]; then
        log_warn "${_name} 服务状态未知，无法确认已恢复"
        return 1
    fi
    if [ "${_was_enabled}" = 1 ] && [ "${_is_enabled}" = 0 ]; then
        svc_exec_mut enable "${_name}" >/dev/null 2>&1 || return 1
    elif [ "${_was_enabled}" = 0 ] && [ "${_is_enabled}" = 1 ]; then
        svc_exec_mut disable "${_name}" >/dev/null 2>&1 || return 1
    fi
    if [ "${_was_active}" = 1 ] && [ "${_is_active}" = 0 ]; then
        svc_exec_mut start "${_name}" >/dev/null 2>&1 || return 1
        svc_exec status "${_name}" >/dev/null 2>&1 || return 1
    elif [ "${_was_active}" = 1 ] && [ "${_reload}" = 1 ]; then
        svc_exec_mut restart "${_name}" >/dev/null 2>&1 || return 1
        svc_exec status "${_name}" >/dev/null 2>&1 || return 1
    elif [ "${_was_active}" = 0 ] && [ "${_is_active}" = 1 ]; then
        svc_exec_mut stop "${_name}" >/dev/null 2>&1 || return 1
    fi
}

_transaction_rollback() {
    local _failed=0 _restored_state _reload=0
    _fw_restore_managed_snapshot "${_FW_PORTS_FILE}" || _failed=1
    if [ "${_install_hosts_pending:-0}" -eq 1 ]; then lifecycle_rollback_hosts || _failed=1; fi
    if _transaction_restore_files; then
        _reload="${_TXN_XRAY_RESTART_ATTEMPTED}"
        _G_SYSD_DIRTY=1
        svc_reload_daemon || _failed=1
    else
        _failed=1
    fi
    if _restored_state=$(_st_read_optional_disk_state); then
        _G_STATE_DISK="${_restored_state}"
        if [ -z "${_restored_state}" ] || [ "${_install_transaction:-0}" -eq 1 ]; then
            _G_STATE="${_TXN_PRE_STATE}"
            _G_STATE_BASE="${_TXN_PRE_STATE_BASE}"
        elif [ "${_restored_state}" = "${_TXN_PRE_STATE_DISK}" ] && [ -n "${_TXN_PRE_STATE_BASE}" ]; then
            _G_STATE="${_TXN_PRE_STATE_BASE}"
            _G_STATE_BASE="${_TXN_PRE_STATE_BASE}"
        else
            _G_STATE="${_restored_state}"
            _st_normalize_schema
            _G_STATE_BASE="${_G_STATE}"
        fi
    else
        _failed=1
    fi
    _transaction_restore_service "${_SVC_XRAY}" "${_TXN_PRE_XRAY_ACTIVE}" "${_TXN_PRE_XRAY_ENABLED}" "${_reload}" || _failed=1
    _transaction_restore_service "${_SVC_TUNNEL}" "${_TXN_PRE_TUNNEL_ACTIVE}" "${_TXN_PRE_TUNNEL_ENABLED}" "${_TXN_TUNNEL_RESTART_ATTEMPTED}" || _failed=1
    [ "${_failed}" -eq 0 ]
}

_transaction_end() {
    local _keep_snapshot="$1"
    _TXN_ACTIVE=0
    if [ "${_keep_snapshot}" -eq 1 ]; then
        log_error "事务回滚未完全成功，快照保留于：${_TXN_DIR}"
    elif ! _fw_keep_snapshot && ! rm -rf -- "${_TXN_DIR}"; then
        log_warn "事务快照清理失败：${_TXN_DIR}"
    fi
    _transaction_lock_release
    _TXN_DIR=""
    _TXN_PRE_STATE=""
    _FW_SCOPE_DIR=""
    _FW_LEDGER_STATE=()
    _TXN_ARTIFACT_PATHS=()
}

_transaction_run() {
    local _label="$1" _rc=0 _keep_snapshot=0 _failure_pause=0
    shift
    local -a _check=()
    if [ "$1" = --check ]; then
        _check=("$2")
        shift 2
    fi
    if [ "${_TXN_ACTIVE:-0}" -eq 1 ]; then
        if [ "${#_check[@]}" -gt 0 ]; then "${_check[@]}" || return $?; fi
        "$@"
        return $?
    fi
    local _PLUGIN_SNAPSHOT_STAMP="" _PLUGIN_SNAPSHOT_PORTS="" _PLUGIN_SNAPSHOT_INBOUNDS=""
    _transaction_begin "${_check[@]}" || return $?
    "$@" || _rc=$?
    if [ "${_rc}" -ne 0 ]; then
        if _transaction_rollback; then
            if [ -n "${_cert_recovery+x}" ]; then
                _cert_recovery='已恢复变更前的配置与服务状态'
            elif [ "${_MENU_HIDE_LINKS:-0}" -eq 1 ] && [ "${_MENU_ACTION_PAUSES:-0}" -eq 0 ]; then
                log_warn "${_label}失败，已恢复变更前的配置与服务状态"
                _failure_pause=1
            fi
        else
            if [ -n "${_cert_recovery+x}" ]; then _cert_recovery='回滚未完全成功，请查看事务诊断'; fi
            log_error "${_label} 失败"
            _keep_snapshot=1
            _rc=1
            if [ -z "${_cert_recovery+x}" ] && [ "${_MENU_HIDE_LINKS:-0}" -eq 1 ] && [ "${_MENU_ACTION_PAUSES:-0}" -eq 0 ]; then _failure_pause=1; fi
        fi
    fi
    _transaction_end "${_keep_snapshot}"
    if [ "${_failure_pause}" -eq 1 ]; then _pause; fi
    return "${_rc}"
}

_commit_state_and_firewall() {
    st_persist || { log_error "state.json 写入失败，拒绝同步防火墙以避免状态漂移"; return 1; }
    fw_reconcile || return 1
}

_commit_inner() {
    config_apply || return 1
    _commit_state_and_firewall
}
_commit() { _transaction_run "配置提交" _commit_inner "$@"; }

_module_disable_commit_inner() {
    local _name="$1"
    _commit_inner || return 1
    log_info "${_name} 防火墙端口已从托管规则中删除"
}
_module_disable_commit() { _transaction_run "模块禁用提交" _module_disable_commit_inner "$@"; }

_module_enable_commit_inner() {
    local _id="$1"
    _commit_inner || return 1
    log_ok "$(module_label "${_id}") 已启用"
    config_print_nodes "${_id}" || true
}
_module_enable_commit() { _transaction_run "模块启用提交" _module_enable_commit_inner "$@"; }

_module_save_fields() {
    _transaction_run "更新模块配置" _module_save_fields_inner "$@"
}

_module_save_fields_inner() {
    local _id="$1"
    shift
    st_set "$@" || return 1
    if [ "$(st_get '.[$id].enabled' --arg id "${_id}")" = "true" ]; then
        _commit_inner
    else
        st_persist || { log_error "state.json 写入失败"; return 1; }
    fi
}

# State mutations must happen inside the transaction callback so the snapshot
# captures the pre-change state, not the already-mutated in-memory document.
_module_update_state_transaction() {
    local _label="${1}"
    shift
    _transaction_run "${_label}" "${@}"
}

_module_update_listen_transaction_inner() {
    local _proto="$1" _listen="$2"
    _module_save_fields_inner "${_proto}" '.[$inbound_id].listen = $listen' \
        --arg inbound_id "${_proto}" --arg listen "${_listen}"
}

_module_update_listen_transaction() {
    _module_update_state_transaction "监听地址更新" _module_update_listen_transaction_inner "${@}"
}


_module_enable_transaction_inner() {
    local _id="$1" _before="${_G_STATE}"
    shift
    "$@" || {
        _G_STATE="${_before}"
        return 1
    }
    if ! _module_enable_commit "${_id}"; then
        _G_STATE="${_before}"
        return 1
    fi
}
_module_enable_transaction() {
    _transaction_run "模块启用" _module_enable_transaction_inner "$@"
}

_module_disable_transaction_inner() {
    local _module_name="$1" _before="${_G_STATE}"
    shift
    "$@" || {
        _G_STATE="${_before}"
        return 1
    }
    if ! _module_disable_commit "${_module_name}"; then
        _G_STATE="${_before}"
        return 1
    fi
}
_module_disable_transaction() {
    _transaction_run "模块禁用" _module_disable_transaction_inner "$@"
}

_module_enable_with_state() {
    local _jq_expr="$1" _id="$2"
    _module_enable_transaction "${_id}" st_set "${_jq_expr}"
}

module_update_port_action() {
    local _proto="${1:-}" _net="${2:-tcp}" _label_suffix="${3:-}"
    case "${_proto}" in
        ff|reality|vltcp|vlquic|socks|http|ss2022)
            _menu_update_port "${_proto}" "${_net}" "${_label_suffix}"
            ;;
        *)
            log_error "不支持统一端口更新的模块: ${_proto}"
            return 1
            ;;
    esac
}

_menu_read_listen() {
    local _input
    prompt "$1" _input || return 1
    if [ -n "${_input:-}" ]; then
        _input=$(val_listen_addr "${_input}") || return 1
    fi
    printf -v "$2" '%s' "${_input:-}"
}

_menu_warn_http_listen() {
    case "$1:$2" in
        http:0.0.0.0|http:::) log_warn "HTTP 代理为明文协议，请确认防火墙与网络边界" ;;
    esac
}

module_update_listen_action() {
    local _proto="${1:-}" _l _label
    case "${_proto}" in
        socks)  _label="SOCKS5" ;;
        http)   _label="HTTP 代理" ;;
        vltcp)  _label="VLESS-TCP" ;;
        vlquic) _label="VLESS-XHTTP-H3" ;;
        ss2022) _label="Shadowsocks 2022" ;;
        *)
            log_error "不支持统一监听地址更新的模块: ${_proto}"
            return 1
            ;;
    esac
    _menu_read_listen "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地，回车保持）: " _l || return 1
    [ -n "${_l}" ] || return 0
    _module_update_listen_transaction "${_proto}" "${_l}" || return 1
    _menu_warn_http_listen "${_proto}" "${_l}"
    log_ok "${_label} 监听地址已更新: ${_l}"
    [ "$(st_get ".${_proto}.enabled")" = true ] && { config_print_nodes "${_proto}" || true; }
    return 0
}

module_reality_update_port() {
    module_update_port_action reality tcp
}

module_vltcp_update_port() {
    module_update_port_action vltcp tcp
}

_module_ff_enable_prepare() {
    local _proto
    _proto=$(st_get '.ff.protocol')
    [ -n "${_proto:-}" ] && [ "${_proto}" != "none" ] \
        || st_set '.ff.protocol = "ws"' || return 1
    st_set '.ff.enabled = true'
}

module_ff_enable() {
    _module_enable_transaction ff _module_ff_enable_prepare
}

module_ff_disable() {
    _module_disable_transaction FreeFlow st_set '.ff.enabled = false | .ff.protocol = "none"' || return 1
    log_ok "FreeFlow 已禁用"
}

_module_reality_enable_prepare() {
    local _pvk
    _pvk=$(st_get '.reality.pvk')
    if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
        log_step "生成 x25519 密钥对..."
        crypto_gen_reality_keypair || return 1
        st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" || true
    fi
    local _split_was_active=0
    if _argo_xhttp_split_active; then _split_was_active=1; fi
    st_set '.reality.enabled = true' || return 1
    if [ "${_split_was_active}" -eq 0 ] && _argo_xhttp_split_active; then
        _argo_xhttp_check_split_port "$(st_get '.argo.xhttp.split.port')" '' || return 1
    fi
}

module_reality_enable() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; return 1; }
    _module_enable_transaction reality _module_reality_enable_prepare
}

module_reality_disable() {
    _module_disable_transaction Reality st_set '.reality.enabled = false' || return 1
    log_ok "Reality 已禁用"
}

module_vltcp_enable() {
    _module_enable_with_state '.vltcp.enabled = true' vltcp
}

module_vltcp_disable() {
    _module_disable_transaction VLESS-TCP st_set '.vltcp.enabled = false' || return 1
    log_ok "VLESS-TCP 已禁用"
}


module_socks_action() {
    local _action="${1:-}"
    case "${_action}" in
        enable)
            _module_enable_with_state '.socks.enabled = true' socks || return 1
            ;;
        disable)
            _module_disable_transaction SOCKS5 st_set '.socks.enabled = false' || return 1
            log_ok "SOCKS5 已禁用"
            ;;
        *)
            log_error "SOCKS5 不支持动作: ${_action}"
            return 1
            ;;
    esac
}

module_socks_enable() {
    module_socks_action enable
}

module_socks_disable() {
    module_socks_action disable
}

_ss2022_validate_key_mode() {
    case "$2:$1" in
        single:*|dual:2022-blake3-aes-128-gcm|dual:2022-blake3-aes-256-gcm) return 0 ;;
        *) log_error "SS2022 加密方法不支持所选密钥模式"; return 1 ;;
    esac
}

_ss2022_validate_credentials() {
    local _method="$1" _key_mode="$2" _server="$3" _user="$4"
    _ss2022_validate_key_mode "$_method" "$_key_mode" || return 1
    val_ss2022_key "$_method" "$_server" >/dev/null || return 1
    if [ "$_key_mode" = dual ]; then
        val_ss2022_key "$_method" "$_user" >/dev/null || return 1
    fi
}

_ss2022_prepare_credentials() {
    local _method="$1" _key_mode="$2" _server="${3:-}" _user="${4:-}"
    val_ss2022_method "$_method" >/dev/null || return 1
    _ss2022_validate_key_mode "$_method" "$_key_mode" || return 1
    if ! val_ss2022_key "$_method" "$_server" >/dev/null 2>&1; then
        _server=$(crypto_gen_ss2022_key "$_method") || return 1
    fi
    if [ "$_key_mode" = single ]; then
        _user=""
    elif ! val_ss2022_key "$_method" "$_user" >/dev/null 2>&1; then
        _user=$(crypto_gen_ss2022_key "$_method") || return 1
    fi
    jq -nc --arg m "$_method" --arg k "$_key_mode" --arg s "$_server" --arg u "$_user" \
        '{method:$m, key_mode:$k, server_key:$s, user_key:$u}'
}

_module_ss2022_enable_prepare() {
    local _credentials
    _credentials=$(_ss2022_prepare_credentials "$(st_get '.ss2022.method')" "$(st_get '.ss2022.key_mode')" \
        "$(st_get '.ss2022.server_key')" "$(st_get '.ss2022.user_key')") || return 1
    st_set '.ss2022 += ($credentials + {enabled:true})' --argjson credentials "$_credentials"
}

module_ss2022_enable() {
    _module_enable_transaction ss2022 _module_ss2022_enable_prepare
}

_ss2022_disable_state() {
    st_set '.ss2022.enabled = false'
}

module_ss2022_disable() {
    _module_disable_transaction "Shadowsocks 2022" _ss2022_disable_state || return 1
    log_ok "Shadowsocks 2022 已禁用"
}

module_ss2022_uninstall() {
    _module_disable_transaction "Shadowsocks 2022" st_set '.ss2022.enabled = false | .ss2022.listen = "0.0.0.0" | .ss2022.method = "2022-blake3-aes-256-gcm" | .ss2022.key_mode = "single" | .ss2022.server_key = "" | .ss2022.user_key = "" | .ports.ss2022 = 8388' || return 1
    log_ok "Shadowsocks 2022 已卸载"
}

module_ss2022_update_port() {
    module_update_port_action ss2022 both "TCP/UDP"
}

module_ss2022_update_listen() {
    module_update_listen_action ss2022
}

_ss2022_select_method() {
    local _context="$1" _choice _method _key_mode=single
    echo ""
    printf "  1. 2022-blake3-aes-256-gcm [单密钥，默认]\n"
    printf "  2. 2022-blake3-aes-128-gcm [单密钥]\n"
    printf "  3. 2022-blake3-chacha20-poly1305 [单密钥]\n"
    printf "  4. 2022-blake3-aes-256-gcm [双密钥]\n"
    printf "  5. 2022-blake3-aes-128-gcm [双密钥]\n"
    prompt "加密方法与密钥模式（回车保持当前设置）: " _choice || return 1
    case "$_choice" in
        "") return 0 ;;
        1) _method="2022-blake3-aes-256-gcm" ;;
        2) _method="2022-blake3-aes-128-gcm" ;;
        3) _method="2022-blake3-chacha20-poly1305" ;;
        4) _method="2022-blake3-aes-256-gcm"; _key_mode=dual ;;
        5) _method="2022-blake3-aes-128-gcm"; _key_mode=dual ;;
        *) log_error "无效的 SS2022 加密选项"; return 1 ;;
    esac
    if [ "$_context" = runtime ]; then
        _module_ss2022_apply_credentials "$_method" "$_key_mode"
    else
        install_plan_ss2022_regenerate_keys "$_method" "$_key_mode"
    fi
}

_ss2022_update_credentials() {
    local _context="$1" _credentials
    shift
    if [ "$#" -eq 0 ]; then
        set -- "$(st_get '.ss2022.method')" "$(st_get '.ss2022.key_mode')"
    fi
    _credentials=$(_ss2022_prepare_credentials "$@") || return 1
    if [ "$_context" = runtime ]; then
        _module_save_fields_inner ss2022 '.ss2022 += $credentials' --argjson credentials "$_credentials"
    else
        st_set '.ss2022 += $credentials' --argjson credentials "$_credentials"
    fi
}

_module_ss2022_apply_credentials() {
    _module_update_state_transaction "SS2022 密钥更新" _ss2022_update_credentials runtime "$@" || return 1
    log_ok "SS2022 密钥已重新生成"
    if [ "$(st_get '.ss2022.enabled')" = true ]; then config_print_nodes ss2022 || true; fi
}

module_ss2022_update_method() {
    _ss2022_select_method runtime
}

module_ss2022_regenerate_keys() {
    _module_ss2022_apply_credentials
}

module_http_action() {
    local _action="${1:-}"
    case "${_action}" in
        enable)
            case "$(st_get '.http.listen')" in
                0.0.0.0|::) log_warn "HTTP 代理为明文协议，当前监听所有接口，请确认防火墙与网络边界" ;;
            esac
            _module_enable_with_state '.http.enabled = true' http || return 1
            ;;
        disable)
            _module_disable_transaction "HTTP 代理" st_set '.http.enabled = false' || return 1
            log_ok "HTTP 代理已禁用"
            ;;
        *)
            log_error "HTTP 代理不支持动作: ${_action}"
            return 1
            ;;
    esac
}

module_http_enable() {
    module_http_action enable
}

module_http_disable() {
    module_http_action disable
}

_module_cforigin_enable_prepare() {
    local _proto _path _listen _edge
    _proto=$(st_get '.cforigin.protocol')
    case "${_proto:-}" in ws|httpupgrade|xhttp) : ;; *) st_set '.cforigin.protocol = "ws"' || return 1 ;; esac
    _path=$(st_get '.cforigin.path')
    [ -n "${_path:-}" ] && [ "${_path}" != "null" ] || st_set '.cforigin.path = "/origin"' || return 1
    _listen=$(st_get '.cforigin.listen')
    [ -n "${_listen:-}" ] && [ "${_listen}" != "null" ] || st_set '.cforigin.listen = "::"' || return 1
    _edge=$(st_get '.cforigin.edge_port')
    [ -n "${_edge:-}" ] && [ "${_edge}" != "null" ] || st_set '.cforigin.edge_port = 443' || return 1
    _cforigin_check_ready || return 1
    st_set '.cforigin.enabled = true' || return 1
}

module_cforigin_enable() {
    _module_enable_transaction cforigin _module_cforigin_enable_prepare || return 1
    cforigin_print_cloudflare_hint
}

module_cforigin_disable() {
    _module_disable_transaction "CF Origin" st_set '.cforigin.enabled = false' || return 1
    log_ok "CF Origin 已禁用"
}

module_ff_uninstall() {
    _module_disable_transaction FreeFlow st_set '.ff.enabled = false | .ff.protocol = "none" | .ff.path = "/" | .ff.host = "" | del(.ff.xhttp)' || return 1
    log_ok "FreeFlow 已卸载"
}

module_reality_uninstall() {
    _module_disable_transaction Reality st_set '.reality.enabled = false | .reality.pbk = null | .reality.pvk = null | .reality.sid = null | del(.reality.xhttp)' || return 1
    log_ok "Reality 已卸载"
}

_module_vltcp_uninstall_prepare() {
    st_set '.vltcp.enabled = false | .vltcp.listen = "0.0.0.0"' || return 1
    st_set '.ports.vltcp = 1234'
}

module_vltcp_uninstall() {
    _module_disable_transaction VLESS-TCP _module_vltcp_uninstall_prepare || return 1
    log_ok "VLESS-TCP 已卸载"
}


module_socks_uninstall() {
    _module_disable_transaction SOCKS5 st_set '.socks.enabled = false | .socks.listen = "0.0.0.0" | .socks.user = "xray2go" | .socks.pass = "xray2go" | .ports.socks = 1080' || return 1
    log_ok "SOCKS5 已卸载"
}

module_socks_update_port() {
    module_update_port_action socks tcp
}

module_socks_update_listen() {
    module_update_listen_action socks
}

module_socks_update_auth() {
    local _en _user _pass _du
    _en=$(st_get '.socks.enabled')
    _du=$(st_get '.socks.user')
    prompt "新用户名（回车保持 ${_du}）: " _user || return 1
    prompt_secret "新密码（回车保持当前）: " _pass || return 1
    [ -n "${_user:-}${_pass:-}" ] || return 0
    _module_save_fields socks '
        (if $u == "" then . else .socks.user = $u end) |
        (if $p == "" then . else .socks.pass = $p end)
    ' --arg u "${_user:-}" --arg p "${_pass:-}" || return 1
    _user=$(st_get '.socks.user')
    log_ok "SOCKS5 账号已更新: ${_user}"
    if [ "${_en}" = "true" ]; then config_print_nodes socks || true; fi
}


module_socks_update_user() {
    local _en _du _user
    _en=$(st_get '.socks.enabled')
    _du=$(st_get '.socks.user')
    prompt "新用户名（回车保持 ${_du}）: " _user || return 1
    _user="${_user:-${_du}}"
    _module_save_fields socks '.socks.user = $u' --arg u "${_user}" || return 1
    log_ok "SOCKS5 用户名已更新: ${_user}"
    if [ "${_en}" = "true" ]; then config_print_nodes socks || true; fi
}

module_socks_update_pass() {
    local _en _pass
    _en=$(st_get '.socks.enabled')
    prompt_secret "新密码（回车保持当前）: " _pass || return 1
    [ -n "${_pass:-}" ] || return 0
    _module_save_fields socks '.socks.pass = $p' --arg p "${_pass}" || return 1
    log_ok "SOCKS5 密码已更新"
    if [ "${_en}" = "true" ]; then config_print_nodes socks || true; fi
}

module_http_uninstall() {
    _module_disable_transaction "HTTP 代理" st_set '.http.enabled = false | .http.listen = "0.0.0.0" | .http.user = "xray2go" | .http.pass = "xray2go" | .ports.http = 1081' || return 1
    log_ok "HTTP 代理已卸载"
}

module_http_update_port() {
    module_update_port_action http tcp
}

module_http_update_listen() {
    module_update_listen_action http
}

module_http_update_auth() {
    local _en _user _pass _du
    _en=$(st_get '.http.enabled')
    _du=$(st_get '.http.user')
    prompt "新用户名（回车保持 ${_du}）: " _user || return 1
    prompt_secret "新密码（回车保持当前）: " _pass || return 1
    [ -n "${_user:-}${_pass:-}" ] || return 0
    _module_save_fields http '
        (if $u == "" then . else .http.user = $u end) |
        (if $p == "" then . else .http.pass = $p end)
    ' --arg u "${_user:-}" --arg p "${_pass:-}" || return 1
    _user=$(st_get '.http.user')
    log_ok "HTTP 代理账号已更新: ${_user}"
    if [ "${_en}" = "true" ]; then config_print_nodes http || true; fi
}

module_http_update_user() {
    local _en _du _user
    _en=$(st_get '.http.enabled')
    _du=$(st_get '.http.user')
    prompt "新用户名（回车保持 ${_du}）: " _user || return 1
    _user="${_user:-${_du}}"
    _module_save_fields http '.http.user = $u' --arg u "${_user}" || return 1
    log_ok "HTTP 代理用户名已更新: ${_user}"
    if [ "${_en}" = "true" ]; then config_print_nodes http || true; fi
}

module_http_update_pass() {
    local _en _pass
    _en=$(st_get '.http.enabled')
    prompt_secret "新密码（回车保持当前）: " _pass || return 1
    [ -n "${_pass:-}" ] || return 0
    _module_save_fields http '.http.pass = $p' --arg p "${_pass}" || return 1
    log_ok "HTTP 代理密码已更新"
    if [ "${_en}" = "true" ]; then config_print_nodes http || true; fi
}
module_vlquic_uninstall() {
    _module_disable_transaction VLESS-XHTTP-H3 st_set '.vlquic.enabled = false | .vlquic.listen = "0.0.0.0" | .vlquic.domain = "" | .vlquic.cert = "" | .vlquic.key = "" | .vlquic.acme_method = "manual" | del(.vlquic.xhttp)' || return 1
    log_ok "VLESS-XHTTP-H3 已卸载"
}

module_cforigin_uninstall() {
    _module_disable_transaction "CF Origin" st_set '.cforigin.enabled = false | .cforigin.domain = "" | .cforigin.protocol = "ws" | .cforigin.path = "/origin" | .cforigin.listen = "::" | .cforigin.edge_port = 443 | .cforigin.edge_h3 = false | .cforigin.xhttp = null | .cforigin.origin_tls = true | .cforigin.cert = "" | .cforigin.key = "" | .cforigin.acme_method = "manual" | .ports.cforigin = 28888' || return 1
    log_ok "CF Origin 已卸载"
}

module_vlquic_update_port() {
    module_update_port_action vlquic udp udp
}

module_cforigin_update_port() {
    local _np
    _menu_select_port tcp _np "新 Origin 回源端口（需与 Cloudflare Origin Rule 的 Destination Port 一致，回车随机）: " || return 1
    _commit_port_change cforigin "${_np}" || return 1
    log_warn "如果 Cloudflare Origin Rule 已手动配置，请同步确认 Destination Port Override = ${_np}"
    cforigin_print_cloudflare_hint
}

module_reality_update_transport() {
    local _en _net _nn
    _en=$(st_get '.reality.enabled')
    _net=$(st_get '.reality.network'); _net="${_net:-tcp}"
    [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
    _module_save_fields reality '.reality.network = $n' --arg n "${_nn}" || return 1
    log_ok "传输方式已切换: ${_nn}"
    if [ "${_en}" = "true" ]; then config_print_nodes reality || true; fi
}

module_vltcp_update_listen() {
    module_update_listen_action vltcp
}

module_vlquic_update_listen() {
    module_update_listen_action vlquic
}

_cforigin_read_transport() {
    local _hint="$1" _output="$2" _option _protocol
    printf '\n  %s1.%s WS\n' "${C_GRN}" "${C_RST}"
    printf '  %s2.%s HTTPUpgrade\n' "${C_GRN}" "${C_RST}"
    printf '  %s3.%s XHTTP (stream-one)\n' "${C_GRN}" "${C_RST}"
    prompt "CF Origin 传输协议 (1-3，${_hint}): " _option || return 1
    case "${_option:-}" in
        1) _protocol=ws ;;
        2) _protocol=httpupgrade ;;
        3) _protocol=xhttp ;;
        '') _protocol='' ;;
        *) log_error "无效选项，请按提示输入"; return 1 ;;
    esac
    printf -v "${_output}" '%s' "${_protocol}"
}

_cforigin_save_transport() {
    local _protocol="$1"
    shift
    "$@" '
        .cforigin.protocol = $protocol | if $protocol == "xhttp" then . else .cforigin.edge_h3 = false end
    ' --arg protocol "${_protocol}"
}

module_cforigin_update_protocol() {
    local _en _current _proto
    _en=$(st_get '.cforigin.enabled')
    _current=$(st_get '.cforigin.protocol')
    _cforigin_read_transport "回车保持 ${_current}" _proto || return 1
    [ -n "${_proto}" ] || return 0
    _cforigin_save_transport "${_proto}" _module_save_fields cforigin || return 1
    log_ok "CF Origin 协议已更新: $(st_get '.cforigin.protocol')"
    if [ "${_en}" = "true" ]; then config_print_nodes cforigin || true; fi
}


_module_cforigin_save_domain() {
    _cforigin_check_origin_tls "$1" || {
        log_error "请从 CF Origin 菜单 9 配置覆盖新域名的证书，并一并保存域名"
        return 1
    }
    _module_save_fields_inner cforigin '.cforigin.domain = $d' --arg d "$1"
}

module_cforigin_update_domain() {
    local _en _domain
    _en=$(st_get '.cforigin.enabled')
    prompt "新域名（回车保持 $(st_get '.cforigin.domain')): " _domain || return 1
    [ -n "${_domain:-}" ] || return 0
    _domain=$(val_domain "${_domain}") || return 1
    _module_update_state_transaction "CF Origin 域名更新" _module_cforigin_save_domain "${_domain}" || return 1
    log_ok "CF Origin 域名已更新: ${_domain}"
    if [ "${_en}" = "true" ]; then cforigin_print_cloudflare_hint; fi
}
module_cforigin_update_path() {
    local _en _path _p _vp
    _en=$(st_get '.cforigin.enabled')
    _path=$(st_get '.cforigin.path')
    prompt "新 path（回车保持 ${_path}）: " _p || return 1
    [ -n "${_p:-}" ] || return 0
    _vp=$(val_path "${_p}") || return 1
    _module_save_fields cforigin '.cforigin.path = $p' --arg p "${_vp}" || return 1
    log_ok "path 已更新: ${_vp}"
    if [ "${_en}" = "true" ]; then config_print_nodes cforigin || true; fi
}

module_cforigin_update_listen() {
    local _l
    _menu_read_listen "新监听地址（:: / 0.0.0.0 / 127.0.0.1，回车保持）: " _l || return 1
    [ -n "${_l}" ] || return 0
    _module_update_listen_transaction cforigin "${_l}" || return 1
    log_ok "监听地址已更新: ${_l}"
}

_argo_activate_tunnel() {
    local _action="$1"
    if [ "${_action}" = restart ] && [ "${_TXN_ACTIVE}" -eq 1 ]; then
        _TXN_TUNNEL_RESTART_ATTEMPTED=1
    fi
    svc_exec_mut "${_action}" "${_SVC_TUNNEL}" || {
        log_error "Argo 服务操作失败 (${_action})"
        return 1
    }
    svc_verify_health "${_SVC_TUNNEL}" 6
}

module_argo_enable_inner() {
    if [ ! -f "${ARGO_BIN}" ] || [ ! -x "${ARGO_BIN}" ]; then
        download_cloudflared || return 1
    fi
    st_set '.argo.enabled = true' || return 1
    config_apply || return 1
    svc_apply_tunnel || return 1
    svc_reload_daemon || return 1
    svc_exec_mut enable "${_SVC_TUNNEL}" || {
        log_error "Argo 服务启用失败"
        return 1
    }
    _argo_activate_tunnel start || return 1
    _commit_state_and_firewall || return 1
    log_ok "Argo 已启用并启动"
}

module_argo_enable() {
    _transaction_run "Argo 启用" module_argo_enable_inner "$@"
}

_svc_stop_and_disable() {
    local _service="$1" _status
    _status=0
    svc_status "${_service}" || _status=$?
    if [ "${_status}" -eq 2 ]; then
        log_error "${_service} 状态查询失败，拒绝卸载"
        return 1
    fi
    svc_exec_mut stop "${_service}" 2>/dev/null || true
    svc_exec_mut disable "${_service}" 2>/dev/null || true
    _status=0
    svc_status "${_service}" || _status=$?
    [ "${_status}" -eq 1 ] || { log_error "${_service} 停止状态无法确认"; return 1; }
    _status=0
    svc_enabled_status "${_service}" || _status=$?
    [ "${_status}" -eq 1 ] || { log_error "${_service} 开机状态无法确认已禁用"; return 1; }
}
module_argo_disable_inner() {
    _svc_stop_and_disable "${_SVC_TUNNEL}" || return 1
    st_set '.argo.enabled = false' || return 1
    _module_disable_commit Argo || return 1
    log_ok "Argo 已禁用"
}

module_argo_disable() {
    _transaction_run "Argo 禁用" module_argo_disable_inner "$@"
}

_svc_remove_units() {
    local _name _dir _suffix=
    if is_systemd; then
        _dir="${_SVC_SYSTEMD_DIR}"
        _suffix=.service
    else
        _dir="${_SVC_OPENRC_DIR}"
    fi
    for _name in "$@"; do
        rm -f -- "${_dir}/${_name}${_suffix}" || return 1
    done
    if [ "${_suffix}" = .service ]; then
        _G_SYSD_DIRTY=1
        svc_reload_daemon || return 1
    fi
}

module_argo_uninstall_inner() {
    _svc_stop_and_disable "${_SVC_TUNNEL}" || return 1
    _svc_remove_units "${_SVC_TUNNEL}" || return 1
    rm -f -- "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml" \
          "${WORK_DIR}/tunnel.json" "${_ARGO_ENV_FILE}" || return 1
    st_set '.argo.enabled = false | .argo.domain = null | .argo.token = null | .argo.cred_b64 = null | .argo.mode = "fixed" | .argo.protocol = "ws" | .argo.auth_protocol = "vless" | .argo.trojan_password = "" | del(.argo.xhttp)' || return 1
    _module_disable_commit Argo || return 1
    log_ok "Argo 已完全卸载"
}

module_argo_uninstall() {
    _transaction_run "Argo 卸载" module_argo_uninstall_inner "$@"
}

_argo_read_transport() {
    local _current="$1" _output="$2" _option _transport
    echo ""
    printf "  ${C_GRN}1.${C_RST} WS
"
    printf "  ${C_GRN}2.${C_RST} XHTTP
"
    prompt "协议 (回车维持 ${_current}): " _option || return 1
    case "${_option:-}" in
        '') _transport="${_current}" ;;
        1) _transport=ws ;;
        2)
            if [ "$(st_get '.argo.auth_protocol')" = trojan ]; then
                log_error "当前入站认证为 Trojan，仅支持 WS；请先将入站认证改回 VLESS"
                return 1
            fi
            _transport=xhttp ;;
        *) log_error "无效选项，请按提示输入"; return 1 ;;
    esac
    printf -v "${_output}" '%s' "${_transport}"
}

_module_argo_update_protocol_impl() {
    local _old _new
    [ "$(st_get '.argo.enabled')" = true ] || { log_warn "请先选项 1 启用 Argo"; return 1; }
    _old=$(st_get '.argo.protocol')
    _argo_read_transport "${_old}" _new || return 1
    if [ "${_new}" = "${_old}" ]; then
        _argo_update_changed=0
        return 0
    fi
    st_set '.argo.protocol = $v' --arg v "${_new}" || return 1
    argo_apply_fixed_tunnel_from_state || return 1
    config_print_nodes argo || true
}

_module_argo_update_auth_protocol_impl() {
    _argo_update_credential install_plan_argo_update_auth_protocol
}

_argo_update_credential() {
    local _before="${_G_STATE}"
    [ "$(st_get '.argo.enabled')" = true ] || { log_warn "请先启用 Argo"; return 1; }
    "$@" || return 1
    if [ "${_G_STATE}" = "${_before}" ]; then
        _argo_update_changed=0
        return 0
    fi
    argo_apply_fixed_tunnel_from_state || return 1
    config_print_nodes argo || true
}

_module_argo_update_trojan_password_impl() {
    _argo_update_credential install_plan_argo_update_trojan_password
}

module_ff_update_mode() {
    _transaction_run "更新 FreeFlow 模式" _module_ff_update_mode_inner
}

_module_ff_update_mode_inner() {
    [ "$(st_get '.ff.enabled')" = "true" ] || { log_warn "FreeFlow 未启用"; return 1; }
    install_plan_ff_update_mode || return 1
    _module_enable_commit ff
}
module_ff_update_port() {
    module_update_port_action ff tcp
}

module_ff_update_host_or_path() {
    local _en _proto _host _path _h _p _vp2
    _en=$(st_get '.ff.enabled')
    _proto=$(st_get '.ff.protocol')
    _host=$(st_get '.ff.host')
    _path=$(st_get '.ff.path')
    { [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; } && { log_warn "请先启用 FreeFlow"; return 1; }
    if [ "${_proto}" = "tcphttp" ]; then
        prompt "新免流 Host（回车保持 ${_host}）: " _h || return 1
        [ -n "${_h:-}" ] || return 0
        _module_save_fields ff '.ff.host = $h' --arg h "${_h}" || return 1
        log_ok "Host 已更新: ${_h}"; config_print_nodes ff || true
    else
        prompt "新 path（回车保持 ${_path}）: " _p || return 1
        [ -n "${_p:-}" ] || return 0
        case "${_p}" in /*) :;; *) _p="/${_p}";; esac
        if ! _vp2=$(val_path "${_p}" 2>/dev/null); then
            log_error "path 格式不合法"; return 1
        fi
        _module_save_fields ff '.ff.path = $p' --arg p "${_vp2}" || return 1
        log_ok "path 已更新: ${_p}"; config_print_nodes ff || true
    fi
}

module_reality_update_sni() {
    local _en _sni _s
    _en=$(st_get '.reality.enabled')
    _sni=$(st_get '.reality.sni')
    log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
    prompt "新 SNI（回车保持 ${_sni}）: " _s || return 1
    [ -n "${_s:-}" ] || return 0
    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "SNI 格式不合法"; return 1; }
    _module_save_fields reality '.reality.sni = $s' --arg s "${_s}" || return 1
    log_ok "SNI 已更新: ${_s}"
    if [ "${_en}" = "true" ]; then config_print_nodes reality || true; fi
}

module_reality_regenerate_keys() {
    local _en
    _en=$(st_get '.reality.enabled')
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; return 1; }
    _transaction_run "更新 REALITY 密钥" _module_reality_regenerate_keys_inner || return 1
    log_ok "密钥对已更新"
    if [ "${_en}" = "true" ]; then config_print_nodes reality || true; fi
}

_module_reality_regenerate_keys_inner() {
    crypto_gen_reality_keypair || return 1
    _module_save_fields_inner reality '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)"
}

_module_vlquic_enable_prepare() {
    local -a _VLQUIC_ISSUE=()
    if [ -z "$(st_get '.vlquic.domain')" ] || [ ! -f "$(st_get '.vlquic.cert')" ] || [ ! -f "$(st_get '.vlquic.key')" ]; then
        vlquic_config_cert || return 1
    fi
    _vlquic_apply_cert || return 1
    st_set '.vlquic.enabled = true'
}

module_vlquic_enable() {
    _module_enable_transaction vlquic _module_vlquic_enable_prepare || return 1
    log_ok "VLESS-XHTTP-H3 已启用 (UDP/$(port_of vlquic))"
}

module_vlquic_disable() {
    _module_disable_transaction VLESS-XHTTP-H3 st_set '.vlquic.enabled = false' || return 1
    log_ok "VLESS-XHTTP-H3 已禁用"
}

module_vlquic_update_cert() { _module_update_certificate vlquic; }

_cert_runtime_fingerprint() {
    local _module="$1" _field _file
    if [ "${_module}" = cforigin ] && [ "$(st_get '.cforigin.origin_tls')" != true ]; then
        return 0
    fi
    st_get '.[$id].domain' --arg id "${_module}" || return 1
    for _field in cert key; do
        _file=$(st_get '.[$id][$field]' --arg id "${_module}" --arg field "${_field}") || return 1
        printf '%q\n' "${_file}"
        if [ -f "${_file}" ]; then
            sha256sum < "${_file}" || { log_error "${_module} 证书或私钥内容无法读取"; return 1; }
        else
            printf 'missing\n'
        fi
    done
}

_cert_resolve_path() {
    local _rest="$1" _resolved='' _part _link _hops=0
    [[ "${_rest}" = /* ]] || _rest="${PWD}/${_rest}"
    # Resolve symlinks even if issuance will create some of the directories.
    while [ -n "${_rest}" ]; do
        _part=${_rest%%/*}
        if [[ "${_rest}" = */* ]]; then _rest=${_rest#*/}; else _rest=''; fi
        case "${_part}" in
            ''|.) continue ;;
            ..) _resolved=${_resolved%/*}; continue ;;
        esac
        if [ -L "${_resolved}/${_part}" ]; then
            _hops=$((_hops + 1))
            [ "${_hops}" -le 40 ] || return 1
            _link=$(readlink -- "${_resolved}/${_part}" && printf '.') || return 1
            _link=${_link%$'\n.'}
            if [[ "${_link}" = /* ]]; then _resolved=''; fi
            _rest="${_link}/${_rest}"
        else
            _resolved+="/${_part}"
        fi
    done
    printf '%s\n' "${_resolved:-/}"
}

_cert_affected_inbounds() {
    local _target="$1" _enabled_only="$2" _id _field _file _canonical _dest _canonical_dest
    for _id in vlquic cforigin; do
        if [ "${_enabled_only}" -eq 1 ] && [ "$(st_get '.[$id].enabled' --arg id "${_id}")" != true ]; then
            continue
        fi
        if [ "${_id}" = "${_target}" ]; then
            printf '%s\n' "${_id}"
            continue
        fi
        [ "${#_cert_artifacts[@]}" -gt 0 ] || continue
        if [ "${_id}" = cforigin ] && [ "$(st_get '.cforigin.origin_tls')" != true ]; then continue; fi
        for _field in cert key; do
            _file=$(st_get '.[$id][$field]' --arg id "${_id}" --arg field "${_field}") || return 1
            [ -n "${_file}" ] || continue
            _canonical=$(_cert_resolve_path "${_file}") || _canonical="${_file}"
            for _dest in "${_cert_artifacts[@]}"; do
                _canonical_dest=$(_cert_resolve_path "${_dest}") || _canonical_dest="${_dest}"
                if [[ "${_canonical}" = "${_canonical_dest}" || "${_file}" -ef "${_dest}" ]]; then
                    printf '%s\n' "${_id}"
                    continue 3
                fi
            done
        done
    done
    return 0
}

_cert_write_paths() {
    _cert_artifacts=()
    if [ "${_cert_target}" = cforigin ]; then
        [ "${#_CFORIGIN_ISSUE[@]}" -gt 0 ] || return 0
    else
        [ "${#_VLQUIC_ISSUE[@]}" -gt 0 ] || return 0
    fi
    _cert_artifacts=("${_CERT_DIR}/${_cert_domain}/fullchain.pem" "${_CERT_DIR}/${_cert_domain}/privkey.pem")
}

_cert_check_destination() {
    local _dest="$1" _path _links
    if [ -L "${_dest}" ] || { [ -e "${_dest}" ] && [ ! -f "${_dest}" ]; }; then
        log_error '签发目的地必须是普通文件，无法安全覆盖此路径'
        return 1
    fi
    [ -e "${_dest}" ] || return 0
    _links=$(stat -c '%h' -- "${_dest}") || return 1
    [ "${_links}" -eq 1 ] || { log_error '签发目的地有硬链接，无法安全回滚'; return 1; }
    _path=$(_cert_resolve_path "${_dest}") || return 1
    # mountinfo escapes whitespace and backslashes in mount point paths.
    _path=${_path//\\/\\134}
    _path=${_path// /\\040}
    _path=${_path//$'\t'/\\011}
    _path=${_path//$'\n'/\\012}
    if ! X2G_CERT_MOUNT_PATH="${_path}" awk '$5 == ENVIRON["X2G_CERT_MOUNT_PATH"] { found=1 } END { exit found }' /proc/self/mountinfo; then
        log_error '无法确认签发目的地可安全恢复，请使用普通文件路径'
        return 1
    fi
}

_cert_check_impact() {
    local _id _dest _enabled _saved_refs _draft_refs
    _cert_affected=$(_cert_affected_inbounds "${_cert_target}" 0) || return 1
    if [ "${_cert_approved}" != '*' ]; then
        for _id in ${_cert_affected}; do
            _enabled=$(st_get '.[$id].enabled' --arg id "${_id}")
            if [ "${_enabled}" = true ] && [[ $'\n'${_cert_approved}$'\n' != *$'\n'"${_id}"$'\n'* ]]; then
                log_warn '可能受影响的入站已增加，请重新确认'
                return 75
            fi
        done
    fi
    if [ "$(jq -r '.acme_method' <<< "${_cert_draft}")" = manual_existing ]; then
        _saved_refs=$(jq -c '.cforigin | {cert, key}' <<< "${_G_STATE}") || return 1
        _draft_refs=$(jq -c '{cert, key}' <<< "${_cert_draft}") || return 1
        if [ "${_saved_refs}" != "${_draft_refs}" ]; then
            if [ "${_cert_approved}" = '*' ]; then
                log_error '已配置的证书文件由其他会话更新，请重新选择证书来源'
                return 1
            fi
            _cert_draft=$(jq -c --argjson refs "${_saved_refs}" '. + $refs' <<< "${_cert_draft}") || return 1
            log_warn '已配置的证书文件由其他会话更新，请确认沿用最新保存的文件'
            return 75
        fi
    fi
    for _dest in "${_cert_artifacts[@]}"; do
        # ACME may follow links or truncate a shared inode. The file snapshot
        # can restore a managed path, but cannot undo writes through these aliases.
        _cert_check_destination "${_dest}" || return 1
    done
}

_cert_apply_draft() {
    local _id _enabled _after _reload=''
    local -a _issue=()
    local -A _before=()
    for _id in ${_cert_affected}; do
        _before["${_id}"]=$(_cert_runtime_fingerprint "${_id}") || return 1
    done
    _enabled=$(st_get '.[$id].enabled' --arg id "${_cert_target}") || return 1
    st_set '.[$id] += $draft' --arg id "${_cert_target}" --argjson draft "${_cert_draft}" || return 1
    if [ "${_cert_target}" = cforigin ]; then
        _issue=("${_CFORIGIN_ISSUE[@]}")
    else
        _issue=("${_VLQUIC_ISSUE[@]}")
        _vlquic_check_ready plan || return 1
    fi
    if [ "${#_issue[@]}" -gt 0 ]; then
        _cert_stage='签发证书'
        "${_issue[@]}" || return 1
    fi
    _cert_stage='校验证书'
    if [ "${_cert_target}" = vlquic ]; then
        _vlquic_check_ready || return 1
    elif [ "${_enabled}" = true ]; then
        _cforigin_check_ready || return 1
    else
        _cforigin_check_origin_tls "${_cert_domain}" || return 1
    fi
    for _id in ${_cert_affected}; do
        _after=$(_cert_runtime_fingerprint "${_id}") || return 1
        [ "${_after}" != "${_before[${_id}]}" ] || continue
        if [ "${_id}" != "${_cert_target}" ]; then
            if [ "${_id}" = vlquic ]; then
                _vlquic_check_ready || return 1
            else
                _cforigin_check_origin_tls "$(st_get '.cforigin.domain')" || return 1
            fi
        fi
        if [ "$(st_get '.[$id].enabled' --arg id "${_id}")" = true ]; then _reload=force; fi
    done
    if [ "${_enabled}" = true ] || [ -n "${_reload}" ]; then
        _cert_stage='验证并重新加载 Xray'
        config_apply tls "${_reload}" || return 1
    fi
    if [ "${_cert_target}" = vlquic ] && [ "${_enabled}" = true ]; then
        _cert_stage='保存配置及防火墙'
        _commit_state_and_firewall
    else
        _cert_stage='保存配置'
        st_persist || { log_error 'state.json 写入失败'; return 1; }
    fi
}

module_cforigin_update_cert() { _module_update_certificate cforigin; }

_cert_read_draft() {
    local _G_STATE="${_G_STATE}"
    "$1_config_cert" || return 1
    _cert_draft=$(jq -c --arg id "$1" '.[$id] | {domain, cert, key, acme_method} +
        if $id == "cforigin" then {origin_tls} else {} end' <<< "${_G_STATE}")
}

_cert_preview() {
    local _cert_target="$1" _cert_domain="$2"
    local -a _cert_artifacts=()
    _cert_write_paths
    _cert_affected_inbounds "${_cert_target}" 1
}

_cert_submit_draft() {
    local _cert_target="$1" _cert_approved="${2-*}" _cert_domain _cert_affected='' _rc=0
    local _cert_stage='读取或保存证书配置' _cert_recovery='未应用变更'
    local -a _cert_artifacts=()
    _cert_domain=$(jq -er '.domain' <<< "${_cert_draft}") || return 1
    _cert_write_paths
    _transaction_run "更新 $(module_label "${_cert_target}") 证书" --check _cert_check_impact _cert_apply_draft || _rc=$?
    case "${_rc}" in
        75) return 75 ;;
        0) log_ok "${_cert_domain} 的证书配置已更新" ;;
        *) log_error "证书更新失败（${_cert_stage}）：${_cert_recovery}"; return 1 ;;
    esac
}

_module_update_certificate() {
    local _cert_draft
    local -a _VLQUIC_ISSUE=() _CFORIGIN_ISSUE=()
    _cert_read_draft "$1" && _cert_submit_draft "$1"
}

_workbench_certificates() {
    local -a _cert_issue_plan=()
    local _cert_plan_saved=0
    _menu_certificates "$@"
    if [ "${_cert_plan_saved}" -eq 1 ]; then
        case "$1" in
            cforigin) _CFORIGIN_ISSUE=("${_cert_issue_plan[@]}") ;;
            vlquic) _VLQUIC_ISSUE=("${_cert_issue_plan[@]}") ;;
        esac
    fi
}

_menu_certificates() {
    local _module="$1" _runtime="$2" _cert_draft='' _cert_source='' _expires _path _domain _choice _confirm
    local _affected _id _rc
    local -a _VLQUIC_ISSUE=() _CFORIGIN_ISSUE=()
    while true; do
        log_title "$(module_label "${_module}") / 证书"
        _domain=$(st_get '.[$id].domain' --arg id "${_module}")
        _path=$(st_get '.[$id].cert' --arg id "${_module}")
        if [ -n "${_path}" ]; then
            _expires=$(LC_ALL=C openssl x509 -noout -enddate -in "${_path}" 2>/dev/null) || _expires='有效期无法读取'
            printf '  %s · 到期时间 %s\n' "${_domain}" "${_expires#notAfter=}"
            if ! openssl x509 -noout -checkend 0 -in "${_path}" >/dev/null 2>&1; then
                log_warn '证书已过期或无法读取'
            fi
        elif [ "${_module}" = cforigin ] && [ -n "${_domain}" ] && [ "$(st_get '.cforigin.origin_tls')" = false ]; then
            printf '  %s · 明文 HTTP 回源\n' "${_domain}"
        else
            printf '  %s · 尚无证书\n' "${_domain:-未配置域名}"
        fi
        _menu_print_action 1 '配置证书'
        if [ -n "${_cert_draft}" ]; then _menu_print_action 2 '重试刚才的配置'; fi
        _menu_print_back
        prompt '选择证书操作: ' _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) _cert_read_draft "${_module}" || continue ;;
            2) [ -n "${_cert_draft}" ] || { log_error '没有待重试的配置'; continue; } ;;
            *) log_error '无效证书操作'; continue ;;
        esac
        _domain=$(jq -r '.domain' <<< "${_cert_draft}")
        while true; do
            printf '  域名 %s · 来源 %s\n' "${_domain}" "${_cert_source}"
            if [ "${_runtime}" -eq 1 ]; then
                _affected=$(_cert_preview "${_module}" "${_domain}") || continue 2
                if [ -n "${_affected}" ]; then
                    printf '  可能受影响的已启用入站\n'
                    for _id in ${_affected}; do printf '  · %s\n' "$(module_label "${_id}")"; done
                    printf '  Xray 可能重新加载。若已停止，重启可能将它启动。\n'
                fi
            fi
            prompt '确认提交证书配置？(y/N): ' _confirm || return 0
            [ "${_confirm,,}" = y ] || continue 2
            [ "${_runtime}" -eq 1 ] || break
            _rc=0
            _cert_submit_draft "${_module}" "${_affected}" || _rc=$?
            case "${_rc}" in
                0) break ;;
                75) : ;;
                *) _pause; continue 2 ;;
            esac
        done
        if [ "${_runtime}" -ne 1 ]; then
            st_set '.[$id] += $draft' --arg id "${_module}" --argjson draft "${_cert_draft}" || continue
            # 交给外层工作台保存签发计划。
            if [ "${_module}" = cforigin ]; then
                _cert_issue_plan=("${_CFORIGIN_ISSUE[@]}")
            else
                _cert_issue_plan=("${_VLQUIC_ISSUE[@]}")
            fi
            _cert_plan_saved=1
            log_ok '证书配置已写入部署计划'
            return 0
        fi
        _cert_draft=''
        _VLQUIC_ISSUE=(); _CFORIGIN_ISSUE=()
    done
}

module_cforigin_update_edge_port() {
    local _edge _ep
    _edge=$(st_get '.cforigin.edge_port')
    prompt "新 Edge 入口端口（Cloudflare 支持端口，回车保持 ${_edge}）: " _ep || return 1
    [ -n "${_ep:-}" ] || return 0
    val_port "${_ep}" >/dev/null && cf_edge_port_valid "${_ep}" || return 1
    _module_update_state_transaction "更新 Edge 入口端口" _module_save_state_field \
        '.cforigin.edge_port = ($p|tonumber)' --arg p "${_ep}" || return 1
    log_ok "Edge 入口端口已更新: ${_ep}"; config_print_nodes cforigin; cforigin_print_cloudflare_hint
}

_module_save_state_field() {
    st_set "$@" && st_persist
}

module_cforigin_toggle_edge_h3() {
    _module_update_state_transaction "切换 CF Origin Edge H3" _module_cforigin_toggle_edge_h3_inner
}

_module_cforigin_toggle_edge_h3_inner() {
    local _proto _edge_h3
    _proto=$(st_get '.cforigin.protocol')
    _edge_h3=$(st_get '.cforigin.edge_h3')
    if [ "${_proto}" != "xhttp" ]; then
        log_warn "Edge HTTP/3 仅对 CF Origin XHTTP 链接生效；请先将协议切换为 XHTTP。"
        return 1
    fi
    if [ "${_edge_h3}" = "true" ]; then
        st_set '.cforigin.edge_h3 = false' || return 1
    else
        st_set '.cforigin.edge_h3 = true' || return 1
    fi
    st_persist || { log_error "state.json 写入失败"; return 1; }
    log_ok "客户端到 Cloudflare Edge HTTP/3 实验性参数已更新: $(st_get '.cforigin.edge_h3')"
    config_print_nodes cforigin; cforigin_print_cloudflare_hint
}

# ==============================================================================
# ACME certificate automation for VLESS-XHTTP-H3
# ==============================================================================
acme_install() {
    local _email="${1:-}"
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
        log_step "安装 acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="${_email}" >/dev/null 2>&1 \
            || { log_error "acme.sh 安装失败"; return 1; }
    fi
    acme_update_account_email "${_email}"
}

acme_update_account_email() {
    local _email="$1" _account_conf="${HOME}/.acme.sh/account.conf"
    [ -x "${HOME}/.acme.sh/acme.sh" ] || return 1
    if [ -f "${_account_conf}" ] && grep -q "^ACCOUNT_EMAIL=.*example\.com" "${_account_conf}" 2>/dev/null; then
        log_warn "检测到旧 ACME 账户邮箱为 example.com，正在更新账户邮箱..."
    fi
    "${HOME}/.acme.sh/acme.sh" --update-account --accountemail "${_email}" >/dev/null 2>&1 || true
    if [ -f "${_account_conf}" ]; then
        local _tmp
        _tmp=$(tmp_file "acme_account_XXXXXX") || return 0
        grep -v '^ACCOUNT_EMAIL=' "${_account_conf}" > "${_tmp}" 2>/dev/null || true
        printf "ACCOUNT_EMAIL='%s'\n" "${_email}" >> "${_tmp}"
        mv "${_tmp}" "${_account_conf}" 2>/dev/null || true
        chmod 600 "${_account_conf}" 2>/dev/null || true
    fi
}

acme_issue_ok_or_existing() {
    local _domain="$1" _out="${2:-}"
    if [ -n "${_out:-}" ] && printf '%s' "${_out}" | grep -qE 'Domains not changed\.|Skipping\. Next renewal time is:'; then
        local _cert_dir="${HOME}/.acme.sh/${_domain}_ecc"
        if [ -f "${_cert_dir}/fullchain.cer" ] || [ -f "${_cert_dir}/${_domain}.cer" ]; then
            log_info "证书已存在且未到续期时间，复用现有证书"
            return 0
        fi
    fi
    return 1
}

acme_timeout_run() {
    local _seconds="${1:-600}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${_seconds}" "$@"
    else
        "$@"
    fi
}

acme_ca_list() {
    # Google Trust Services ACME requires External Account Binding for new accounts.
    # Without EAB credentials it is not suitable for unattended fallback.
    printf '%s\n' letsencrypt zerossl
}

acme_ca_label() {
    case "${1:-}" in
        letsencrypt) printf "Let's Encrypt" ;;
        google)      printf 'Google Trust Services' ;;
        zerossl)     printf 'ZeroSSL' ;;
        *)           printf '%s' "$1" ;;
    esac
}

acme_issue_with_ca_fallback() {
    local _domain="$1" _email="$2" _auth_mode="$3" _auth_a="${4:-}" _auth_b="${5:-}" _issue_mode="${6:-dns_cf}"
    local _ca _label _issue_out _issue_rc _last_out=""
    for _ca in $(acme_ca_list); do
        _label=$(acme_ca_label "${_ca}")
        log_step "ACME CA: ${_label}"
        "${HOME}/.acme.sh/acme.sh" --set-default-ca --server "${_ca}" >/dev/null 2>&1 || true
        case "${_issue_mode}" in
            dns_cf)
                case "${_auth_mode}" in
                    token)
                        _issue_out=$(CF_Token="${_auth_a}" CF_Zone_ID="${_auth_b}" CF_Account_ID="" CF_Key="" CF_Email="" \
                            acme_timeout_run 600 "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${_domain}" --keylength ec-256 --accountemail "${_email}" 2>&1)
                        ;;
                    key)
                        _issue_out=$(CF_Token="" CF_Zone_ID="" CF_Account_ID="" CF_Key="${_auth_a}" CF_Email="${_auth_b}" \
                            acme_timeout_run 600 "${HOME}/.acme.sh/acme.sh" --issue --dns dns_cf -d "${_domain}" --keylength ec-256 --accountemail "${_email}" 2>&1)
                        ;;
                    *)
                        log_error "未知 Cloudflare 认证模式: ${_auth_mode}"; return 1 ;;
                esac
                ;;
            http01)
                _issue_out=$(acme_timeout_run 600 "${HOME}/.acme.sh/acme.sh" --issue -d "${_domain}" --standalone --httpport 80 --keylength ec-256 --accountemail "${_email}" 2>&1)
                ;;
            *)
                log_error "未知 ACME 签发模式: ${_issue_mode}"; return 1 ;;
        esac
        _issue_rc=$?
        _last_out="${_issue_out}"
        printf '%s\n' "${_issue_out}" | redact_sensitive
        if [ "${_issue_rc}" -eq 0 ]; then
            log_ok "${_label} 签发成功"
            return 0
        fi
        if acme_issue_ok_or_existing "${_domain}" "${_issue_out}"; then
            log_ok "${_label} 已有证书可复用"
            return 0
        fi
        log_warn "${_label} 签发失败，切换下一个 CA"
    done
    if printf '%s\n' "${_last_out}" | grep -qE 'retryafter=86400|too large \(> 600\)'; then
        log_error "CA 已接受验证但订单处理要求等待 86400 秒；请稍后重试，或切换其它 CA/手动证书"
    elif printf '%s\n' "${_last_out}" | grep -qE 'curl: \\(28\\)|Cannot init API'; then
        log_error "所有 CA 均失败；检测到 ACME API 网络不可达/超时，请检查 VPS 到 CA 的 443 出站连通性"
    fi
    return 1
}

acme_cf_find_zone() {
    local _domain="$1" _token="$2" _name _resp _zone_id _zone_name
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_token:-}" ] || { log_error "Cloudflare API Token 不能为空"; return 1; }
    case "${_token}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare API Token 含非法字符"; return 1;; esac

    _name="${_domain}"
    while [ -n "${_name:-}" ] && [ "${_name#*.}" != "${_name}" ]; do
        _resp=$(curl -fsS -H "Authorization: Bearer ${_token}" \
            --get "https://api.cloudflare.com/client/v4/zones" \
            --data-urlencode "name=${_name}" \
            --data-urlencode "status=active" \
            --data-urlencode "per_page=1" 2>/dev/null) || true
        _zone_id=$(printf '%s' "${_resp:-}" | jq -r 'if .success == true and (.result|length) > 0 then .result[0].id else empty end' 2>/dev/null) || true
        _zone_name=$(printf '%s' "${_resp:-}" | jq -r 'if .success == true and (.result|length) > 0 then .result[0].name else empty end' 2>/dev/null) || true
        if [ -n "${_zone_id:-}" ] && [ -n "${_zone_name:-}" ]; then
            case "${_zone_id}" in *[!A-Za-z0-9_-]*) log_error "Cloudflare 返回的 Zone ID 格式不合法"; return 1;; esac
            log_info "已自动识别 Cloudflare Zone: ${_zone_name} (${_zone_id})" >&2
            printf '%s' "${_zone_id}"
            return 0
        fi
        _name="${_name#*.}"
    done
    log_error "无法通过 Cloudflare API 自动识别 ${_domain} 的 Zone ID；请确认 Token 具备 Zone:Read 权限且域名已托管在 Cloudflare"
    return 1
}

acme_issue_cf_token() {
    local _domain="$1" _token="$2" _email="${3:-}" _zone
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_token:-}" ] || { log_error "Cloudflare API Token 不能为空"; return 1; }
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    case "${_token}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare API Token 含非法字符"; return 1;; esac
    _zone=$(acme_cf_find_zone "${_domain}" "${_token}") || return 1
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Token='${_token}'
CF_Zone_ID='${_zone}'
export CF_Token CF_Zone_ID
" || { log_error "ACME 凭证写入失败"; return 1; }
    log_step "DNS-01 签发证书（Cloudflare Token；按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" token "${_token}" "${_zone}" dns_cf \
        || { log_error "DNS-01 签发失败；请检查 Cloudflare Token 权限（Zone:Read + DNS:Edit）、域名是否在该账号下，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert "${_domain}" "dns_cf_token"
}
acme_issue_cf_key() {
    local _domain="$1" _cf_key="$2" _cf_email="$3" _email="${4:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_cf_key:-}" ]   || { log_error "Cloudflare Global API Key 不能为空"; return 1; }
    case "${_cf_key}" in cfut_*|cfat_*) log_error "你输入的是 Cloudflare API Token，不是 Global API Key；请选择选项 2"; return 1;; esac
    [ -n "${_cf_email:-}" ] || { log_error "Cloudflare 账号邮箱不能为空"; return 1; }

    case "${_cf_key}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare Global API Key 含非法字符"; return 1;; esac
    case "${_cf_email}" in *' '*|*"'"*|*'"'*|*'`'*|*'\'*) log_error "Cloudflare 账号邮箱不合法"; return 1;; esac
    printf '%s' "${_cf_email}" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
        || { log_error "Cloudflare 账号邮箱格式不合法"; return 1; }

    acme_install "${_email:-${_cf_email}}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Key='${_cf_key}'
CF_Email='${_cf_email}'
export CF_Key CF_Email
" || { log_error "ACME 凭证写入失败"; return 1; }
    log_step "DNS-01 签发证书（Cloudflare Global Key；按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" key "${_cf_key}" "${_cf_email}" dns_cf \
        || { log_error "DNS-01 签发失败；请检查 Cloudflare Global API Key/账号邮箱、域名是否在该账号下，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert "${_domain}" "dns_cf_key"
}

acme_issue_cf_token_to_state() {
    local _prefix="$1" _domain="$2" _token="$3" _email="${4:-}" _zone
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_token:-}" ] || { log_error "Cloudflare API Token 不能为空"; return 1; }
    case "${_token}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare API Token 含非法字符"; return 1;; esac
    _zone=$(acme_cf_find_zone "${_domain}" "${_token}") || return 1
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Token='${_token}'
CF_Zone_ID='${_zone}'
export CF_Token CF_Zone_ID
" || { log_error "ACME 凭证写入失败"; return 1; }
    log_step "DNS-01 签发证书（Cloudflare Token；按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" token "${_token}" "${_zone}" dns_cf \
        || { log_error "DNS-01 签发失败；请检查 Cloudflare Token 权限（Zone:Read + DNS:Edit）、域名是否在该账号下，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert_to_state "${_prefix}" "${_domain}" "dns_cf_token"
}

acme_issue_cf_key_to_state() {
    local _prefix="$1" _domain="$2" _cf_key="$3" _cf_email="$4" _email="${5:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_cf_key:-}" ]   || { log_error "Cloudflare Global API Key 不能为空"; return 1; }
    case "${_cf_key}" in cfut_*|cfat_*) log_error "你输入的是 Cloudflare API Token，不是 Global API Key；请选择 Token 模式"; return 1;; esac
    [ -n "${_cf_email:-}" ] || { log_error "Cloudflare 账号邮箱不能为空"; return 1; }
    case "${_cf_key}" in *$'\r'*|*$'\n'*|*"'"*) log_error "Cloudflare Global API Key 含非法字符"; return 1;; esac
    case "${_cf_email}" in *' '*|*"'"*|*'"'*|*'`'*|*'\'*) log_error "Cloudflare 账号邮箱不合法"; return 1;; esac
    printf '%s' "${_cf_email}" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' \
        || { log_error "Cloudflare 账号邮箱格式不合法"; return 1; }
    acme_install "${_email:-${_cf_email}}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    atomic_write_secret "${_ACME_ENV_FILE}" "CF_Key='${_cf_key}'
CF_Email='${_cf_email}'
export CF_Key CF_Email
" || { log_error "ACME 凭证写入失败"; return 1; }
    log_step "DNS-01 签发证书（Cloudflare Global Key；按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" key "${_cf_key}" "${_cf_email}" dns_cf \
        || { log_error "DNS-01 签发失败；请检查 Cloudflare Global API Key/账号邮箱、域名是否在该账号下，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert_to_state "${_prefix}" "${_domain}" "dns_cf_key"
}

acme_install_cert() {
    acme_install_cert_to_state vlquic "$@"
}

acme_install_cert_to_state() {
    local _module="$1" _domain="$2" _method="${3:-manual}" _dir
    case "${_module}" in vlquic|cforigin) : ;; *) return 1 ;; esac
    val_domain "${_domain}" >/dev/null || return 1
    _dir="${_CERT_DIR}/${_domain}"
    # Config is applied only after the certificate and state have both been prepared.
    "${HOME}/.acme.sh/acme.sh" --install-cert -d "${_domain}" --ecc \
        --fullchain-file "${_dir}/fullchain.pem" --key-file "${_dir}/privkey.pem" \
        || { log_error "证书安装失败"; return 1; }
    chmod 700 "${_dir}" 2>/dev/null || true
    chmod 600 "${_dir}/privkey.pem" 2>/dev/null || true
    chmod 644 "${_dir}/fullchain.pem" 2>/dev/null || true
    st_set '.[$inbound_id] += {domain:$domain,cert:($dir+"/fullchain.pem"),key:($dir+"/privkey.pem"),acme_method:$method} |
            ._managed_cert_domains = (((._managed_cert_domains | arrays // []) + [$domain]) | unique)' \
        --arg inbound_id "${_module}" --arg domain "${_domain}" --arg dir "${_dir}" --arg method "${_method}"
}

acme_issue_http01() {
    local _domain="$1" _email="${2:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    if port_mgr_in_use 80; then
        log_error "80/tcp 已被占用，无法使用 HTTP-01 standalone"
        return 1
    fi
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    log_step "HTTP-01 standalone 签发证书（按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" none "" "" http01 \
        || { log_error "HTTP-01 签发失败；请检查 A 记录、80/tcp 端口、DNS only，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert "${_domain}" "http01"
}

acme_issue_http01_to_state() {
    local _prefix="$1" _domain="$2" _email="${3:-}"
    val_domain "${_domain}" >/dev/null || return 1
    [ -n "${_email:-}" ] || { log_error "ACME 邮箱不能为空"; return 1; }
    if port_mgr_in_use 80; then
        log_error "80/tcp 已被占用，无法使用 HTTP-01 standalone"
        return 1
    fi
    acme_install "${_email}" || return 1
    mkdir -p "${_CERT_DIR}/${_domain}"
    log_step "HTTP-01 standalone 签发证书（按 Let's Encrypt → ZeroSSL 轮换）..."
    acme_issue_with_ca_fallback "${_domain}" "${_email}" none "" "" http01 \
        || { log_error "HTTP-01 签发失败；请检查 A 记录、80/tcp 端口、DNS only，以及 VPS 到 CA 的 443 出站连通性"; return 1; }
    acme_install_cert_to_state "${_prefix}" "${_domain}" "http01"
}

_cert_prompt_email() {
    local _email_input
    while prompt "$1（0 返回）: " _email_input; do
        case "${_email_input}" in
            0) return 1 ;;
            *@example.com|*@example.org|*@example.net) ;;
            *) if [[ "${_email_input}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                   printf -v "$2" '%s' "${_email_input}"
                   return 0
               fi ;;
        esac
        log_error '请输入有效的邮箱地址'
    done
    return 1
}

_cert_prompt_secret() {
    local _secret
    while prompt_secret "$1（需重新输入，0 返回）: " _secret; do
        [ "${_secret}" != 0 ] || return 1
        if [ -n "${_secret}" ]; then printf -v "$2" '%s' "${_secret}"; return 0; fi
        log_error '凭证不能为空'
    done
    return 1
}

_cert_prompt_file() {
    local _file _hint='' _read=prompt
    [ -z "$3" ] || _hint='，回车保留'
    [ "${4:-}" != secret ] || _read=prompt_secret
    while "${_read}" "$1（0 返回${_hint}）: " _file; do
        [ "${_file}" != 0 ] || return 1
        _file="${_file:-$3}"
        if [ -f "${_file}" ]; then printf -v "$2" '%s' "${_file}"; return 0; fi
        log_error "$1不存在，请重新输入"
    done
    return 1
}

_tls_cert_config() {
    local _module="$1" _domain _saved _domain_label _email _source _last=4 _method
    local _cert='' _key='' _token _cf_key _cf_email _tls=true _issue_suffix='' _label
    local -a _issue=() _prefix=()
    local -a _sources=('Cloudflare API Token' 'Cloudflare Global API Key' 'HTTP-01 standalone'
        '使用已有证书文件' '沿用已配置证书' '明文 HTTP 回源')
    _label=$(module_label "${_module}")
    _saved=$(st_get '.[$id].domain' --arg id "${_module}")
    if [ "${_module}" = cforigin ]; then
        _last=6
        _domain_label='回源域名（Cloudflare 已代理）'
        _prefix=(cforigin)
        _issue_suffix=_to_state
    else
        _domain_label='入口域名（DNS only 直连 VPS）'
    fi
    [ -z "${_saved}" ] || _domain_label+=" [${_saved}]"
    while true; do
        prompt "${_domain_label}（0 返回）: " _domain || return 1
        [ "${_domain}" != 0 ] || return 1
        _domain="${_domain:-${_saved}}"
        val_domain "${_domain}" >/dev/null && break
    done
    while true; do
        local _choice
        log_title "证书来源"
        for ((_choice=1; _choice<=_last; _choice++)); do
            _menu_print_action "${_choice}" "${_sources[_choice-1]}"
        done
        _menu_print_back
        prompt "选择证书来源 (0-${_last}，回车选 1): " _source || return 1
        _source="${_source:-1}"
        [ "${_source}" != 0 ] || return 1
        _menu_index_valid "${_source}" "${_last}" || { log_error '无效证书来源'; continue; }
        if [ "${_source}" = 5 ]; then
            _cert=$(st_get '.cforigin.cert'); _key=$(st_get '.cforigin.key')
            _check_tls_certificate "${_label}" "${_domain}" "${_cert}" "${_key}" || continue
        fi
        break
    done
    if [ "${_source}" -le 3 ]; then
        _cert_prompt_email 'ACME 邮箱' _email || return 1
    fi
    case "${_source}" in
        1) _cert_prompt_secret 'Cloudflare API Token（Zone:Read + DNS:Edit）' _token || return 1
           _method=cf_token
           _issue=("acme_issue_cf_token${_issue_suffix}" "${_prefix[@]}" "${_domain}" "${_token}" "${_email}") ;;
        2) _cert_prompt_email 'Cloudflare 账号邮箱' _cf_email || return 1
           _cert_prompt_secret 'Cloudflare Global API Key' _cf_key || return 1
           _method=cf_key
           _issue=("acme_issue_cf_key${_issue_suffix}" "${_prefix[@]}" "${_domain}" "${_cf_key}" "${_cf_email}" "${_email}") ;;
        3) log_info 'HTTP-01 需要域名指向本机，且 80/tcp 可从公网访问'
           _method=http01
           _issue=("acme_issue_http01${_issue_suffix}" "${_prefix[@]}" "${_domain}" "${_email}") ;;
        4) until
               _cert_prompt_file '证书文件路径' _cert "${_cert}" || return 1
               _cert_prompt_file '私钥文件路径' _key "${_key}" secret || return 1
               _check_tls_certificate "${_label}" "${_domain}" "${_cert}" "${_key}"
           do :; done
           _method=manual ;;
        5) _method=manual_existing ;;
        6) log_warn '明文 HTTP 回源需要 Cloudflare Flexible 或等效配置'
           _method=plain_http; _tls=false ;;
    esac
    if [ "${_module}" = cforigin ]; then
        st_set '.cforigin += {domain:$d, cert:$c, key:$k, acme_method:$m, origin_tls:$tls}' \
            --arg d "${_domain}" --arg c "${_cert}" --arg k "${_key}" --arg m "${_method}" --argjson tls "${_tls}" || return 1
        _CFORIGIN_ISSUE=("${_issue[@]}")
    else
        st_set '.vlquic += {domain:$d, cert:$c, key:$k, acme_method:$m}' \
            --arg d "${_domain}" --arg c "${_cert}" --arg k "${_key}" --arg m "${_method}" || return 1
        _VLQUIC_ISSUE=("${_issue[@]}")
    fi
    if [ -n "${_cert_source+x}" ]; then _cert_source="${_sources[_source-1]}"; fi
}

cforigin_config_cert() { _tls_cert_config cforigin; }

_cforigin_check_ready() {
    case "$(st_get '.cforigin.protocol')" in ws|httpupgrade|xhttp) : ;; *) log_error "CF Origin 协议非法"; return 1 ;; esac
    val_path "$(st_get '.cforigin.path')" >/dev/null || return 1
    cf_edge_port_valid "$(st_get '.cforigin.edge_port')" || return 1
    val_port "$(port_of cforigin)" >/dev/null || return 1
    val_listen_addr "$(st_get '.cforigin.listen')" >/dev/null || return 1
    local _domain
    _domain=$(st_get '.cforigin.domain')
    val_domain "${_domain}" >/dev/null || { log_error "CF Origin 域名为空或格式不合法"; return 1; }
    [ "$(st_get '.cforigin.origin_tls')" = true ] || return 0
    if [ "${1:-}" = plan ] && [ "${#_CFORIGIN_ISSUE[@]}" -gt 0 ]; then
        [ "${_CFORIGIN_ISSUE[2]}" = "${_domain}" ] || { log_error "域名已变更，请重新选择证书来源"; return 1; }
        return 0
    fi
    _cforigin_check_origin_tls "${_domain}"
}

_cforigin_check_origin_tls() {
    [ "$(st_get '.cforigin.origin_tls')" = true ] || return 0
    _check_tls_certificate "CF Origin" "$1" "$(st_get '.cforigin.cert')" "$(st_get '.cforigin.key')"
}

_check_tls_certificate() {
    local _label="$1" _domain="$2" _cert="$3" _key="$4" _cert_pub _key_pub
    [ -f "${_cert}" ] || { log_error "${_label} 证书文件不存在"; return 1; }
    [ -f "${_key}" ] || { log_error "${_label} 私钥文件不存在"; return 1; }
    # 以叶证书为本地信任锚，同时检查有效期和域名。由客户端或 CDN 校验完整证书链。
    openssl verify -partial_chain -trusted "${_cert}" -verify_hostname "${_domain}" "${_cert}" >/dev/null 2>&1 || {
        log_error "${_label} 证书不覆盖 ${_domain}，或证书有效期、格式有误"
        return 1
    }
    _cert_pub=$(openssl x509 -in "${_cert}" -pubkey -noout 2>/dev/null) &&
        _key_pub=$(openssl pkey -in "${_key}" -passin pass: -pubout 2>/dev/null) &&
        [ -n "${_cert_pub}" ] && [ "${_cert_pub}" = "${_key_pub}" ] || {
        log_error "${_label} 证书与私钥不匹配，或私钥无法读取"
        return 1
    }
}

vlquic_config_cert() { _tls_cert_config vlquic; }

_vlquic_check_ready() {
    local _domain
    _domain=$(st_get '.vlquic.domain')
    [ -n "${_domain}" ] && [ "${_domain}" != null ] || { log_error "VLESS-XHTTP-H3 域名不能为空"; return 1; }
    if [ "${1:-}" = plan ] && [ "${#_VLQUIC_ISSUE[@]}" -gt 0 ]; then
        [ "${_VLQUIC_ISSUE[1]}" = "${_domain}" ] || { log_error "VLESS-XHTTP-H3 域名已变更，请重新选择证书来源"; return 1; }
        return 0
    fi
    _check_tls_certificate VLESS-XHTTP-H3 "${_domain}" "$(st_get '.vlquic.cert')" "$(st_get '.vlquic.key')"
}

_vlquic_apply_cert() {
    if [ "${#_VLQUIC_ISSUE[@]}" -gt 0 ]; then
        _vlquic_check_ready plan || return 1
        local _dir="${_CERT_DIR}/${_VLQUIC_ISSUE[1]}" _file _path _known
        for _file in fullchain.pem privkey.pem; do
            _path="${_dir}/${_file}"
            for _known in "${_TXN_ARTIFACT_PATHS[@]}"; do
                [ "${_known}" != "${_path}" ] || continue 2
            done
            _transaction_snapshot_file "${_path}" "${#_TXN_ARTIFACT_PATHS[@]}" || return 1
            _TXN_ARTIFACT_PATHS+=("${_path}")
        done
        "${_VLQUIC_ISSUE[@]}" || return 1
    fi
    _vlquic_check_ready
}

# ==============================================================================
# Argo tunnel integration
# ==============================================================================
# 核心设计：
#   - token/remote-managed tunnel：官方命令 cloudflared tunnel run --token <token>
#     token 仅存入 0600 env 文件；ingress 由 Cloudflare Zero Trust 远端配置管理。
#   - credentials/local-managed tunnel：官方命令 cloudflared tunnel --config tunnel.yml run
#     tunnel.yml 包含 tunnel ID、credentials-file 与本地 ingress。

# 生成 tunnel.yml（cred 模式：含 credentials-file）
_argo_gen_yml_cred() {
    local _domain="$1" _tid="$2" _cred="$3"
    # 校验所有字段，防止 YAML 注入
    local _port; _port=$(val_port "$(port_of argo)") || return 1
    val_domain "${_domain}" >/dev/null || return 1
    # tid 只允许 hex UUID 或 AccountTag（字母数字连字符）
    printf '%s' "${_tid}" | grep -qE '^[a-zA-Z0-9_-]{8,}$'         || { log_error "TunnelID 格式非法"; return 1; }
    local _new
    _new=$(printf 'tunnel: %s
credentials-file: %s

ingress:
  - hostname: %s
    service: http://localhost:%s
    originRequest:
      connectTimeout: 30s
      noTLSVerify: true
  - service: http_status:404
'         "${_tid}" "${_cred}" "${_domain}" "${_port}")
    local _cur; _cur=$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || true)
    [ "${_cur}" = "${_new}" ] && return 0
    atomic_write_secret "${WORK_DIR}/tunnel.yml" "${_new}"         || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已更新 [cred] (${_domain} → localhost:${_port})"
}

# token 模式：不生成 tunnel.yml；采用 Cloudflare 官方 remote-managed tunnel token 运行方式。
# 本地脚本只能保存 token 和域名状态；ingress 应在 Cloudflare Zero Trust 远端配置为 http://localhost:<argo-port>。
_argo_gen_yml_token() {
    local _domain="$1" _token="$2"
    # token/remote-managed tunnel：不把 token 写入 tunnel.yml；token 仅写入 0600 env file。
    # 注意：cloudflared token 模式的 ingress 通常由 Cloudflare 远端配置管理；本地无法可靠覆盖 ingress。
    local _port; _port=$(val_port "$(port_of argo)") || return 1
    val_domain "${_domain}" >/dev/null || return 1
    printf '%s' "${_token}" | grep -qE '^[A-Za-z0-9=_-]{20,}$'         || { log_error "token 格式非法"; return 1; }
    rm -f -- "${WORK_DIR}/tunnel.yml" || return 1
    log_ok "token 模式已配置：token 保存于 ${_ARGO_ENV_FILE}；请在 Cloudflare Zero Trust 远端将 Public Hostname 服务指向 http://localhost:${_port}"
}

argo_apply_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(st_get '.argo.protocol')  回源端口: $(port_of argo)"
    local _domain _auth
    prompt "请输入 Argo 域名: " _domain || return 1
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*)
        log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt_secret "请输入 Argo 密钥 (token 或 JSON 内容): " _auth || return 1
    [ -z "${_auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 \
            || { log_error "JSON 凭证格式不合法"; return 1; }
        local _tid
        _tid=$(printf '%s' "${_auth}" | jq -r '
            if (.TunnelID? // "") != "" then .TunnelID
            elif (.AccountTag? // "") != "" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${_tid:-}" ] && { log_error "无法提取 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*)
            log_error "TunnelID 含非法字符"; return 1;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        atomic_write_secret "${_cred}" "${_auth}" || { log_error "凭证写入失败"; return 1; }
        # 凭证文件含敏感字段，严格限制权限
        chmod 600 "${_cred}" 2>/dev/null || true
        _argo_gen_yml_cred "${_domain}" "${_tid}" "${_cred}" || return 1
        st_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        st_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        rm -f "${WORK_DIR}/tunnel.json" 2>/dev/null || true
        _argo_gen_yml_token "${_domain}" "${_auth}" || return 1
    else
        log_error "密钥格式无法识别"
        return 1
    fi

    _svc_write_argo_env || return 1
    svc_apply_tunnel || return 1
    svc_reload_daemon || return 1
    svc_exec_mut enable "${_SVC_TUNNEL}" 2>/dev/null || true
    config_apply  || return 1
    st_persist    || { log_error "state.json 写入失败"; return 1; }
    # tunnel restart 通过服务互斥接口执行
    svc_exec_mut restart "${_SVC_TUNNEL}" || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (domain=${_domain})"
    argo_check_health || true
}


_argo_prepare_fixed_tunnel_from_state() {
    local _domain _token _cred _tid _cred_b64
    _domain=$(st_get '.argo.domain')
    case "${_domain:-}" in ''|null|*' '*|*'/'*|*$'\t'*)
        log_error "Argo 域名未配置或格式不合法"
        return 1 ;;
    esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "Argo 域名格式不合法"; return 1; }

    _cred="${WORK_DIR}/tunnel.json"
    _cred_b64=$(st_get '.argo.cred_b64')
    if [ -n "${_cred_b64:-}" ] && [ "${_cred_b64}" != "null" ]; then
        printf '%s' "${_cred_b64}" | base64 -d > "${_cred}" 2>/dev/null \
            || { log_error "Argo JSON 凭证解码失败"; return 1; }
        chmod 600 "${_cred}" 2>/dev/null || true
    else
        _token=$(st_get '.argo.token')
        if [ -n "${_token}" ]; then
            val_argo_token "${_token}" >/dev/null || return 1
            _argo_gen_yml_token "${_domain}" "${_token}" || return 1
            rm -f -- "${_cred}" || return 1
            st_set '.argo.mode = "fixed"'
            return $?
        fi
    fi

    if [ -f "${_cred}" ]; then
        jq . < "${_cred}" >/dev/null 2>&1 || { log_error "tunnel.json 格式不合法"; return 1; }
        _tid=$(jq -r 'if (.TunnelID? // "") != "" then .TunnelID elif (.AccountTag? // "") != "" then .AccountTag else empty end' "${_cred}" 2>/dev/null)
        [ -n "${_tid:-}" ] || { log_error "tunnel.json 缺少 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*) log_error "TunnelID 含非法字符"; return 1;; esac
        _argo_gen_yml_cred "${_domain}" "${_tid}" "${_cred}" || return 1
        st_set '.argo.token = null | .argo.mode = "fixed"' || return 1
    else
        log_error "Argo token 或 JSON 凭证缺失"
        return 1
    fi
}

argo_apply_fixed_tunnel_from_state() {
    _argo_prepare_fixed_tunnel_from_state || return 1
    svc_apply_tunnel || return 1
    svc_reload_daemon || return 1
    svc_exec_mut enable "${_SVC_TUNNEL}" || {
        log_error "Argo 服务启用失败"
        return 1
    }
    config_apply || return 1
    _argo_activate_tunnel restart || return 1
    _commit_state_and_firewall || return 1
    log_ok "固定隧道本地配置已同步 (domain=$(st_get '.argo.domain'))"
}

_module_argo_update_domain_impl() {
    local _domain _old_domain _old_domain_json
    [ "$(st_get '.argo.enabled')" = "true" ] || { log_warn "请先启用 Argo"; return 1; }
    _old_domain=$(st_get '.argo.domain')
    _old_domain_json=$(printf '%s' "${_G_STATE}" | jq -c '.argo.domain' 2>/dev/null) \
        || { log_error "无法读取当前 Argo 域名"; return 1; }
    prompt "Argo 域名（回车保持 ${_old_domain}）: " _domain || return 1
    [ -n "${_domain:-}" ] || return 0
    case "${_domain}" in ''|*' '*|*'/'*|*$'\t'*) log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }
    st_set '.argo.domain = $d' --arg d "${_domain}" || return 1
    argo_apply_fixed_tunnel_from_state || {
        st_set '.argo.domain = $d' --argjson d "${_old_domain_json}" || true
        log_error "固定隧道同步失败，已回滚 Argo 域名为 ${_old_domain}"
        return 1
    }
    config_print_nodes argo || true
}

_module_argo_update_auth_impl() {
    _argo_update_credential install_plan_argo_update_auth
}

module_argo_update_action() {
    local _argo_update_changed=1
    case "${1:-}" in
        protocol|auth_protocol|trojan_password|domain|auth)
            _transaction_run "更新 Argo" "_module_argo_update_$1"_impl || return 1
            [ "${_argo_update_changed}" -eq 0 ] || argo_check_health || true ;;
        *)
            log_error "未知 Argo 字段动作: ${1:-}"
            return 1
            ;;
    esac
}

module_argo_update_protocol() {
    module_argo_update_action protocol
}

module_argo_update_auth_protocol() {
    module_argo_update_action auth_protocol
}

module_argo_update_trojan_password() {
    module_argo_update_action trojan_password
}

module_argo_update_domain() {
    module_argo_update_action domain
}

module_argo_update_auth() {
    module_argo_update_action auth
}

argo_check_health() {
    local _domain _code
    _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != null ] || return 0
    log_step "Argo 域名探测（最长 15 秒）..."
    _code=$(curl -q -sS --max-time 15 --connect-timeout 5 \
        -o /dev/null -w '%{http_code}' "https://${_domain}/" 2>/dev/null) || true
    case "${_code}" in
        5??) log_warn "Argo 域名返回 HTTP ${_code}，请检查 Cloudflare 和 Tunnel 回源"; return 1 ;;
        [234]??) log_info "Argo 域名返回 HTTP ${_code}，请通过客户端确认节点连通" ;;
        *) log_warn "Argo 域名探测未收到 HTTP 响应"; return 1 ;;
    esac
}

module_argo_update_port() {
    local _port
    _menu_select_port tcp _port || return 1
    _transaction_run "更新 Argo 回源端口" _module_argo_update_port_inner "${_port}" || return 1
    log_ok "Argo 回源端口已更新: ${_port}"
    config_print_nodes argo || true
}

_module_argo_update_port_inner() {
    st_set '.ports.argo = ($port|tonumber)' --arg port "$1" || return 1
    argo_apply_fixed_tunnel_from_state
}

# ==============================================================================
# Downloads and verification
# ==============================================================================
_xray_health_check() {
    local _bin="${1:-${XRAY_BIN}}"
    [ -f "${_bin}" ] && [ -x "${_bin}" ] || return 1
    "${_bin}" version >/dev/null 2>&1 || return 1
    local _tc; _tc=$(tmp_file "xray_hc_XXXXXX.json") || return 1
    printf '{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' \
        > "${_tc}"
    "${_bin}" -test -c "${_tc}" >/dev/null 2>&1; local _rc=$?
    rm -f "${_tc}" 2>/dev/null || true
    return "${_rc}"
}

_xray_latest_tag() {
    local _tag _i
    for _i in 1 2; do
        _tag=$(curl -sfL --max-time 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | jq -r 'select(.draft != true and .prerelease != true) | .tag_name // empty' 2>/dev/null) || true
        [[ "${_tag:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "${_tag}"; return 0; }
        [ "${_i}" -lt 2 ] && sleep 2
    done
    return 1
}

_xray_download_from_mirrors() {
    local _filename="$1" _dest="$2" _tag="$3"
    for _mirror in "${_XRAY_MIRRORS[@]}"; do
        log_step "下载 ${_filename} ..."
        curl -sfL --connect-timeout 15 --max-time 120 \
            -o "${_dest}" "${_mirror}/${_tag}/${_filename}"
        [ $? -eq 0 ] && [ -s "${_dest}" ] && return 0
        log_warn "镜像失败，尝试下一个..."
        rm -f "${_dest}" 2>/dev/null || true
    done
    log_error "所有镜像均下载失败: ${_filename}"; return 1
}

_xray_binary_tag() {
    "$1" version 2>/dev/null | awk 'NR == 1 && $1 == "Xray" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print "v" $2}'
}

_xray_stage_release() {
    local _tag="$1" _stage="$2" _zip_name _z _dgst _expected _actual
    platform_detect_arch || return 1
    _zip_name="Xray-linux-${_G_ARCH_XRAY}.zip"
    _z="${_stage}/${_zip_name}"
    command -v sha256sum >/dev/null 2>&1 || { log_error "缺少 sha256sum，拒绝安装未校验 Xray 二进制"; return 1; }
    command -v unzip >/dev/null 2>&1 || { log_error "缺少 unzip，无法解压 Xray 发布包"; return 1; }
    _xray_download_from_mirrors "${_zip_name}" "${_z}" "${_tag}" || return 1
    log_step "校验 SHA256..."
    _dgst=$(curl -sfL --max-time 15 \
        "https://github.com/XTLS/Xray-core/releases/download/${_tag}/${_zip_name}.dgst" 2>/dev/null) || {
        log_error "无法下载官方 Xray SHA256 摘要"; return 1;
    }
    _expected=$(awk 'toupper($0) ~ /SHA2-256/ {print tolower($NF); exit}' <<< "${_dgst}")
    [[ "${_expected}" =~ ^[0-9a-f]{64}$ ]] || { log_error "未获取到有效的 Xray SHA256 摘要"; return 1; }
    _actual=$(sha256sum "${_z}") || return 1
    if [ "${_actual%% *}" != "${_expected}" ]; then
        log_error "SHA256 校验失败"; return 1
    fi
    log_ok "SHA256 校验通过"
    unzip -p "${_z}" xray > "${_stage}/xray" || { log_error "解压 Xray 二进制失败"; return 1; }
    chmod 755 "${_stage}/xray" || return 1
    if [ "$(_xray_binary_tag "${_stage}/xray")" != "${_tag}" ] || ! _xray_health_check "${_stage}/xray"; then
        log_error "Xray 二进制版本或健康检查未通过"; return 1
    fi
}

download_xray() (
    local _cur _tag _stage
    if _xray_health_check "${XRAY_BIN}" 2>/dev/null; then
        _cur=$(_xray_binary_tag "${XRAY_BIN}")
        log_info "xray 已存在且健康 (${_cur:-unknown})，跳过下载"; return 0
    fi
    _tag=$(_xray_latest_tag) || { log_error "无法获取 Xray 最新稳定版本号"; return 1; }
    mkdir -p "${WORK_DIR}" || return 1
    _stage=$(mktemp -d "${WORK_DIR}/.xray-install.XXXXXX") || return 1
    trap 'rm -rf -- "${_stage}"' EXIT
    _xray_stage_release "${_tag}" "${_stage}" || return 1
    mv -fT -- "${_stage}/xray" "${XRAY_BIN}" || return 1
    log_ok "Xray 安装完成 (${_tag})"
)

_xray_upgrade_cleanup() {
    local _stage="$1" _restore="$2" _running="$3"
    if [ "${_restore}" -eq 1 ] && [ ! -e "${_stage}/xray" ]; then
        if ! mv -fT -- "${_stage}/previous" "${XRAY_BIN}"; then
            log_error "恢复旧内核失败，旧内核保留在 ${_stage}/previous"
            return 1
        fi
        if [ "${_running}" -eq 1 ] &&
            ! { svc_exec_mut restart "${_SVC_XRAY}" && svc_verify_health "${_SVC_XRAY}" 6; }; then
            log_error "已恢复旧内核，但 Xray 服务未能恢复运行"
        else
            log_warn "已恢复升级前的 Xray 内核"
        fi
    fi
    rm -rf -- "${_stage}"
}

_xray_upgrade_locked() (
    local _current="$1" _latest="$2" _stage _restore=0 _running=0
    if [ -e "${_UNINSTALL_PENDING}" ] || [ ! -f "${CONFIG_FILE}" ] ||
        [ -L "${XRAY_BIN}" ] || [ "$(_xray_binary_tag "${XRAY_BIN}")" != "${_current}" ]; then
        log_error "部署状态或 Xray 版本已变化，请重新检查后再试"
        return 1
    fi
    _stage=$(mktemp -d "${WORK_DIR}/.xray-upgrade.XXXXXX") || return 1
    trap '_xray_upgrade_cleanup "${_stage}" "${_restore}" "${_running}"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _xray_stage_release "${_latest}" "${_stage}" || return 1
    if ! XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-${WORK_DIR}}" "${_stage}/xray" -test -c "${CONFIG_FILE}" >/dev/null 2>&1; then
        log_error "新版 Xray 未通过现有配置检查，升级已取消"
        return 1
    fi
    if svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1; then _running=1; fi
    cp -p -- "${XRAY_BIN}" "${_stage}/previous" || return 1
    # 同目录树内原子替换，暂存文件消失后才需要回滚。
    _restore=1
    mv -fT -- "${_stage}/xray" "${XRAY_BIN}" || return 1
    if [ "${_running}" -eq 1 ] &&
        ! { svc_exec_mut restart "${_SVC_XRAY}" && svc_verify_health "${_SVC_XRAY}" 6; }; then
        log_error "新版 Xray 服务未能正常启动"
        return 1
    fi
    _restore=0
    log_ok "Xray 内核已升级：${_current} → ${_latest}"
)

module_xray_upgrade() {
    local _current _latest _answer
    if [ -e "${_UNINSTALL_PENDING}" ] || [ ! -f "${CONFIG_FILE}" ] || [ ! -x "${XRAY_BIN}" ] || [ -L "${XRAY_BIN}" ]; then
        log_error "请先完成 Xray-2go 部署或清理，再升级内核"
        return 1
    fi
    command -v flock >/dev/null 2>&1 || { log_error "升级内核需要 flock，以保护并发操作"; return 1; }
    _current=$(_xray_binary_tag "${XRAY_BIN}")
    [ -n "${_current}" ] || { log_error "无法读取当前 Xray 版本"; return 1; }
    _latest=$(_xray_latest_tag) || { log_error "无法获取 Xray 最新稳定版本号"; return 1; }
    log_info "当前 Xray 内核：${_current}，官方最新稳定版：${_latest}"
    if jq -en --arg current "${_current#v}" --arg latest "${_latest#v}" '
        def version: split(".") | map(tonumber);
        ($current | version) >= ($latest | version)
    ' >/dev/null; then
        log_info "当前内核已达到最新稳定版，无需升级"
        return 0
    fi
    prompt "确认升级内核？运行中的 Xray 将短暂重启 (y/N): " _answer || return 1
    [[ "${_answer:-}" == [yY] ]] || return 0
    with_lock _xray_upgrade_locked "${_current}" "${_latest}"
}

download_cloudflared() {
    platform_detect_arch
    if [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; then
        log_info "cloudflared 已存在，跳过下载"; return 0
    fi
    local _existing_cf; _existing_cf=$(command -v cloudflared 2>/dev/null || true)
    if [ -n "${_existing_cf:-}" ]; then
        cp -f "${_existing_cf}" "${ARGO_BIN}" || { log_error "复制 cloudflared 到 ${ARGO_BIN} 失败"; return 1; }
        chmod +x "${ARGO_BIN}"
        "${ARGO_BIN}" --version >/dev/null 2>&1 || { log_error "cloudflared --version 验证失败"; return 1; }
        log_ok "使用系统已安装的 cloudflared: ${_existing_cf}"
        return 0
    fi
    rm -f "${ARGO_BIN}" 2>/dev/null || true

    # 官方最佳实践优先：使用 Cloudflare 软件仓库/系统包管理器安装 cloudflared，避免脚本自管裸二进制校验链。
    log_step "通过系统包管理器安装 cloudflared..."
    if command -v apt-get >/dev/null 2>&1; then
        platform_pkg_require ca-certificates update-ca-certificates || return 1
        platform_pkg_require curl curl || return 1
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            -o /usr/share/keyrings/cloudflare-main.gpg \
            || { log_error "Cloudflare GPG key 下载失败"; return 1; }
        printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' \
            > /etc/apt/sources.list.d/cloudflared.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 \
            || { log_error "cloudflared 官方仓库 apt update 失败"; return 1; }
        DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared >/dev/null 2>&1 \
            || { log_error "cloudflared 包安装失败"; return 1; }
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
        cat > /etc/yum.repos.d/cloudflared.repo <<'EOF'
[cloudflared]
name=cloudflared
baseurl=https://pkg.cloudflare.com/cloudflared/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflare.com/cloudflare-main.gpg
EOF
        ${_pm} install -y cloudflared >/dev/null 2>&1 \
            || { log_error "cloudflared 包安装失败"; return 1; }
    else
        log_error "当前系统无 Cloudflare 官方包仓库自动安装路径；请先按 Cloudflare 官方文档安装 cloudflared 后重试，或先在菜单中关闭 Argo"
        return 1
    fi

    local _cf_bin; _cf_bin=$(command -v cloudflared 2>/dev/null || true)
    [ -n "${_cf_bin:-}" ] || { log_error "cloudflared 安装后不可用"; return 1; }
    cp -f "${_cf_bin}" "${ARGO_BIN}" || { log_error "复制 cloudflared 到 ${ARGO_BIN} 失败"; return 1; }
    chmod +x "${ARGO_BIN}"
    "${ARGO_BIN}" --version >/dev/null 2>&1 || { log_error "cloudflared --version 验证失败"; return 1; }
    log_ok "cloudflared 已通过官方包仓库安装"
}

# ==============================================================================
# Install and uninstall
# ==============================================================================
_install_detect_existing_xray() {
    command -v systemctl >/dev/null 2>&1 && \
        systemctl list-unit-files 2>/dev/null | grep -qiE '^xray[^2]' && return 0
    [ -f /etc/init.d/xray ] && return 0
    command -v rc-service >/dev/null 2>&1 && rc-service xray status >/dev/null 2>&1 && return 0
    command -v rc-update  >/dev/null 2>&1 && rc-update show 2>/dev/null | grep -q '\bxray\b' && return 0
    local _wx; _wx=$(command -v xray 2>/dev/null || true)
    [ -n "${_wx:-}" ] && [ "${_wx}" != "${XRAY_BIN}" ] && return 0
    pgrep -x xray >/dev/null 2>&1 && return 0
    return 1
}

_install_check_port_conflicts() {
    local _preview="${1:-}" _rules _rule _port _proto
    _rules=$(fw_desired_rules "${_preview}") || return 1
    if [ "${_preview}" = preview ]; then
        printf '  计划监听端口（端口/协议）\n'
    else
        log_step "检测端口冲突..."
    fi
    while IFS= read -r _rule; do
        [ -n "${_rule:-}" ] || continue
        _port=${_rule%/*}; _proto=${_rule#*/}
        if [ "${_preview}" = preview ]; then
            printf '    %s\n' "${_rule}"
        fi
        case "${_proto}" in
            udp)
                port_mgr_in_use_udp "${_port}" && \
                    log_warn "UDP/${_port} 已被占用，相关模块可能无法启动" ;;
            tcp)
                port_mgr_in_use "${_port}" && \
                    log_warn "TCP/${_port} 已被占用，相关模块可能无法启动" ;;
            *) log_warn "未知端口协议: ${_rule}" ;;
        esac
    done <<EOF
${_rules}
EOF
    return 0
}

module_xray_install_core() {
    clear; log_title "══════════ 安装 Xray-2go ══════════"
    platform_preflight || return 1
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"
    # 确保现有敏感文件权限正确
    [ -f "${STATE_FILE}" ]    && chmod 600 "${STATE_FILE}"    2>/dev/null || true
    [ -f "${_ARGO_ENV_FILE}" ] && chmod 600 "${_ARGO_ENV_FILE}" 2>/dev/null || true
    [ -f "${WORK_DIR}/tunnel.json" ] && chmod 600 "${WORK_DIR}/tunnel.json" 2>/dev/null || true

    # 刷新内置插件并重建注册表
    plugin_refresh_runtime || return 1

    _install_detect_existing_xray && {
        log_warn "检测到系统已存在 xray 相关组件"
        log_warn "将以隔离模式运行（服务名: ${_SVC_XRAY}）"
    }

    _install_check_port_conflicts || { log_error "端口冲突无法解决"; return 1; }

    download_xray || return 1
    [ "$(st_get '.argo.enabled')" = "true" ] && {
        download_cloudflared || return 1
    }

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        crypto_gen_reality_keypair || return 1
        st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" || return 1
    fi

    config_apply || return 1

    svc_apply_xray || return 1
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        _argo_prepare_fixed_tunnel_from_state && svc_apply_tunnel || return 1
    fi
    svc_reload_daemon || return 1

    platform_fix_time_sync
    fw_reconcile || return 1

    log_step "启动服务..."
    if ! svc_enable_start_verify "${_SVC_XRAY}" 8 required; then
        log_error "${_SVC_XRAY} 未正常运行，回滚"
        svc_exec_mut stop "${_SVC_XRAY}" 2>/dev/null || true
        return 1
    fi

    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        if ! svc_enable_start_verify "${_SVC_TUNNEL}" 6 required; then
            log_error "${_SVC_TUNNEL} 未正常运行，回滚"
            svc_exec_mut stop "${_SVC_TUNNEL}" 2>/dev/null || true
            return 1
        fi
    fi

    log_info "网络调优未内置执行：为避免运行未签名第三方 root 脚本，请按需参考可信来源手动配置。"

    st_persist || { log_error "state.json 写入失败"; return 1; }
    if is_openrc; then
        lifecycle_apply_sysctl
        if [ ! -e "${_HOSTS_BAK}" ]; then
            _install_hosts_pending=1
            lifecycle_apply_hosts_patch
        fi
    fi
    return 0
}

shortcut_is_managed() {
    local _target
    _target=$(readlink -- "${SHORTCUT}") || return 1
    [ "${_target}" = xray2go ] || [ "${_target}" = "${SELF_DEST}" ]
}

module_xray_uninstall() {
    local _a; prompt "确定要卸载 xray2go？(y/N): " _a || return 1
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return 0;; esac
    command -v flock >/dev/null 2>&1 || { log_error "卸载需要 flock，以保护并发操作"; return 1; }
    with_lock _module_xray_uninstall_locked
}

_uninstall_managed_files() {
    local _module _path _domain _state _domains
    if [ -d "${PLUGIN_DIR}" ] && [ ! -L "${PLUGIN_DIR}" ]; then
        for _module in "${_BUILTIN_PLUGINS[@]}"; do
            _path="${PLUGIN_DIR}/${_module}.sh"
            if _plugin_is_managed_builtin "${_path}" "${_module}"; then
                rm -f -- "${_path}" || return 1
            fi
        done
    fi
    [ -d "${_CERT_DIR}" ] && [ ! -L "${_CERT_DIR}" ] || return 0
    _state=$(_st_read_object "${STATE_FILE}") || return 0
    _domains=$(_managed_certificate_domains <<< "${_state}" | jq -r '.[]') || return 1
    while IFS= read -r _domain; do
        val_domain "${_domain}" >/dev/null 2>&1 || continue
        _path="${_CERT_DIR}/${_domain}"
        [ -d "${_path}" ] && [ ! -L "${_path}" ] || continue
        rm -f -- "${_path}/fullchain.pem" "${_path}/privkey.pem" || return 1
        rmdir -- "${_path}" 2>/dev/null || true
    done <<< "${_domains}"
}

_module_xray_uninstall_locked() {
    local _s _service_failed=0
    mkdir -p "${WORK_DIR}" || return 1
    : > "${_UNINSTALL_PENDING}" || return 1
    log_step "卸载中..."
    for _s in "${_SVC_XRAY}" "${_SVC_TUNNEL}"; do
        if ! _svc_stop_and_disable "${_s}"; then
            log_error "卸载未完成，请处理服务后再次执行 u"
            _service_failed=1
        fi
    done
    [ "${_service_failed}" -eq 0 ] || return 1
    if ! fw_force_cleanup; then
        log_error "卸载未完成。请恢复防火墙后端后再次执行 u"
        return 1
    fi

    _uninstall_managed_files || return 1
    rm -f -- "${WORK_DIR}/xray.pid" "${_X2G_ROOT}/var/run/xray2go.pid" "${_X2G_ROOT}/var/run/tunnel2go.pid" \
        "${CONFIG_FILE}" "${CONFIG_FILE}".*.bak "${WORK_DIR}/config_failed.json" \
        "${STATE_FILE}" "${STATE_FILE}".*.bak "${_CONFIG_HASH_FILE}" \
        "${_ARGO_ENV_FILE}" "${_ACME_ENV_FILE}" "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json" \
        "${XRAY_BIN}" "${ARGO_BIN}" || return 1
    _svc_remove_units "${_SVC_XRAY}" "${_SVC_TUNNEL}" || return 1
    lifecycle_rollback_sysctl || return 1
    lifecycle_rollback_hosts || return 1
    if [ -d "${HOME}/.cloudflared" ]; then log_info "已保留 ${HOME}/.cloudflared 中的独立 Tunnel 文件"; fi
    if shortcut_is_managed; then
        rm -f -- "${SHORTCUT}" || { log_error "快捷命令清理失败"; return 1; }
    fi
    rm -f -- "${SELF_DEST}.bak" || return 1
    rm -f -- "${SELF_DEST}" || { log_error "管理脚本清理失败"; return 1; }
    rm -f -- "${_UNINSTALL_PENDING}" || return 1
    rmdir -- "${PLUGIN_DIR}" "${_CERT_DIR}" 2>/dev/null || true
    rmdir -- "${WORK_DIR}" 2>/dev/null || log_info "已保留 ${WORK_DIR} 中归属未确认的文件"
    log_ok "xray2go 卸载完成"
}

# 在更新子进程中运行。EXIT 处理需要在函数返回后仍能读取暂存状态。
_install_main_script() {
    _stage='' _committed=0 _updating=0 _creating_shortcut=0 _rotating_backup=0
    local _bin_dir _header
    command -v flock >/dev/null 2>&1 || { log_error "更新需要 flock，以保护并发操作"; return 1; }
    exec 9>"${_LOCK_FILE}" || return 1
    flock -x 9 || { log_error "获取文件锁失败"; return 1; }
    [ ! -e "${_UNINSTALL_PENDING}" ] || { log_error "卸载待继续，拒绝脚本更新"; return 1; }
    _bin_dir=$(dirname "${SELF_DEST}")
    mkdir -p -- "${_bin_dir}" || { log_error "无法创建脚本安装目录"; return 1; }

    if [ -e "${SELF_DEST}" ] || [ -L "${SELF_DEST}" ]; then
        if [ ! -f "${SELF_DEST}" ] || [ -L "${SELF_DEST}" ]; then
            log_error "脚本安装路径被占用: ${SELF_DEST}"
            return 1
        fi
    fi
    if { [ -e "${SHORTCUT}" ] || [ -L "${SHORTCUT}" ]; } && ! shortcut_is_managed; then
        log_error "快捷命令路径已被其他文件占用: ${SHORTCUT}"
        return 1
    fi

    if { [ -e "${SELF_DEST}.bak" ] || [ -L "${SELF_DEST}.bak" ]; } &&
       { [ ! -f "${SELF_DEST}.bak" ] || [ -L "${SELF_DEST}.bak" ]; }; then
        log_error "脚本备份路径被占用: ${SELF_DEST}.bak"
        return 1
    fi

    # 在目标目录所在文件系统准备新脚本，最后以 rename 原子替换。
    _stage=$(mktemp -d "${_bin_dir}/.xray2go-update.XXXXXX") || { log_error "无法创建更新暂存目录"; return 1; }
    # shellcheck disable=SC2317 # 由 EXIT trap 调用
    _install_main_script_cleanup() {
        local _failed=0
        trap '' INT TERM
        if [ "${_committed}" -eq 0 ]; then
            if [ "${_updating}" -eq 1 ] && [ ! -e "${_stage}/xray2go" ]; then
                if [ -f "${_stage}/original" ]; then
                    command mv -fT -- "${_stage}/original" "${SELF_DEST}" || _failed=1
                else
                    rm -f -- "${SELF_DEST}" || _failed=1
                fi
            fi
            if [ "${_rotating_backup}" -eq 1 ] && [ ! -e "${_stage}/previous" ]; then
                if [ -f "${_stage}/saved-backup" ]; then
                    command mv -fT -- "${_stage}/saved-backup" "${SELF_DEST}.bak" || _failed=1
                else
                    rm -f -- "${SELF_DEST}.bak" || _failed=1
                fi
            fi
            if [ "${_creating_shortcut}" -eq 1 ] && [ ! -L "${_stage}/shortcut" ] && shortcut_is_managed; then
                rm -f -- "${SHORTCUT}" || _failed=1
            fi
        fi
        if [ "${_failed}" -eq 0 ]; then
            rm -rf -- "${_stage}"
        else
            log_error "更新恢复失败，请检查暂存目录: ${_stage}"
        fi
    }
    trap _install_main_script_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    log_step "正在下载官方 main 分支脚本..."
    curl -q --proto '=https' -fsS --connect-timeout 10 --max-time 30 \
        -o "${_stage}/xray2go" https://raw.githubusercontent.com/Luckylos/xray-2go/main/xray_2go.sh \
        || { log_error "下载失败，当前脚本仍可用"; return 1; }
    if ! IFS= read -r _header < "${_stage}/xray2go" ||
       { [ "${_header}" != '#!/usr/bin/env bash' ] && [ "${_header}" != '#!/bin/bash' ]; } ||
       ! BASH_ENV='' "${BASH}" -n "${_stage}/xray2go"; then
        log_error "下载的脚本未通过 Bash 格式或语法检查"
        return 1
    fi
    chmod 755 -- "${_stage}/xray2go" || { log_error "无法设置脚本执行权限"; return 1; }

    local _replace=1
    if [ -f "${SELF_DEST}" ]; then
        if [ -x "${SELF_DEST}" ] && cmp -s -- "${_stage}/xray2go" "${SELF_DEST}"; then
            _replace=0
        else
            cp -p -- "${SELF_DEST}" "${_stage}/original" &&
                cp -p -- "${SELF_DEST}" "${_stage}/previous" &&
                chmod +x -- "${_stage}/previous" || { log_error "无法暂存当前脚本"; return 1; }
            if [ -f "${SELF_DEST}.bak" ]; then
                cp -p -- "${SELF_DEST}.bak" "${_stage}/saved-backup" || return 1
            fi
            _rotating_backup=1
        fi
    fi
    if [ ! -L "${SHORTCUT}" ]; then
        ln -s -- xray2go "${_stage}/shortcut" || return 1
        _creating_shortcut=1
        if ! mv -nT -- "${_stage}/shortcut" "${SHORTCUT}" || [ -L "${_stage}/shortcut" ]; then
            log_error "创建快捷命令失败: ${SHORTCUT}"
            return 1
        fi
    fi
    _updating="${_replace}"
    if [ "${_rotating_backup}" -eq 1 ] && ! mv -fT -- "${_stage}/previous" "${SELF_DEST}.bak"; then
        log_error "无法备份当前脚本"
        return 1
    fi
    if [ "${_replace}" -eq 1 ] && ! mv -fT -- "${_stage}/xray2go" "${SELF_DEST}"; then
        log_error "替换脚本失败"
        return 1
    fi
    _committed=1
}

module_config_update_shortcut() {
    local _rc=0
    ( _install_main_script ) &
    _UPDATE_PID=$!
    wait "${_UPDATE_PID}" || _rc=$?
    _UPDATE_PID=""
    [ "${_rc}" -eq 0 ] || return "${_rc}"
    log_ok "快捷方式和脚本已更新，正在重新载入管理菜单"
    exec "${BASH}" "${SELF_DEST}"
}

_module_config_save_uuid() {
    st_set '.uuid = $u' --arg u "$1" && _commit
}

module_config_update_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v || return 1
    if [ -z "${_v:-}" ]; then
        _v=$(crypto_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID"
    fi
    # 通过 val_uuid 统一校验，防止配置注入
    val_uuid "${_v}" >/dev/null || return 1
    _transaction_run "更新 UUID" _module_config_save_uuid "${_v}" || return 1
    log_ok "UUID 已更新"; config_print_nodes
}

# ==============================================================================
# Interactive menus
# ==============================================================================

# ── 安装向导（历史兼容层已收敛到统一闭环工作台） ─────────────────────────────

# ── 单文件模块注册表 / 管理子菜单辅助 ─────────────────────────────────────────

# 集中维护模块 ID 与公共动作处理器；专用字段动作仍在 module_dispatch 中显式列出。
_MODULE_IDS="argo ff reality vltcp vlquic cforigin socks http ss2022"

declare -A _MODULE_LABELS=(
    [argo]="Argo"
    [ff]="FreeFlow"
    [reality]="Reality"
    [vltcp]="VLESS-TCP"
    [vlquic]="VLESS-XHTTP-H3"
    [cforigin]="CF Origin"
    [socks]="SOCKS5"
    [http]="HTTP 代理"
    [ss2022]="Shadowsocks 2022"
)
declare -A _MODULE_MENU_FN=(
    [argo]=unified_menu_argo
    [ff]=unified_menu_freeflow
    [reality]=unified_menu_reality
    [vltcp]=unified_menu_vltcp
    [vlquic]=unified_menu_vlquic
    [cforigin]=unified_menu_cforigin
    [socks]=unified_menu_socks
    [http]=unified_menu_http
    [ss2022]=unified_menu_ss2022
)
declare -A _MODULE_RESTART_TARGET=(
    [argo]=argo
    [ff]=xray
    [reality]=xray
    [vltcp]=xray
    [vlquic]=xray
    [cforigin]=xray
    [socks]=xray
    [http]=xray
    [ss2022]=xray
)
declare -A _MODULE_ENABLE_FN=(
    [argo]=module_argo_enable
    [ff]=module_ff_enable
    [reality]=module_reality_enable
    [vltcp]=module_vltcp_enable
    [vlquic]=module_vlquic_enable
    [cforigin]=module_cforigin_enable
    [socks]=module_socks_enable
    [http]=module_http_enable
    [ss2022]=module_ss2022_enable
)
declare -A _MODULE_DISABLE_FN=(
    [argo]=module_argo_disable
    [ff]=module_ff_disable
    [reality]=module_reality_disable
    [vltcp]=module_vltcp_disable
    [vlquic]=module_vlquic_disable
    [cforigin]=module_cforigin_disable
    [socks]=module_socks_disable
    [http]=module_http_disable
    [ss2022]=module_ss2022_disable
)
declare -A _MODULE_UNINSTALL_FN=(
    [argo]=module_argo_uninstall
    [ff]=module_ff_uninstall
    [reality]=module_reality_uninstall
    [vltcp]=module_vltcp_uninstall
    [vlquic]=module_vlquic_uninstall
    [cforigin]=module_cforigin_uninstall
    [socks]=module_socks_uninstall
    [http]=module_http_uninstall
    [ss2022]=module_ss2022_uninstall
)
declare -A _MODULE_UPDATE_PORT_FN=(
    [argo]=module_argo_update_port
    [ff]=module_ff_update_port
    [reality]=module_reality_update_port
    [vltcp]=module_vltcp_update_port
    [vlquic]=module_vlquic_update_port
    [cforigin]=module_cforigin_update_port
    [socks]=module_socks_update_port
    [http]=module_http_update_port
    [ss2022]=module_ss2022_update_port
)
declare -A _MODULE_UPDATE_LISTEN_FN=(
    [vltcp]=module_vltcp_update_listen
    [vlquic]=module_vlquic_update_listen
    [cforigin]=module_cforigin_update_listen
    [socks]=module_socks_update_listen
    [http]=module_http_update_listen
    [ss2022]=module_ss2022_update_listen
)

module_registry_has() {
    local _id="${1:-}"
    [ -n "${_id}" ] || return 1
    [ -n "${_MODULE_LABELS[${_id}]-}" ]
}

module_label() {
    local _id="${1:-unknown}" _label
    _label="${_MODULE_LABELS[${_id}]-}"
    [ -n "${_label}" ] && printf '%s' "${_label}" || printf '%s' "${_id}"
}

module_summary() {
    local _mod="$1"
    case "${_mod}" in
        argo)
            local _as _dom
            _as=$(check_argo); _dom=$(st_get '.argo.domain')
            if [ "$(st_get '.argo.enabled')" = "true" ]; then
                [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
                    && printf '%s' "${_as} [$(st_get '.argo.protocol'), ${_dom}, port=$(port_of argo)]" \
                    || printf '%s' "${_as} [未配置域名]"
            else
                printf '未启用'
            fi ;;
        ff)
            local _fp _fpa _ffhost
            _fp=$(st_get '.ff.protocol'); _fpa=$(st_get '.ff.path'); _ffhost=$(st_get '.ff.host')
            if [ "$(st_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ]; then
                [ "${_fp}" = "tcphttp" ] \
                    && printf '%s' "${_fp} (host=${_ffhost}, port=$(port_of ff))" \
                    || printf '%s' "${_fp} (path=${_fpa}, port=$(port_of ff))"
            else
                printf '未启用'
            fi ;;
        reality)
            [ "$(st_get '.reality.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of reality), $(st_get '.reality.network'), sni=$(st_get '.reality.sni'))" \
                || printf '未启用' ;;
        vltcp)
            [ "$(st_get '.vltcp.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of vltcp), listen=$(st_get '.vltcp.listen'))" \
                || printf '未启用' ;;
        vlquic)
            [ "$(st_get '.vlquic.enabled')" = "true" ] \
                && printf '%s' "已启用 (udp=$(port_of vlquic), domain=$(st_get '.vlquic.domain'))" \
                || printf '未启用' ;;
        cforigin)
            [ "$(st_get '.cforigin.enabled')" = "true" ] \
                && printf '%s' "已启用 ($(st_get '.cforigin.protocol'), edge=$(st_get '.cforigin.edge_port'), h3=$(st_get '.cforigin.edge_h3'), origin=$(port_of cforigin), domain=$(st_get '.cforigin.domain'))" \
                || printf '未启用' ;;
        socks)
            [ "$(st_get '.socks.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of socks), listen=$(st_get '.socks.listen'), user=$(st_get '.socks.user'))" \
                || printf '未启用' ;;
        http)
            [ "$(st_get '.http.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of http), listen=$(st_get '.http.listen'), user=$(st_get '.http.user'))" \
                || printf '未启用' ;;
        ss2022)
            [ "$(st_get '.ss2022.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of ss2022), listen=$(st_get '.ss2022.listen'), method=$(st_get '.ss2022.method'))" \
                || printf '未启用' ;;
        *)
            printf 'unknown' ;;
    esac
}

module_show_action() {
    local _mod="${1:-}"
    if [ "${_mod}" = "all" ]; then
        config_print_nodes
    elif module_registry_has "${_mod}"; then
        config_print_nodes "${_mod}"
        if [ "${_mod}" = "cforigin" ]; then
            cforigin_print_cloudflare_hint
        fi
    else
        log_error "不支持节点展示的模块: ${_mod}"
        return 1
    fi
    return 0
}

module_show_nodes() {
    module_show_action all
}

module_cforigin_show() {
    module_show_action cforigin
}

module_nodes_show() {
    if [ "${_MENU_CX:-1}" -eq 0 ] 2>/dev/null || check_xray >/dev/null 2>&1; then
        config_print_nodes
        cforigin_print_cloudflare_hint
        return 0
    fi
    log_warn "Xray-2go 未安装或未运行"
    return 1
}

_module_argo_restart_inner() {
    _argo_activate_tunnel restart || return 1
    log_ok "${_SVC_TUNNEL} 已重启"
}

module_restart_action() {
    local _target="${1:-}"
    case "${_target}" in
        xray)
            _transaction_run "Xray 重启" svc_restart_xray
            ;;
        argo)
            _transaction_run "Argo 重启" _module_argo_restart_inner
            ;;
        *)
            log_error "不支持的重启目标: ${_target}"
            return 1
            ;;
    esac
}

module_xray_restart() {
    module_restart_action xray
}

module_argo_restart() {
    module_restart_action argo
}

module_status_action() {
    local _target="${1:-}"
    case "${_target}" in
        xray)
            case "$(_deployment_state)" in
                running)     printf 'running'; return 0 ;;
                stopped)     printf 'stopped'; return 1 ;;
                uninstalled) printf 'not installed'; return 2 ;;
                *)           printf 'unknown'; return 4 ;;
            esac
            ;;
        argo)
            [ "$(st_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
            [ -f "${ARGO_BIN}" ] || { printf 'not installed'; return 2; }
            svc_exec status "${_SVC_TUNNEL}" \
                && { printf 'running'; return 0; } \
                || { printf 'stopped'; return 1; }
            ;;
        *)
            printf 'unknown'
            return 1
            ;;
    esac
}

module_registry_dispatch_common() {
    local _mod="${1}" _action="${2}" _fn _target
    case "${_action}" in
        menu)
            _fn="${_MODULE_MENU_FN[${_mod}]-}"
            [ -n "${_fn}" ] || { log_error "模块 ${_mod} 未注册菜单处理器"; return 1; }
            "${_fn}" runtime || return $?
            _menu_return_to_parent
            ;;
        restart)
            _target="${_MODULE_RESTART_TARGET[${_mod}]-}"
            [ -n "${_target}" ] || { log_error "模块 ${_mod} 未注册重启目标"; return 1; }
            module_restart_action "${_target}"
            ;;
        show)
            module_show_action "${_mod}"
            ;;
        enable|disable|uninstall)
            if [ "${_action}" = "enable" ]; then
                _fn="${_MODULE_ENABLE_FN[${_mod}]-}"
            elif [ "${_action}" = "disable" ]; then
                _fn="${_MODULE_DISABLE_FN[${_mod}]-}"
            else
                _fn="${_MODULE_UNINSTALL_FN[${_mod}]-}"
            fi
            [ -n "${_fn}" ] || { log_error "模块 ${_mod} 未注册 ${_action} 处理器"; return 1; }
            "${_fn}"
            ;;
        update_port)
            _fn="${_MODULE_UPDATE_PORT_FN[${_mod}]-}"
            [ -n "${_fn}" ] || { log_error "模块 ${_mod} 未注册端口处理器"; return 1; }
            "${_fn}"
            ;;
        update_listen)
            _fn="${_MODULE_UPDATE_LISTEN_FN[${_mod}]-}"
            [ -n "${_fn}" ] || { log_error "模块 ${_mod} 未注册监听地址处理器"; return 1; }
            "${_fn}"
            ;;
        *)
            return 2
            ;;
    esac
}

module_dispatch() {
    local _mod="${1:-}" _action="${2:-menu}"
    case "${_action}" in
        menu|restart|show|enable|disable|uninstall|update_port|update_listen)
            if module_registry_has "${_mod}"; then
                module_registry_dispatch_common "${_mod}" "${_action}"
                return $?
            fi
            ;;
    esac
    case "${_mod}:${_action}" in
        # core/global actions
        xray:restart) module_xray_restart ;;
        xray:install) module_xray_install ;;
        xray:upgrade) module_xray_upgrade ;;
        xray:uninstall) module_xray_uninstall ;;
        nodes:show) module_nodes_show ;;
        config:update_uuid) module_config_update_uuid ;;
        config:update_shortcut) module_config_update_shortcut ;;

        # Common module actions are dispatched from the registry above.

        # field/config update actions
        argo:update_protocol) module_argo_update_action protocol ;;
        argo:update_auth_protocol) module_argo_update_action auth_protocol ;;
        argo:update_trojan_password) module_argo_update_action trojan_password ;;
        argo:update_domain) module_argo_update_action domain ;;
        argo:update_auth) module_argo_update_action auth ;;
        ff:update_mode) module_ff_update_mode ;;
        ff:update_host_or_path) module_ff_update_host_or_path ;;
        reality:update_transport) module_reality_update_transport ;;
        cforigin:update_protocol) module_cforigin_update_protocol ;;
        cforigin:update_domain) module_cforigin_update_domain ;;
        cforigin:update_path) module_cforigin_update_path ;;
        socks:update_auth) module_socks_update_auth ;;
        socks:update_user) module_socks_update_user ;;
        socks:update_pass) module_socks_update_pass ;;
        http:update_auth) module_http_update_auth ;;
        http:update_user) module_http_update_user ;;
        http:update_pass) module_http_update_pass ;;
        ss2022:update_method) module_ss2022_update_method ;;
        ss2022:regenerate_keys) module_ss2022_regenerate_keys ;;

        # key/toggle actions
        reality:update_sni) module_reality_update_sni ;;
        reality:regenerate_keys) module_reality_regenerate_keys ;;

        # complex/specialized actions
        vlquic:update_cert) module_vlquic_update_cert ;;
        cforigin:update_cert) module_cforigin_update_cert ;;
        cforigin:update_edge_port) module_cforigin_update_edge_port ;;
        cforigin:toggle_edge_h3) module_cforigin_toggle_edge_h3 ;;
        *) log_error "未知模块动作: ${_mod}:${_action}"; return 1 ;;
    esac
}

# 交互输入端口并写入 .ports.<proto>
# 交互选择端口并校验，只输出端口。可传入提示、回车保留值和占用处理（confirm / warn）。
_menu_select_port() {
    local _proto="${1:-tcp}" _outvar="${2:-}" _port_input _proto_label
    _proto_label="${_proto^^}"
    while true; do
        prompt "${3:-新端口（回车随机，0 返回）: }" _port_input || return 1
        [ "${_port_input}" != 0 ] || return 1
        if [ -z "${_port_input}" ]; then
            _port_input="${4:-}"
            [ -n "${_port_input}" ] || _port_input=$(port_mgr_random_proto "${_proto}") || return 1
        fi
        val_port "${_port_input}" >/dev/null && break
    done
    local _busy
    case "${_proto}" in
        udp)  port_mgr_in_use_udp "${_port_input}" && _busy=1 || _busy=0 ;;
        both) _proto_label="TCP/UDP"; port_mgr_in_use_both "${_port_input}" && _busy=1 || _busy=0 ;;
        *)    port_mgr_in_use "${_port_input}" && _busy=1 || _busy=0 ;;
    esac
    if [ "${_busy}" -eq 1 ]; then
        if [ "${5:-confirm}" = confirm ]; then
            log_warn "${_proto_label}/${_port_input} 已被占用"
            local _a; prompt "仍然继续？(y/N): " _a || return 1
            case "${_a:-n}" in y|Y) :;; *) return 1;; esac
        else
            log_warn "${_proto_label}/${_port_input} 已被占用；当前不会自动更换，请手动确认端口"
        fi
    fi
    if [ -n "${_outvar:-}" ]; then
        printf '%s' "${_outvar}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' \
            || { log_error "内部错误：非法输出变量名 ${_outvar}"; return 1; }
        printf -v "${_outvar}" '%s' "${_port_input}"
    else
        printf '%s' "${_port_input}"
    fi
}

_menu_input_port_proto() {
    local _jq_path="$1" _proto="${2:-tcp}" _outvar="${3:-}" _np
    _menu_select_port "${_proto}" _np || return 1
    st_set "${_jq_path} = (\$p|tonumber)" --arg p "${_np}" || return 1
    if [ -n "${_outvar:-}" ]; then
        printf -v "${_outvar}" '%s' "${_np}"
    else
        printf '%s' "${_np}"
    fi
}

_menu_input_port() {
    _menu_input_port_proto "$1" tcp "${2:-}"
}

_menu_update_port() {
    local _proto="$1" _net="${2:-tcp}" _label_suffix="${3:-}" _np
    _menu_select_port "${_net}" _np || return 1
    _commit_port_change "${_proto}" "${_np}" "${_label_suffix}"
}

_menu_confirm_uninstall() {
    local _name="$1" _a
    prompt "确定要卸载 ${_name}？(y/N): " _a || return 1
    case "${_a:-n}" in y|Y) return 0;; *) return 1;; esac
}

_menu_toggle_xpad() {
    local _target="$1" _label="$2"
    _transaction_run "切换 xPadding" _module_toggle_xpad_inner "${_target}" || return 1
    log_ok "${_label} xPadding: $(xpad_of "${_target}")"
    config_print_nodes "${_target}" || true
}

_set_xpad_toggle() {
    local _target="$1" _next=true
    case "${_target}" in
        argo|ff|reality) : ;;
        *) log_error "未知 xPadding 目标: ${_target}"; return 1 ;;
    esac
    if [ "$(xpad_of "${_target}")" = true ]; then _next=false; fi
    st_set '.xpad[$id] = $value' --arg id "${_target}" --argjson value "${_next}"
}

_module_toggle_xpad_inner() {
    _set_xpad_toggle "$1" && config_apply && st_persist
}

_xray_runtime_status() {
    module_status_action xray || :
}

_menu_print_module_status() {
    local _enabled="$1" _svc_status="$2"
    [ "${_enabled}" = "true" ] \
        && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_svc_status}" \
        || printf "  模块: ${C_YLW}未启用${C_RST}\n"
}

_menu_print_action() {
    local _key="$1" _label="$2" _color="${3:-${C_GRN}}"
    printf "  ${_color}%s.${C_RST} %s\n" "${_key}" "${_label}"
}

_menu_print_back() {
    _menu_print_action 0 "返回上一级" "${C_PUR}"
}

_module_apply_persist_print() {
    local _message="$1" _print_nodes="${2:-yes}"
    config_apply || return 1
    st_persist || { log_error "state.json 写入失败"; return 1; }
    [ -n "${_message:-}" ] && log_ok "${_message}"
    [ "${_print_nodes}" = "yes" ] && config_print_nodes
}

check_xray_install() {
    [ -f "${CONFIG_FILE}" ] && return 0
    if is_systemd; then
        systemctl cat "${_SVC_XRAY}" >/dev/null 2>&1 && return 0
    else
        [ -f "${_SVC_OPENRC_DIR}/${_SVC_XRAY}" ] && return 0
    fi
    return 1
}

check_xray() {
    module_status_action xray
}

_manage_module_entry_check() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return 1; }
}

check_argo() {
    module_status_action argo
}

# ── Argo 管理 ─────────────────────────────────────────────────────────────────

# ── FreeFlow 管理 ─────────────────────────────────────────────────────────────

# ── Reality 管理 ──────────────────────────────────────────────────────────────

# ── VLESS-TCP 管理 ────────────────────────────────────────────────────────────


# ── VLESS-XHTTP-H3 管理 ────────────────────────────────────────────────────────



# ── SOCKS5 管理 ───────────────────────────────────────────────────────────────

# ── Cloudflare Origin 回源管理 ────────────────────────────────────────────────

# ── 主菜单 ────────────────────────────────────────────────────────────────────

_deployment_state() {
    local _status=0
    _svc_runtime_state "${_SVC_XRAY}" || _status=$?
    case "${_status}" in
        0) printf 'running' ;;
        1) printf 'stopped' ;;
        3) if check_xray_install; then printf 'stopped'; else printf 'uninstalled'; fi ;;
        *) printf 'unknown' ;;
    esac
}

_require_first_deploy() {
    case "$(_deployment_state)" in
        uninstalled) return 0 ;;
        unknown) log_error '无法确认 Xray-2go 是否已安装，拒绝首次部署' ;;
        *) log_error 'Xray-2go 已安装。如需重装，请先用维护菜单卸载' ;;
    esac
    return 1
}

_menu_collect_status() {
    _MENU_STATE=$(_deployment_state)
}

_menu_render() {
    local _module _summary
    printf '\n'
    log_title "Xray-2go 控制台"
    case "${_MENU_STATE}" in
        running) printf '  Xray  %s运行中%s\n' "${C_GRN}" "${C_RST}" ;;
        stopped) printf '  Xray  %s已安装 · 未运行%s\n' "${C_YLW}" "${C_RST}" ;;
        *) printf '  Xray  %s状态未知%s\n' "${C_YLW}" "${C_RST}" ;;
    esac
    for _module in ${_MODULE_IDS}; do
        _summary=$(module_summary "${_module}")
        [ "${_summary}" != '未启用' ] || continue
        printf '  %s  %s\n' "$(module_label "${_module}")" "${_summary}"
    done
    printf '\n'
    _menu_print_action 1 '查看与导出节点'
    _menu_print_action 2 '管理入站'
    _menu_print_action 3 '维护'
    _menu_print_action 0 '退出'
}

_menu_return_to_parent() {
    if [ -n "${_menu_redraw+x}" ]; then _menu_redraw=1; fi
}

_menu_inbounds() {
    local _module _summary _choice _index
    local -a _active_inbounds _inactive_inbounds _details _modules
    while true; do
        _active_inbounds=(); _inactive_inbounds=(); _details=()
        for _module in ${_MODULE_IDS}; do
            _summary=$(module_summary "${_module}")
            if [ "${_summary}" = '未启用' ]; then
                _inactive_inbounds+=("${_module}")
            else
                _active_inbounds+=("${_module}")
                _details+=("${_summary}")
            fi
        done
        _modules=("${_active_inbounds[@]}" "${_inactive_inbounds[@]}")
        log_title '管理入站'
        for _index in "${!_modules[@]}"; do
            _menu_print_action "$((_index + 1))" "$(module_label "${_modules[_index]}") · ${_details[_index]:-未启用}"
        done
        _menu_print_back
        prompt '选择入站: ' _choice || return 0
        if [ "${_choice}" = 0 ]; then return 0; fi
        if _menu_index_valid "${_choice}" "${#_modules[@]}"; then
            module_dispatch "${_modules[_choice-1]}" || _pause
        else
            log_error '无效入站编号'
        fi
    done
}

_menu_index_valid() {
    [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -le "$2" ]
}

_menu_confirm_interrupt() {
    local _confirm
    prompt "$1，将中断相关连接。继续？(y/N): " _confirm || return 1
    case "${_confirm}" in
        y|Y) return 0 ;;
        *) log_info '已取消'; return 1 ;;
    esac
}

_menu_maintenance() {
    local _choice _MENU_ACTION_PAUSES=1
    while true; do
        [ ! -e "${_UNINSTALL_PENDING}" ] || return 0
        log_title '维护'
        _menu_print_action 1 '重启 Xray'
        _menu_print_action 2 '更新脚本'
        _menu_print_action 3 '更新 Xray 内核'
        _menu_print_action 4 '更新 UUID'
        _menu_print_action 5 '卸载整套 Xray-2go' "${C_RED}"
        _menu_print_back
        prompt '选择维护操作: ' _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) _menu_confirm_interrupt '重启 Xray' || continue
               module_dispatch xray restart ;;
            2) module_dispatch config update_shortcut ;;
            3) module_dispatch xray upgrade ;;
            4) module_dispatch config update_uuid ;;
            5) module_dispatch xray uninstall
               _pause
               return 0 ;;
            *) log_error '无效维护编号'; continue ;;
        esac
        _pause
    done
}

_menu_node_health() {
    case "${_MENU_STATE:-unknown}" in
        stopped) printf '  可导出已保存配置，当前服务未运行。\n' ;;
        unknown) printf '  Xray 状态未知，以下节点根据已保存配置生成。\n' ;;
    esac
}

_menu_node_formats() {
    local _node="$1" _choice _formats=2
    local _kind="${_node_kinds[_node]}" _outbound="${_node_outbounds[_node]}"
    if [ "${_kind}" = link ]; then
        _menu_node_health
        _print_link "${_node_links[_node]}"
        _pause
        return 0
    fi
    [ "${_kind}" != split ] || _formats=3
    while true; do
        log_title "${_node_names[_node]}"
        _menu_node_health
        _menu_print_action 1 '分享链接'
        _menu_print_action 2 'Xray 出站 JSON'
        [ "${_formats}" -ne 3 ] || _menu_print_action 3 'Mihomo provider'
        _menu_print_back
        prompt "选择格式 (0-${_formats}): " _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) _print_link "${_node_links[_node]}" ;;
            2) printf '%s\n' "${_outbound}" ;;
            3) if [ "${_kind}" != split ]; then log_error '无效格式编号'; continue; fi
               _argo_xhttp_mihomo_warn_differences "${_outbound}" || log_warn '无法检查 Mihomo 下行覆盖差异'
               _argo_xhttp_export_mihomo "${_outbound}" || log_error '无法生成 Mihomo provider' ;;
            *) log_error '无效格式编号'; continue ;;
        esac
        _pause
    done
}

_menu_nodes() {
    local _filter="${1:-}" _module _links _link _name _kind _choice _index _count _total _outbound
    local -a _node_names=() _node_links=() _node_outbounds=() _node_kinds=() _unavailable=() _kinds=()
    for _module in "${_PLUGIN_REGISTRY[@]}"; do
        [ -z "${_filter}" ] || [ "${_module}" = "${_filter}" ] || continue
        plugin_call "${_module}" enabled || continue
        _kinds=()
        case "${_module}" in
            argo)
                if [ "$(st_get '.argo.auth_protocol + ":" + .argo.protocol')" = vless:xhttp ]; then
                    _kinds=(normal)
                    if _argo_xhttp_split_active; then _kinds+=(split); fi
                fi ;;
            ff|cforigin) [ "$(st_get '.[$id].protocol' --arg id "${_module}")" != xhttp ] || _kinds=(direct) ;;
            reality) [ "$(st_get '.reality.network')" != xhttp ] || _kinds=(direct) ;;
            vlquic) _kinds=(direct) ;;
        esac
        if [ "${#_kinds[@]}" -gt 0 ]; then
            for _kind in "${_kinds[@]}"; do
                case "${_kind}" in
                    normal) _name=Argo-XHTTP ;;
                    split) _name=Argo-XHTTP-Split ;;
                    *) _name=$(module_label "${_module}") ;;
                esac
                if ! _outbound=$("_${_module}_xhttp_export_json" "${_kind}" 2>/dev/null) ||
                   ! _link=$(_xhttp_link_from_outbound "${_module}" "${_outbound}") ||
                   ! _link=$(plugin_filter_links "${_module}" <<< "${_link}") || [ -z "${_link}" ]; then
                    if [ "${_kind}" = split ]; then
                        log_warn 'Argo XHTTP 分离节点暂不可导出，请检查域名、Reality 公钥和公网地址'
                    else
                        _unavailable+=("${_name}")
                    fi
                    continue
                fi
                _node_names+=("${_name}")
                _node_links+=("${_link}")
                _node_outbounds+=("${_outbound}")
                _node_kinds+=("${_kind}")
            done
            continue
        fi
        if ! _links=$(plugin_collect_links "${_module}" 2>/dev/null) || [ -z "${_links}" ]; then
            _unavailable+=("$(module_label "${_module}")")
            continue
        fi
        _count=0
        while IFS= read -r _link; do
            _count=$((_count + 1))
            _name="$(module_label "${_module}")"
            [ "${_count}" -eq 1 ] || _name+=" · ${_count}"
            _node_names+=("${_name}")
            _node_links+=("${_link}")
            _node_outbounds+=("")
            _node_kinds+=(link)
        done <<< "${_links}"
    done
    _total=${#_node_links[@]}
    if [ "${#_unavailable[@]}" -gt 0 ]; then
        log_warn "无法生成节点，请检查必填配置和服务器地址：${_unavailable[*]}"
    fi
    if [ "${_total}" -eq 0 ]; then
        _menu_node_health
        [ "${#_unavailable[@]}" -ne 0 ] || log_info '没有已启用的入站'
        _pause
        return 0
    fi
    if [ "${_total}" -eq 1 ]; then _menu_node_formats 0; return; fi
    while true; do
        log_title '查看与导出节点'
        _menu_node_health
        for _index in "${!_node_names[@]}"; do
            _menu_print_action "$((_index + 1))" "${_node_names[_index]} · ${_node_links[_index]%%://*} · 已启用"
        done
        _menu_print_action "$((_total + 1))" '全部分享链接'
        _menu_print_back
        prompt '选择节点: ' _choice || return 0
        if [ "${_choice}" = 0 ]; then return 0; fi
        if [ "${_choice}" = "$((_total + 1))" ]; then
            for _link in "${_node_links[@]}"; do _print_link "${_link}"; done
            _pause
        elif _menu_index_valid "${_choice}" "${_total}"; then
            _menu_node_formats "$((_choice - 1))"
        else
            log_error '无效节点编号'
        fi
    done
}

install_plan_reset_defaults() {
    _CFORIGIN_ISSUE=()
    _VLQUIC_ISSUE=()
    local _uuid _reset
    _uuid=$(st_get '.uuid')
    # 只重置核心认识的设置，保留扩展插件的状态和端口。
    _reset=$(jq -c --argjson defaults "${_STATE_DEFAULT}" '
        def extras($known): with_entries(select(.key as $k | $known | has($k) | not));
        ((.ports // {}) | extras($defaults.ports)) as $ports
        | $defaults + extras($defaults) | .ports += $ports
    ' <<< "${_G_STATE}") || return 1
    _G_STATE="${_reset}"
    _st_normalize_schema
    if [ -n "${_uuid:-}" ] && val_uuid "${_uuid}" >/dev/null 2>&1; then
        st_set '.uuid = $u' --arg u "${_uuid}" || return 1
    else
        st_set '.uuid = $u' --arg u "$(crypto_gen_uuid)" || return 1
    fi
    st_set '
        .argo.enabled = false |
        .argo.protocol = "ws" |
        .argo.mode = "fixed" |
        .argo.domain = null |
        .argo.token = null |
        .ff.enabled = false |
        .ff.protocol = "none" |
        .ff.path = "/" |
        .ff.host = "" |
        .reality.enabled = false |
        .reality.sni = "addons.mozilla.org" |
        .reality.network = "tcp" |
        .reality.pbk = null |
        .reality.pvk = null |
        .reality.sid = null |
        .vltcp.enabled = false |
        .vltcp.listen = "0.0.0.0" |
        .socks.enabled = false |
        .socks.listen = "0.0.0.0" |
        .socks.user = "xray2go" |
        .socks.pass = "xray2go" |
        .http.enabled = false |
        .http.listen = "0.0.0.0" |
        .http.user = "xray2go" |
        .http.pass = "xray2go" |
        .ss2022.enabled = false |
        .ss2022.listen = "0.0.0.0" |
        .ss2022.method = "2022-blake3-aes-256-gcm" |
        .ss2022.key_mode = "single" |
        .ss2022.server_key = "" |
        .ss2022.user_key = "" |
        .vlquic.enabled = false |
        .vlquic.listen = "0.0.0.0" |
        .vlquic.domain = "" |
        .vlquic.cert = "" |
        .vlquic.key = "" |
        .vlquic.acme_method = "manual" |
        .cforigin.enabled = false |
        .cforigin.domain = "" |
        .cforigin.protocol = "ws" |
        .cforigin.path = "/origin" |
        .cforigin.listen = "::" |
        .cforigin.edge_port = 443 |
        .cforigin.edge_h3 = false |
        .cforigin.origin_tls = true |
        .cforigin.cert = "" |
        .cforigin.key = "" |
        .cforigin.acme_method = "manual" |
        .xpad.argo = true |
        .xpad.ff = true |
        .xpad.reality = true
    ' || return 1
}

reality_pick_default_tcp_port() {
    local _preferred=443 _fallback
    if port_mgr_in_use "${_preferred}"; then
        _fallback=$(port_mgr_random_proto tcp) || return 1
        log_warn "TCP/${_preferred} 已被占用，Reality 预设自动改用随机端口: ${_fallback}"
        printf '%s' "${_fallback}"
        return 0
    fi
    printf '%s' "${_preferred}"
}

preset_apply_reality_tcp_default() {
    local _port _explicit_port="${1:-}"
    install_plan_reset_defaults || return 1
    if [ -n "${_explicit_port:-}" ]; then
        val_port "${_explicit_port}" >/dev/null || return 1
        _port="${_explicit_port}"
    else
        _port=$(reality_pick_default_tcp_port) || return 1
    fi
    st_set '
        .reality.enabled = true |
        .reality.network = "tcp" |
        .reality.sni = "addons.mozilla.org" |
        .ports.reality = ($p|tonumber) |
        .argo.enabled = false |
        .ff.enabled = false |
        .ff.protocol = "none" |
        .vltcp.enabled = false |
        .socks.enabled = false |
        .http.enabled = false |
        .vlquic.enabled = false |
        .cforigin.enabled = false
    ' --arg p "${_port}" || return 1
    log_info "已应用预设: VLESS + Reality (TCP, port=${_port})"
}

install_plan_has_enabled_module() {
    local _name
    for _name in "${_PLUGIN_REGISTRY[@]}"; do
        plugin_call "${_name}" enabled && return 0
    done
    return 1
}

install_plan_module_summary() {
    local _mod="$1"
    case "${_mod}" in
        argo)
            [ "$(st_get '.argo.enabled')" = "true" ]                 && printf '%s' "已启用 ($(st_get '.argo.protocol'), port=$(port_of argo), domain=$(st_get '.argo.domain'))"                 || printf '未启用' ;;
        ff)
            if [ "$(st_get '.ff.enabled')" = "true" ] && [ "$(st_get '.ff.protocol')" != "none" ]; then
                if [ "$(st_get '.ff.protocol')" = "tcphttp" ]; then
                    printf '%s' "已启用 (tcphttp, host=$(st_get '.ff.host'), port=$(port_of ff))"
                else
                    printf '%s' "已启用 ($(st_get '.ff.protocol'), path=$(st_get '.ff.path'), port=$(port_of ff))"
                fi
            else
                printf '未启用'
            fi ;;
        reality)
            [ "$(st_get '.reality.enabled')" = "true" ]                 && printf '%s' "已启用 ($(st_get '.reality.network'), port=$(port_of reality), sni=$(st_get '.reality.sni'))"                 || printf '未启用' ;;
        vltcp)
            [ "$(st_get '.vltcp.enabled')" = "true" ]                 && printf '%s' "已启用 (port=$(port_of vltcp), listen=$(st_get '.vltcp.listen'))"                 || printf '未启用' ;;
        socks)
            [ "$(st_get '.socks.enabled')" = "true" ]                 && printf '%s' "已启用 (port=$(port_of socks), listen=$(st_get '.socks.listen'), user=$(st_get '.socks.user'))"                 || printf '未启用' ;;
        http)
            [ "$(st_get '.http.enabled')" = "true" ]                 && printf '%s' "已启用 (port=$(port_of http), listen=$(st_get '.http.listen'), user=$(st_get '.http.user'))"                 || printf '未启用' ;;
        vlquic)
            [ "$(st_get '.vlquic.enabled')" = "true" ]                 && printf '%s' "已启用 (udp=$(port_of vlquic), domain=$(st_get '.vlquic.domain'))"                 || printf '未启用' ;;
        cforigin)
            [ "$(st_get '.cforigin.enabled')" = "true" ]                 && printf '%s' "已启用 ($(st_get '.cforigin.protocol'), edge=$(st_get '.cforigin.edge_port'), origin=$(port_of cforigin), domain=$(st_get '.cforigin.domain'))"                 || printf '未启用' ;;
        ss2022)
            [ "$(st_get '.ss2022.enabled')" = "true" ] \
                && printf '%s' "已启用 (port=$(port_of ss2022), listen=$(st_get '.ss2022.listen'), method=$(st_get '.ss2022.method'))" \
                || printf '未启用' ;;
        *) printf 'unknown' ;;
    esac
}

install_plan_render_summary() {
    clear; echo ""
    log_title "══ 自定义安装计划 ══"
    printf "  说明      : ${C_YLW}选择要启用的模块，完成配置后选择 11 预览并确认安装${C_RST}\n"
    printf "  UUID：已配置\n"
    printf "  Argo      : %s\n" "$(install_plan_module_summary argo)"
    printf "  FreeFlow  : %s\n" "$(install_plan_module_summary ff)"
    printf "  Reality   : %s\n" "$(install_plan_module_summary reality)"
    printf "  VLESS-TCP : %s\n" "$(install_plan_module_summary vltcp)"
    printf "  SOCKS5    : %s\n" "$(install_plan_module_summary socks)"
    printf "  HTTP代理  : %s\n" "$(install_plan_module_summary http)"
    printf "  SS2022   : %s\n" "$(install_plan_module_summary ss2022)"
    printf "  XHTTP-H3  : %s\n" "$(install_plan_module_summary vlquic)"
    printf "  CF-Origin : %s\n" "$(install_plan_module_summary cforigin)"
    _hr
    printf "  ${C_BOLD}模块配置${C_RST}\n"
    _menu_print_action 1 "进入 Argo 配置页"
    _menu_print_action 2 "进入 FreeFlow 配置页"
    _menu_print_action 3 "进入 Reality 配置页"
    _menu_print_action 4 "进入 VLESS-TCP 配置页"
    _menu_print_action 5 "进入 SOCKS5 配置页"
    _menu_print_action 6 "进入 VLESS-XHTTP-H3 配置页"
    _menu_print_action 7 "进入 CF Origin 配置页"
    _menu_print_action 12 "进入 HTTP 代理配置页"
    _menu_print_action 13 "进入 Shadowsocks 2022 配置页"
    _hr
    printf "  ${C_BOLD}全局操作${C_RST}\n"
    _menu_print_action 8 "更新 UUID"
    _menu_print_action 9 "重置为初始安装计划" "${C_YLW}"
    _menu_print_action 10 "运行安装前检查"
    _menu_print_action 11 "预览并确认安装" "${C_GRN}"
    _menu_print_action 0 "取消安装并返回主菜单" "${C_PUR}"
    _hr
}

install_plan_argo_toggle() {
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        st_set '.argo.enabled = false | .argo.domain = null | .argo.token = null | .argo.cred_b64 = null | .argo.mode = "fixed" | .argo.protocol = "ws" | .argo.auth_protocol = "vless" | .argo.trojan_password = ""' || return 1
        log_ok "Argo 已禁用"
    else
        st_set '.argo.enabled = true' || return 1
        [ -n "$(st_get '.argo.protocol')" ] || st_set '.argo.protocol = "ws"' || return 1
        log_ok "Argo 已启用"
    fi
}

install_plan_argo_update_auth_protocol() {
    echo ""
    log_title "Argo 入站认证协议"
    printf "  ${C_GRN}1.${C_RST} VLESS ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} Trojan + WS + Argo\n"
    local _c
    prompt "请选择 (1-2，回车默认1): " _c || return 1
    case "${_c:-1}" in
        2)
            [ "$(st_get '.argo.protocol')" = "ws" ] || {
                log_error "Trojan Argo 当前仅支持 WS，请先将传输协议设为 WS"; return 1; }
            st_set '.argo.auth_protocol = "trojan"' || return 1
            argo_seed_trojan_password || return 1
            log_ok "Argo 入站认证已设置为 Trojan" ;;
        *)
            st_set '.argo.auth_protocol = "vless"' || return 1
            log_ok "Argo 入站认证已设置为 VLESS" ;;
    esac
}

# 切换到 Trojan 时补齐独立密码，避免状态字段长期为空、被动回退到 UUID
argo_seed_trojan_password() {
    local _cur _pw
    _cur=$(st_get '.argo.trojan_password')
    trojan_password_is_valid "${_cur:-}" && return 0
    _pw=$(crypto_gen_trojan_password) || { log_error "Trojan 密码生成失败"; return 1; }
    val_trojan_password "${_pw}" >/dev/null || return 1
    st_set '.argo.trojan_password = $p' --arg p "${_pw}" || return 1
    log_info "已生成独立 Trojan 密码（可在 Argo 工作台“修改 Trojan 密码”中重设）"
}

install_plan_argo_update_trojan_password() {
    [ "$(st_get '.argo.auth_protocol')" = "trojan" ] || {
        log_error "当前 Argo 入站认证不是 Trojan，请先将入站认证设为 Trojan"; return 1; }
    local _cur _pw
    _cur=$(st_get '.argo.trojan_password')
    if trojan_password_is_valid "${_cur:-}"; then
        prompt_secret "Trojan 密码（回车保持当前，8-128 位 URL-safe 字符）: " _pw || return 1
    else
        prompt_secret "Trojan 密码（回车自动生成，8-128 位 URL-safe 字符）: " _pw || return 1
    fi
    if [ -z "${_pw:-}" ]; then
        trojan_password_is_valid "${_cur:-}" && { log_info "保持当前 Trojan 密码"; return 0; }
        _pw=$(crypto_gen_trojan_password) || { log_error "Trojan 密码生成失败"; return 1; }
        log_info "已生成独立 Trojan 密码"
    fi
    val_trojan_password "${_pw}" >/dev/null || return 1
    st_set '.argo.trojan_password = $p' --arg p "${_pw}" || return 1
    log_ok "Argo Trojan 密码已更新"
}

install_plan_argo_update_protocol() {
    local _old _new
    _old=$(st_get '.argo.protocol')
    _argo_read_transport "${_old}" _new || return 1
    [ "${_new}" != "${_old}" ] || return 0
    st_set '.argo.protocol = $v' --arg v "${_new}" || return 1
    log_ok "Argo 协议已设置为: ${_new}"
}

_install_plan_update_port() {
    local _module="$1" _transport="$2" _conflict="$3" _current _selected _label
    _label=$(module_label "${_module}")
    _current=$(port_of "${_module}") || return 1
    _menu_select_port "${_transport}" _selected "${_label} 端口（回车保持 ${_current}）: " \
        "${_current}" "${_conflict}" || return 1
    [ "${_selected}" != "${_current}" ] || return 0
    st_set '.ports[$id] = ($p|tonumber)' --arg id "${_module}" --arg p "${_selected}" || return 1
    log_ok "${_label} 端口已设置为: ${_selected}"
}

install_plan_argo_update_port() { _install_plan_update_port argo tcp confirm; }

install_plan_argo_update_domain() {
    local _domain _cur
    _cur=$(st_get '.argo.domain')
    prompt "Argo 域名（回车保持 ${_cur:-未配置}）: " _domain || return 1
    [ -n "${_domain:-}" ] || { log_info "保持 Argo 域名: ${_cur:-未配置}"; return 0; }
    case "${_domain}" in ''|*' '*|*'/'*|*$'	'*) log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'         || { log_error "域名格式不合法"; return 1; }
    st_set '.argo.domain = $d' --arg d "${_domain}" || return 1
    log_ok "Argo 域名已设置为: $(st_get '.argo.domain')"
}

install_plan_argo_update_auth() {
    local _auth _json_b64 _tid
    prompt_secret "Argo 密钥 (token 或 JSON 内容，回车保持当前): " _auth || return 1
    [ -n "${_auth:-}" ] || { log_info "保持当前 Argo 密钥/凭证"; return 0; }
    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 \
            || { log_error "JSON 凭证格式不合法"; return 1; }
        _tid=$(printf '%s' "${_auth}" | jq -r 'if (.TunnelID? // "") != "" then .TunnelID elif (.AccountTag? // "") != "" then .AccountTag else empty end' 2>/dev/null)
        [ -n "${_tid:-}" ] || { log_error "无法提取 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*) log_error "TunnelID 含非法字符"; return 1;; esac
        _json_b64=$(printf '%s' "${_auth}" | base64 -w0 2>/dev/null) || { log_error "JSON 凭证编码失败"; return 1; }
        st_set '.argo.token = null | .argo.cred_b64 = $c | .argo.mode = "fixed"' --arg c "${_json_b64}" || return 1
        log_ok "Argo 安装计划已切换为 JSON 凭证模式"
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        st_set '.argo.token = $t | .argo.cred_b64 = null | .argo.mode = "fixed"' --arg t "${_auth}" || return 1
        log_ok "Argo 安装计划已切换为 token 模式"
    else
        log_error "密钥格式无法识别"
        return 1
    fi
}

install_plan_argo_toggle_xpad() {
    [ "$(st_get '.argo.protocol')" = "xhttp" ] || { log_warn "Argo 当前不是 XHTTP，xPadding 不适用"; return 0; }
    _set_xpad_toggle argo || return 1
    log_ok "Argo 安装计划 xPadding: $(xpad_of argo)"
}

install_plan_ff_toggle() {
    if [ "$(st_get '.ff.enabled')" = "true" ] && [ "$(st_get '.ff.protocol')" != "none" ]; then
        st_set '.ff.enabled = false | .ff.protocol = "none"' || return 1
        log_ok "FreeFlow 已禁用"
    else
        st_set '.ff.enabled = true' || return 1
        [ "$(st_get '.ff.protocol')" = "none" ] && st_set '.ff.protocol = "ws"' || return 1
        log_ok "FreeFlow 已启用"
    fi
}

install_plan_ff_update_mode() {
    echo ""
    log_title "FreeFlow 传输协议"
    printf "  ${C_GRN}1.${C_RST} VLESS + WS
"
    printf "  ${C_GRN}2.${C_RST} VLESS + HTTPUpgrade
"
    printf "  ${C_GRN}3.${C_RST} VLESS + XHTTP (stream-one)
"
    printf "  ${C_GRN}4.${C_RST} VLESS + TCP + HTTP 伪装（免流）
"
    local _c _host
    prompt "请选择 (1-4，回车默认1): " _c || return 1
    case "${_c:-1}" in
        1) st_set '.ff.enabled = true | .ff.protocol = "ws"' || return 1 ;;
        2) st_set '.ff.enabled = true | .ff.protocol = "httpupgrade"' || return 1 ;;
        3) st_set '.ff.enabled = true | .ff.protocol = "xhttp"' || return 1 ;;
        4)
            prompt "免流 Host（如 realname.1888.com.mo）: " _host || return 1
            [ -n "${_host:-}" ] || { log_error "Host 不能为空"; return 1; }
            st_set '.ff.enabled = true | .ff.protocol = "tcphttp" | .ff.host = $h' --arg h "${_host}" || return 1
            log_info "已选: TCP + HTTP 伪装（host=${_host}）"
            return 0 ;;
        *) log_error "无效选项，请按提示输入"; return 1 ;;
    esac
    log_ok "FreeFlow 协议已设置为: $(st_get '.ff.protocol')"
}

install_plan_ff_update_port() { _install_plan_update_port ff tcp warn; }

install_plan_ff_update_host_or_path() {
    local _proto _host _path _h _p _vp2
    _proto=$(st_get '.ff.protocol')
    _host=$(st_get '.ff.host')
    _path=$(st_get '.ff.path')
    if [ "${_proto}" = "tcphttp" ]; then
        prompt "FreeFlow 免流 Host（回车保持 ${_host}）: " _h || return 1
        [ -n "${_h:-}" ] || { log_info "保持 Host: ${_host}"; return 0; }
        st_set '.ff.host = $h' --arg h "${_h}" || return 1
        log_ok "FreeFlow Host 已设置为: $(st_get '.ff.host')"
    else
        prompt "FreeFlow path（回车保持 ${_path}）: " _p || return 1
        [ -n "${_p:-}" ] || { log_info "保持 path: ${_path}"; return 0; }
        case "${_p}" in /*) :;; *) _p="/${_p}";; esac
        if ! _vp2=$(val_path "${_p}" 2>/dev/null); then
            log_error "path 格式不合法"; return 1
        fi
        st_set '.ff.path = $p' --arg p "${_vp2}" || return 1
        log_ok "FreeFlow path 已设置为: $(st_get '.ff.path')"
    fi
}

install_plan_ff_toggle_xpad() {
    [ "$(st_get '.ff.protocol')" = "xhttp" ] || { log_warn "FreeFlow 当前不是 XHTTP，xPadding 不适用"; return 0; }
    _set_xpad_toggle ff || return 1
    log_ok "FreeFlow 安装计划 xPadding: $(xpad_of ff)"
}

install_plan_reality_toggle() {
    [ "$(st_get '.reality.enabled')" = "true" ]         && st_set '.reality.enabled = false'         || st_set '.reality.enabled = true' || return 1
    log_ok "Reality 已$( [ "$(st_get '.reality.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_reality_update_port() { _install_plan_update_port reality tcp warn; }

install_plan_reality_update_sni() {
    local _ds _sni
    _ds=$(st_get '.reality.sni')
    log_info "SNI 建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
    prompt "Reality 伪装 SNI（回车默认 ${_ds}）: " _sni || return 1
    [ -n "${_sni:-}" ] || { log_info "保持 Reality SNI: ${_ds}"; return 0; }
    printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'         && st_set '.reality.sni = $s' --arg s "${_sni}"         || { log_warn "SNI 格式不合法，保持默认值 ${_ds}"; return 0; }
    log_ok "Reality SNI 已设置为: $(st_get '.reality.sni')"
}

install_plan_reality_update_transport() {
    echo ""
    printf "  ${C_GRN}1.${C_RST} TCP + XTLS-Vision ${C_YLW}[默认]${C_RST}
"
    printf "  ${C_GRN}2.${C_RST} XHTTP + Reality (auto)
"
    local _nc
    prompt "Reality 传输方式 (1-2，回车默认1): " _nc || return 1
    case "${_nc:-1}" in
        2) st_set '.reality.network = "xhttp"'; log_info "已选：XHTTP + Reality" ;;
        *) st_set '.reality.network = "tcp"';   log_info "已选：TCP + XTLS-Vision" ;;
    esac || return 1
}

install_plan_reality_toggle_xpad() {
    [ "$(st_get '.reality.network')" = "xhttp" ] || { log_warn "Reality 当前不是 XHTTP，xPadding 不适用"; return 0; }
    _set_xpad_toggle reality || return 1
    log_ok "Reality 安装计划 xPadding: $(xpad_of reality)"
}

install_plan_vltcp_toggle() {
    [ "$(st_get '.vltcp.enabled')" = "true" ]         && st_set '.vltcp.enabled = false'         || st_set '.vltcp.enabled = true' || return 1
    log_ok "VLESS-TCP 已$( [ "$(st_get '.vltcp.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_vltcp_update_port() { _install_plan_update_port vltcp tcp warn; }

_install_plan_update_listen() {
    local _module="$1" _current _listen _label
    _label=$(module_label "${_module}")
    _current=$(st_get '.[$id].listen' --arg id "${_module}") || return 1
    _menu_read_listen "${_label} 监听地址（回车保持 ${_current}）: " _listen || return 1
    [ -n "${_listen}" ] || return 0
    st_set '.[$id].listen = $listen' --arg id "${_module}" --arg listen "${_listen}" || return 1
    _menu_warn_http_listen "${_module}" "${_listen}"
    log_ok "${_label} 监听地址已设置为: ${_listen}"
}

install_plan_vltcp_update_listen() { _install_plan_update_listen vltcp; }

install_plan_socks_toggle() {
    [ "$(st_get '.socks.enabled')" = "true" ]         && st_set '.socks.enabled = false'         || st_set '.socks.enabled = true' || return 1
    log_ok "SOCKS5 已$( [ "$(st_get '.socks.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_socks_update_port() { _install_plan_update_port socks tcp warn; }

install_plan_socks_update_listen() { _install_plan_update_listen socks; }

install_plan_socks_update_user() {
    local _du _user
    _du=$(st_get '.socks.user')
    prompt "SOCKS5 用户名（回车默认 ${_du}）: " _user || return 1
    _user="${_user:-${_du}}"
    st_set '.socks.user = $u' --arg u "${_user}" || return 1
    log_ok "SOCKS5 用户名已设置为: $(st_get '.socks.user')"
}

install_plan_socks_update_pass() {
    local _pass
    prompt_secret "SOCKS5 密码（回车保持当前）: " _pass || return 1
    [ -n "${_pass:-}" ] || { log_info "保持当前 SOCKS5 密码"; return 0; }
    st_set '.socks.pass = $p' --arg p "${_pass}" || return 1
    log_ok "SOCKS5 密码已更新"
}

install_plan_http_toggle() {
    [ "$(st_get '.http.enabled')" = "true" ] \
        && st_set '.http.enabled = false' \
        || st_set '.http.enabled = true' || return 1
    [ "$(st_get '.http.enabled')" = "true" ] && \
        log_warn "HTTP 代理为明文 TCP 代理，公开监听前请确认网络边界与防火墙策略"
    log_ok "HTTP 代理已$( [ "$(st_get '.http.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_http_update_port() { _install_plan_update_port http tcp warn; }

install_plan_http_update_listen() { _install_plan_update_listen http; }

install_plan_http_update_user() {
    local _du _user
    _du=$(st_get '.http.user')
    prompt "HTTP 代理用户名（回车默认 ${_du}）: " _user || return 1
    _user="${_user:-${_du}}"
    st_set '.http.user = $u' --arg u "${_user}" || return 1
    log_ok "HTTP 代理用户名已设置为: $(st_get '.http.user')"
}

install_plan_http_update_pass() {
    local _pass
    prompt_secret "HTTP 代理密码（回车保持当前）: " _pass || return 1
    [ -n "${_pass:-}" ] || { log_info "保持当前 HTTP 代理密码"; return 0; }
    st_set '.http.pass = $p' --arg p "${_pass}" || return 1
    log_ok "HTTP 代理密码已更新"
}

install_plan_cforigin_toggle() {
    [ "$(st_get '.cforigin.enabled')" = "true" ]         && st_set '.cforigin.enabled = false'         || st_set '.cforigin.enabled = true' || return 1
    log_ok "CF Origin 已$( [ "$(st_get '.cforigin.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_cforigin_update_protocol() {
    local _proto
    _cforigin_read_transport "回车默认 WS" _proto || return 1
    _cforigin_save_transport "${_proto:-ws}" st_set || return 1
    log_ok "CF Origin 协议已设置为: $(st_get '.cforigin.protocol')"
}

install_plan_cforigin_update_domain() {
    local _domain _cur
    _cur=$(st_get '.cforigin.domain')
    prompt "CF Origin 域名（回车保持 ${_cur:-未配置}）: " _domain || return 1
    [ -n "${_domain:-}" ] || { log_info "保持 CF Origin 域名: ${_cur:-未配置}"; return 0; }
    _domain=$(val_domain "${_domain}") || return 1
    st_set '.cforigin.domain = $d' --arg d "${_domain}" || return 1
    log_ok "CF Origin 域名已设置为: $(st_get '.cforigin.domain')"
}

install_plan_cforigin_update_path() {
    local _path _p _vp
    _path=$(st_get '.cforigin.path')
    prompt "CF Origin path（回车保持 ${_path}）: " _p || return 1
    [ -n "${_p:-}" ] || { log_info "保持 path: ${_path}"; return 0; }
    _vp=$(val_path "${_p}") || return 1
    st_set '.cforigin.path = $p' --arg p "${_vp}" || return 1
    log_ok "CF Origin path 已设置为: $(st_get '.cforigin.path')"
}

install_plan_cforigin_update_edge_port() {
    local _edge _ep
    _edge=$(st_get '.cforigin.edge_port')
    prompt "CF Origin Edge 入口端口（回车保持 ${_edge}）: " _ep || return 1
    [ -n "${_ep:-}" ] || { log_info "保持 Edge 入口端口: ${_edge}"; return 0; }
    val_port "${_ep}" >/dev/null && cf_edge_port_valid "${_ep}" || return 1
    st_set '.cforigin.edge_port = ($p|tonumber)' --arg p "${_ep}" || return 1
    log_ok "CF Origin Edge 入口端口已设置为: $(st_get '.cforigin.edge_port')"
}

install_plan_cforigin_update_origin_port() {
    _install_plan_update_port cforigin tcp warn || return 1
    log_warn "如果 Cloudflare Origin Rule 已手动配置，请同步确认 Destination Port Override = $(port_of cforigin)"
}

install_plan_cforigin_update_listen() { _install_plan_update_listen cforigin; }

install_plan_cforigin_toggle_edge_h3() {
    [ "$(st_get '.cforigin.protocol')" = "xhttp" ] || { log_warn "CF Origin 当前不是 XHTTP，实验性客户端到 Cloudflare Edge HTTP/3 不适用"; return 0; }
    [ "$(st_get '.cforigin.edge_h3')" = "true" ]         && st_set '.cforigin.edge_h3 = false'         || st_set '.cforigin.edge_h3 = true' || return 1
    log_ok "实验性客户端到 Cloudflare Edge HTTP/3 已$( [ "$(st_get '.cforigin.edge_h3')" = "true" ] && printf '开启' || printf '关闭' )"
}

install_plan_cforigin_update_cert() {
    cforigin_config_cert || return 1
    log_ok "CF Origin 域名/证书计划已更新"
}

install_plan_vlquic_toggle() {
    [ "$(st_get '.vlquic.enabled')" = "true" ]         && st_set '.vlquic.enabled = false'         || st_set '.vlquic.enabled = true' || return 1
    log_ok "VLESS-XHTTP-H3 已$( [ "$(st_get '.vlquic.enabled')" = "true" ] && printf '启用' || printf '禁用' )"
}

install_plan_vlquic_update_port() { _install_plan_update_port vlquic udp warn; }

install_plan_vlquic_update_listen() { _install_plan_update_listen vlquic; }

install_plan_vlquic_update_cert() {
    vlquic_config_cert || return 1
    log_ok "VLESS-XHTTP-H3 域名/证书配置已写入安装计划"
}

install_plan_ss2022_toggle() {
    if [ "$(st_get '.ss2022.enabled')" = "true" ]; then
        _ss2022_disable_state || return 1
        log_ok "Shadowsocks 2022 已禁用"
    else
        _module_ss2022_enable_prepare || return 1
        log_ok "Shadowsocks 2022 已启用"
    fi
}

install_plan_ss2022_update_port() { _install_plan_update_port ss2022 both warn; }

install_plan_ss2022_update_listen() { _install_plan_update_listen ss2022; }

install_plan_ss2022_update_method() {
    _ss2022_select_method install
}

install_plan_ss2022_regenerate_keys() {
    _ss2022_update_credentials install "$@" || return 1
    log_ok "安装计划 SS2022 密钥已重新生成"
}

install_plan_configure_uuid() {
    local _v
    prompt "新 UUID（回车自动生成）: " _v || return 1
    if [ -z "${_v:-}" ]; then
        _v=$(crypto_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID"
    fi
    val_uuid "${_v}" >/dev/null || return 1
    st_set '.uuid = $u' --arg u "${_v}" || return 1
    log_ok "安装计划 UUID 已更新"
}

install_plan_validate() {
    install_plan_has_enabled_module || { log_error "安装计划无效：至少启用一个入站模块"; return 1; }

    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        local _argo_domain
        _argo_domain=$(st_get '.argo.domain')
        val_domain "${_argo_domain}" >/dev/null || {
            log_error "Argo 域名未配置或格式不合法"; return 1;
        }
        val_argo_auth_state || return 1
        local _argo_auth
        _argo_auth=$(st_get '.argo.auth_protocol')
        case "${_argo_auth}" in
            vless) : ;;
            trojan)
                [ "$(st_get '.argo.protocol')" = "ws" ] || {
                    log_error "Trojan Argo 当前仅支持 WS 传输"; return 1; }
                local _trojan_password
                _trojan_password=$(st_get '.argo.trojan_password')
                [ -n "${_trojan_password:-}" ] || _trojan_password=$(st_get '.uuid')
                val_trojan_password "${_trojan_password}" >/dev/null || return 1 ;;
            *) log_error "Argo 入站认证协议非法"; return 1 ;;
        esac
        case "$(st_get '.argo.protocol')" in ws|xhttp) : ;; *) log_error "Argo 协议非法"; return 1 ;; esac
        val_port "$(port_of argo)" >/dev/null || return 1
    fi

    if [ "$(st_get '.ff.enabled')" = "true" ]; then
        case "$(st_get '.ff.protocol')" in ws|httpupgrade|xhttp|tcphttp) : ;; *) log_error "FreeFlow 协议非法"; return 1 ;; esac
        val_port "$(port_of ff)" >/dev/null || return 1
        if [ "$(st_get '.ff.protocol')" = "tcphttp" ]; then
            [ -n "$(st_get '.ff.host')" ] || { log_error "FreeFlow Host 不能为空"; return 1; }
        else
            val_path "$(st_get '.ff.path')" >/dev/null || return 1
        fi
    fi

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        case "$(st_get '.reality.network')" in tcp|xhttp) : ;; *) log_error "Reality 传输方式非法"; return 1 ;; esac
        val_port "$(port_of reality)" >/dev/null || return 1
        val_domain "$(st_get '.reality.sni')" >/dev/null || return 1
    fi

    if [ "$(st_get '.vltcp.enabled')" = "true" ]; then
        val_port "$(port_of vltcp)" >/dev/null || return 1
        val_listen_addr "$(st_get '.vltcp.listen')" >/dev/null || return 1
    fi

    if [ "$(st_get '.socks.enabled')" = "true" ]; then
        val_port "$(port_of socks)" >/dev/null || return 1
        val_listen_addr "$(st_get '.socks.listen')" >/dev/null || return 1
        [ -n "$(st_get '.socks.user')" ] || { log_error "SOCKS5 用户名不能为空"; return 1; }
    fi

    if [ "$(st_get '.ss2022.enabled')" = "true" ]; then
        val_port "$(port_of ss2022)" >/dev/null || return 1
        val_listen_addr "$(st_get '.ss2022.listen')" >/dev/null || return 1
        _ss2022_validate_credentials "$(st_get '.ss2022.method')" "$(st_get '.ss2022.key_mode')" \
            "$(st_get '.ss2022.server_key')" "$(st_get '.ss2022.user_key')" || return 1
    fi

    if [ "$(st_get '.http.enabled')" = "true" ]; then
        val_port "$(port_of http)" >/dev/null || return 1
        val_listen_addr "$(st_get '.http.listen')" >/dev/null || return 1
        [ -n "$(st_get '.http.user')" ] || { log_error "HTTP 代理用户名不能为空"; return 1; }
        [ -n "$(st_get '.http.pass')" ] || { log_error "HTTP 代理密码不能为空"; return 1; }
    fi

    if [ "$(st_get '.vlquic.enabled')" = "true" ]; then
        val_port "$(port_of vlquic)" >/dev/null || return 1
        val_listen_addr "$(st_get '.vlquic.listen')" >/dev/null || return 1
        _vlquic_check_ready plan || return 1
    fi

    if [ "$(st_get '.cforigin.enabled')" = "true" ]; then
        _cforigin_check_ready plan || return 1
    fi

    log_ok "安装计划校验通过"
}

_install_issue_certs_and_start() {
    if [ "$(st_get '.cforigin.enabled')" = true ] && [ "${#_CFORIGIN_ISSUE[@]}" -gt 0 ]; then
        "${_CFORIGIN_ISSUE[@]}" && _cforigin_check_ready || return 1
    fi
    if [ "$(st_get '.vlquic.enabled')" = true ]; then
        _vlquic_apply_cert || return 1
    fi
    module_xray_install_core
}

install_execute_current_plan() {
    local _verify_client="${1:-}" _result _install_rc=0
    local _install_transaction=1 _install_hosts_pending=0
    command -v flock >/dev/null 2>&1 || { log_error "首次部署需要 flock，以保护并发操作"; return 1; }
    install_plan_validate || return 1
    local -a _cert_artifacts=()
    if [ "$(st_get '.cforigin.enabled')" = true ] && [ "${#_CFORIGIN_ISSUE[@]}" -gt 0 ]; then
        local _domain="${_CFORIGIN_ISSUE[2]}"
        _cert_artifacts=("${_CERT_DIR}/${_domain}/fullchain.pem" "${_CERT_DIR}/${_domain}/privkey.pem")
    fi
    if _transaction_run "部署 Xray-2go" _install_issue_certs_and_start; then
        _CFORIGIN_ISSUE=()
        _VLQUIC_ISSUE=()
    else
        _install_rc=$?
    fi
    if [ "${_install_rc}" -ne 0 ]; then
        log_error "安装失败"
        return 1
    fi

    log_ok "══ 安装完成，服务已启动 ══"
    if [ "${_MENU_HIDE_LINKS:-0}" -eq 1 ]; then
        log_info '在首页选择「查看与导出节点」获取客户端配置。'
        cforigin_print_cloudflare_hint
        return 0
    fi
    if config_print_nodes; then
        log_info "复制上方对应节点的链接，在支持该协议及传输方式的客户端中选择从剪贴板导入。"
    else
        log_warn "暂未导出分享链接，请通过主菜单 1 重试，或按模块的连接参数手动配置客户端。"
    fi
    cforigin_print_cloudflare_hint
    log_info "请在自己的设备上启用该节点并访问一个网页，验证从客户端到服务器的连接。"
    if [ "${_verify_client}" = interactive ]; then
        if prompt "已在客户端成功访问网页？(y/N): " _result && [[ "${_result:-}" == [yY] ]]; then
            log_ok "客户端连接已由你确认"
            return 0
        fi
    fi
    log_info "客户端连接待确认，可在主菜单 1 重新查看节点和连接提示。"
}

_unified_mode_label() {
    [ "${1:-install}" = "runtime" ] && printf '已安装管理' || printf '安装前配置'
}

_unified_mode_is_runtime() {
    [ "${1:-install}" = "runtime" ]
}

_unified_render_mode_header() {
    local _mode="$1" _hint="${2:-}"
    printf "  模式: ${C_YLW}%s${C_RST}\n" "$(_unified_mode_label "${_mode}")"
    [ -n "${_hint}" ] && printf "  提示: ${C_YLW}%s${C_RST}\n" "${_hint}"
}

_unified_runtime_status_for() {
    case "${1:-}" in
        argo) check_argo ;;
        *) _xray_runtime_status ;;
    esac
}

_unified_runtime_toggle() {
    local _mod="$1" _enabled="$2"
    if [ "${_enabled}" = "true" ]; then
        _menu_confirm_interrupt "停用 $(module_label "${_mod}")" || return 0
        module_dispatch "${_mod}" disable || return 1
    else
        module_dispatch "${_mod}" enable || return 1
    fi
}

_unified_state_label() {
    [ "${1:-false}" = "true" ] && printf '已启用' || printf '未启用'
}

_unified_render_status() {
    local _runtime="$1" _enabled="$2" _svc="$3"
    if [ "${_runtime}" -eq 1 ]; then
        _menu_print_module_status "${_enabled}" "${_svc}"
    else
        printf "  当前状态: ${C_YLW}%s${C_RST}\n" "$(_unified_state_label "${_enabled}")"
    fi
}



_unified_toggle_or_plan() {
    local _runtime="$1" _mod="$2" _enabled="$3" _plan_fn="$4"
    if [ "${_runtime}" -eq 1 ]; then
        _unified_runtime_toggle "${_mod}" "${_enabled}"
    else
        "${_plan_fn}"
    fi
}

_unified_dispatch_or_plan() {
    local _runtime="$1" _mod="$2" _action="$3" _plan_fn="$4"
    if [ "${_runtime}" -eq 1 ]; then
        module_dispatch "${_mod}" "${_action}"
    else
        "${_plan_fn}"
    fi
}

_unified_runtime_fn_or_plan() {
    local _runtime="$1" _plan_fn="$2"
    shift 2
    if [ "${_runtime}" -eq 1 ]; then
        "$@"
    else
        "${_plan_fn}"
    fi
}

_unified_runtime_only_fn() {
    local _runtime="$1"
    shift
    if [ "${_runtime}" -eq 1 ]; then
        "$@"
    else
        log_error "无效选项，请按提示输入"
        return 1
    fi
}

_xhttp_validate_profile() {
    local _checked
    _checked=$(jq -ces '
        def require($path; condition):
            if condition then . else error("XHTTP 字段无效: " + $path) end;
        def checked(f): f as $_ | .;
        def only($allowed): type == "object" and (keys_unsorted - $allowed) == [];
        def port: type == "number" and floor == . and . >= 1 and . <= 65535;
        def bounds:
            if type == "number" then [., .]
            elif type == "string" and test("^[0-9]+(-[0-9]+)?$") then split("-") | map(tonumber)
            else [] end;
        def range($min): bounds as $v | ($v|length) > 0 and
            all($v[]; floor == . and . >= $min and . <= 2147483647) and $v[0] <= $v[-1];
        def xmux($path):
            require($path; only(["maxConcurrency","maxConnections","cMaxReuseTimes","hMaxRequestTimes","hMaxReusableSecs","hKeepAlivePeriod"])) |
            checked([to_entries[] | .key as $key | .value |
                require($path + "." + $key;
                    if $key == "hKeepAlivePeriod" then type == "number" and floor == . and . >= -1 and . <= 2147483647
                    else range(0) end)]) |
            require($path + ".maxConnections 与 " + $path + ".maxConcurrency 只能设置一项正值";
                ([.maxConcurrency, .maxConnections] | map(select((bounds | max // 0) > 0)) | length <= 1));
        def extra($path):
            require($path; type == "object") |
            require($path + ".downloadSettings（请改用 split.download）"; has("downloadSettings") | not) |
            checked((.xmux // {}) | xmux($path + ".xmux")) |
            require($path + ".xPaddingBytes"; if has("xPaddingBytes") then .xPaddingBytes | range(1) else true end) |
            require($path + ".scMaxEachPostBytes"; if has("scMaxEachPostBytes") then .scMaxEachPostBytes | range(1) else true end) |
            require($path + ".scMinPostsIntervalMs"; if has("scMinPostsIntervalMs") then .scMinPostsIntervalMs | . == -1 or range(0) else true end) |
            require($path + ".noGRPCHeader"; if has("noGRPCHeader") then .noGRPCHeader | type == "boolean" else true end);
        def download:
            require("split.download"; only(["address","port","network","security","tlsSettings","xhttpSettings","sockopt"])) |
            require("split.download.address"; (.address // "") | type == "string" and test("^[a-zA-Z0-9_.:\\[\\]-]*$")) |
            require("split.download.port"; .port == null or (.port | port)) |
            require("split.download.network"; (.network // "xhttp") == "xhttp") |
            require("split.download.security"; (.security // "tls") == "tls") |
            require("split.download.tlsSettings"; (.tlsSettings // {}) | type == "object" and (has("certificates") | not)) |
            require("split.download.sockopt"; (.sockopt // {}) | type == "object") |
            checked((.xhttpSettings // {}) |
                require("split.download.xhttpSettings"; only(["path","host","extra"])) |
                require("split.download.xhttpSettings.path"; (.path // "/argo") | type == "string" and startswith("/")) |
                require("split.download.xhttpSettings.host"; (.host // "") | type == "string") |
                checked((.extra // {}) | extra("split.download.xhttpSettings.extra")));
        (if length == 1 then .[0] else error("XHTTP 请输入一个 JSON 对象") end) |
        require("配置对象（允许 mode、server、client、split）"; only(["mode","server","client","split"])) |
        require("mode（auto、packet-up、stream-up 或 stream-one）"; .mode | IN(null,"auto","packet-up","stream-up","stream-one")) |
        checked(.server | if . == null then . else extra("server") end) |
        checked(.client | if . == null then . else extra("client") end) |
        checked(.split | if . == null then . else
            require("split（允许 port、mode、download）"; only(["port","mode","download"])) |
            require("split.port（1–65535 的整数）"; .port | port) |
            require("split.mode（packet-up 或 stream-up）"; (.mode // "packet-up") | IN("packet-up","stream-up")) |
            checked((.download // {}) | download) end)
    ' <<< "$1" 2>&1) || {
        case "${_checked}" in
            *': XHTTP '*) log_error "XHTTP ${_checked#*: XHTTP }" ;;
            *"parse error:"*) log_error "XHTTP JSON 语法无效" ;;
            *) log_error "无法校验 XHTTP JSON" ;;
        esac
        return 1
    }
    printf '%s\n' "${_checked}"
}

_xhttp_store_profile() {
    local _module="$1" _profile="$2" _old_split
    if [ "${_module}" = argo ]; then
        _argo_xhttp_check_profile_split "${_profile}" || return 1
        if jq -e '(.split | type) == "object" and .split.mode == null' <<< "${_profile}" >/dev/null; then
            _old_split=$(st_get '.argo.xhttp.split') || return 1
            _old_split=${_old_split:-null}
            _profile=$(jq -c --argjson old "${_old_split}" '
                .split.mode = (if ($old | type) == "object" then ($old.mode // "packet-up") else "stream-up" end)
            ' <<< "${_profile}") || return 1
        fi
    fi
    st_set '.[$inbound_id].xhttp = $profile' --arg inbound_id "${_module}" --argjson profile "${_profile}"
}

_xhttp_apply_profile() {
    local _module="$1" _profile="$2"
    _xhttp_store_profile "${_module}" "${_profile}" || return 1
    if { [ "${_module}" = reality ] && [ "$(st_get '.reality.network')" != xhttp ]; } ||
       { [ "${_module}" = ff ] && [ "$(st_get '.ff.protocol')" != xhttp ]; }; then
        st_persist
    elif [ "$(st_get '.[$inbound_id].enabled' --arg inbound_id "${_module}")" = true ]; then
        _commit_inner
    else
        st_persist
    fi
}

_argo_xhttp_check_split_port() {
    local _port="$1" _old_port="$2"
    if [ "${_port}" = "$(port_of argo)" ] || [ "${_port}" = "$(port_of reality)" ]; then
        log_error "split.port：REALITY 上行端口 ${_port} 须与 Argo 回源和 Reality 端口不同"
        return 1
    fi
    if [ "${_port}" != "${_old_port}" ] && port_mgr_in_use "${_port}"; then
        log_error "split.port：REALITY 上行端口已被占用（${_port}）"
        return 1
    fi
}

_argo_xhttp_check_profile_split() {
    local _port _old_port=''
    _port=$(jq -r '.split.port // empty' <<< "$1") || return 1
    [ -n "${_port}" ] || return 0
    [ "$(st_get '.reality.enabled')" = true ] || { log_error "split.port：请先启用本机 Reality"; return 1; }
    if _argo_xhttp_split_active; then _old_port=$(st_get '.argo.xhttp.split.port'); fi
    _argo_xhttp_check_split_port "${_port}" "${_old_port}"
}

_xhttp_set_profile() {
    local _module="$1" _runtime="$2" _raw="$3" _profile=null _invalid _mode _label
    _label=$(module_label "${_module}")
    if [ "${_raw}" != null ]; then
        _profile=$(_xhttp_validate_profile "${_raw}") || return 1
        _invalid=$(jq -r --arg id "${_module}" '
            if $id != "argo" and has("split") then "split（仅 Argo 支持）"
            else ["server","client"][] as $side | (.[$side] // {}) | keys[] as $key |
                select($key | IN("path", "mode", "host", "extra", "xhttpModeH3")) | "\($side).\($key)"
            end
        ' <<< "${_profile}") || return 1
        [ -z "${_invalid}" ] || { log_error "${_label} XHTTP 保留字段: ${_invalid}"; return 1; }
        if [ "${_module}" != argo ]; then
            _mode=$(st_get '.[$id].xhttp.mode // "stream-one"' --arg id "${_module}") || return 1
            _profile=$(jq -ce --arg mode "${_mode}" '.mode //= $mode' <<< "${_profile}") || return 1
        fi
    fi
    if [ "${_runtime}" = 1 ]; then
        _transaction_run "更新 ${_label} XHTTP" _xhttp_apply_profile "${_module}" "${_profile}" || return 1
        log_ok "${_label} XHTTP 配置已保存"
    else
        _xhttp_store_profile "${_module}" "${_profile}" || return 1
        log_ok "${_label} XHTTP 已写入安装计划"
    fi
}

_argo_xhttp_set_profile() { _xhttp_set_profile argo "$@"; }

_xhttp_export_vless_outbound() {
    jq -n --arg address "$1" --argjson port "$2" \
        --arg uuid "$(st_get '.uuid')" --argjson stream "$3" '
        {protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$uuid,encryption:"none"}]}]},
         streamSettings:$stream}'
}

_argo_xhttp_export_json() {
    local _stream _address _port
    _stream=$(_argo_xhttp_client_stream "$1") || return 1
    if [ "$1" = split ]; then
        _address=$(platform_get_realip) || return 1
        _port=$(st_get '.argo.xhttp.split.port') || return 1
    else
        _address=$(st_get '.cfip') || return 1
        _port=$(st_get '.cfport') || return 1
    fi
    _address="${_address#[}"
    [ -n "${_address%]}" ] || return 1
    _xhttp_export_vless_outbound "${_address%]}" "${_port}" "${_stream}"
}

_argo_xhttp_mihomo_warn_differences() {
    local _outbound="${1:-}" _warnings
    [ -n "${_outbound}" ] || _outbound=$(_argo_xhttp_export_json split) || return 1
    _warnings=$(jq -r '
        .streamSettings as $stream |
        $stream.xhttpSettings.extra.downloadSettings as $down |
        [if $down.xhttpSettings.extra.xPaddingBytes != null and
             $down.xhttpSettings.extra.xPaddingBytes != $stream.xhttpSettings.extra.xPaddingBytes
         then "Mihomo 下行没有独立 Padding，会继承上行值" else empty end,
         if ([$down | .. | objects | select(has("sockopt"))] | length) > 0 then
             "Mihomo 下行没有独立 sockopt，拨号设置由上下行共享"
         else empty end,
         if ($down.xhttpSettings.extra.xmux | type) == "object" and
            ($stream.xhttpSettings.extra.xmux | type) != "object"
         then "Mihomo 1.19.34 下行复用设置需要上行同时提供 reuse-settings 才会启用管理器"
         else empty end] | .[]
    ' <<< "${_outbound}") || return 1
    [ -n "${_warnings}" ] || return 0
    while IFS= read -r _warning; do [ -z "${_warning}" ] || log_warn "${_warning}"; done <<< "${_warnings}"
}

_argo_xhttp_export_mihomo() {
    local _outbound="${1:-}"
    [ -n "${_outbound}" ] || _outbound=$(_argo_xhttp_export_json split) || return 1
    jq '
        def omit_null: with_entries(select(.value != null));
        def string_or_null: if . == null then null else tostring end;
        def reuse_settings:
            if . == null then null else
                {"max-concurrency": (.maxConcurrency | string_or_null),
                 "max-connections": (.maxConnections | string_or_null),
                 "c-max-reuse-times": (.cMaxReuseTimes | string_or_null),
                 "h-max-request-times": (.hMaxRequestTimes | string_or_null),
                 "h-max-reusable-secs": (.hMaxReusableSecs | string_or_null),
                 "h-keep-alive-period": .hKeepAlivePeriod} | omit_null
            end;
        def xhttp_opts:
            {path, host, mode, headers: (.headers // .extra.headers),
             "x-padding-bytes": .extra.xPaddingBytes, "x-padding-obfs-mode": .extra.xPaddingObfsMode,
             "x-padding-key": .extra.xPaddingKey, "x-padding-header": .extra.xPaddingHeader,
             "x-padding-placement": .extra.xPaddingPlacement, "x-padding-method": .extra.xPaddingMethod,
             "uplink-http-method": .extra.uplinkHTTPMethod, "no-grpc-header": .extra.noGRPCHeader,
             "session-placement": (.extra.sessionIDPlacement // .extra.sessionPlacement),
             "session-key": (.extra.sessionIDKey // .extra.sessionKey),
             "session-table": .extra.sessionIDTable, "session-length": (.extra.sessionIDLength | string_or_null),
             "seq-placement": .extra.seqPlacement, "seq-key": .extra.seqKey,
             "uplink-data-placement": .extra.uplinkDataPlacement, "uplink-data-key": .extra.uplinkDataKey,
             "uplink-chunk-size": (.extra.uplinkChunkSize | string_or_null),
             "sc-max-each-post-bytes": (.extra.scMaxEachPostBytes | string_or_null),
             "sc-min-posts-interval-ms": (.extra.scMinPostsIntervalMs | string_or_null),
             "reuse-settings": (.extra.xmux | reuse_settings)} | omit_null;
        .settings.vnext[0] as $peer | .streamSettings as $stream |
        $stream.xhttpSettings.extra.downloadSettings as $down |
        ($down.xhttpSettings | {path,host,headers:(.headers // .extra.headers),
                               "reuse-settings":(.extra.xmux | reuse_settings)}) +
        {server:$down.address, port:$down.port, tls:true, servername:$down.tlsSettings.serverName,
         "client-fingerprint":$down.tlsSettings.fingerprint,
         alpn:$down.tlsSettings.alpn, "skip-cert-verify":$down.tlsSettings.allowInsecure,
         "reality-opts":{"public-key":""}} | omit_null | . as $download |
        {proxies: [{name:"Argo-XHTTP-Split", type:"vless", server:$peer.address,
                    port:$peer.port, uuid:$peer.users[0].id, udp:true, tls:true, network:"xhttp",
                    servername:$stream.realitySettings.serverName,
                    "client-fingerprint":$stream.realitySettings.fingerprint,
                    "reality-opts":{"public-key":$stream.realitySettings.password,
                                    "short-id":$stream.realitySettings.shortId,
                                    "support-x25519mlkem768":true},
                    "xhttp-opts": ($stream.xhttpSettings | xhttp_opts | . + {"download-settings":$download})}]}
    ' <<< "${_outbound}"
}

_argo_xhttp_render_status() {
    jq -r --argjson server "$(_xhttp_server_extra argo)" --arg legacy "$(xpad_of argo)" '
        ((.client // {}) | .xmux // {}) as $xmux |
        "模式 \(.mode // "auto") · Padding \(
            if .server == null and $legacy == "true" then "旧版设置"
            else $server.xPaddingBytes // "Xray 默认" end)" +
        (if .server == null and $legacy == "true" and $server.xPaddingBytes != null then
            "（\($server.xPaddingBytes)）" else "" end),
        "XMUX \(if ($xmux | length) == 0 then "Xray 默认" else $xmux | tojson end)",
        (if .split == null then "上下行分离 已关闭"
         else "REALITY 上行 TCP \(.split.port) · \(.split.mode // "packet-up") / Cloudflare TLS 下行" end)
    ' <<< "$(st_get '.argo.xhttp // {}')"
}

_xhttp_edit_advanced() {
    local _module="$1" _runtime="$2" _current _draft
    _current=$(_xhttp_saved_profile "${_module}" | jq -c '. // {}') || return 1
    printf '当前 XHTTP JSON: %s\n' "${_current}"
    while prompt '编辑单行 JSON（可直接粘贴，回车或 0 返回）: ' _draft '' && [ -n "${_draft}" ]; do
        [ "${_draft}" != 0 ] || return 0
        if "_${_module}_xhttp_set_profile" "${_runtime}" "${_draft}"; then
            return 0
        fi
    done
}

# 读取已保存的 XHTTP 配置时，将旧版占位值和 Argo 的旧下行安全层视为缺省。
_xhttp_saved_profile() {
    st_get '.[$id].xhttp | (if type == "object" then
        with_entries(select(((.key | IN("server", "client", "mode")) and (.value == false)) | not)) |
        if $id == "argo" and (.split.download | type == "object") then
            del(.split.download.realitySettings) |
            if (.split.download.security | IN("reality", "none")) then del(.split.download.security) else . end
        else . end
        else null end) | tojson' --arg id "$1"
}

_xhttp_edit_field() {
    local _module="$1" _runtime="$2" _field="$3" _label="$4" _raw _profile _server
    _server=$(_xhttp_server_extra "${_module}") || return 1
    while prompt "${_label}（空行返回）: " _raw '' && [ -n "${_raw}" ]; do
        _profile=$(_xhttp_saved_profile "${_module}" | jq -c '
            ($path | split(".")) as $field | (. // {}) |
            if $field[0] == "server" then .server //= $server
            elif $field[0] == "client" then .client //= {} | .client.xmux //= {}
            else . end |
            if $value == "-" and $path == "mode" and $inbound_id != "argo" then .mode = "stream-one"
            elif $value == "-" and $path != "split.port" then delpaths([$field])
            else setpath($field; if ($value | test("^[0-9]+$")) then $value | tonumber else $value end) end
        ' --arg inbound_id "${_module}" --arg path "${_field}" --arg value "${_raw}" --argjson server "${_server}")
        if "_${_module}_xhttp_set_profile" "${_runtime}" "${_profile}"; then
            return 0
        fi
    done
}

_xhttp_edit_common() {
    local _module="$1" _runtime="$2" _choice _field _label _last=6
    while true; do
        log_title "══ $(module_label "${_module}") XHTTP 常用参数 ══"
        "_${_module}_xhttp_render_status"
        _menu_print_action 1 "传输模式"
        _menu_print_action 2 "Padding 字节范围"
        _menu_print_action 3 "XMUX 最大连接数"
        _menu_print_action 4 "XMUX 最大并发数"
        _menu_print_action 5 "XMUX 每连接请求数"
        _menu_print_action 6 "XMUX 连接复用时长（秒）"
        _menu_print_back
        prompt "请选择常用参数 (0-${_last}): " _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) _field=mode; _label='auto、packet-up、stream-up 或 stream-one' ;;
            2) _field=server.xPaddingBytes; _label='Padding 字节数或范围，如 128-768' ;;
            3) _field=client.xmux.maxConnections; _label='最大连接数或范围' ;;
            4) _field=client.xmux.maxConcurrency; _label='最大并发数或范围' ;;
            5) _field=client.xmux.hMaxRequestTimes; _label='每连接请求数或范围，如 600-900' ;;
            6) _field=client.xmux.hMaxReusableSecs; _label='连接复用时长或范围，如 1800-3000' ;;
            *) log_error "无效选项，请按提示输入"; continue ;;
        esac
        _xhttp_edit_field "${_module}" "${_runtime}" "${_field}" "${_label}，输入 - 恢复该项默认值"
    done
}

_argo_split_summary() {
    local _port _mode
    _port=$(st_get '.argo.xhttp.split.port // empty')
    _mode=$(st_get '.argo.xhttp.split.mode // "packet-up"')
    if [ -n "${_port}" ]; then
        printf '已配置 · %s · TCP/%s' "${_mode}" "${_port}"
    else
        printf '未配置'
    fi
}

_argo_split_menu() {
    local _runtime="$1" _choice _saved _profile
    if [ "$(st_get '.argo.protocol')" != xhttp ] || [ "$(st_get '.argo.auth_protocol')" != vless ]; then
        log_warn '上下行分离需要 Argo VLESS XHTTP'
        return 1
    fi
    while true; do
        _saved=$(st_get '.argo.xhttp.split | type')
        log_title 'Argo / 上下行分离'
        printf '  %s\n' "$(_argo_split_summary)"
        if [ "${_saved}" = object ]; then
            _menu_print_action 1 '关闭上下行分离'
            _menu_print_action 2 '修改上行模式'
            _menu_print_action 3 '修改 REALITY 上行端口'
        else
            _menu_print_action 1 '启用上下行分离，设置 REALITY 上行端口'
        fi
        _menu_print_back
        prompt '选择分离设置: ' _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) if [ "${_saved}" = object ]; then
                   _profile=$(_xhttp_saved_profile argo | jq -c 'del(.split)')
                   _argo_xhttp_set_profile "${_runtime}" "${_profile:-null}" || true
               else
                   _xhttp_edit_field argo "${_runtime}" split.port 'REALITY 上行端口（独立于现有 Reality）'
               fi ;;
            2) [ "${_saved}" = object ] || { log_error '请先配置上下行分离'; continue; }
               _xhttp_edit_field argo "${_runtime}" split.mode '上行模式（packet-up 或 stream-up）' ;;
            3) [ "${_saved}" = object ] || { log_error '请先配置上下行分离'; continue; }
               _xhttp_edit_field argo "${_runtime}" split.port 'REALITY 上行端口（独立于现有 Reality）' ;;
            *) log_error '无效分离设置' ;;
        esac
    done
}

_argo_xhttp_menu() {
    local _runtime="$1" _choice _profile
    if [ "$(st_get '.argo.protocol')" != xhttp ] || [ "$(st_get '.argo.auth_protocol')" != vless ]; then
        log_warn '高级设置需要 Argo VLESS XHTTP'
        return 1
    fi
    while true; do
        log_title 'Argo / 高级设置'
        _argo_xhttp_render_status
        _menu_print_action 1 '恢复默认模式和 Extra，保留分离配置'
        _menu_print_action 2 '编辑 Extra 与下行覆盖 JSON'
        _menu_print_action 5 '恢复旧版 xPadding 配置'
        _menu_print_action 7 '逐项编辑模式、Padding 和 XMUX'
        _menu_print_action 8 '切换旧版 xPadding'
        _menu_print_back
        prompt '选择高级设置: ' _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1) _profile=$(_xhttp_saved_profile argo | jq -c '. // {} | del(.mode) | .server={} | .client={}')
               _argo_xhttp_set_profile "${_runtime}" "${_profile}" || true ;;
            2) log_info 'JSON 字段：mode、server、client、split（port/mode/download）'
               _xhttp_edit_advanced argo "${_runtime}" ;;
            5) _profile=$(_xhttp_saved_profile argo | jq -c 'if .split then {split} else null end')
               _argo_xhttp_set_profile "${_runtime}" "${_profile}" || true ;;
            7) _xhttp_edit_common argo "${_runtime}" ;;
            8) _xhttp_legacy_padding argo "${_runtime}" ;;
            *) log_error '无效高级设置' ;;
        esac
    done
}

_xhttp_legacy_padding() {
    local _module="$1" _runtime="$2"
    if [ "$(st_get '.[$id].xhttp.server | type' --arg id "${_module}")" = object ]; then
        log_info '当前 Padding 由 Extra 管理。可编辑 Padding 或恢复旧版设置。'
        return 0
    fi
    _unified_runtime_fn_or_plan "${_runtime}" "install_plan_${_module}_toggle_xpad" \
        _menu_toggle_xpad "${_module}" "$(module_label "${_module}")"
}

unified_menu_argo() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _proto _port _domain _xpad _auth_mode _svc _auth_proto _pw_state
        _en=$(st_get '.argo.enabled')
        _proto=$(st_get '.argo.protocol')
        _port=$(port_of argo)
        _domain=$(st_get '.argo.domain')
        _xpad=$(xpad_of argo)
        _auth_proto=$(st_get '.argo.auth_protocol')
        if [ "${_auth_proto}" = "trojan" ]; then
            trojan_password_is_valid "$(st_get '.argo.trojan_password')" \
                && _pw_state='已设置独立密码' || _pw_state='未设置（回退 UUID）'
        else
            _pw_state='不适用'
        fi
        [ -f "${WORK_DIR}/tunnel.json" ] && _auth_mode='json-cred' || { [ -n "$(st_get '.argo.token')" ] && [ "$(st_get '.argo.token')" != "null" ] && _auth_mode='token' || _auth_mode='未配置'; }
        _svc=$(_unified_runtime_status_for argo)
        log_title "══ Argo 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "需要 Cloudflare Tunnel 域名与 token/JSON 凭证"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  协议: ${C_GRN}%s${C_RST}  回源端口: ${C_YLW}%s${C_RST}\n" "${_proto}" "${_port}"
        printf "  域名: ${C_CYN}%s${C_RST}  鉴权: ${C_YLW}%s${C_RST}\n" "${_domain:-未配置}" "${_auth_mode}"
        printf "  入站认证: ${C_GRN}%s${C_RST}  Trojan 密码: ${C_YLW}%s${C_RST}\n" "${_auth_proto}" "${_pw_state}"
        printf "  xPadding: ${C_YLW}%s${C_RST}\n" "${_xpad}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改传输协议（WS / XHTTP）"
        _menu_print_action 3 "修改回源端口"
        _menu_print_action 4 "修改域名"
        _menu_print_action 5 "修改密钥/凭证"
        _menu_print_action 6 "修改入站认证（VLESS / Trojan）"
        _menu_print_action 7 "修改 Trojan 密码（仅 Trojan）"
        if [ "${_proto}" = xhttp ] && [ "${_auth_proto}" = vless ]; then
            _menu_print_action 9 "上下行分离 · $(_argo_split_summary)"
            _menu_print_action x '高级设置（XHTTP）'
        fi
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action r "重启隧道服务"
            _menu_print_action h "探测 Argo 域名"
            _menu_print_action u "卸载 Argo" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" argo "${_en}" install_plan_argo_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" argo update_protocol install_plan_argo_update_protocol || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" argo update_port install_plan_argo_update_port || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" argo update_domain install_plan_argo_update_domain || true ;;
            5) _unified_dispatch_or_plan "${_runtime}" argo update_auth install_plan_argo_update_auth || true ;;
            6) _unified_dispatch_or_plan "${_runtime}" argo update_auth_protocol install_plan_argo_update_auth_protocol || true ;;
            7) _unified_dispatch_or_plan "${_runtime}" argo update_trojan_password install_plan_argo_update_trojan_password || true ;;
            9) _argo_split_menu "${_runtime}" || true ;;
            x) _argo_xhttp_menu "${_runtime}" || true ;;
            r) if [ "${_runtime}" -eq 1 ] && _menu_confirm_interrupt '重启 Argo Tunnel'; then
                   module_dispatch argo restart || true
               fi ;;

            h) if [ "${_runtime}" -eq 1 ]; then
                   argo_check_health || true
                   _pause
               fi ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "Argo" || continue
                    module_dispatch argo uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_freeflow() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _proto _path _host _port _xpad _active _svc
        _en=$(st_get '.ff.enabled')
        _proto=$(st_get '.ff.protocol')
        _path=$(st_get '.ff.path')
        _host=$(st_get '.ff.host')
        _port=$(port_of ff)
        _xpad=$(xpad_of ff)
        [ "${_en}" = "true" ] && [ "${_proto}" != "none" ] && _active=true || _active=false
        _svc=$(_unified_runtime_status_for ff)
        log_title "══ FreeFlow 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "常用字段只改当前项，不再重走整段问答"
        _unified_render_status "${_runtime}" "${_active}" "${_svc}"
        if [ "${_proto}" = "tcphttp" ]; then
            printf "  协议: ${C_GRN}%s${C_RST}  端口: ${C_YLW}%s${C_RST}  Host: ${C_CYN}%s${C_RST}\n" "${_proto}" "${_port}" "${_host}"
        else
            printf "  协议: ${C_GRN}%s${C_RST}  端口: ${C_YLW}%s${C_RST}  路径: ${C_CYN}%s${C_RST}\n" "${_proto}" "${_port}" "${_path}"
        fi
        printf "  xPadding: ${C_YLW}%s${C_RST}\n" "${_xpad}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改传输协议"
        _menu_print_action 3 "修改监听端口"
        _menu_print_action 4 "修改 Host / 路径 path"
        _menu_print_action x '高级设置（XHTTP）'
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 FreeFlow" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" ff "${_active}" install_plan_ff_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" ff update_mode install_plan_ff_update_mode || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" ff update_port install_plan_ff_update_port || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" ff update_host_or_path install_plan_ff_update_host_or_path || true ;;
            x) _direct_xhttp_menu ff "${_runtime}" "${_proto}" && continue ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "FreeFlow" || continue
                    module_dispatch ff uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_reality() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _sni _net _xpad _svc
        _en=$(st_get '.reality.enabled')
        _port=$(port_of reality)
        _sni=$(st_get '.reality.sni')
        _net=$(st_get '.reality.network'); _net="${_net:-tcp}"
        _xpad=$(xpad_of reality)
        _svc=$(_unified_runtime_status_for reality)
        log_title "══ Reality 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "默认推荐 TCP + Reality；需要时再切 XHTTP"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  端口: ${C_YLW}%s${C_RST}  SNI: ${C_CYN}%s${C_RST}  传输: ${C_GRN}%s${C_RST}\n" "${_port}" "${_sni}" "${_net}"
        printf "  xPadding: ${C_YLW}%s${C_RST}\n" "${_xpad}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改监听端口"
        _menu_print_action 3 "修改 SNI"
        _menu_print_action 4 "切换传输协议（TCP / XHTTP）"
        _menu_print_action x '高级设置（XHTTP）'
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action k "重新生成密钥对"
            _menu_print_action u "卸载 Reality" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" reality "${_en}" install_plan_reality_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" reality update_port install_plan_reality_update_port || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" reality update_sni install_plan_reality_update_sni || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" reality update_transport install_plan_reality_update_transport || true ;;
            x) _direct_xhttp_menu reality "${_runtime}" "${_net}" && continue ;;
            k) _unified_runtime_only_fn "${_runtime}" module_dispatch reality regenerate_keys || true ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "Reality" || continue
                    module_dispatch reality uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_vltcp() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _listen _svc
        _en=$(st_get '.vltcp.enabled')
        _port=$(port_of vltcp)
        _listen=$(st_get '.vltcp.listen')
        _svc=$(_unified_runtime_status_for vltcp)
        log_title "══ VLESS-TCP 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "明文直连模块，建议结合受控网络环境使用"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改监听端口"
        _menu_print_action 3 "修改监听地址"
        _menu_print_action 4 "查看当前节点摘要"
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 VLESS-TCP" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" vltcp "${_en}" install_plan_vltcp_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" vltcp update_port install_plan_vltcp_update_port || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" vltcp update_listen install_plan_vltcp_update_listen || true ;;
            4) log_info "VLESS-TCP: ${_summary}" ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "VLESS-TCP" || continue
                    module_dispatch vltcp uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_vlquic() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _listen _domain _svc
        _en=$(st_get '.vlquic.enabled')
        _port=$(port_of vlquic)
        _listen=$(st_get '.vlquic.listen')
        _domain=$(st_get '.vlquic.domain')
        _svc=$(_unified_runtime_status_for vlquic)
        log_title "══ VLESS-XHTTP-H3 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "需要域名、证书与 UDP/QUIC 可用"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  UDP端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        printf "  域名: ${C_CYN}%s${C_RST}\n" "${_domain:-未配置}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改 UDP 监听端口"
        _menu_print_action 3 "修改监听地址"
        _menu_print_action 4 '证书'
        _menu_print_action x '高级设置（XHTTP）'
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 VLESS-XHTTP-H3" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" vlquic "${_en}" install_plan_vlquic_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" vlquic update_port install_plan_vlquic_update_port || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" vlquic update_listen install_plan_vlquic_update_listen || true ;;
            4) _workbench_certificates vlquic "${_runtime}" ;;
            x) _direct_xhttp_menu vlquic "${_runtime}" xhttp && continue ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "VLESS-XHTTP-H3" || continue
                    module_dispatch vlquic uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

_reality_xhttp_set_profile() { _xhttp_set_profile reality "$@"; }
_ff_xhttp_set_profile() { _xhttp_set_profile ff "$@"; }
_vlquic_xhttp_set_profile() { _xhttp_set_profile vlquic "$@"; }

_ff_xhttp_render_status() { _xhttp_render_status_with_legacy_padding ff; }

_ff_xhttp_export_json() {
    local _ip _stream
    _ip=$(platform_get_realip)
    [ -n "${_ip}" ] || { log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 1; }
    _stream=$(_ff_xhttp_client_stream "${_ip}") || return 1
    _ip="${_ip#[}"; _ip="${_ip%]}"
    _xhttp_export_vless_outbound "${_ip}" "$(port_of ff)" "${_stream}"
}

_vlquic_xhttp_render_status() {
    jq -r '
        "  当前模式 \(.mode // "stream-one") · Padding \(.server.xPaddingBytes // "Xray 默认")",
        "  XMUX \(if (.client.xmux // {} | length) == 0 then "Xray 默认" else .client.xmux | tojson end) · HTTP/3 (UDP)"
    ' <<< "$(st_get '.vlquic.xhttp // {}')"
}

_vlquic_xhttp_export_json() {
    local _domain _stream
    _domain=$(st_get '.vlquic.domain')
    [ -n "${_domain}" ] || { log_warn "请先配置 VLESS-XHTTP-H3 域名，再导出出站 JSON"; return 1; }
    _stream=$(_vlquic_xhttp_client_stream "${_domain}") || return 1
    _xhttp_export_vless_outbound "${_domain}" "$(port_of vlquic)" "${_stream}"
}

_reality_xhttp_render_status() { _xhttp_render_status_with_legacy_padding reality; }

_xhttp_render_status_with_legacy_padding() {
    local _module="$1" _server
    _server=$(_xhttp_server_extra "${_module}") || return 1
    jq -r --argjson server "${_server}" --arg legacy "$(xpad_of "${_module}")" '
        "  当前模式 \(.mode // "stream-one") · Padding \(
            if .server == null and $legacy == "true" then "旧版设置"
            else $server.xPaddingBytes // "Xray 默认" end)",
        "  XMUX \(if (.client.xmux // {} | length) == 0 then "Xray 默认" else .client.xmux | tojson end)"
    ' <<< "$(st_get '.[$id].xhttp // {}' --arg id "${_module}")"
}

_reality_xhttp_export_json() {
    local _address _stream
    _stream=$(_reality_xhttp_client_stream) || return 1
    _address=$(platform_get_realip)
    _address="${_address#[}"; _address="${_address%]}"
    [ -n "${_address}" ] || { log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 1; }
    _xhttp_export_vless_outbound "${_address}" "$(port_of reality)" "${_stream}"
}

_cforigin_xhttp_set_profile() { _xhttp_set_profile cforigin "$@"; }

_cforigin_xhttp_export_json() {
    local _domain _stream
    _domain=$(st_get '.cforigin.domain') || return 1
    [ -n "${_domain}" ] || { log_warn "请先配置 CF Origin 域名，再导出出站 JSON"; return 1; }
    _stream=$(_cforigin_xhttp_client_stream) || return 1
    _xhttp_export_vless_outbound "${_domain}" "$(st_get '.cforigin.edge_port')" "${_stream}"
}

_cforigin_xhttp_render_status() {
    jq -r --arg edge_h3 "$(st_get '.cforigin.edge_h3')" '
        "  当前模式 \(.mode // "stream-one") · Padding \(.server.xPaddingBytes // "Xray 默认")",
        "  XMUX \(if (.client.xmux // {} | length) == 0 then "Xray 默认" else .client.xmux | tojson end)",
        "  Edge HTTP/3 \(if $edge_h3 == "true" then "已启用（实验性）" else "已关闭" end)"
    ' <<< "$(st_get '.cforigin.xhttp // {}')"
}



_direct_xhttp_menu() {
    local _module="$1" _runtime="$2" _transport="$3" _choice _mode _profile _input _label
    _label=$(module_label "${_module}")
    [ "${_transport}" = xhttp ] || { log_warn "请先选择 ${_label} 的 XHTTP 传输"; return 1; }
    while true; do
        log_title "${_label} / XHTTP"
        "_${_module}_xhttp_render_status"
        _menu_print_action 1 "选择传输模式"
        _menu_print_action 2 "编辑服务端和客户端 Extra JSON"
        case "${_module}" in
            ff|reality) _menu_print_action 3 '切换旧版 xPadding' ;;
            cforigin) _menu_print_action 3 '切换 Cloudflare Edge HTTP/3' ;;
        esac
        _menu_print_action 4 "恢复 stream-one 和默认 Extra"
        _menu_print_action 5 "逐项编辑常用参数"
        _menu_print_back
        prompt "选择高级设置: " _choice || return 0
        case "${_choice}" in
            0) return 0 ;;
            1)
                while prompt '传输模式（1 stream-one，2 auto，3 packet-up，4 stream-up，0 返回）: ' _input; do
                    case "${_input}" in
                        1) _mode=stream-one; break ;;
                        2) _mode=auto; break ;;
                        3) _mode=packet-up; break ;;
                        4) _mode=stream-up; break ;;
                        0|'') continue 2 ;;
                        *) log_error '请输入 1–4 选择传输模式' ;;
                    esac
                done
                [ -n "${_input}" ] || return 0
                _profile=$(_xhttp_saved_profile "${_module}" | jq -c --arg mode "${_mode}" '.mode = $mode')
                "_${_module}_xhttp_set_profile" "${_runtime}" "${_profile}" || true ;;
            2)
                log_info 'JSON 字段: mode, server（入站 Extra）, client（客户端 Extra）'
                _xhttp_edit_advanced "${_module}" "${_runtime}"
                continue ;;
            3) case "${_module}" in
                   ff|reality) _xhttp_legacy_padding "${_module}" "${_runtime}" ;;
                   cforigin) _unified_dispatch_or_plan "${_runtime}" cforigin toggle_edge_h3 install_plan_cforigin_toggle_edge_h3 || true ;;
                   *) log_error '无效高级设置' ;;
               esac ;;
            4) "_${_module}_xhttp_set_profile" "${_runtime}" null || true ;;
            5) _xhttp_edit_common "${_module}" "${_runtime}"; continue ;;
            *) log_error "请输入 0–5 选择操作" ;;
        esac
    done
}

_cforigin_xhttp_menu() {
    _direct_xhttp_menu cforigin "$1" "$(st_get '.cforigin.protocol')"
}

unified_menu_cforigin() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _proto _path _domain _edge _edge_h3 _origin _listen _tls _svc
        _en=$(st_get '.cforigin.enabled')
        _proto=$(st_get '.cforigin.protocol')
        _path=$(st_get '.cforigin.path')
        _domain=$(st_get '.cforigin.domain')
        _edge=$(st_get '.cforigin.edge_port')
        _edge_h3=$(st_get '.cforigin.edge_h3')
        _origin=$(port_of cforigin)
        _listen=$(st_get '.cforigin.listen')
        _tls=$(st_get '.cforigin.origin_tls')
        _svc=$(_unified_runtime_status_for cforigin)
        log_title "══ CF Origin 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "需要 Cloudflare 域名、回源规则与源站证书"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  协议: ${C_GRN}%s${C_RST}  路径: ${C_CYN}%s${C_RST}\n" "${_proto}" "${_path}"
        printf "  域名: ${C_CYN}%s${C_RST}  Edge: ${C_YLW}%s${C_RST}  Origin: ${C_YLW}%s${C_RST}\n" "${_domain:-未配置}" "${_edge}" "${_origin}"
        printf "  监听: ${C_CYN}%s${C_RST}  Edge-H3: ${C_YLW}%s${C_RST}  TLS: ${C_YLW}%s${C_RST}\n" "${_listen}" "${_edge_h3}" "${_tls}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改协议（WS / HTTPUpgrade / XHTTP）"
        _menu_print_action 3 "修改域名"
        _menu_print_action 4 "修改路径 path"
        _menu_print_action 5 "修改 Edge 入口端口"
        _menu_print_action 6 "修改 Origin 回源端口"
        _menu_print_action 7 "修改监听地址"
        _menu_print_action 9 '证书'
        _menu_print_action x '高级设置（XHTTP）'
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 CF Origin" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" cforigin "${_en}" install_plan_cforigin_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" cforigin update_protocol install_plan_cforigin_update_protocol || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" cforigin update_domain install_plan_cforigin_update_domain || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" cforigin update_path install_plan_cforigin_update_path || true ;;
            5) _unified_dispatch_or_plan "${_runtime}" cforigin update_edge_port install_plan_cforigin_update_edge_port || true ;;
            6) _unified_dispatch_or_plan "${_runtime}" cforigin update_port install_plan_cforigin_update_origin_port || true ;;
            7) _unified_dispatch_or_plan "${_runtime}" cforigin update_listen install_plan_cforigin_update_listen || true ;;
            9) _workbench_certificates cforigin "${_runtime}" ;;
            x) _cforigin_xhttp_menu "${_runtime}" && continue ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "CF Origin" || continue
                    module_dispatch cforigin uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_socks() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _listen _user _svc
        _en=$(st_get '.socks.enabled')
        _port=$(port_of socks)
        _listen=$(st_get '.socks.listen')
        _user=$(st_get '.socks.user')
        _svc=$(_unified_runtime_status_for socks)
        log_title "══ SOCKS5 闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "账号密码变更支持单字段修改"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}  用户: ${C_GRN}%s${C_RST}\n" "${_port}" "${_listen}" "${_user}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改监听端口"
        _menu_print_action 3 "修改监听地址"
        _menu_print_action 4 "修改用户名"
        _menu_print_action 5 "修改密码"
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 SOCKS5" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" socks "${_en}" install_plan_socks_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" socks update_port install_plan_socks_update_port || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" socks update_listen install_plan_socks_update_listen || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" socks update_user install_plan_socks_update_user || true ;;
            5) _unified_dispatch_or_plan "${_runtime}" socks update_pass install_plan_socks_update_pass || true ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "SOCKS5" || continue
                    module_dispatch socks uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_ss2022() {
    local _mode="$1" _runtime=0
    [ -n "$_mode" ] || _mode=install
    _unified_mode_is_runtime "$_mode" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _listen _method _key_mode _svc
        _en=$(st_get '.ss2022.enabled')
        _port=$(port_of ss2022)
        _listen=$(st_get '.ss2022.listen')
        _method=$(st_get '.ss2022.method')
        _key_mode=单密钥
        if [ "$(st_get '.ss2022.key_mode')" = dual ]; then _key_mode=双密钥; fi
        _svc=$(_unified_runtime_status_for ss2022)
        log_title "══ Shadowsocks 2022 闭环工作台 ══"
        _unified_render_mode_header "$_mode" "使用 Xray-core 内置 SS2022"
        _unified_render_status "$_runtime" "$_en" "$_svc"
        printf "  端口: $C_YLW%s$C_RST  监听: $C_CYN%s$C_RST  方法: $C_GRN%s（%s）$C_RST\\n" "$_port" "$_listen" "$_method" "$_key_mode"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改 TCP/UDP 监听端口"
        _menu_print_action 3 "修改监听地址"
        _menu_print_action 4 "修改加密方法与密钥模式（会重新生成密钥）"
        _menu_print_action 5 "重新生成密钥"
        if [ "$_runtime" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 Shadowsocks 2022" "$C_RED"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "$_c" in
            1) _unified_toggle_or_plan "$_runtime" ss2022 "$_en" install_plan_ss2022_toggle || true ;;
            2) _unified_dispatch_or_plan "$_runtime" ss2022 update_port install_plan_ss2022_update_port || true ;;
            3) _unified_dispatch_or_plan "$_runtime" ss2022 update_listen install_plan_ss2022_update_listen || true ;;
            4) _unified_dispatch_or_plan "$_runtime" ss2022 update_method install_plan_ss2022_update_method || true ;;
            5) _unified_dispatch_or_plan "$_runtime" ss2022 regenerate_keys install_plan_ss2022_regenerate_keys || true ;;
            u)
                if [ "$_runtime" -eq 1 ]; then
                    _menu_confirm_uninstall "Shadowsocks 2022" || continue
                    module_dispatch ss2022 uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

unified_menu_http() {
    local _mode="${1:-install}" _runtime=0
    _unified_mode_is_runtime "${_mode}" && { _runtime=1; _manage_module_entry_check || return; }
    while true; do
        local _en _port _listen _user _svc
        _en=$(st_get '.http.enabled')
        _port=$(port_of http)
        _listen=$(st_get '.http.listen')
        _user=$(st_get '.http.user')
        _svc=$(_unified_runtime_status_for http)
        log_title "══ HTTP 代理闭环工作台 ══"
        _unified_render_mode_header "${_mode}" "HTTP 代理为明文 TCP 协议，公开监听前请确认网络边界"
        _unified_render_status "${_runtime}" "${_en}" "${_svc}"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}  用户: ${C_GRN}%s${C_RST}\n" "${_port}" "${_listen}" "${_user}"
        _hr
        _menu_print_action 1 "$([ "${_en}" = true ] && printf 停用 || printf 启用)入站"
        _menu_print_action 2 "修改监听端口"
        _menu_print_action 3 "修改监听地址"
        _menu_print_action 4 "修改用户名"
        _menu_print_action 5 "修改密码"
        if [ "${_runtime}" -eq 1 ]; then
            _hr
            _menu_print_action u "卸载 HTTP 代理" "${C_RED}"
        fi
        _menu_print_back
        _hr
        prompt '选择工作台操作: ' _c || return 0
        case "${_c:-}" in
            1) _unified_toggle_or_plan "${_runtime}" http "${_en}" install_plan_http_toggle || true ;;
            2) _unified_dispatch_or_plan "${_runtime}" http update_port install_plan_http_update_port || true ;;
            3) _unified_dispatch_or_plan "${_runtime}" http update_listen install_plan_http_update_listen || true ;;
            4) _unified_dispatch_or_plan "${_runtime}" http update_user install_plan_http_update_user || true ;;
            5) _unified_dispatch_or_plan "${_runtime}" http update_pass install_plan_http_update_pass || true ;;
            u)
                if [ "${_runtime}" -eq 1 ]; then
                    _menu_confirm_uninstall "HTTP 代理" || continue
                    module_dispatch http uninstall || continue
                    return 0
                else
                    log_error "无效选项，请按提示输入"
                fi ;;
            0) return 0 ;;
            *) log_error "无效选项，请按提示输入" ;;
        esac
    done
}

install_wizard_render() {
    log_title 'Xray-2go · 首次部署'
    _menu_print_action 1 '快速部署 Reality（VLESS + Reality TCP）'
    _menu_print_action 2 '快速部署 Argo（需要域名与 Cloudflare 凭证）'
    _menu_print_action 3 '自定义部署'
    _menu_print_action 0 '退出'
}
install_wizard_confirm() {
    local _c
    clear; echo ""
    log_title "══ 确认部署 ══"
    printf "  Argo      : %s\n" "$(install_plan_module_summary argo)"
    printf "  FreeFlow  : %s\n" "$(install_plan_module_summary ff)"
    printf "  Reality   : %s\n" "$(install_plan_module_summary reality)"
    printf "  VLESS-TCP : %s\n" "$(install_plan_module_summary vltcp)"
    printf "  SOCKS5    : %s\n" "$(install_plan_module_summary socks)"
    printf "  HTTP代理  : %s\n" "$(install_plan_module_summary http)"
    printf "  SS2022   : %s\n" "$(install_plan_module_summary ss2022)"
    printf "  XHTTP-H3  : %s\n" "$(install_plan_module_summary vlquic)"
    printf "  CF-Origin : %s\n" "$(install_plan_module_summary cforigin)"
    if [ "$(st_get '.cforigin.enabled')" = true ] && [ "${#_CFORIGIN_ISSUE[@]}" -gt 0 ]; then
        printf '  CF-Origin 证书将在确认部署后签发。\n'
    fi
    if [ "$(st_get '.vlquic.enabled')" = true ] && [ "${#_VLQUIC_ISSUE[@]}" -gt 0 ]; then
        printf '  XHTTP-H3 证书将在确认部署后签发。\n'
    fi
    _hr
    printf "  ${C_YLW}安装前会再次执行完整校验；确认后才开始安装。${C_RST}\n"
    _install_check_port_conflicts preview || return 1
    prompt "确认开始部署？(y/N): " _c || return 1
    case "${_c:-}" in
        y|Y|yes|YES) install_execute_current_plan interactive ;;
        *) log_info "已取消本次部署"; return 2 ;;
    esac
}

install_wizard_require_argo_domain() {
    local _domain
    while true; do
        _domain=$(st_get '.argo.domain')
        [ -n "${_domain}" ] && [ "${_domain}" != "null" ] && return 0
        install_plan_argo_update_domain || return 1
        _domain=$(st_get '.argo.domain')
        [ -n "${_domain}" ] && [ "${_domain}" != "null" ] && return 0
        log_error "Argo 域名是必填项，请重新输入"
    done
}

install_wizard_require_argo_auth() {
    local _token _cred
    while true; do
        _token=$(st_get '.argo.token')
        _cred=$(st_get '.argo.cred_b64')
        { [ -n "${_token}" ] && [ "${_token}" != "null" ]; } || { [ -n "${_cred}" ] && [ "${_cred}" != "null" ]; } && return 0
        install_plan_argo_update_auth || return 1
        _token=$(st_get '.argo.token')
        _cred=$(st_get '.argo.cred_b64')
        { [ -n "${_token}" ] && [ "${_token}" != "null" ]; } || { [ -n "${_cred}" ] && [ "${_cred}" != "null" ]; } && return 0
        log_error "Argo 凭证是必填项，请重新输入"
    done
}

install_wizard_reality() {
    preset_apply_reality_tcp_default || return 1
    install_wizard_confirm
}

install_wizard_argo() {
    install_plan_reset_defaults || return 1
    install_plan_argo_toggle || return 1
    install_plan_argo_update_protocol || return 1
    install_wizard_require_argo_domain || return 1
    install_wizard_require_argo_auth || return 1
    install_plan_argo_update_auth_protocol || return 1
    if [ "$(st_get '.argo.auth_protocol')" = "trojan" ]; then
        install_plan_argo_update_trojan_password || return 1
    fi
    install_wizard_confirm
}

install_wizard_menu() {
    local _c _menu_redraw _result _MENU_ACTION_PAUSES=1
    install_plan_reset_defaults || return 1
    while true; do
        install_wizard_render
        _menu_redraw=0
        _result=0
        prompt "请选择部署方案 (0-3，回车选 1): " _c || { _menu_return_to_parent; return 0; }
        case "${_c:-1}" in
            1) install_wizard_reality || _result=$? ;;
            2) install_wizard_argo || _result=$? ;;
            3) install_plan_menu || _result=$?
               [ "${_menu_redraw}" -eq 0 ] || continue ;;
            0) return 0 ;;
            *) log_error "无效选项，请输入 0-3"; continue ;;
        esac
        if [ "${_result}" -ne 2 ]; then _pause; fi
        [ "${_result}" -ne 0 ] || return 0
    done
}

install_plan_menu() {
    local _result
    while true; do
        install_plan_render_summary
        local _c
        prompt "请选择操作 (0-13): " _c || { _menu_return_to_parent; return 0; }
        _result=0
        case "${_c:-}" in
            1) unified_menu_argo install && continue ;;
            2) unified_menu_freeflow install && continue ;;
            3) unified_menu_reality install && continue ;;
            4) unified_menu_vltcp install && continue ;;
            5) unified_menu_socks install && continue ;;
            6) unified_menu_vlquic install && continue ;;
            7) unified_menu_cforigin install && continue ;;
            8) install_plan_configure_uuid || true ;;
            9) install_plan_reset_defaults || true; log_info "安装计划已重置为初始状态" ;;
            10) install_plan_validate || true ;;
            11) install_wizard_confirm && return 0
                _result=$? ;;
            12) unified_menu_http install && continue ;;
            13) unified_menu_ss2022 install && continue ;;
            0) _menu_return_to_parent; return 0 ;;
            *) log_error "无效选项，请输入 0-13" ;;
        esac
        if [ "${_result}" -ne 2 ]; then _pause; fi
    done
}

module_xray_install() {
    _require_first_deploy || return 1
    install_wizard_menu
}

_menu_pending_uninstall() {
    local _choice
    log_title '检测到未完成卸载'
    _menu_print_action 1 '继续卸载'
    _menu_print_action 0 '退出'
    while prompt '选择操作 (0-1): ' _choice; do
        case "${_choice}" in
            1) platform_detect_init; module_xray_uninstall; return $? ;;
            0) return 0 ;;
            *) log_error '无效选项，请输入 0 或 1' ;;
        esac
    done
}

menu() {
    local _MENU_STATE _choice _MENU_HIDE_LINKS=1
    while true; do
        if [ -e "${_UNINSTALL_PENDING}" ]; then _menu_pending_uninstall; return; fi
        _menu_collect_status
        if [ "${_MENU_STATE}" = uninstalled ]; then
            install_wizard_menu || return
            _menu_collect_status
            [ "${_MENU_STATE}" != uninstalled ] || return 0
            continue
        fi
        _menu_render
        prompt '输入编号 (0-3): ' _choice || return 0
        case "${_choice}" in
            1) _menu_nodes "" ;;
            2) _menu_inbounds ;;
            3) _menu_maintenance ;;
            0) return 0 ;;
            *) log_error '无效选项，请输入 0-3' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
用法:
  xray2go                 进入交互菜单
  xray2go --help          显示帮助
  xray2go reality
  xray2go reality -p <port>
  xray_2go.sh reality
  xray_2go.sh reality -p <port>

说明:
  - 无参数: 打开控制台。首次使用时直接选择部署方案
  - reality: 非交互一键安装 VLESS + Reality (TCP)
  - reality -p <port>: 使用指定监听端口进行一键安装
EOF
}

parse_args() {
    _CLI_ACTION="menu"
    _CLI_REALITY_PORT=""

    [ "$#" -eq 0 ] && return 0

    case "$1" in
        reality)
            _CLI_ACTION="install"
            shift ;;
        -h|--help|help)
            _CLI_ACTION="help"
            return 0 ;;
        *)
            log_error "未知命令: $1"
            return 1 ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -p)
                shift
                [ "$#" -gt 0 ] || { log_error "-p 需要端口值"; return 1; }
                val_port "$1" >/dev/null || return 1
                _CLI_REALITY_PORT="$1"
                shift ;;
            *)
                log_error "未知参数: $1"
                return 1 ;;
        esac
    done
}

cli_install() {
    preset_apply_reality_tcp_default "${_CLI_REALITY_PORT:-}" || return 1
    install_execute_current_plan
}

cli_dispatch() {
    case "${_CLI_ACTION:-menu}" in
        menu) menu ;;
        help) usage ;;
        install) cli_install ;;
        *) log_error "未知 CLI 动作: ${_CLI_ACTION:-}"; return 1 ;;
    esac
}

# ==============================================================================
# Entrypoint
# ==============================================================================
main() {
    parse_args "$@" || { usage; return 1; }
    if [ "${_CLI_ACTION}" = help ]; then
        cli_dispatch
        return
    fi
    check_root
    if [ -e "${_UNINSTALL_PENDING}" ]; then
        [ "${_CLI_ACTION}" = menu ] || { log_error "卸载未完成，请从主菜单选择继续卸载"; return 1; }
        _menu_pending_uninstall
        return $?
    fi
    platform_detect_init
    _transaction_lock_acquire || { log_error "启动初始化需要可用的部署写锁"; return 1; }
    local _startup_rc=0
    if [ -e "${_UNINSTALL_PENDING}" ]; then
        _transaction_lock_release
        if [ "${_CLI_ACTION}" = menu ]; then _menu_pending_uninstall; return $?; fi
        log_error "卸载未完成，请重新运行脚本并选择继续卸载"
        return 1
    fi
    if platform_preflight && st_init && plugin_refresh_runtime; then
        :
    else
        _startup_rc=$?
    fi
    _transaction_lock_release
    [ "${_startup_rc}" -eq 0 ] || return "${_startup_rc}"
    cli_dispatch
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
