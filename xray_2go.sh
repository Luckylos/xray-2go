#!/usr/bin/env bash
# ==============================================================================
# xray-2go v8.3  — Xray 落地代理管理脚本
# 协议支持：Argo 固定隧道(WS/XHTTP) · FreeFlow(WS/HTTPUpgrade/XHTTP)
#           Reality(TCP/XHTTP) · VLESS-TCP 明文落地
# 平台支持：Debian/Ubuntu (systemd) · Alpine (OpenRC)
# ==============================================================================
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] \
    || { printf '\033[1;91m[ERR ] 需要 bash 4.0 或更高版本\033[0m\n' >&2; exit 1; }

# ==============================================================================
# §1  全局常量
# ==============================================================================
readonly WORK_DIR="/etc/xray2go"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"
readonly _FW_PORTS_FILE="${WORK_DIR}/.fw_ports"
readonly _SVC_XRAY="xray2go"
readonly _SVC_TUNNEL="tunnel2go"

readonly _XRAY_MIRRORS=(
    "https://github.com/XTLS/Xray-core/releases/download"
    "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download"
    "https://hub.fastgit.xyz/XTLS/Xray-core/releases/download"
)

# ==============================================================================
# §2  临时文件沙箱与信号处理
# ==============================================================================
_TMP_DIR=""

trap '_cleanup_exit' EXIT
trap '_cleanup_int'  INT TERM

_cleanup_exit() {
    [ -n "${_TMP_DIR:-}" ] && rm -rf "${_TMP_DIR}" 2>/dev/null || true
    [ -t 1 ] && tput cnorm 2>/dev/null || true
}

_cleanup_int() {
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

_tmp_file() {
    [ -z "${_TMP_DIR:-}" ] && {
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) \
            || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    }
    mktemp "${_TMP_DIR}/${1:-tmp_XXXXXX}"
}

# ==============================================================================
# §3  UI 工具函数
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf "${C_CYN}[INFO]${C_RST} %s\n"     "$*"; }
log_ok()    { printf "${C_GRN}[ OK ]${C_RST} %s\n"     "$*"; }
log_warn()  { printf "${C_YLW}[WARN]${C_RST} %s\n"     "$*" >&2; }
log_error() { printf "${C_RED}[ERR ]${C_RST} %s\n"     "$*" >&2; }
log_step()  { printf "${C_PUR}[....] %s${C_RST}\n"     "$*"; }
log_title() { printf "\n${C_BOLD}${C_PUR}%s${C_RST}\n" "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

prompt() {
    printf "${C_RED}%s${C_RST}" "$1" >&2
    read -r "$2" </dev/tty
}

_pause() {
    local _d
    printf "${C_RED}按回车键继续...${C_RST}" >&2
    read -r _d </dev/tty || true
}

_hr() { printf "${C_PUR}  ──────────────────────────────────${C_RST}\n"; }

# ==============================================================================
# §4  平台检测
# ==============================================================================
_INIT_SYS=""
_ARCH_CF=""
_ARCH_XRAY=""

_detect_init() {
    if [ -f /.dockerenv ] || grep -qE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
        log_warn "检测到容器环境，服务管理功能可能受限"
    fi
    local _p1
    _p1=$(cat /proc/1/comm 2>/dev/null | tr -d '\n' || printf 'unknown')
    if [ "${_p1}" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        _INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _INIT_SYS="openrc"
    else
        die "不支持的 init 系统（PID1: ${_p1}，需要 systemd 或 OpenRC）"
    fi
    log_info "Init: ${_INIT_SYS}  PID1: ${_p1}"
}

is_systemd() { [ "${_INIT_SYS}" = "systemd" ]; }
is_openrc()  { [ "${_INIT_SYS}" = "openrc"  ]; }

_detect_arch() {
    [ -n "${_ARCH_XRAY:-}" ] && return 0
    case "$(uname -m)" in
        x86_64)        _ARCH_CF="amd64";  _ARCH_XRAY="64"        ;;
        x86|i686|i386) _ARCH_CF="386";    _ARCH_XRAY="32"        ;;
        aarch64|arm64) _ARCH_CF="arm64";  _ARCH_XRAY="arm64-v8a" ;;
        armv7l)        _ARCH_CF="armv7";  _ARCH_XRAY="arm32-v7a" ;;
        s390x)         _ARCH_CF="s390x";  _ARCH_XRAY="s390x"     ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

# ==============================================================================
# §5  系统工具函数
# ==============================================================================
check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    local _rc=0
    if   command -v apt-get >/dev/null 2>&1; then
        find /var/cache/apt/pkgcache.bin -mtime -1 >/dev/null 2>&1 \
            || DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v yum     >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v apk     >/dev/null 2>&1; then apk add       "${_pkg}" >/dev/null 2>&1; _rc=$?
    else die "未找到包管理器，无法安装 ${_pkg}"; fi
    hash -r 2>/dev/null || true
    [ "${_rc}" -ne 0 ] && die "${_pkg} 安装失败 (exit ${_rc})"
    command -v "${_bin}" >/dev/null 2>&1 || die "${_bin} 安装后仍不可用"
    log_ok "${_pkg} 已就绪"
}

preflight_check() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do pkg_require "${_d}"; done
    command -v xxd    >/dev/null 2>&1 || log_info "xxd 未安装 — Reality shortId 将由 openssl/od 生成"
    command -v openssl >/dev/null 2>&1 || log_info "openssl 未安装 — Reality shortId 将由 /dev/urandom 生成"
    [ -f "${XRAY_BIN}" ] && {
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已修复 xray 可执行位"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏，建议重新安装"
    }
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已修复 cloudflared 可执行位"; }
    log_ok "依赖预检通过"
}

port_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'; return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'; return
    fi
    local _h; _h=$(printf '%04X' "${_p}")
    awk -v h="${_h}" 'NR>1&&substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

_CACHED_REALIP=""
get_realip() {
    [ -n "${_CACHED_REALIP:-}" ] && { printf '%s' "${_CACHED_REALIP}"; return 0; }
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
    _CACHED_REALIP="${_result}"
    printf '%s' "${_CACHED_REALIP}"
}

urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;
         s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;
         s/\[/%5B/g;s/\]/%5D/g'
}

