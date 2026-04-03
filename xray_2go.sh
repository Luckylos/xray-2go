#!/usr/bin/env bash
# ==============================================================================
# xray-2go v3.1
# 协议：Argo WS/XHTTP (Cloudflare Tunnel) · FreeFlow WS/HTTPUpgrade/XHTTP
# 架构：SSOT _STATE · 声明式配置引擎 · 原子化提交 · 统一服务接口
# 平台：Debian/Ubuntu (systemd) · Alpine (OpenRC)
# ==============================================================================
set -uo pipefail

# ── §0  临时文件沙箱 ──────────────────────────────────────────────────────────
_TMP_DIR=""
_SPINNER_PID=0

trap '_global_cleanup' EXIT
trap '_int_handler'    INT TERM

_global_cleanup() {
    [ "${_SPINNER_PID}" -ne 0 ] && kill "${_SPINNER_PID}" 2>/dev/null || true
    [ -n "${_TMP_DIR:-}"      ] && rm -rf "${_TMP_DIR}"   2>/dev/null || true
    tput cnorm 2>/dev/null || true
}
_int_handler() {
    printf '\n\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}
_tmp_dir() {
    [ -z "${_TMP_DIR:-}" ] && \
        _TMP_DIR=$(mktemp -d /tmp/xray2go_XXXXXX) || true
    [ -n "${_TMP_DIR:-}" ] || { printf '\033[1;91m[ERR ] 无法创建临时目录\033[0m\n' >&2; exit 1; }
    printf '%s' "${_TMP_DIR}"
}
_tmp_file() { mktemp "$(_tmp_dir)/${1:-tmp_XXXXXX}"; }

# ── §1  路径常量 ──────────────────────────────────────────────────────────────
readonly WORK_DIR="/etc/xray"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly ARGO_LOG="${WORK_DIR}/argo.log"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

# ── §2  UI 层 ─────────────────────────────────────────────────────────────────
readonly _RST=$'\033[0m'  _BOLD=$'\033[1m'
readonly _RED=$'\033[1;91m'  _GRN=$'\033[1;32m'
readonly _YLW=$'\033[1;33m'  _PUR=$'\033[1;35m'  _CYN=$'\033[1;36m'

log_info()  { printf "${_CYN}[INFO]${_RST} %s\n"      "$*"; }
log_ok()    { printf "${_GRN}[ OK ]${_RST} %s\n"      "$*"; }
log_warn()  { printf "${_YLW}[WARN]${_RST} %s\n"      "$*" >&2; }
log_error() { printf "${_RED}[ERR ]${_RST} %s\n"      "$*" >&2; }
log_step()  { printf "${_PUR}[....] %s${_RST}\n"      "$*"; }
log_title() { printf "\n${_BOLD}${_PUR}%s${_RST}\n"   "$*"; }
die()       { log_error "$1"; exit "${2:-1}"; }

prompt() {
    local _msg="$1" _var="$2"
    printf "${_RED}%s${_RST}" "${_msg}" >&2
    read -r "${_var}" </dev/tty
}
_pause() {
    local _d
    printf "${_RED}按回车键继续...${_RST}" >&2
    read -r _d </dev/tty || true
}
_hr() { printf "${_PUR}  ──────────────────────────────────${_RST}\n"; }

spinner_start() {
    printf "${_CYN}[....] %s${_RST}\n" "$1"
    ( local i=0 c='-\|/'
      while true; do
          printf "\r${_CYN}[ %s  ]${_RST} %s  " "${c:$(( i%4 )):1}" "$1" >&2
          sleep 0.12; i=$(( i+1 ))
      done ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
}
spinner_stop() {
    [ "${_SPINNER_PID}" -ne 0 ] && { kill "${_SPINNER_PID}" 2>/dev/null; _SPINNER_PID=0; }
    printf '\r\033[2K' >&2
}

# ── §3  平台检测 ──────────────────────────────────────────────────────────────
_INIT_SYS=""
_ARCH_CF=""
_ARCH_XRAY=""

_detect_init() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        _INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _INIT_SYS="openrc"
    else
        die "不支持的 init 系统（需要 systemd 或 OpenRC）"
    fi
}
is_systemd() { [ "${_INIT_SYS}" = "systemd" ]; }
is_openrc()  { [ "${_INIT_SYS}" = "openrc"  ]; }
is_alpine()  { [ -f /etc/alpine-release ]; }
is_debian()  { [ -f /etc/debian_version ]; }

detect_arch() {
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

# ── §4  依赖预检 ──────────────────────────────────────────────────────────────
check_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请在 root 下运行脚本"; }

pkg_require() {
    local _pkg="$1" _bin="${2:-$1}"
    command -v "${_bin}" >/dev/null 2>&1 && return 0
    log_step "安装依赖: ${_pkg}"
    if   command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then apk add        "${_pkg}" >/dev/null 2>&1
    else die "未找到包管理器，无法安装 ${_pkg}"
    fi
    hash -r 2>/dev/null || true
    command -v "${_bin}" >/dev/null 2>&1 || die "${_pkg} 安装失败，请手动安装后重试"
    log_ok "${_pkg} 已就绪"
}

preflight_check() {
    log_step "检查依赖 (curl / unzip / jq)..."
    for _d in curl unzip jq; do pkg_require "${_d}"; done
    # 二进制完整性（若已安装）
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || chmod +x "${XRAY_BIN}"
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏，建议重新安装"
    fi
    [ -f "${ARGO_BIN}" ] && [ ! -x "${ARGO_BIN}" ] && chmod +x "${ARGO_BIN}"
    log_ok "依赖检查通过"
}

# ── §5  SSOT 状态层 ───────────────────────────────────────────────────────────
# Schema：
# {
#   "uuid":   "<自动生成>",
#   "argo":   {"enabled":true,  "protocol":"ws",   "port":8888,
#              "mode":"temp",   "domain":null,      "token":null},
#   "ff":     {"enabled":false, "protocol":"none", "path":"/"},
#   "cfip":   "cf.tencentapp.cn",
#   "cfport": "443"
# }
_STATE=""

readonly _STATE_DEFAULT='{
  "uuid":   "",
  "argo":   {"enabled":true,  "protocol":"ws", "port":8888,
             "mode":"temp",   "domain":null,   "token":null},
  "ff":     {"enabled":false, "protocol":"none", "path":"/"},
  "cfip":   "cf.tencentapp.cn",
  "cfport": "443"
}'

# state_get <jq_path> → stdout（null/空输出空串）
state_get() {
    printf '%s' "${_STATE}" | jq -r "${1} // empty" 2>/dev/null || true
}

# state_set <jq_filter> [--arg/--argjson ...] → 原地更新 _STATE
state_set() {
    local _f="$1"; shift
    local _new
    _new=$(printf '%s' "${_STATE}" | jq "$@" "${_f}" 2>/dev/null) \
        || { log_error "state_set 失败: ${_f}"; return 1; }
    [ -n "${_new:-}" ] || { log_error "state_set 返回空 JSON"; return 1; }
    _STATE="${_new}"
}

# state_persist → 原子写入 STATE_FILE
state_persist() {
    mkdir -p "${WORK_DIR}"
    local _t; _t=$(_tmp_file "state_XXXXXX.json") || return 1
    printf '%s\n' "${_STATE}" | jq . > "${_t}" 2>/dev/null \
        || { log_error "state 序列化失败"; return 1; }
    mv "${_t}" "${STATE_FILE}"
}

# state_init → 从 STATE_FILE 加载，或初始化默认值
state_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _STATE="${_raw}"
            _ensure_uuid
            return 0
        fi
        log_warn "state.json 损坏，重置为默认值"
    fi
    _STATE="${_STATE_DEFAULT}"
    _ensure_uuid
    [ -d "${WORK_DIR}" ] && state_persist 2>/dev/null || true
}

_ensure_uuid() {
    local _u; _u=$(state_get '.uuid')
    [ -z "${_u:-}" ] && state_set '.uuid = $u' --arg u "$(_gen_uuid)"
}

# ── §6  工具函数 ──────────────────────────────────────────────────────────────
_gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
        awk 'BEGIN{srand()} {h=$0; printf "%s-%s-4%s-%s%s-%s\n",
            substr(h,1,8),substr(h,9,4),substr(h,14,3),
            substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
    fi
}

# _kernel_ge MAJOR MINOR（兼容 4.9-generic 等后缀）
_kernel_ge() {
    local _cur; _cur=$(uname -r)
    local _cm="${_cur%%.*}"
    local _cr="${_cur#*.}"; _cr="${_cr%%.*}"; _cr="${_cr%%[^0-9]*}"
    [ "${_cm}" -gt "$1" ] || { [ "${_cm}" -eq "$1" ] && [ "${_cr:-0}" -ge "$2" ]; }
}

port_in_use() {
    local _p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | awk -v p=":${_p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    local _h; _h=$(printf '%04X' "${_p}")
    awk -v h="${_h}" 'NR>1&&substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

get_realip() {
    local _ip _org _v6
    _ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || true
    if [ -z "${_ip:-}" ]; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && printf '[%s]' "${_v6}" || printf ''
        return
    fi
    _org=$(curl -sf --max-time 5 "https://ipinfo.io/${_ip}/org" 2>/dev/null) || true
    if printf '%s' "${_org:-}" | grep -qiE 'Cloudflare|UnReal|AEZA|Andrei'; then
        _v6=$(curl -sf --max-time 5 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${_v6:-}" ] && printf '[%s]' "${_v6}" || printf '%s' "${_ip}"
    else
        printf '%s' "${_ip}"
    fi
}

# 指数退避轮询 Argo 日志：3→6→8→8→8→8s，初始 sleep 3s，最多约 44s
get_temp_domain() {
    local _d _delay=3 _i=1
    sleep 3
    while [ "${_i}" -le 6 ]; do
        _d=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
             "${ARGO_LOG}" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${_d:-}" ] && printf '%s' "${_d}" && return 0
        sleep "${_delay}"; _i=$(( _i+1 ))
        _delay=$(( _delay < 8 ? _delay*2 : 8 ))
    done
    return 1
}

_urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;
         s/\$/%24/g;s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;
         s/\*/%2A/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;
         s/=/%3D/g;s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\]/%5D/g'
}

# ── §7  声明式配置引擎 ────────────────────────────────────────────────────────
# _gen_inbound_snippet <type>  → JSON inbound 片段（type: argo | ff）
# 所有值经 jq --arg/--argjson 序列化，无注入风险
# 新增协议：在此添加 case 分支，其余函数无需改动

readonly _SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