fix_time_sync() {
    [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || return 0
    local _pm; command -v dnf >/dev/null 2>&1 && _pm="dnf" || _pm="yum"
    log_step "RHEL 系：修正时间同步..."
    ${_pm} install -y chrony >/dev/null 2>&1 || true
    systemctl enable --now chronyd >/dev/null 2>&1 || true
    chronyc -a makestep >/dev/null 2>&1 || true
    ${_pm} update -y ca-certificates >/dev/null 2>&1 || true
    log_ok "时间同步已修正"
}

# ==============================================================================
# §6  防火墙管理
# ==============================================================================
_fw_open() {
    local _port="$1" _proto="${2:-tcp}" _any=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw status numbered 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+.*${_port}/${_proto}" \
            || { ufw allow "${_port}/${_proto}" >/dev/null 2>&1 && _any=1; }
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --query-port="${_port}/${_proto}" --permanent >/dev/null 2>&1 \
            || { firewall-cmd --permanent --add-port="${_port}/${_proto}" >/dev/null 2>&1 \
                 && firewall-cmd --reload >/dev/null 2>&1 && _any=1; }
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null \
            || { iptables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null && _any=1; }
        ip6tables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null \
            || ip6tables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || true
    fi
    [ "${_any}" -eq 1 ] && log_ok "防火墙已开放: ${_port}/${_proto}" \
                        || log_info "防火墙端口已存在: ${_port}/${_proto}"
}

_fw_close() {
    local _port="$1" _proto="${2:-tcp}"
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' \
        && ufw delete allow "${_port}/${_proto}" >/dev/null 2>&1 || true
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 \
        && { firewall-cmd --permanent --remove-port="${_port}/${_proto}" >/dev/null 2>&1 \
             && firewall-cmd --reload >/dev/null 2>&1 || true; }
    if command -v iptables >/dev/null 2>&1; then
        local _n=0
        while iptables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || break
            _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
        done
        _n=0
        while ip6tables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || break
            _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
        done
    fi
    log_info "防火墙已关闭: ${_port}/${_proto}"
}

# 计算当前配置应开放的端口列表
_fw_expected_ports() {
    [ "$(state_get '.reality.enabled')" = "true" ] && printf '%s\n' "$(state_get '.reality.port')"
    [ "$(state_get '.vltcp.enabled')"   = "true" ] && printf '%s\n' "$(state_get '.vltcp.port')"
    [ "$(state_get '.ff.enabled')"      = "true" ] \
        && [ "$(state_get '.ff.protocol')" != "none" ] && printf '8080\n'
}

firewall_sync() {
    log_step "同步防火墙规则..."
    mkdir -p "${WORK_DIR}"
    local _expected _managed _p
    _expected=$(_fw_expected_ports | sort -un)
    _managed=$(grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null | sort -un || true)

    for _p in ${_managed}; do
        printf '%s\n' ${_expected} | grep -qx "${_p}" || _fw_close "${_p}" tcp
    done
    for _p in ${_expected}; do
        _fw_open "${_p}" tcp
    done

    if [ -n "${_expected:-}" ]; then
        printf '%s\n' ${_expected} > "${_FW_PORTS_FILE}" 2>/dev/null || true
    else
        rm -f "${_FW_PORTS_FILE}" 2>/dev/null || true
    fi
}

_firewall_cleanup_all() {
    log_step "清理 xray2go 托管防火墙规则..."
    local _ports _p
    _ports=$(grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null || true)
    [ -f "${STATE_FILE}" ] && for _p in \
        "$(state_get '.argo.port'    2>/dev/null || true)" \
        "$(state_get '.reality.port' 2>/dev/null || true)" \
        "$(state_get '.vltcp.port'   2>/dev/null || true)"; do
        case "${_p:-}" in ''|null|*[!0-9]*) continue;; esac
        _ports=$(printf '%s\n%s' "${_ports}" "${_p}")
    done
    for _p in $(printf '%s\n' ${_ports} | grep -E '^[0-9]+$' | sort -un); do
        _fw_close "${_p}" tcp 2>/dev/null || true
    done
    rm -f "${_FW_PORTS_FILE}" 2>/dev/null || true
    log_ok "防火墙规则清理完成"
}

# ==============================================================================
# §7  状态管理
# ==============================================================================
_STATE=""

readonly _STATE_DEFAULT='{
  "uuid":    "",
  "argo":    {"enabled":true,  "protocol":"ws",   "port":8888,
              "mode":"fixed",  "domain":null,      "token":null},
  "ff":      {"enabled":false, "protocol":"none", "path":"/"},
  "reality": {"enabled":false, "port":443, "sni":"addons.mozilla.org",
              "network":"tcp", "pbk":null, "pvk":null, "sid":null},
  "vltcp":   {"enabled":false, "port":1234, "listen":"0.0.0.0"},
  "cfip":    "cf.tencentapp.cn",
  "cfport":  "443"
}'

state_get() {
    printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null || true
}

state_set() {
    local _f="$1"; shift
    local _n
    _n=$(printf '%s' "${_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_f}"; return 1; }
    [ -n "${_n:-}" ] && _STATE="${_n}" || { log_error "state_set 返回空 JSON"; return 1; }
}

state_persist() {
    mkdir -p "${WORK_DIR}"
    [ -f "${STATE_FILE}" ] && {
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${STATE_FILE}" "${STATE_FILE}.${_ts}.bak" 2>/dev/null || true
        ls -t "${STATE_FILE}".*.bak 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null || true
    }
    local _t; _t=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_t}" || { log_error "state 序列化失败"; return 1; }
    mv "${_t}" "${STATE_FILE}"
}

# 补全可能缺失的字段（兼容旧版 state.json）
_state_fill_defaults() {
    local _c
    _c=$(state_get '.vltcp')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } \
        && state_set '.vltcp = {"enabled":false,"port":1234,"listen":"0.0.0.0"}'
    _c=$(state_get '.reality.network')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && state_set '.reality.network = "tcp"'
    _c=$(state_get '.cfip')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && state_set '.cfip = "cf.tencentapp.cn"'
    _c=$(state_get '.cfport')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && state_set '.cfport = "443"'
}

state_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            _state_fill_defaults
            [ -z "$(state_get '.uuid')" ] \
                && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
            return 0
        fi
        log_warn "state.json 损坏，重置为默认值..."
    fi
    _STATE="${_STATE_DEFAULT}"
    state_set '.uuid = $u' --arg u "$(_gen_uuid)"
    [ -d "${WORK_DIR}" ] && { state_persist 2>/dev/null || true; }
}

# ==============================================================================
# §8  密钥生成
# ==============================================================================
_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0; printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8), substr(h,9,4), substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1), substr(h,18,3), substr(h,21,12)}'
}

_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，无法生成密钥对"; return 1; }
    local _out; _out=$("${XRAY_BIN}" x25519 2>&1) \
        || { log_error "xray x25519 失败"; return 1; }
    [ -z "${_out:-}" ] && { log_error "xray x25519 无输出"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')
    { [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ]; } && { log_error "密钥解析失败"; return 1; }
    printf '%s' "${_pvk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "私钥格式异常"; return 1; }
    printf '%s' "${_pbk}" | grep -qE '^[A-Za-z0-9_=-]{20,}$' || { log_error "公钥格式异常"; return 1; }
    state_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}" \
        || return 1
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

_gen_reality_sid() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    command -v xxd    >/dev/null 2>&1 \
        && { head -c 8 /dev/urandom 2>/dev/null | xxd -p | tr -d '\n'; return; }
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
# §9  协议入站配置生成
# ==============================================================================
_inbound_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || return 0
    local _port _uuid; _port=$(state_get '.argo.port'); _uuid=$(state_get '.uuid')
    case "$(state_get '.argo.protocol')" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", xhttpSettings:{path:"/argo", mode:"auto"}}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:"/argo"}}}' ;;
    esac
}

_inbound_ff() {
    [ "$(state_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(state_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _path _uuid; _path=$(state_get '.ff.path'); _uuid=$(state_get '.uuid')
    case "${_proto}" in
        ws)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws", wsSettings:{path:$path}}}' ;;
        httpupgrade)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"httpupgrade", httpupgradeSettings:{path:$path}}}' ;;
        xhttp)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", xhttpSettings:{path:$path, mode:"stream-one"}}}' ;;
        *) log_error "_inbound_ff: 未知协议 ${_proto}"; return 1 ;;
    esac
}

_inbound_reality() {
    [ "$(state_get '.reality.enabled')" = "true" ] || return 0
    local _pvk; _pvk=$(state_get '.reality.pvk')
    { [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; } \
        && { log_warn "Reality 密钥未就绪，已跳过该入站"; return 0; }
    local _port _sni _sid _net _uuid
    _port=$(state_get '.reality.port'); _sni=$(state_get '.reality.sni')
    _sid=$(state_get  '.reality.sid');  _net=$(state_get '.reality.network')
    _net="${_net:-tcp}";                _uuid=$(state_get '.uuid')
    case "${_net}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", security:"reality",
                    realitySettings:{dest:($sni+":443"), serverNames:[$sni],
                        privateKey:$pvk, shortIds:[$sid]},
                    xhttpSettings:{path:"/", mode:"auto"}}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid, flow:"xtls-rprx-vision"}], decryption:"none"},
                streamSettings:{network:"tcp", security:"reality",
                    realitySettings:{dest:($sni+":443"), serverNames:[$sni],
                        privateKey:$pvk, shortIds:[$sid]}}}' ;;
    esac
}

_inbound_vltcp() {
    [ "$(state_get '.vltcp.enabled')" = "true" ] || return 0
    local _port _listen _uuid
    _port=$(state_get '.vltcp.port'); _listen=$(state_get '.vltcp.listen')
    _uuid=$(state_get '.uuid')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"}}'
}