_gen_inbound_snippet() {
    local _type="$1"
    local _uuid; _uuid=$(state_get '.uuid')

    case "${_type}" in
        argo)
            local _port _proto
            _port=$(state_get '.argo.port')
            _proto=$(state_get '.argo.protocol')
            case "${_proto}" in
                xhttp)
                    jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                          --argjson sniff "${_SNIFF}" '{
                        port:$port, listen:"127.0.0.1", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"xhttp", security:"none",
                            xhttpSettings:{host:"", path:"/argo", mode:"auto"}},
                        sniffing:$sniff}' ;;
                *)  # ws（默认）
                    jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                          --argjson sniff "${_SNIFF}" '{
                        port:$port, listen:"127.0.0.1", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"ws", security:"none",
                            wsSettings:{path:"/argo"}},
                        sniffing:$sniff}' ;;
            esac ;;

        ff)
            local _proto _path
            _proto=$(state_get '.ff.protocol')
            _path=$( state_get '.ff.path')
            case "${_proto}" in
                ws)
                    jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                          --argjson sniff "${_SNIFF}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"ws", security:"none",
                            wsSettings:{path:$path}},
                        sniffing:$sniff}' ;;
                httpupgrade)
                    jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                          --argjson sniff "${_SNIFF}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"httpupgrade", security:"none",
                            httpupgradeSettings:{path:$path}},
                        sniffing:$sniff}' ;;
                xhttp)
                    jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                          --argjson sniff "${_SNIFF}" '{
                        port:8080, listen:"::", protocol:"vless",
                        settings:{clients:[{id:$uuid}], decryption:"none"},
                        streamSettings:{network:"xhttp", security:"none",
                            xhttpSettings:{host:"", path:$path, mode:"stream-one"}},
                        sniffing:$sniff}' ;;
                *) log_error "_gen_inbound_snippet ff: 未知协议 ${_proto}"; return 1 ;;
            esac ;;

        *) log_error "_gen_inbound_snippet: 未知类型 '${_type}'"; return 1 ;;
    esac
}

# config_synthesize <outfile>：从 _STATE 合成完整 config.json
config_synthesize() {
    local _out="$1" _ibs="[]" _ib

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _ib=$(_gen_inbound_snippet argo) || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    local _ff_proto; _ff_proto=$(state_get '.ff.protocol')
    if [ "$(state_get '.ff.enabled')" = "true" ] && [ "${_ff_proto}" != "none" ]; then
        _ib=$(_gen_inbound_snippet ff) || return 1
        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]')
    fi

    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用（无可用节点）"

    jq -n --argjson inbounds "${_ibs}" '{
        log:      {access:"/dev/null", error:"/dev/null", loglevel:"none"},
        inbounds: $inbounds,
        dns:      {servers:["https+local://1.1.1.1/dns-query"]},
        outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]
    }' > "${_out}" || { log_error "config 合成失败"; return 1; }
}

# config_commit：合成 → xray-test → mv → 重启（原子化，失败时现配置零污染）
config_commit() {
    local _t; _t=$(_tmp_file "xray_next_XXXXXX.json") || return 1

    log_step "合成配置..."
    config_synthesize "${_t}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            mv "${_t}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            log_error "config 验证失败！现场已保留于 ${WORK_DIR}/config_failed.json"
            return 1
        fi
        log_ok "config 验证通过"
    fi

    mkdir -p "${WORK_DIR}"
    mv "${_t}" "${CONFIG_FILE}" || { log_error "config 写入失败"; return 1; }
    log_ok "config.json 已更新"

    _svc_manager status xray >/dev/null 2>&1 && \
        { _svc_manager restart xray && log_ok "xray 已重启" || { log_error "xray 重启失败"; return 1; }; }
}

# ── §8  Argo 配置引擎 ─────────────────────────────────────────────────────────
# 从 _STATE 动态生成 tunnel.yml（遍历 argo 入站端口，扩展点明确）
_gen_argo_config() {
    local _domain="$1" _tid="$2" _cred="$3"
    local _port; _port=$(state_get '.argo.port')
    printf 'tunnel: %s\ncredentials-file: %s\nprotocol: http2\n\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      noTLSVerify: true\n  - service: http_status:404\n' \
        "${_tid}" "${_cred}" "${_domain}" "${_port}" > "${WORK_DIR}/tunnel.yml" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已生成 (${_domain} → localhost:${_port})"
}

# 从 _STATE.argo.mode 派生 cloudflared 启动命令（服务文件由此命令生成，无需 sed 修补）
_build_tunnel_cmd() {
    local _port; _port=$(state_get '.argo.port')
    case "$(state_get '.argo.mode')" in
        fixed)
            if [ -f "${WORK_DIR}/tunnel.yml" ]; then
                printf '%s tunnel --edge-ip-version auto --config %s run' \
                    "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
            else
                printf '%s tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token %s' \
                    "${ARGO_BIN}" "$(state_get '.argo.token')"
            fi ;;
        *)
            printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
                "${ARGO_BIN}" "${_port}" ;;
    esac
}

# ── §9  统一服务管理接口 ──────────────────────────────────────────────────────
# 业务代码严禁直接调用 systemctl / rc-service
_svc_manager() {
    local _act="$1" _name="$2" _rc=0
    if is_systemd; then
        case "${_act}" in
            enable)  systemctl enable   "${_name}" >/dev/null 2>&1; _rc=$? ;;
            disable) systemctl disable  "${_name}" >/dev/null 2>&1; _rc=$? ;;
            status)  systemctl is-active --quiet "${_name}" 2>/dev/null;   _rc=$? ;;
            *)       systemctl "${_act}" "${_name}" >/dev/null 2>&1;       _rc=$? ;;
        esac
    else
        case "${_act}" in
            enable)  rc-update add "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            disable) rc-update del "${_name}" default >/dev/null 2>&1; _rc=$? ;;
            status)  rc-service  "${_name}" status    >/dev/null 2>&1; _rc=$? ;;
            *)       rc-service  "${_name}" "${_act}" >/dev/null 2>&1; _rc=$? ;;
        esac
    fi
    return "${_rc}"
}

_SYSD_DIRTY=0
_svc_daemon_reload() {
    is_systemd                  || return 0
    [ "${_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _SYSD_DIRTY=0
}

# 幂等服务文件写入（内容无变化则跳过；变化时返回 1 → 调用方置 _SYSD_DIRTY）
_svc_write() {
    local _dest="$1" _content="$2"
    [ "$(cat "${_dest}" 2>/dev/null || true)" = "${_content}" ] && return 0
    printf '%s' "${_content}" > "${_dest}"
    return 1
}

# 服务单元内容（printf 替代 heredoc，避免 IFS 截断）
_svc_xray_systemd() {
    printf '[Unit]\nDescription=Xray Service\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=on-failure\nRestartPreventExitStatus=23\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}
_svc_tunnel_systemd() {
    printf '[Unit]\nDescription=Cloudflare Tunnel\nAfter=network.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=/bin/sh -c '"'"'%s >> %s 2>&1'"'"'\nRestart=on-failure\nRestartSec=5s\n\n[Install]\nWantedBy=multi-user.target\n' \
        "$(_build_tunnel_cmd)" "${ARGO_LOG}"
}
_svc_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\npidfile="/var/run/xray.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}
_svc_tunnel_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel"\ncommand="/bin/sh"\ncommand_args="-c '"'"'%s >> %s 2>&1'"'"'"\ncommand_background=true\npidfile="/var/run/tunnel.pid"\n' \
        "$(_build_tunnel_cmd)" "${ARGO_LOG}"
}

_register_xray_service() {
    if is_systemd; then
        _svc_write "/etc/systemd/system/xray.service" "$(_svc_xray_systemd)" || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/xray" "$(_svc_xray_openrc)" || chmod +x /etc/init.d/xray
    fi
}
_register_tunnel_service() {
    if is_systemd; then
        _svc_write "/etc/systemd/system/tunnel.service" "$(_svc_tunnel_systemd)" || _SYSD_DIRTY=1
    else
        _svc_write "/etc/init.d/tunnel" "$(_svc_tunnel_openrc)" || chmod +x /etc/init.d/tunnel
    fi
}

# ── §10 零持久化节点解析 ──────────────────────────────────────────────────────
# 实时从 _STATE 生成链接，无任何文件 I/O
_get_share_links() {
    local _uuid _cfip _cfport
    _uuid=$(state_get '.uuid')
    _cfip=$(state_get '.cfip')
    _cfport=$(state_get '.cfport')

    # Argo
    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        local _domain; _domain=$(state_get '.argo.domain')
        if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
            case "$(state_get '.argo.protocol')" in
                xhttp)
                    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                        "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
                *)
                    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                        "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
            esac
        fi
    fi

    # FreeFlow
    if [ "$(state_get '.ff.enabled')" = "true" ] && \
       [ "$(state_get '.ff.protocol')" != "none" ]; then
        local _ip; _ip=$(get_realip)
        if [ -n "${_ip:-}" ]; then
            local _pe; _pe=$(_urlencode_path "$(state_get '.ff.path')")
            case "$(state_get '.ff.protocol')" in
                ws)
                    printf 'vless://%s@%s:8080?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                        "${_uuid}" "${_ip}" "${_ip}" "${_pe}" ;;
                httpupgrade)
                    printf 'vless://%s@%s:8080?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                        "${_uuid}" "${_ip}" "${_ip}" "${_pe}" ;;
                xhttp)
                    printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                        "${_uuid}" "${_ip}" "${_ip}" "${_pe}" ;;
            esac
        else
            log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"
        fi
    fi
}

print_nodes() {
    echo ""
    local _links; _links=$(_get_share_links)
    if [ -z "${_links:-}" ]; then
        log_warn "暂无可用节点（Argo 域名未配置或 IP 获取失败）"
        return 1
    fi
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        [ -n "${_l:-}" ] && printf "${_CYN}%s${_RST}\n" "${_l}"
    done
    echo ""
}

# ── §11 下载层 ────────────────────────────────────────────────────────────────
download_xray() {
    detect_arch
    [ -f "${XRAY_BIN}" ] && { log_info "xray 已存在，跳过下载"; return 0; }
    local _z; _z=$(_tmp_file "xray_XXXXXX.zip") || return 1
    local _url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${_ARCH_XRAY}.zip"
    spinner_start "下载 Xray (${_ARCH_XRAY})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${_z}" "${_url}"
    local _rc=$?; spinner_stop
    [ "${_rc}" -ne 0 ] && { log_error "Xray 下载失败，请检查网络"; return 1; }
    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "Xray zip 损坏"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 || { log_error "Xray 解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"
    log_ok "Xray 下载完成 ($(${XRAY_BIN} version 2>/dev/null | head -1 | awk '{print $2}'))"
}

download_cloudflared() {
    detect_arch
    [ -f "${ARGO_BIN}" ] && { log_info "cloudflared 已存在，跳过下载"; return 0; }
    local _url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_ARCH_CF}"
    spinner_start "下载 cloudflared (${_ARCH_CF})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${_url}"
    local _rc=$?; spinner_stop
    [ "${_rc}" -ne 0 ] && { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; log_error "cloudflared 文件为空"; return 1; }
    chmod +x "${ARGO_BIN}"
    log_ok "cloudflared 下载完成"
}