# ==============================================================================
# §10 节点链接生成与展示
# ==============================================================================
_link_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || return 0
    local _domain; _domain=$(state_get '.argo.domain')
    { [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; } || return 0
    local _uuid _cfip _cfport
    _uuid=$(state_get '.uuid'); _cfip=$(state_get '.cfip'); _cfport=$(state_get '.cfport')
    case "$(state_get '.argo.protocol')" in
        xhttp)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
    esac
}

_link_ff() {
    [ "$(state_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(state_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _ip; _ip=$(get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 0; }
    local _penc _uuid
    _penc=$(urlencode_path "$(state_get '.ff.path')"); _uuid=$(state_get '.uuid')
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        xhttp)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
    esac
}

_link_reality() {
    [ "$(state_get '.reality.enabled')" = "true" ] || return 0
    local _pbk; _pbk=$(state_get '.reality.pbk')
    { [ -n "${_pbk:-}" ] && [ "${_pbk}" != "null" ]; } || return 0
    local _ip; _ip=$(get_realip)
    [ -z "${_ip:-}" ] && { log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 0; }
    local _uuid _port _sni _sid _net
    _uuid=$(state_get '.uuid'); _port=$(state_get '.reality.port')
    _sni=$(state_get '.reality.sni'); _sid=$(state_get '.reality.sid')
    _net=$(state_get '.reality.network'); _net="${_net:-tcp}"
    case "${_net}" in
        xhttp)
            printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=auto#Reality-XHTTP\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_sni}" "${_pbk}" "${_sid}" ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                "${_uuid}" "${_ip}" "${_port}" "${_sni}" "${_pbk}" "${_sid}" ;;
    esac
}

_link_vltcp() {
    [ "$(state_get '.vltcp.enabled')" = "true" ] || return 0
    local _listen _host _uuid
    _listen=$(state_get '.vltcp.listen'); _uuid=$(state_get '.uuid')
    case "${_listen}" in
        0.0.0.0|::) _host=$(get_realip) ;;
        *)           _host="${_listen}"  ;;
    esac
    [ -z "${_host:-}" ] && { log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"; return 0; }
    printf 'vless://%s@%s:%s?type=tcp&security=none#VLESS-TCP\n' \
        "${_uuid}" "${_host}" "$(state_get '.vltcp.port')"
}

print_nodes() {
    echo ""
    local _links
    _links=$( _link_argo; _link_ff; _link_reality; _link_vltcp )
    if [ -z "${_links:-}" ]; then
        log_warn "暂无可用节点（请检查 Argo 域名或服务器 IP）"; return 1
    fi
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        [ -n "${_l:-}" ] && printf "${C_CYN}%s${C_RST}\n" "${_l}"
    done
    echo ""
}

# ==============================================================================
# §11 配置合成
# ==============================================================================
config_synthesize() {
    local _ibs="[]" _used_keys="" _ib _p _l _key

    _append_inbound() {
        local _name="$1" _fn="$2"
        _ib=$("${_fn}") || { log_error "协议 ${_name} 配置生成失败"; return 1; }
        [ -n "${_ib:-}" ] || return 0
        _p=$(printf '%s' "${_ib}" | jq -r '.port // empty')
        _l=$(printf '%s' "${_ib}" | jq -r '.listen // "0.0.0.0"')
        _key="${_l}:${_p}"
        if printf '%s\n' ${_used_keys} | grep -qxF "${_key}"; then
            log_error "端口冲突: ${_key} 已被占用，跳过 [${_name}]，请修改端口后重新应用"
            return 0
        fi
        _used_keys="${_used_keys} ${_key}"
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]') \
            || { log_error "inbounds 组装失败 (${_name})"; return 1; }
    }

    _append_inbound "argo"    _inbound_argo    || return 1
    _append_inbound "ff"      _inbound_ff      || return 1
    _append_inbound "reality" _inbound_reality || return 1
    _append_inbound "vltcp"   _inbound_vltcp   || return 1

    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] \
        && log_warn "所有入站均已禁用，xray 将以零入站模式运行"

    jq -n --argjson inbounds "${_ibs}" '{
        log:      {loglevel:"none", access:"none", error:"none"},
        inbounds: $inbounds,
        outbounds:[{protocol:"freedom", settings:{domainStrategy:"AsIs"}}],
        policy:   {
            levels:{"0":{connIdle:300, uplinkOnly:1, downlinkOnly:1,
                         statsUserUplink:false, statsUserDownlink:false}},
            system:{statsInboundUplink:false, statsInboundDownlink:false}
        }
    }' || { log_error "config JSON 合成失败"; return 1; }
}

# ==============================================================================
# §12 服务管理
# ==============================================================================
_SYSD_DIRTY=0