# ── §12 环境自愈 ──────────────────────────────────────────────────────────────
check_bbr() {
    local _a; _a=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')
    [ "${_a}" = "bbr" ] && { log_ok "TCP BBR 已启用"; return 0; }
    log_warn "当前拥塞控制: ${_a}（推荐 BBR 以提升性能）"
    _kernel_ge 4 9 || { log_warn "内核 < 4.9，不支持 BBR"; return 0; }
    is_systemd || return 0
    local _ans; prompt "是否现在启用 BBR？(y/N): " _ans
    case "${_ans:-n}" in y|Y)
        modprobe tcp_bbr 2>/dev/null || true
        mkdir -p /etc/modules-load.d /etc/sysctl.d
        printf 'tcp_bbr\n' > /etc/modules-load.d/xray2go-bbr.conf
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
            > /etc/sysctl.d/88-xray2go-bbr.conf
        sysctl -p /etc/sysctl.d/88-xray2go-bbr.conf >/dev/null 2>&1
        log_ok "BBR 已启用（重启后持久生效）"
    ;; esac
}

check_systemd_resolved() {
    is_debian && is_systemd || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local _s; _s=$(awk -F= '/^DNSStubListener/{gsub(/ /,"",$2);print $2}' \
                   /etc/systemd/resolved.conf 2>/dev/null || printf '')
    [ "${_s:-yes}" != "no" ] && \
        log_info "systemd-resolved stub 127.0.0.53:53 — xray 使用 DoH，无冲突"
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

# ── §13 安装 / 卸载 ───────────────────────────────────────────────────────────
install_core() {
    clear; log_title "══════════ 安装 Xray-2go ══════════"
    preflight_check
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    download_xray || return 1
    [ "$(state_get '.argo.enabled')" = "true" ] && { download_cloudflared || return 1; }

    config_commit || return 1

    _register_xray_service
    [ "$(state_get '.argo.enabled')" = "true" ] && _register_tunnel_service
    _svc_daemon_reload

    if is_openrc; then
        printf '0 0\n' > /proc/sys/net/ipv4/ping_group_range 2>/dev/null || true
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
        sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    fi

    fix_time_sync

    log_step "启动服务..."
    _svc_manager enable xray
    _svc_manager start  xray || { log_error "xray 启动失败"; return 1; }
    log_ok "xray 已启动"

    if [ "$(state_get '.argo.enabled')" = "true" ]; then
        _svc_manager enable tunnel
        _svc_manager start  tunnel || { log_error "tunnel 启动失败"; return 1; }
        log_ok "tunnel 已启动"
    fi

    state_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

uninstall_all() {
    local _a; prompt "确定要卸载 xray-2go？(y/N): " _a
    case "${_a:-n}" in y|Y) : ;; *) log_info "已取消"; return ;; esac
    log_step "卸载中..."
    for _s in xray tunnel; do
        _svc_manager stop    "${_s}" 2>/dev/null || true
        _svc_manager disable "${_s}" 2>/dev/null || true
    done
    if is_systemd; then
        rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/xray /etc/init.d/tunnel
    fi
    rm -rf "${WORK_DIR}"
    rm -f  "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak"
    log_ok "Xray-2go 卸载完成"
}

# ── §14 隧道操作 ──────────────────────────────────────────────────────────────
configure_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(state_get '.argo.protocol')  端口: $(state_get '.argo.port')"
    echo ""
    local _dom _auth
    prompt "请输入 Argo 域名: " _dom
    case "${_dom:-}" in ''|*' '*|*'/'*|*$'\t'*) log_error "域名格式不合法"; return 1 ;; esac
    printf '%s' "${_dom}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }
    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " _auth
    [ -z "${_auth:-}" ] && { log_error "密钥不能为空"; return 1; }

    if printf '%s' "${_auth}" | grep -q "TunnelSecret"; then
        printf '%s' "${_auth}" | jq . >/dev/null 2>&1 || { log_error "JSON 凭证格式不合法"; return 1; }
        local _tid
        _tid=$(printf '%s' "${_auth}" | jq -r '
            if (.TunnelID? //"")!="" then .TunnelID
            elif (.AccountTag?//"")!="" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${_tid:-}" ] && { log_error "无法提取 TunnelID/AccountTag"; return 1; }
        case "${_tid}" in *$'\n'*|*'"'*|*"'"*|*':'*)
            log_error "TunnelID 含非法字符"; return 1 ;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        printf '%s' "${_auth}" > "${_cred}"
        _gen_argo_config "${_dom}" "${_tid}" "${_cred}" || return 1
        state_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_dom}" || return 1

    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        state_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_dom}" || return 1
        rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    _register_tunnel_service; _svc_daemon_reload
    _svc_manager enable tunnel 2>/dev/null || true
    config_commit  || return 1
    state_persist  || log_warn "state.json 写入失败"
    _svc_manager restart tunnel || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 ($(state_get '.argo.protocol'), domain=${_dom})"
}

reset_temp_tunnel() {
    state_set '.argo.mode = "temp" | .argo.domain = null | .argo.token = null | .argo.protocol = "ws"' \
        || return 1
    rm -f "${WORK_DIR}/tunnel.yml" "${WORK_DIR}/tunnel.json"
    _register_tunnel_service; _svc_daemon_reload
    config_commit || return 1
    state_persist || log_warn "state.json 写入失败"
    log_ok "已切换至临时隧道 (WS)"
}

refresh_temp_domain() {
    [ "$(state_get '.argo.enabled')" = "true" ]  || { log_warn "未启用 Argo"; return 1; }
    [ "$(state_get '.argo.protocol')" = "ws"  ]  || { log_error "XHTTP 不支持临时隧道"; return 1; }
    [ "$(state_get '.argo.mode')" = "temp"    ]  || { log_warn "当前为固定隧道，无需刷新"; return 1; }
    rm -f "${ARGO_LOG}"
    log_step "重启隧道并等待新域名（最多约 44s）..."
    _svc_manager restart tunnel || return 1
    local _d; _d=$(get_temp_domain) || { log_warn "未能获取临时域名，请检查网络"; return 1; }
    log_ok "ArgoDomain: ${_d}"
    state_set '.argo.domain = $d' --arg d "${_d}" || return 1
    state_persist || log_warn "state.json 写入失败"
    print_nodes
}

# ── §15 UUID / 端口管理（SSOT 工作流：state_set → config_commit → state_persist → print_nodes）
manage_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    printf '%s' "${_v}" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }
    state_set '.uuid = $u' --arg u "${_v}" || return 1
    config_commit  || return 1
    state_persist  || log_warn "state.json 写入失败"
    log_ok "UUID 已更新: ${_v}"
    print_nodes
}

manage_port() {
    local _p; prompt "新回源端口（回车随机）: " _p
    [ -z "${_p:-}" ] && \
        _p=$(shuf -i 2000-65000 -n 1 2>/dev/null || awk 'BEGIN{srand();print int(rand()*63000)+2000}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1 ;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } || { log_error "端口须在 1-65535 之间"; return 1; }
    if port_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) : ;; *) return 1 ;; esac
    fi
    state_set '.argo.port = ($p|tonumber)' --arg p "${_p}" || return 1
    config_commit || return 1
    _register_tunnel_service; _svc_daemon_reload
    _svc_manager restart tunnel || log_warn "tunnel 重启失败，请手动重启"
    state_persist || log_warn "state.json 写入失败"
    log_ok "回源端口已更新: ${_p}"
    print_nodes
}

# ── §16 脚本更新 ──────────────────────────────────────────────────────────────
install_shortcut() {
    log_step "拉取最新脚本..."
    local _t; _t=$(_tmp_file "xray2go_XXXXXX.sh") || return 1
    curl -sfL --connect-timeout 15 --max-time 60 -o "${_t}" "${UPSTREAM_URL}" \
        || { log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${_t}" 2>/dev/null || { log_error "脚本语法验证失败，已中止"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${_t}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}" && chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${_GRN}s${_RST} 快速启动"
}

# ── §17 状态检测 ──────────────────────────────────────────────────────────────
check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    _svc_manager status xray && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}
check_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                         || { printf 'not installed'; return 2; }
    _svc_manager status tunnel && { printf 'running'; return 0; } || { printf 'stopped'; return 1; }
}

# ── §18 交互询问（纯输入收集）────────────────────────────────────────────────
ask_argo_mode() {
    echo ""; log_title "Argo 隧道"
    printf "  ${_GRN}1.${_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${_YLW}[默认]${_RST}\n"
    printf "  ${_GRN}2.${_RST} 不安装 Argo（仅 FreeFlow 节点）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.enabled = false'; log_info "已选：不安装 Argo" ;;
        *) state_set '.argo.enabled = true';  log_info "已选：安装 Argo"   ;;
    esac; echo ""
}

ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${_GRN}1.${_RST} WS（临时+固定均支持）${_YLW}[默认]${_RST}\n"
    printf "  ${_GRN}2.${_RST} XHTTP（auto 模式，仅固定隧道）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) state_set '.argo.protocol = "xhttp"'
           log_warn "XHTTP 不支持临时隧道！安装后将进入固定隧道配置。" ;;
        *) state_set '.argo.protocol = "ws"' ;;
    esac
    log_info "已选协议: $(state_get '.argo.protocol')"; echo ""
}

ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文 port 8080）"
    printf "  ${_GRN}1.${_RST} VLESS + WS\n"
    printf "  ${_GRN}2.${_RST} VLESS + HTTPUpgrade\n"
    printf "  ${_GRN}3.${_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${_GRN}4.${_RST} 不启用 FreeFlow ${_YLW}[默认]${_RST}\n"
    local _c; prompt "请选择 (1-4，回车默认4): " _c
    case "${_c:-4}" in
        1) state_set '.ff.enabled = true | .ff.protocol = "ws"'          ;;
        2) state_set '.ff.enabled = true | .ff.protocol = "httpupgrade"' ;;
        3) state_set '.ff.enabled = true | .ff.protocol = "xhttp"'       ;;
        *) state_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; echo ""; return 0 ;;
    esac
    port_in_use 8080 && log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    local _p; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) : ;; *) _p="/${_p:-}"; esac
    state_set '.ff.path = $p' --arg p "${_p:-/}"
    log_info "已选: $(state_get '.ff.protocol')（path=${_p:-/}）"; echo ""
}