exec_svc() {
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

exec_svc_reload() {
    is_systemd && [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

# 写入服务文件，内容有变化时返回非零（触发 daemon-reload）
_svc_write() {
    local _dest="$1" _content="$2"
    [ "$(cat "${_dest}" 2>/dev/null)" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"; return 1
}

_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray2go Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=always\nRestartSec=3\nRestartPreventExitStatus=23\nLimitNOFILE=1048576\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_tpl_tunnel_systemd() {
    printf '[Unit]\nDescription=Cloudflare Tunnel2go\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=%s\nRestart=on-failure\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
        "$1"
}

_tpl_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray2go service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\noutput_log="/dev/null"\nerror_log="/dev/null"\npidfile="/var/run/xray2go.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

_tpl_tunnel_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go"\ncommand="/bin/sh"\ncommand_args="-c '"'"'%s >/dev/null 2>&1'"'"'"\ncommand_background=true\npidfile="/var/run/tunnel2go.pid"\n' \
        "$1"
}

apply_xray_service() {
    if is_systemd; then
        _svc_write "/etc/systemd/system/${_SVC_XRAY}.service" "$(_tpl_xray_systemd)" \
            || _SYSD_DIRTY=1
    else
        local _f="/etc/init.d/${_SVC_XRAY}"
        _svc_write "${_f}" "$(_tpl_xray_openrc)" || chmod +x "${_f}"
    fi
}

apply_tunnel_service() {
    local _cmd; _cmd=$(_build_tunnel_cmd)
    if is_systemd; then
        _svc_write "/etc/systemd/system/${_SVC_TUNNEL}.service" \
            "$(_tpl_tunnel_systemd "${_cmd}")" || _SYSD_DIRTY=1
    else
        local _f="/etc/init.d/${_SVC_TUNNEL}"
        _svc_write "${_f}" "$(_tpl_tunnel_openrc "${_cmd}")" || chmod +x "${_f}"
    fi
}

_remove_svc_files() {
    if is_systemd; then
        rm -f "/etc/systemd/system/${_SVC_XRAY}.service" \
              "/etc/systemd/system/${_SVC_TUNNEL}.service" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f "/etc/init.d/${_SVC_XRAY}" "/etc/init.d/${_SVC_TUNNEL}" 2>/dev/null || true
    fi
}

# ==============================================================================
# §13 下载
# ==============================================================================
_xray_health_check() {
    local _bin="${1:-${XRAY_BIN}}"
    [ -f "${_bin}" ] && [ -x "${_bin}" ] || return 1
    "${_bin}" version >/dev/null 2>&1 || return 1
    local _tc; _tc=$(_tmp_file "hc_XXXXXX.json") || return 1
    printf '{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' > "${_tc}"
    "${_bin}" -test -c "${_tc}" >/dev/null 2>&1; local _rc=$?
    rm -f "${_tc}" 2>/dev/null || true
    return "${_rc}"
}

_xray_latest_tag() {
    curl -sfL --max-time 10 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true
}

download_xray() {
    _detect_arch
    if _xray_health_check "${XRAY_BIN}" 2>/dev/null; then
        local _v; _v=$("${XRAY_BIN}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "xray 已存在且健康 (v${_v:-unknown})，跳过下载"; return 0
    fi
    log_info "重新下载 xray..."; rm -f "${XRAY_BIN}" 2>/dev/null || true

    local _tag; _tag=$(_xray_latest_tag)
    [ -z "${_tag:-}" ] && { log_warn "无法获取版本号，使用 latest"; _tag="latest"; }

    local _zip="Xray-linux-${_ARCH_XRAY}.zip"
    local _z; _z=$(_tmp_file "xray_XXXXXX.zip") || return 1

    local _mirror _ok=0
    for _mirror in "${_XRAY_MIRRORS[@]}"; do
        log_step "下载 ${_zip} ..."
        curl -sfL --connect-timeout 15 --max-time 120 \
            -o "${_z}" "${_mirror}/${_tag}/${_zip}" && [ -s "${_z}" ] \
            && { _ok=1; break; }
        log_warn "镜像失败，尝试下一个..."; rm -f "${_z}" 2>/dev/null || true
    done
    [ "${_ok}" -eq 1 ] || { log_error "所有镜像均下载失败"; return 1; }

    if [ "${_tag}" != "latest" ] && command -v sha256sum >/dev/null 2>&1; then
        log_step "校验 SHA256..."
        local _dgst _expected _actual
        _dgst=$(curl -sfL --max-time 15 \
            "https://github.com/XTLS/Xray-core/releases/download/${_tag}/${_zip}.dgst" \
            2>/dev/null) || true
        _expected=$(printf '%s' "${_dgst:-}" | grep -i 'SHA2-256' | awk '{print $NF}' | head -1 | tr -d '[:space:]')
        if [ -n "${_expected:-}" ]; then
            _actual=$(sha256sum "${_z}" | awk '{print $1}')
            [ "${_actual}" = "${_expected}" ] \
                && log_ok "SHA256 校验通过" \
                || { log_error "SHA256 校验失败"; rm -f "${_z}"; return 1; }
        else
            log_warn "未获取到校验值，跳过 SHA256"
        fi
    fi

    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "zip 文件损坏"; rm -f "${_z}"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 || { log_error "解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"

    _xray_health_check "${XRAY_BIN}" \
        || { log_error "xray 健康检查失败，已清除"; rm -f "${XRAY_BIN}"; return 1; }
    log_ok "Xray 安装完成 ($("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}'))"
}

download_cloudflared() {
    _detect_arch
    if [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; then
        log_info "cloudflared 已存在，跳过下载"; return 0
    fi
    rm -f "${ARGO_BIN}" 2>/dev/null || true
    local _url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    log_step "下载 cloudflared (${_ARCH_CF}) ..."
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${_url}" \
        && [ -s "${ARGO_BIN}" ] \
        || { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    chmod +x "${ARGO_BIN}"
    log_ok "cloudflared 下载完成"
}

# ==============================================================================
# §14 配置原子提交
# ==============================================================================
apply_config() {
    local _t; _t=$(_tmp_file "cfg_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    config_synthesize > "${_t}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            log_error "config 验证失败！现场: ${WORK_DIR}/config_failed.json"
            mv "${_t}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
    else
        log_warn "xray 未就绪，跳过预检"
    fi

    mkdir -p "${WORK_DIR}"
    [ -f "${CONFIG_FILE}" ] && {
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${CONFIG_FILE}" "${CONFIG_FILE}.${_ts}.bak" 2>/dev/null || true
        ls -t "${CONFIG_FILE}".*.bak 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null || true
    }

    mv "${_t}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已更新"

    exec_svc status "${_SVC_XRAY}" >/dev/null 2>&1 && {
        exec_svc restart "${_SVC_XRAY}" || { log_error "xray2go 重启失败"; return 1; }
        log_ok "xray2go 已重启"
    }
}

# ==============================================================================
# §15 安装与卸载
# ==============================================================================

# 端口冲突检测，将占用的端口自动随机替换
_check_port_conflicts() {
    log_step "检测端口冲突..."
    _rand_free_port() {
        local _i=0 _p
        while true; do
            _p=$(shuf -i 10000-60000 -n 1 2>/dev/null \
                 || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
            port_in_use "${_p}" || { printf '%s' "${_p}"; return 0; }
            _i=$(( _i + 1 )); [ "${_i}" -gt 30 ] \
                && { log_error "无法找到空闲端口"; return 1; }
        done
    }
    local _path _cur _new
    for _path in '.argo.port' '.reality.port' '.vltcp.port'; do
        case "${_path}" in
            '.argo.port')    [ "$(state_get '.argo.enabled')"    = "true" ] || continue ;;
            '.reality.port') [ "$(state_get '.reality.enabled')" = "true" ] || continue ;;
            '.vltcp.port')   [ "$(state_get '.vltcp.enabled')"   = "true" ] || continue ;;
        esac
        _cur=$(state_get "${_path}")
        if port_in_use "${_cur}"; then
            _new=$(_rand_free_port) || return 1
            state_set "${_path} = (\$p|tonumber)" --arg p "${_new}" || return 1
            log_ok "端口 ${_cur} 已占用，自动分配: ${_new}"
        fi
    done
    [ "$(state_get '.ff.enabled')" = "true" ] \
        && [ "$(state_get '.ff.protocol')" != "none" ] \
        && port_in_use 8080 \
        && log_warn "FreeFlow 端口 8080 已被占用（固定端口），可能无法正常使用"
    return 0
}

# 检测系统是否已有独立 xray 进程（仅用于提示）
_detect_existing_xray() {
    command -v systemctl >/dev/null 2>&1 \
        && systemctl list-unit-files 2>/dev/null | grep -qiE '^xray[^2]' && return 0
    [ -f /etc/init.d/xray ] && return 0
    local _wx; _wx=$(command -v xray 2>/dev/null || true)
    { [ -n "${_wx:-}" ] && [ "${_wx}" != "${XRAY_BIN}" ]; } && return 0
    pgrep -x xray >/dev/null 2>&1 && return 0
    return 1
}

_verify_service_health() {
    local _svc="${1:-${_SVC_XRAY}}" _max="${2:-8}"
    log_step "验证 ${_svc} 就绪（最长 ${_max}s）..."
    local _i=0
    while [ "${_i}" -lt "${_max}" ]; do
        sleep 1; _i=$(( _i + 1 ))
        exec_svc status "${_svc}" >/dev/null 2>&1 \
            && { log_ok "${_svc} 已就绪 (${_i}s)"; return 0; }
    done
    log_error "${_svc} 启动失败（${_max}s 超时）"
    is_systemd && {
        journalctl -u "${_svc}" --no-pager -n 20 2>/dev/null >&2 || true
        systemctl status "${_svc}" --no-pager -l 2>/dev/null >&2 || true
    } || log_error "请手动执行: rc-service ${_svc} status"
    return 1
}

# 安装失败时的回滚清理，接收安装前 xray/argo 是否存在的标志
_install_rollback() {
    local _had_xray="$1" _had_argo="$2"
    log_warn "安装中断，回滚..."
    [ "${_had_xray}" -eq 0 ] && rm -f "${XRAY_BIN}" 2>/dev/null || true
    [ "${_had_argo}" -eq 0 ] && rm -f "${ARGO_BIN}" 2>/dev/null || true
    rm -f "${CONFIG_FILE}" 2>/dev/null || true
    _remove_svc_files
}

exec_install_core() {
    clear; log_title "══════════ 安装 Xray-2go v8.3 ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    _detect_existing_xray && {
        log_warn "检测到系统已存在 xray 相关组件"
        log_warn "本脚本以隔离模式运行（服务名: ${_SVC_XRAY}，目录: ${WORK_DIR}）"
    }

    _check_port_conflicts || { log_error "端口冲突无法解决，安装中止"; return 1; }

    local _had_xray=0 _had_argo=0
    { [ -f "${XRAY_BIN}" ] && [ -x "${XRAY_BIN}" ]; } && _had_xray=1
    { [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; } && _had_argo=1

    download_xray        || { _install_rollback "${_had_xray}" "${_had_argo}"; return 1; }
    [ "$(state_get '.argo.enabled')" = "true" ] && {
        download_cloudflared || { _install_rollback "${_had_xray}" "${_had_argo}"; return 1; }
    }

    [ "$(state_get '.reality.enabled')" = "true" ] && {
        log_step "生成 Reality x25519 密钥对..."
        _gen_reality_keypair || { _install_rollback "${_had_xray}" "${_had_argo}"; return 1; }
        state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)"
    }

    apply_config || { _install_rollback "${_had_xray}" "${_had_argo}"; return 1; }

    apply_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && apply_tunnel_service
    exec_svc_reload

    is_openrc && {
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    }

    fix_time_sync
    firewall_sync

    log_step "启动服务..."
    exec_svc enable "${_SVC_XRAY}"
    exec_svc start  "${_SVC_XRAY}" \
        || { log_error "启动失败"; _install_rollback "${_had_xray}" "${_had_argo}"; return 1; }

    _verify_service_health "${_SVC_XRAY}" 8 || {
        log_error "${_SVC_XRAY} 未正常运行，安装回滚"
        exec_svc stop "${_SVC_XRAY}" 2>/dev/null || true
        _install_rollback "${_had_xray}" "${_had_argo}"
        return 1
    }

    [ "$(state_get '.argo.enabled')" = "true" ] && {
        exec_svc enable "${_SVC_TUNNEL}"
        exec_svc start  "${_SVC_TUNNEL}" \
            && log_ok "${_SVC_TUNNEL} 已启动" \
            || log_error "tunnel 启动失败（不影响 xray）"
    }

    # 网络性能调优（外部脚本，可选）
    echo ""
    log_step "网络性能调优"
    printf "是否立即运行 Eric86777 的网络调优脚本？(推荐 Y) [Y/n]: "
    read -r _tune_choice </dev/tty
    case "${_tune_choice:-y}" in
        [yY]) log_info "下载并执行 net-tcp-tune.sh ..."
              bash <(curl -fsSL "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/net-tcp-tune.sh?$(date +%s)") ;;
        *)    log_info "已跳过，可后续手动执行" ;;
    esac

    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

exec_uninstall() {
    local _a; prompt "确定要卸载 xray2go？(y/N): " _a
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return;; esac
    log_step "卸载中..."

    for _s in "${_SVC_XRAY}" "${_SVC_TUNNEL}"; do
        exec_svc stop    "${_s}" 2>/dev/null || true
        exec_svc disable "${_s}" 2>/dev/null || true
    done

    _firewall_cleanup_all
    rm -f "${WORK_DIR}/xray.pid" /var/run/xray2go.pid /var/run/tunnel2go.pid 2>/dev/null || true
    _remove_svc_files

    rm -rf "${WORK_DIR}" 2>/dev/null || true
    [ -d "${WORK_DIR}" ] \
        && log_warn "${WORK_DIR} 未能完全删除，请手动: rm -rf ${WORK_DIR}" \
        || log_ok "${WORK_DIR} 已清除"

    rm -f "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    log_ok "xray2go 卸载完成"
}

# ==============================================================================
# §16 Argo 固定隧道
# ==============================================================================
_build_tunnel_cmd() {
    if [ -f "${WORK_DIR}/tunnel.yml" ]; then
        printf '%s tunnel --no-autoupdate run --config %s' "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
    else
        printf '%s tunnel --no-autoupdate run --token %s' "${ARGO_BIN}" "$(state_get '.argo.token')"
    fi
}

_gen_argo_yml() {
    local _domain="$1" _tid="$2" _cred="$3" _port
    _port=$(state_get '.argo.port')
    {
        printf 'tunnel: %s\n' "${_tid}"
        printf 'credentials-file: %s\n' "${_cred}"
        printf '\ningress:\n'
        printf '  - hostname: %s\n    service: http://localhost:%s\n' "${_domain}" "${_port}"
        printf '    originRequest:\n      connectTimeout: 30s\n      noTLSVerify: true\n'
        printf '  - service: http_status:404\n'
    } > "${WORK_DIR}/tunnel.yml" || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (${_domain} → localhost:${_port})"
}

apply_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(state_get '.argo.protocol')  端口: $(state_get '.argo.port')"
    echo ""
    local _domain; prompt "请输入 Argo 域名: " _domain
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*) log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    local _auth; prompt "请输入 Argo 密钥 (token 或 JSON): " _auth
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
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*) log_error "TunnelID 含非法字符"; return 1;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        printf '%s' "${_auth}" > "${_cred}"
        _gen_argo_yml "${_domain}" "${_tid}" "${_cred}" || return 1
        state_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        state_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    apply_tunnel_service; exec_svc_reload
    exec_svc enable "${_SVC_TUNNEL}" 2>/dev/null || true
    apply_config  || return 1
    state_persist || log_warn "state.json 写入失败"
    exec_svc restart "${_SVC_TUNNEL}" || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (${_domain})"
    check_argo_health || true
}