# ── §19 管理子菜单 ────────────────────────────────────────────────────────────
manage_argo() {
    [ "$(state_get '.argo.enabled')" = "true" ] || { log_warn "未启用 Argo"; sleep 1; return; }
    [ -f "${ARGO_BIN}" ]                         || { log_warn "Argo 未安装"; sleep 1; return; }

    while true; do
        local _as _dom _pt _po _td
        _as=$(check_argo)
        _dom=$(state_get '.argo.domain')
        _pt=$(state_get '.argo.protocol')
        _po=$(state_get '.argo.port')
        [ "$(state_get '.argo.mode')" = "fixed" ] && [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
            && _td="固定 (${_pt}, ${_dom})" || _td="临时 (WS)"

        clear; echo ""; log_title "══ Argo 隧道管理 ══"
        printf "  状态: ${_GRN}%s${_RST}  协议: ${_CYN}%s${_RST}  端口: ${_YLW}%s${_RST}\n" \
            "${_as}" "${_pt}" "${_po}"
        printf "  类型: %s\n" "${_td}"; _hr
        printf "  ${_GRN}1.${_RST} 添加/更新固定隧道\n"
        printf "  ${_GRN}2.${_RST} 切换协议 (WS ↔ XHTTP，仅固定隧道)\n"
        printf "  ${_GRN}3.${_RST} 切换回临时隧道 (WS)\n"
        printf "  ${_GRN}4.${_RST} 刷新临时域名\n"
        printf "  ${_GRN}5.${_RST} 修改回源端口 (当前: ${_YLW}${_po}${_RST})\n"
        printf "  ${_GRN}6.${_RST} 启动隧道\n"
        printf "  ${_GRN}7.${_RST} 停止隧道\n"
        printf "  ${_PUR}0.${_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                echo ""
                printf "  ${_GRN}1.${_RST} WS ${_YLW}[默认]${_RST}\n"
                printf "  ${_GRN}2.${_RST} XHTTP (auto)\n"
                local _pp; prompt "协议 (回车维持 ${_pt}): " _pp
                case "${_pp:-}" in 2) state_set '.argo.protocol = "xhttp"' ;;
                                   1) state_set '.argo.protocol = "ws"'    ;; esac
                if configure_fixed_tunnel; then print_nodes
                else log_error "固定隧道配置失败"; fi ;;
            2)
                [ "$(state_get '.argo.mode')" = "fixed" ] \
                    || { log_warn "当前为临时隧道，请先配置固定隧道"; _pause; continue; }
                local _np; [ "${_pt}" = "ws" ] && _np="xhttp" || _np="ws"
                state_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                if config_commit && state_persist; then
                    log_ok "协议已切换: ${_np}"; print_nodes
                else
                    log_error "切换失败，回滚"
                    state_set '.argo.protocol = $p' --arg p "${_pt}"
                fi ;;
            3)
                [ "$(state_get '.argo.protocol')" = "xhttp" ] && \
                    { log_error "请先切换协议为 WS"; _pause; continue; }
                reset_temp_tunnel || { _pause; continue; }
                _svc_manager restart tunnel || { _pause; continue; }
                log_step "等待临时域名（最多约 44s）..."
                local _d; _d=$(get_temp_domain) || _d=""
                if [ -n "${_d:-}" ]; then
                    state_set '.argo.domain = $d' --arg d "${_d}" && state_persist || true
                    log_ok "ArgoDomain: ${_d}"; print_nodes
                else
                    log_warn "未能获取临时域名，可从 [4. 刷新临时域名] 重试"
                fi ;;
            4) refresh_temp_domain ;;
            5) manage_port ;;
            6) _svc_manager start  tunnel \
                && log_ok "隧道已启动" || log_error "启动失败，请检查日志" ;;
            7) _svc_manager stop   tunnel \
                && log_ok "隧道已停止" || log_error "停止失败" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