check_argo_health() {
    local _domain; _domain=$(state_get '.argo.domain')
    { [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; } || return 0
    log_step "Argo 健康检查（最长 15s）..."
    local _i
    for _i in 3 6 9 12 15; do
        sleep "${_i}" 2>/dev/null || sleep 3
        local _code
        _code=$(curl -sfL --max-time 5 --connect-timeout 3 \
            -o /dev/null -w '%{http_code}' "https://${_domain}/" 2>/dev/null) || true
        case "${_code:-000}" in
            [2345]??) log_ok "Argo 隧道连通 (HTTP ${_code})"; return 0 ;;
        esac
        [ "${_i}" -lt 15 ] && printf '\r  等待中... (%ss)' "${_i}" >&2
    done
    printf '\n' >&2
    log_warn "健康检查超时，请稍后通过 [3. Argo 管理] 确认"
    return 1
}

# ==============================================================================
# §17 UUID 更新与脚本自更新
# ==============================================================================
exec_update_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(_gen_uuid) && log_info "已生成 UUID: ${_v}" \
            || { log_error "UUID 生成失败"; return 1; }
    fi
    printf '%s' "${_v}" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }
    state_set '.uuid = $u' --arg u "${_v}" || return 1
    apply_config  || return 1
    state_persist || log_warn "state.json 写入失败"
    log_ok "UUID 已更新: ${_v}"; print_nodes
}

exec_install_shortcut() {
    log_step "拉取最新脚本..."
    local _t; _t=$(_tmp_file "xray2go_XXXXXX.sh") || return 1
    curl -sfL --connect-timeout 15 --max-time 60 -o "${_t}" "${UPSTREAM_URL}" \
        || { log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${_t}" 2>/dev/null || { log_error "脚本语法验证失败"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${_t}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}" && chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${C_GRN}s${C_RST} 快速启动"
}

# ==============================================================================
# §18 管理菜单公共辅助
# ==============================================================================
_input_port() {
    local _jq_path="$1" _p
    prompt "新端口（回车随机）: " _p
    [ -z "${_p:-}" ] && _p=$(shuf -i 1024-65000 -n 1 2>/dev/null \
                              || awk 'BEGIN{srand();print int(rand()*63976)+1024}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } || { log_error "端口超范围"; return 1; }
    port_in_use "${_p}" && {
        log_warn "端口 ${_p} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) :;; *) return 1;; esac
    }
    state_set "${_jq_path} = (\$p|tonumber)" --arg p "${_p}" || return 1
    printf '%s' "${_p}"
}

_restart_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在，请先安装"; return 1; }
    exec_svc restart "${_SVC_XRAY}" \
        && { log_ok "${_SVC_XRAY} 已重启"; _verify_service_health "${_SVC_XRAY}" 6; } \
        || log_error "${_SVC_XRAY} 重启失败"
}

_confirm_remove() {
    local _name="$1" _a
    prompt "确定要卸载 ${_name}？(y/N): " _a
    case "${_a:-n}" in y|Y) return 0;; *) return 1;; esac
}

# ==============================================================================
# §19 协议管理子菜单
# ==============================================================================

# ── Argo 管理 ─────────────────────────────────────────────────────────────────
manage_argo() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成安装"; sleep 1; return; }
    while true; do
        local _en _proto _port _domain _svc_st
        _en=$(state_get '.argo.enabled'); _proto=$(state_get '.argo.protocol')
        _port=$(state_get '.argo.port');  _domain=$(state_get '.argo.domain')
        exec_svc status "${_SVC_TUNNEL}" >/dev/null 2>&1 && _svc_st="running" || _svc_st="stopped"

        clear; echo ""; log_title "══ Argo 固定隧道管理 ══"
        if [ "${_en}" = "true" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_svc_st}"
            printf "  协议: ${C_CYN}%s${C_RST}  回源端口: ${C_YLW}%s${C_RST}\n" "${_proto}" "${_port}"
            { [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; } \
                && printf "  域名: ${C_GRN}%s${C_RST}\n" "${_domain}" \
                || printf "  域名: ${C_YLW}未配置（请选项 4 配置）${C_RST}\n"
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Argo\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Argo\n"
        printf "  ${C_GRN}3.${C_RST} 重启隧道服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Argo\n"; _hr
        printf "  ${C_GRN}4.${C_RST} 配置/更新固定隧道域名\n"
        printf "  ${C_GRN}5.${C_RST} 切换协议 (WS ↔ XHTTP)\n"
        printf "  ${C_GRN}6.${C_RST} 修改回源端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}7.${C_RST} 查看节点链接\n"
        printf "  ${C_GRN}8.${C_RST} 健康检查\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)  if [ "${_en}" = "true" ]; then log_info "Argo 已处于启用状态"; _pause; continue; fi
                { [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; } \
                    || { log_step "下载 cloudflared..."; download_cloudflared || { _pause; continue; }; }
                state_set '.argo.enabled = true' || { _pause; continue; }
                apply_config || { state_set '.argo.enabled = false'; _pause; continue; }
                apply_tunnel_service; exec_svc_reload
                exec_svc enable "${_SVC_TUNNEL}"
                exec_svc start  "${_SVC_TUNNEL}" \
                    && log_ok "Argo 已启用并启动" \
                    || log_warn "Argo 启用成功，但服务启动失败，请检查域名配置"
                state_persist || log_warn "state.json 写入失败" ;;
            2)  if [ "${_en}" != "true" ]; then log_info "Argo 已处于禁用状态"; _pause; continue; fi
                exec_svc stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                exec_svc disable "${_SVC_TUNNEL}" 2>/dev/null || true
                state_set '.argo.enabled = false' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "Argo 已禁用（配置保留，可随时重新启用）" ;;
            3)  if [ "${_en}" != "true" ]; then log_warn "Argo 未启用"; _pause; continue; fi
                exec_svc restart "${_SVC_TUNNEL}" \
                    && { log_ok "${_SVC_TUNNEL} 已重启"; _verify_service_health "${_SVC_TUNNEL}" 6; } \
                    || log_error "${_SVC_TUNNEL} 重启失败" ;;
            9)  _confirm_remove "Argo" || { _pause; continue; }
                exec_svc stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                exec_svc disable "${_SVC_TUNNEL}" 2>/dev/null || true
                is_systemd \
                    && { rm -f "/etc/systemd/system/${_SVC_TUNNEL}.service" 2>/dev/null || true
                         systemctl daemon-reload >/dev/null 2>&1 || true; } \
                    || rm -f "/etc/init.d/${_SVC_TUNNEL}" 2>/dev/null || true
                rm -f "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json" 2>/dev/null || true
                state_set '.argo.enabled = false | .argo.domain = null | .argo.token = null | .argo.mode = "fixed"' \
                    || true
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "Argo 已卸载"; _pause; return ;;
            4)  if [ "${_en}" != "true" ]; then log_warn "请先选项 1 启用 Argo"; _pause; continue; fi
                echo ""
                printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[当前: ${_proto}]${C_RST}  ${C_GRN}2.${C_RST} XHTTP\n"
                local _pp; prompt "协议 (回车维持): " _pp
                case "${_pp:-}" in
                    1) state_set '.argo.protocol = "ws"';;
                    2) state_set '.argo.protocol = "xhttp"';;
                esac
                apply_fixed_tunnel && print_nodes || log_error "固定隧道配置失败" ;;
            5)  if [ "${_en}" != "true" ]; then log_warn "请先选项 1 启用 Argo"; _pause; continue; fi
                local _np; [ "${_proto}" = "ws" ] && _np="xhttp" || _np="ws"
                state_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                apply_config && state_persist \
                    && { log_ok "协议已切换: ${_np}"; print_nodes; } \
                    || { log_error "切换失败，回滚"; state_set '.argo.protocol = $p' --arg p "${_proto}"; } ;;
            6)  local _p
                prompt "新回源端口（回车随机）: " _p
                [ -z "${_p:-}" ] && _p=$(shuf -i 2000-65000 -n 1 2>/dev/null \
                                         || awk 'BEGIN{srand();print int(rand()*63000)+2000}')
                case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; _pause; continue;; esac
                { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } \
                    || { log_error "端口超范围"; _pause; continue; }
                state_set '.argo.port = ($p|tonumber)' --arg p "${_p}" || { _pause; continue; }
                apply_config || { _pause; continue; }
                apply_tunnel_service; exec_svc_reload
                exec_svc restart "${_SVC_TUNNEL}" || log_warn "tunnel 重启失败，请手动重启"
                state_persist || log_warn "state.json 写入失败"
                log_ok "回源端口已更新: ${_p}"; print_nodes ;;
            7)  print_nodes ;;
            8)  check_argo_health || true ;;
            0)  return ;;
            *)  log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── FreeFlow 管理 ─────────────────────────────────────────────────────────────
manage_freeflow() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成安装"; sleep 1; return; }
    while true; do
        local _en _proto _path _xstat
        _en=$(state_get '.ff.enabled'); _proto=$(state_get '.ff.protocol')
        _path=$(state_get '.ff.path')
        exec_svc status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        [ "${_en}" = "true" ] && [ "${_proto}" != "none" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n  协议: ${C_CYN}%s${C_RST}  path: ${C_YLW}%s${C_RST}  端口: 8080\n" "${_xstat}" "${_proto}" "${_path}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 FreeFlow\n"
        printf "  ${C_RED}2.${C_RST} 禁用 FreeFlow\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 FreeFlow\n"; _hr
        printf "  ${C_GRN}4.${C_RST} 变更传输协议\n"
        printf "  ${C_GRN}5.${C_RST} 修改 path（当前: ${C_YLW}${_path}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)  if [ "${_en}" = "true" ] && [ "${_proto}" != "none" ]; then
                    log_info "FreeFlow 已处于启用状态"; _pause; continue
                fi
                _ask_ff_proto || { _pause; continue; }
                [ "$(state_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "FreeFlow 已启用"; print_nodes ;;
            2)  if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_info "FreeFlow 已处于禁用状态"; _pause; continue
                fi
                state_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "FreeFlow 已禁用（path 配置保留）" ;;
            3)  _restart_xray || true ;;
            9)  _confirm_remove "FreeFlow" || { _pause; continue; }
                state_set '.ff.enabled = false | .ff.protocol = "none" | .ff.path = "/"' \
                    || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "FreeFlow 已卸载"; _pause; return ;;
            4)  _ask_ff_proto || { _pause; continue; }
                [ "$(state_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "FreeFlow 协议已变更"; print_nodes ;;
            5)  if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_warn "请先选项 1 启用 FreeFlow"; _pause; continue
                fi
                local _p; prompt "新 path（回车保持 ${_path}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) :;; *) _p="/${_p}";; esac
                    state_set '.ff.path = $p' --arg p "${_p}" || { _pause; continue; }
                    apply_config  || { _pause; continue; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "path 已更新: ${_p}"; print_nodes
                fi ;;
            6)  print_nodes ;;
            0)  return ;;
            *)  log_error "无效选项" ;;
        esac
        _pause
    done
}