manage_freeflow() {
    while true; do
        local _en _pt _pa
        _en=$(state_get '.ff.enabled')
        _pt=$(state_get '.ff.protocol')
        _pa=$(state_get '.ff.path')

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        if [ "${_en}" = "true" ] && [ "${_pt}" != "none" ]; then
            printf "  状态: ${_GRN}已启用${_RST}  协议: ${_CYN}%s${_RST}  path: ${_YLW}%s${_RST}\n" \
                "${_pt}" "${_pa}"
        else
            printf "  状态: ${_YLW}未启用${_RST}\n"
        fi; _hr
        printf "  ${_GRN}1.${_RST} 添加/变更方式\n"
        printf "  ${_GRN}2.${_RST} 修改 path\n"
        printf "  ${_RED}3.${_RST} 卸载 FreeFlow\n"
        printf "  ${_PUR}0.${_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c

        case "${_c:-}" in
            1)
                ask_freeflow_mode
                config_commit  || { log_error "配置更新失败"; _pause; continue; }
                state_persist  || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已变更"; print_nodes ;;
            2)
                if [ "${_en}" != "true" ] || [ "${_pt}" = "none" ]; then
                    log_warn "FreeFlow 未启用，请先选择 [1]"; _pause; continue
                fi
                local _p; prompt "新 path（回车保持 ${_pa}）: " _p
                if [ -n "${_p:-}" ]; then
                    case "${_p}" in /*) : ;; *) _p="/${_p}"; esac
                    state_set '.ff.path = $p' --arg p "${_p}" || { _pause; continue; }
                    config_commit  || { log_error "更新失败"; _pause; continue; }
                    state_persist  || log_warn "state.json 写入失败"
                    log_ok "path 已修改: ${_p}"; print_nodes
                fi ;;
            3)
                state_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                config_commit || { log_error "卸载失败"; _pause; continue; }
                state_persist || log_warn "state.json 写入失败"
                log_ok "FreeFlow 已卸载" ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── §20 主菜单 ────────────────────────────────────────────────────────────────
menu() {
    while true; do
        local _xs _as _cx _xc _fd _ad _dom
        _xs=$(check_xray); _cx=$?
        _as=$(check_argo)
        [ "${_cx}" -eq 0 ] && _xc="${_GRN}" || _xc="${_RED}"

        local _fen _fpt _fpa
        _fen=$(state_get '.ff.enabled')
        _fpt=$(state_get '.ff.protocol')
        _fpa=$(state_get '.ff.path')
        [ "${_fen}" = "true" ] && [ "${_fpt}" != "none" ] \
            && _fd="${_fpt} (path=${_fpa})" || _fd="未启用"

        _dom=$(state_get '.argo.domain')
        if [ "$(state_get '.argo.enabled')" = "true" ]; then
            [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
                && _ad="${_as} [$(state_get '.argo.protocol'), 固定: ${_dom}]" \
                || _ad="${_as} [WS, 临时]"
        else
            _ad="未启用"
        fi

        clear; echo ""
        printf "${_BOLD}${_PUR}  ╔═══════════════════════════════╗${_RST}\n"
        printf "${_BOLD}${_PUR}  ║     Xray-2go  v3.1            ║${_RST}\n"
        printf "${_BOLD}${_PUR}  ╠═══════════════════════════════╣${_RST}\n"
        printf "${_BOLD}${_PUR}  ║${_RST}  Xray : ${_xc}%-22s${_RST}${_PUR} ${_RST}\n" "${_xs}"
        printf "${_BOLD}${_PUR}  ║${_RST}  Argo : %-22s${_PUR} ${_RST}\n" "${_ad}"
        printf "${_BOLD}${_PUR}  ║${_RST}  FF   : %-22s${_PUR} ${_RST}\n" "${_fd}"
        printf "${_BOLD}${_PUR}  ╚═══════════════════════════════╝${_RST}\n\n"

        printf "  ${_GRN}1.${_RST} 安装 Xray-2go\n"
        printf "  ${_RED}2.${_RST} 卸载 Xray-2go\n"; _hr
        printf "  ${_GRN}3.${_RST} Argo 管理\n"
        printf "  ${_GRN}4.${_RST} FreeFlow 管理\n"; _hr
        printf "  ${_GRN}5.${_RST} 查看节点\n"
        printf "  ${_GRN}6.${_RST} 修改 UUID\n"
        printf "  ${_GRN}7.${_RST} 快捷方式/脚本更新\n"; _hr
        printf "  ${_RED}0.${_RST} 退出\n\n"
        local _c; prompt "请输入选择 (0-7): " _c; echo ""

        case "${_c:-}" in
            1)
                if [ "${_cx}" -eq 0 ]; then
                    log_warn "Xray-2go 已安装，如需重装请先卸载 (选项 2)"
                else
                    ask_argo_mode
                    [ "$(state_get '.argo.enabled')" = "true" ] && ask_argo_protocol
                    ask_freeflow_mode

                    [ "$(state_get '.argo.enabled')" = "true" ] && \
                        port_in_use "$(state_get '.argo.port')" && \
                        log_warn "端口 $(state_get '.argo.port') 已被占用，可安装后修改"
                    [ "$(state_get '.ff.enabled')" = "true" ] && port_in_use 8080 && \
                        log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"

                    check_systemd_resolved
                    check_bbr

                    install_core || { log_error "安装失败"; _pause; continue; }

                    if [ "$(state_get '.argo.protocol')" = "xhttp" ]; then
                        log_warn "XHTTP 仅支持固定隧道，现在进入配置..."
                        configure_fixed_tunnel \
                            || log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"

                    elif [ "$(state_get '.argo.enabled')" = "true" ]; then
                        echo ""
                        printf "  ${_GRN}1.${_RST} 临时隧道 (WS, 自动域名) ${_YLW}[默认]${_RST}\n"
                        printf "  ${_GRN}2.${_RST} 固定隧道 (自有 token/json)\n"
                        local _tc; prompt "请选择隧道类型 (回车默认1): " _tc
                        case "${_tc:-1}" in
                            2)
                                if configure_fixed_tunnel; then :; else
                                    log_warn "固定隧道配置失败，回退临时隧道"
                                    _svc_manager restart tunnel || true
                                    local _td; _td=$(get_temp_domain) || _td=""
                                    if [ -n "${_td:-}" ]; then
                                        state_set '.argo.domain = $d' --arg d "${_td}" \
                                            && state_persist || true
                                        log_ok "ArgoDomain: ${_td}"
                                    else
                                        log_warn "未能获取临时域名，可从 [3→4] 刷新"
                                    fi
                                fi ;;
                            *)
                                log_step "等待临时域名（最多约 44s）..."
                                _svc_manager restart tunnel || true
                                local _td; _td=$(get_temp_domain) || _td=""
                                if [ -n "${_td:-}" ]; then
                                    state_set '.argo.domain = $d' --arg d "${_td}" \
                                        && state_persist || true
                                    log_ok "ArgoDomain: ${_td}"
                                else
                                    log_warn "未能获取临时域名，可从 [3→4] 刷新"
                                fi ;;
                        esac
                    fi
                    print_nodes
                fi ;;
            2) uninstall_all ;;
            3) manage_argo ;;
            4) manage_freeflow ;;
            5) [ "${_cx}" -eq 0 ] && print_nodes || log_warn "Xray-2go 未安装或未运行" ;;
            6) [ -f "${CONFIG_FILE}" ] && manage_uuid || log_warn "请先安装 Xray-2go" ;;
            7) install_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-7" ;;
        esac
        _pause
    done
}

# ── §21 入口 ──────────────────────────────────────────────────────────────────
main() {
    check_root       # 权限检查
    _detect_init     # init 系统检测
    preflight_check  # 依赖预检（jq 必须在 state_init 前就绪）
    state_init       # SSOT 引导
    menu
}

main "$@"