# FreeFlow 协议选择（供安装向导和管理菜单复用）
_ask_ff_proto() {
    printf "  ${C_GRN}1.${C_RST} WS  ${C_GRN}2.${C_RST} HTTPUpgrade  ${C_GRN}3.${C_RST} XHTTP  ${C_GRN}4.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-4，回车默认4): " _c
    case "${_c:-4}" in
        1) state_set '.ff.enabled = true | .ff.protocol = "ws"';;
        2) state_set '.ff.enabled = true | .ff.protocol = "httpupgrade"';;
        3) state_set '.ff.enabled = true | .ff.protocol = "xhttp"';;
        *) state_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; return 0;;
    esac
    port_in_use 8080 && log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    local _p; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) :;; *) _p="/${_p}";; esac
    state_set '.ff.path = $p' --arg p "${_p:-/}"
    log_info "已选: $(state_get '.ff.protocol')（path=${_p:-/}）"
}

# ── Reality 管理 ──────────────────────────────────────────────────────────────
manage_reality() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成安装"; sleep 1; return; }
    while true; do
        local _en _port _sni _pbk _pvk _sid _net _xstat
        _en=$(  state_get '.reality.enabled'); _port=$(state_get '.reality.port')
        _sni=$( state_get '.reality.sni');     _pbk=$( state_get '.reality.pbk')
        _pvk=$( state_get '.reality.pvk');     _sid=$( state_get '.reality.sid')
        _net=$( state_get '.reality.network'); _net="${_net:-tcp}"
        exec_svc status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"
        local _pbk_disp="未生成"
        { [ -n "${_pbk:-}" ] && [ "${_pbk}" != "null" ]; } && _pbk_disp="${_pbk:0:16}..."

        clear; echo ""; log_title "══ Reality 管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  SNI: ${C_CYN}%s${C_RST}  传输: ${C_GRN}%s${C_RST}\n" \
            "${_port}" "${_sni}" "${_net}"
        printf "  公钥: %s\n" "${_pbk_disp}"
        { [ -n "${_sid:-}" ] && [ "${_sid}" != "null" ]; } \
            && printf "  ShortId: ${C_CYN}%s${C_RST}\n" "${_sid}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Reality\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Reality\n"; _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改 SNI（当前: ${C_CYN}${_sni}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 切换传输方式（当前: ${C_GRN}${_net}${C_RST}）\n"
        printf "  ${C_GRN}7.${C_RST} 重新生成密钥对\n"
        printf "  ${C_GRN}8.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)  if [ "${_en}" = "true" ]; then log_info "Reality 已处于启用状态"; _pause; continue; fi
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
                    log_step "生成 x25519 密钥对..."
                    _gen_reality_keypair || { _pause; continue; }
                    state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || true
                fi
                state_set '.reality.enabled = true' || { _pause; continue; }
                apply_config || { state_set '.reality.enabled = false'; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "Reality 已启用"; print_nodes ;;
            2)  if [ "${_en}" != "true" ]; then log_info "Reality 已处于禁用状态"; _pause; continue; fi
                state_set '.reality.enabled = false' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "Reality 已禁用（配置保留）" ;;
            3)  _restart_xray || true ;;
            9)  _confirm_remove "Reality" || { _pause; continue; }
                state_set '.reality.enabled = false | .reality.pbk = null | .reality.pvk = null | .reality.sid = null' \
                    || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "Reality 已卸载（密钥已清除）"; _pause; return ;;
            4)  local _np; _np=$(_input_port '.reality.port') || { _pause; continue; }
                [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "端口已更新: ${_np}"
                [ "${_en}" = "true" ] && print_nodes ;;
            5)  log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _s; prompt "新 SNI（回车保持 ${_sni}）: " _s
                if [ -n "${_s:-}" ]; then
                    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    state_set '.reality.sni = $s' --arg s "${_s}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_s}"; [ "${_en}" = "true" ] && print_nodes
                fi ;;
            6)  local _nn; [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
                state_set '.reality.network = $n' --arg n "${_nn}" || { _pause; continue; }
                [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "传输方式已切换: ${_nn}"; [ "${_en}" = "true" ] && print_nodes ;;
            7)  [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                _gen_reality_keypair || { _pause; continue; }
                state_set '.reality.sid = $s' --arg s "$(_gen_reality_sid)" || { _pause; continue; }
                [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "密钥对已更新"; [ "${_en}" = "true" ] && print_nodes ;;
            8)  print_nodes ;;
            0)  return ;;
            *)  log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── VLESS-TCP 管理 ────────────────────────────────────────────────────────────
manage_vltcp() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成安装"; sleep 1; return; }
    while true; do
        local _en _port _listen _xstat
        _en=$(state_get '.vltcp.enabled'); _port=$(state_get '.vltcp.port')
        _listen=$(state_get '.vltcp.listen')
        exec_svc status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ VLESS-TCP 明文落地管理 ══"
        [ "${_en}" = "true" ] \
            && printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}" \
            || printf "  模块: ${C_YLW}未启用${C_RST}\n"
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
        printf "  ${C_RED}2.${C_RST} 禁用 VLESS-TCP\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 VLESS-TCP\n"; _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改监听地址（当前: ${C_CYN}${_listen}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)  if [ "${_en}" = "true" ]; then log_info "VLESS-TCP 已处于启用状态"; _pause; continue; fi
                state_set '.vltcp.enabled = true' || { _pause; continue; }
                apply_config || { state_set '.vltcp.enabled = false'; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "VLESS-TCP 已启用 (端口: ${_port})"; print_nodes ;;
            2)  if [ "${_en}" != "true" ]; then log_info "VLESS-TCP 已处于禁用状态"; _pause; continue; fi
                state_set '.vltcp.enabled = false' || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "VLESS-TCP 已禁用（配置保留）" ;;
            3)  _restart_xray || true ;;
            9)  _confirm_remove "VLESS-TCP" || { _pause; continue; }
                state_set '.vltcp.enabled = false | .vltcp.port = 1234 | .vltcp.listen = "0.0.0.0"' \
                    || { _pause; continue; }
                apply_config  || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "VLESS-TCP 已卸载"; _pause; return ;;
            4)  local _np; _np=$(_input_port '.vltcp.port') || { _pause; continue; }
                [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                state_persist || log_warn "state.json 写入失败"
                firewall_sync; log_ok "端口已更新: ${_np}"
                [ "${_en}" = "true" ] && print_nodes ;;
            5)  local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    state_set '.vltcp.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { apply_config || { _pause; continue; }; }
                    state_persist || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_l}"; [ "${_en}" = "true" ] && print_nodes
                fi ;;
            6)  print_nodes ;;
            0)  return ;;
            *)  log_error "无效选项" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §20 主菜单
# ==============================================================================

# 状态检查辅助（返回字符串，通过 $? 报告是否 running）
_xray_status()  {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    exec_svc status "${_SVC_XRAY}" && printf 'running' || printf 'stopped'
}

_argo_status() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { printf '未启用'; return 3; }
    [ -f "${ARGO_BIN}" ] || { printf 'not installed'; return 2; }
    exec_svc status "${_SVC_TUNNEL}" && printf 'running' || printf 'stopped'
}

menu() {
    while true; do
        # 收集状态
        local _xs _xc _xcolor
        _xs=$(_xray_status); _xc=$?
        [ "${_xc}" -eq 0 ] && _xcolor="${C_GRN}" || _xcolor="${C_RED}"

        local _as _dom _argo_desc
        _as=$(_argo_status); _dom=$(state_get '.argo.domain')
        if [ "$(state_get '.argo.enabled')" = "true" ]; then
            { [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ]; } \
                && _argo_desc="${_as} [$(state_get '.argo.protocol'), ${_dom}]" \
                || _argo_desc="${_as} [未配置域名]"
        else
            _argo_desc="未启用"
        fi

        local _ff_desc
        local _fp _fpa; _fp=$(state_get '.ff.protocol'); _fpa=$(state_get '.ff.path')
        [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ] \
            && _ff_desc="${_fp} (path=${_fpa})" || _ff_desc="未启用"

        local _re_desc
        [ "$(state_get '.reality.enabled')" = "true" ] \
            && _re_desc="已启用 (port=$(state_get '.reality.port'), $(state_get '.reality.network'), sni=$(state_get '.reality.sni'))" \
            || _re_desc="未启用"

        local _vt_desc
        [ "$(state_get '.vltcp.enabled')" = "true" ] \
            && _vt_desc="已启用 (port=$(state_get '.vltcp.port'), listen=$(state_get '.vltcp.listen'))" \
            || _vt_desc="未启用"

        clear; echo ""
        printf "${C_BOLD}${C_PUR}  ╔══════════════════════════════════════════╗${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ║                Xray-2go  v8.3            ║${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ╠══════════════════════════════════════════╣${C_RST}\n"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Xray     : ${_xcolor}%-29s${C_RST}${C_PUR} ${C_RST}\n" "${_xs}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Argo     : %-29s${C_PUR} ${C_RST}\n" "${_argo_desc}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  Reality  : %-29s${C_PUR} ${C_RST}\n" "${_re_desc}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  VLESS-TCP: %-29s${C_PUR} ${C_RST}\n" "${_vt_desc}"
        printf "${C_BOLD}${C_PUR}  ║${C_RST}  FF       : %-29s${C_PUR} ${C_RST}\n" "${_ff_desc}"
        printf "${C_BOLD}${C_PUR}  ╚══════════════════════════════════════════╝${C_RST}\n\n"
        printf "  ${C_GRN}1.${C_RST} 安装 Xray-2go\n"
        printf "  ${C_RED}2.${C_RST} 卸载 Xray-2go\n"; _hr
        printf "  ${C_GRN}3.${C_RST} Argo 管理\n"
        printf "  ${C_GRN}4.${C_RST} Reality 管理\n"
        printf "  ${C_GRN}5.${C_RST} VLESS-TCP 管理\n"
        printf "  ${C_GRN}6.${C_RST} FreeFlow 管理\n"; _hr
        printf "  ${C_GRN}7.${C_RST} 查看节点\n"
        printf "  ${C_GRN}8.${C_RST} 修改 UUID\n"
        printf "  ${C_GRN}s.${C_RST} 快捷方式/脚本更新\n"; _hr
        printf "  ${C_RED}0.${C_RST} 退出\n\n"

        local _c; prompt "请输入选择 (0-8/s): " _c; echo ""
        case "${_c:-}" in
            1)  if [ "${_xc}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装并运行，如需重装请先卸载 (选项 2)"; _pause; continue
                fi
                # 安装向导
                echo ""; log_title "Argo 固定隧道"
                printf "  ${C_GRN}1.${C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${C_YLW}[默认]${C_RST}  ${C_GRN}2.${C_RST} 不安装\n"
                local _a; prompt "请选择 (1-2，回车默认1): " _a
                case "${_a:-1}" in
                    2) state_set '.argo.enabled = false'; log_info "不安装 Argo";;
                    *) state_set '.argo.enabled = true'
                       echo ""; log_title "Argo 传输协议"
                       printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}  ${C_GRN}2.${C_RST} XHTTP\n"
                       local _ap; prompt "请选择 (1-2，回车默认1): " _ap
                       case "${_ap:-1}" in
                           2) state_set '.argo.protocol = "xhttp"';;
                           *) state_set '.argo.protocol = "ws"';;
                       esac
                       log_info "已选: $(state_get '.argo.protocol')";;
                esac

                echo ""; log_title "FreeFlow（明文 port 8080）"
                _ask_ff_proto

                echo ""; log_title "VLESS + Reality"
                printf "  ${C_GRN}1.${C_RST} 启用  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
                local _re; prompt "请选择 (1-2，回车默认2): " _re
                case "${_re:-2}" in
                    1) state_set '.reality.enabled = true'
                       local _rp _dp; _dp=$(state_get '.reality.port')
                       prompt "监听端口（回车默认 ${_dp}）: " _rp
                       [ -n "${_rp:-}" ] && case "${_rp}" in
                           *[!0-9]*) log_warn "无效，使用默认";;
                           *) { [ "${_rp}" -ge 1 ] && [ "${_rp}" -le 65535 ]; } \
                               && state_set '.reality.port = ($p|tonumber)' --arg p "${_rp}" \
                               || log_warn "超范围，使用默认";;
                       esac
                       local _ds; _ds=$(state_get '.reality.sni')
                       log_info "SNI 建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                       local _sni; prompt "伪装 SNI（回车默认 ${_ds}）: " _sni
                       [ -n "${_sni:-}" ] && {
                           printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                               && state_set '.reality.sni = $s' --arg s "${_sni}" \
                               || log_warn "格式不合法，使用默认"
                       }
                       printf "  ${C_GRN}1.${C_RST} TCP+Vision ${C_YLW}[默认]${C_RST}  ${C_GRN}2.${C_RST} XHTTP\n"
                       local _rn; prompt "传输方式: " _rn
                       case "${_rn:-1}" in
                           2) state_set '.reality.network = "xhttp"';;
                           *) state_set '.reality.network = "tcp"';;
                       esac
                       log_info "Reality: port=$(state_get '.reality.port') sni=$(state_get '.reality.sni') net=$(state_get '.reality.network')";;
                    *) state_set '.reality.enabled = false'; log_info "不启用 Reality";;
                esac

                echo ""; log_title "VLESS-TCP 明文落地"
                printf "  ${C_GRN}1.${C_RST} 启用  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
                local _vt; prompt "请选择 (1-2，回车默认2): " _vt
                case "${_vt:-2}" in
                    1) state_set '.vltcp.enabled = true'
                       local _vp _vdp; _vdp=$(state_get '.vltcp.port')
                       prompt "监听端口（回车默认 ${_vdp}）: " _vp
                       [ -n "${_vp:-}" ] && case "${_vp}" in
                           *[!0-9]*) log_warn "无效，使用默认";;
                           *) { [ "${_vp}" -ge 1 ] && [ "${_vp}" -le 65535 ]; } \
                               && state_set '.vltcp.port = ($p|tonumber)' --arg p "${_vp}" \
                               || log_warn "超范围，使用默认";;
                       esac
                       local _vl _vdl; _vdl=$(state_get '.vltcp.listen')
                       prompt "监听地址（回车默认 ${_vdl}）: " _vl
                       [ -n "${_vl:-}" ] && state_set '.vltcp.listen = $l' --arg l "${_vl}"
                       log_info "VLESS-TCP: port=$(state_get '.vltcp.port') listen=$(state_get '.vltcp.listen')";;
                    *) state_set '.vltcp.enabled = false'; log_info "不启用 VLESS-TCP";;
                esac

                [ "$(state_get '.reality.enabled')" = "true" ] && {
                    local _rport _aport
                    _rport=$(state_get '.reality.port'); _aport=$(state_get '.argo.port')
                    [ "${_rport}" = "${_aport}" ] \
                        && log_warn "Reality 端口与 Argo 端口相同，安装时将自动修正"
                }

                exec_install_core || { _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                [ "$(state_get '.argo.enabled')" = "true" ] && {
                    apply_fixed_tunnel \
                        || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"
                }
                print_nodes ;;
            2)  exec_uninstall ;;
            3)  manage_argo ;;
            4)  manage_reality ;;
            5)  manage_vltcp ;;
            6)  manage_freeflow ;;
            7)  [ "${_xc}" -eq 0 ] && print_nodes \
                    || log_warn "Xray-2go 未安装或未运行" ;;
            8)  [ -f "${CONFIG_FILE}" ] && exec_update_uuid \
                    || log_warn "请先安装 Xray-2go" ;;
            s)  exec_install_shortcut ;;
            0)  log_info "已退出"; exit 0 ;;
            *)  log_error "无效选项，请输入 0-8 或 s" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §21 入口
# ==============================================================================
main() {
    check_root
    _detect_init
    preflight_check
    state_init
    menu
}
main "$@"
