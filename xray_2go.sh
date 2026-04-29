#!/usr/bin/env bash
# ==============================================================================
# xray-2go v8.3  — Xray 落地代理管理脚本（结构级重构版）
# 协议支持：Argo 固定隧道(WS/XHTTP) · FreeFlow(WS/HTTPUpgrade/XHTTP/TCP-HTTP)
#           Reality(TCP/XHTTP) · VLESS-TCP 明文落地
# 平台支持：Debian/Ubuntu (systemd) · Alpine (OpenRC)
# ==============================================================================
set -uo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] \
    || { printf '\033[1;91m[ERR ] 需要 bash 4.0 或更高版本\033[0m\n' >&2; exit 1; }

# ==============================================================================
# §L1  全局常量（只读，零副作用）
# ==============================================================================
readonly WORK_DIR="/etc/xray2go"
readonly XRAY_BIN="${WORK_DIR}/xray"
readonly ARGO_BIN="${WORK_DIR}/argo"
readonly CONFIG_FILE="${WORK_DIR}/config.json"
readonly STATE_FILE="${WORK_DIR}/state.json"
readonly SHORTCUT="/usr/local/bin/s"
readonly SELF_DEST="/usr/local/bin/xray2go"
readonly UPSTREAM_URL="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"

# 内部路径
readonly _LOCK_FILE="${WORK_DIR}/.lock"
readonly _FW_PORTS_FILE="${WORK_DIR}/.fw_ports"
readonly _SYSCTL_FILE="/etc/sysctl.d/99-xray2go.conf"
readonly _HOSTS_BAK="${WORK_DIR}/.hosts.bak"
# Argo token env file（避免 shell 拼接注入）
readonly _ARGO_ENV_FILE="${WORK_DIR}/.argo_env"

readonly _SVC_XRAY="xray2go"
readonly _SVC_TUNNEL="tunnel2go"

readonly _XRAY_MIRRORS=(
    "https://github.com/XTLS/Xray-core/releases/download"
    "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download"
    "https://hub.fastgit.xyz/XTLS/Xray-core/releases/download"
)

readonly _XPAD_JSON='{"xPaddingObfsMode":true,"xPaddingMethod":"tokenish","xPaddingPlacement":"queryInHeader","xPaddingHeader":"X-Cache","xPaddingKey":"_Luckylos"}'
readonly _XPAD_QS='%22xPaddingObfsMode%22%3Atrue%2C%22xPaddingMethod%22%3A%22tokenish%22%2C%22xPaddingPlacement%22%3A%22queryInHeader%22%2C%22xPaddingHeader%22%3A%22X-Cache%22%2C%22xPaddingKey%22%3A%22_Luckylos%22'

# 协议注册表（顺序即入站顺序）
readonly _PROTO_REGISTRY=( argo ff reality vltcp )

# ==============================================================================
# §L2  临时文件沙箱
# ==============================================================================
# 所有临时文件强制在 WORK_DIR/.tmp_* ，保证与目标文件同一文件系统
# 从而使 mv 保持原子性（rename syscall）

_G_TMP_DIR=""

trap '_trap_exit' EXIT
trap '_trap_int'  INT TERM

_trap_exit() {
    [ -n "${_G_TMP_DIR:-}" ] && rm -rf "${_G_TMP_DIR}" 2>/dev/null || true
    [ -t 1 ] && tput cnorm 2>/dev/null || true
}

_trap_int() {
    printf '\n' >&2
    printf '\033[1;91m[ERR ] 已中断\033[0m\n' >&2
    exit 130
}

# 确保 WORK_DIR 存在，创建同 FS 临时目录
_ensure_tmp_dir() {
    if [ -z "${_G_TMP_DIR:-}" ]; then
        mkdir -p "${WORK_DIR}" 2>/dev/null || true
        _G_TMP_DIR=$(mktemp -d "${WORK_DIR}/.tmp_XXXXXX") \
            || { printf '\033[1;91m[ERR ] 无法在 %s 创建临时目录\033[0m\n' "${WORK_DIR}" >&2; exit 1; }
    fi
}

tmp_file() {
    _ensure_tmp_dir
    mktemp "${_G_TMP_DIR}/${1:-tmp_XXXXXX}"
}

# ==============================================================================
# §L3  Utils — 日志、安全输出、字符串工具
# ==============================================================================
readonly C_RST=$'\033[0m'  C_BOLD=$'\033[1m'
readonly C_RED=$'\033[1;91m'  C_GRN=$'\033[1;32m'  C_YLW=$'\033[1;33m'
readonly C_PUR=$'\033[1;35m'  C_CYN=$'\033[1;36m'

log_info()  { printf '%s[INFO]%s %s\n'     "${C_CYN}" "${C_RST}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n'     "${C_GRN}" "${C_RST}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'     "${C_YLW}" "${C_RST}" "$*" >&2; }
log_error() { printf '%s[ERR ]%s %s\n'     "${C_RED}" "${C_RST}" "$*" >&2; }
log_step()  { printf '%s[....] %s%s\n'     "${C_PUR}" "$*" "${C_RST}"; }
log_title() { printf '\n%s%s%s\n'          "${C_BOLD}${C_PUR}" "$*" "${C_RST}"; }

die() { log_error "$1"; exit "${2:-1}"; }

prompt() {
    # 格式串固定，避免用户数据污染格式
    printf '%s%s%s' "${C_RED}" "$1" "${C_RST}" >&2
    read -r "$2" </dev/tty
}

_pause() {
    local _d
    printf '%s按回车键继续...%s' "${C_RED}" "${C_RST}" >&2
    read -r _d </dev/tty || true
}

_hr() { printf '%s  ──────────────────────────────────%s\n' "${C_PUR}" "${C_RST}"; }

# 安全打印节点链接（B5 修复：格式串固定，颜色作参数）
_print_link() {
    local _link="$1"
    [ -n "${_link:-}" ] && printf '%s%s%s\n' "${C_CYN}" "${_link}" "${C_RST}"
}

# URL 路径编码
urlencode_path() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/'\''/%27/g;s/(/%28/g;s/)/%29/g;s/\*/%2A/g;s/+/%2B/g;
         s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;s/?/%3F/g;s/@/%40/g;
         s/\[/%5B/g;s/\]/%5D/g'
}

# ==============================================================================
# §L4  Platform — 检测、包管理、网络
# ==============================================================================
_G_INIT_SYS=""
_G_ARCH_CF=""
_G_ARCH_XRAY=""
_G_CACHED_REALIP=""

platform_detect_init() {
    if [ -f /.dockerenv ] || \
       grep -qE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null; then
        log_warn "检测到容器环境，服务管理功能可能受限"
    fi
    local _pid1_comm
    _pid1_comm=$(cat /proc/1/comm 2>/dev/null | tr -d '\n' || printf 'unknown')
    if [ "${_pid1_comm}" = "systemd" ] && command -v systemctl >/dev/null 2>&1; then
        _G_INIT_SYS="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        _G_INIT_SYS="openrc"
    else
        die "不支持的 init 系统（PID 1: ${_pid1_comm}，需要 systemd 或 OpenRC）"
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
        if ! find /var/cache/apt/pkgcache.bin -mtime -1 >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        fi
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v dnf  >/dev/null 2>&1; then dnf install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v yum  >/dev/null 2>&1; then yum install -y "${_pkg}" >/dev/null 2>&1; _rc=$?
    elif command -v apk  >/dev/null 2>&1; then apk add       "${_pkg}" >/dev/null 2>&1; _rc=$?
    else die "未找到包管理器，无法安装 ${_pkg}"; fi
    hash -r 2>/dev/null || true
    [ "${_rc}" -ne 0 ] && die "${_pkg} 安装失败 (exit ${_rc})，请手动安装后重试"
    command -v "${_bin}" >/dev/null 2>&1 \
        || die "${_bin} 安装后仍不可用，请检查 ${_pkg} 包名是否正确"
    log_ok "${_pkg} 已就绪"
}

platform_preflight() {
    log_step "依赖预检..."
    for _d in curl unzip jq; do platform_pkg_require "${_d}"; done
    command -v xxd >/dev/null 2>&1 \
        || platform_pkg_require "xxd" "xxd" 2>/dev/null \
        || log_info "xxd 未安装 — Reality shortId 将 fallback 到 openssl/od"
    command -v openssl >/dev/null 2>&1 \
        || log_info "openssl 未安装 — Reality shortId 将由 /dev/urandom 生成"
    if [ -f "${XRAY_BIN}" ]; then
        [ -x "${XRAY_BIN}" ] || { chmod +x "${XRAY_BIN}"; log_warn "已修复 xray 可执行位"; }
        "${XRAY_BIN}" version >/dev/null 2>&1 || log_warn "xray 二进制可能损坏，建议重新安装"
    fi
    [ -f "${ARGO_BIN}" ] && ! [ -x "${ARGO_BIN}" ] \
        && { chmod +x "${ARGO_BIN}"; log_warn "已修复 cloudflared 可执行位"; }
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
# §L_PORT  Port Manager — 精确端口检测（唯一入口）
# ==============================================================================
# 所有端口占用检查必须经过此模块，禁止在其他地方直接调用 ss/netstat/proc

# 精确检测端口是否被监听（B10 修复：精确匹配，无前缀误报）
port_mgr_in_use() {
    local _p="$1"
    # 方法1：ss 精确匹配（`:PORT ` 或 `:PORT$`）
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null \
            | awk -v p="${_p}" \
                'BEGIN{r=0} {
                    # 提取第4列地址:端口，精确比较端口部分
                    split($4, a, ":");
                    if (a[length(a)] == p) { r=1; exit }
                } END{exit !r}'
        return $?
    fi
    # 方法2：netstat 精确匹配
    if command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null \
            | awk -v p="${_p}" \
                'BEGIN{r=0} {
                    split($4, a, ":");
                    if (a[length(a)] == p) { r=1; exit }
                } END{exit !r}'
        return $?
    fi
    # 方法3：/proc/net/tcp 精确 hex 匹配（B10 修复：hex 精确匹配）
    local _hex
    _hex=$(printf '%04X' "${_p}")
    awk -v h="${_hex}" \
        'NR>1 {
            # 第2列格式 local_addr:local_port（hex），精确匹配端口部分
            n = split($2, a, ":");
            if (a[n] == h) { found=1; exit }
        } END{exit !found}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# 随机选取空闲端口
port_mgr_random() {
    local _i=0 _p
    while true; do
        _p=$(shuf -i 10000-60000 -n 1 2>/dev/null \
             || awk 'BEGIN{srand();print int(rand()*50000)+10000}')
        _i=$(( _i + 1 ))
        port_mgr_in_use "${_p}" || { printf '%s' "${_p}"; return 0; }
        [ "${_i}" -gt 30 ] && { log_error "无法在 10000-60000 中找到空闲端口"; return 1; }
    done
}

# ==============================================================================
# §L5  State — 读/写/持久化（with_lock + atomic_write）
# ==============================================================================
_G_STATE=""

readonly _STATE_DEFAULT='{
  "uuid":    "",
  "argo":    {"enabled":true,  "protocol":"ws",   "port":8888,
              "mode":"fixed",  "domain":null,      "token":null},
  "ff":      {"enabled":false, "protocol":"none", "path":"/", "host":""},
  "reality": {"enabled":false, "port":443, "sni":"addons.mozilla.org",
              "network":"tcp", "pbk":null, "pvk":null, "sid":null},
  "vltcp":   {"enabled":false, "port":1234, "listen":"0.0.0.0"},
  "xpad":    {"enabled":true},
  "cfip":    "cf.tencentapp.cn",
  "cfport":  "443"
}'

# ── 原子写入（B4 修复：同 FS tmp → rename）─────────────────────────────────
# 用法：atomic_write <目标文件> <内容>
# 所有写文件操作必须经过此函数
atomic_write() {
    local _dest="$1" _content="$2"
    local _dir; _dir=$(dirname "${_dest}")
    mkdir -p "${_dir}" 2>/dev/null || true
    local _t; _t=$(tmp_file "aw_XXXXXX") || return 1
    printf '%s' "${_content}" > "${_t}" || { rm -f "${_t}"; return 1; }
    mv "${_t}" "${_dest}" || { rm -f "${_t}"; return 1; }
}

# 原子写入 + 保留 N 份备份（B6 修复：保留 3 份）
atomic_write_with_backup() {
    local _dest="$1" _content="$2" _keep="${3:-3}"
    if [ -f "${_dest}" ]; then
        local _ts; _ts=$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'bak')
        cp -f "${_dest}" "${_dest}.${_ts}.bak" 2>/dev/null || true
        # 保留最新 _keep 份，删除其余
        ls -t "${_dest}".*.bak 2>/dev/null \
            | tail -n "+$(( _keep + 1 ))" \
            | xargs rm -f 2>/dev/null || true
    fi
    atomic_write "${_dest}" "${_content}"
}

# ── 文件锁（S5 修复：串行化所有 read-modify-write）───────────────────────────
# 用法：with_lock <函数名> [参数...]
# 需要 flock（util-linux，Debian/Alpine 均默认安装）
with_lock() {
    local _fn="$1"; shift
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 9 || { log_error "获取文件锁失败"; exit 1; }
            "${_fn}" "$@"
        ) 9>"${_LOCK_FILE}"
    else
        # flock 不可用时降级（无锁，仅 warn）
        log_warn "flock 不可用，并发写入无保护"
        "${_fn}" "$@"
    fi
}

# ── State 读/写 ───────────────────────────────────────────────────────────────

st_get() {
    local _v
    _v=$(printf '%s' "${_G_STATE}" | jq -r "${1} // empty" 2>/dev/null) || true
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

# 内部：实际持久化逻辑（由 with_lock 包裹）
_st_persist_inner() {
    local _json
    _json=$(printf '%s\n' "${_G_STATE}" | jq . 2>/dev/null) \
        || { log_error "state 序列化失败"; return 1; }
    atomic_write_with_backup "${STATE_FILE}" "${_json}" 3
}

# 公开接口：带锁持久化
st_persist() {
    with_lock _st_persist_inner
}

_st_merge_defaults() {
    local _c

    _c=$(st_get '.vltcp')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && \
        st_set '.vltcp = {"enabled":false,"port":1234,"listen":"0.0.0.0"}'

    _c=$(st_get '.reality.network')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.reality.network = "tcp"'

    _c=$(st_get '.cfip')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfip = "cf.tencentapp.cn"'

    _c=$(st_get '.cfport')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.cfport = "443"'

    _c=$(st_get '.ff.host')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.ff.host = ""'

    _c=$(st_get '.xpad.enabled')
    { [ -z "${_c:-}" ] || [ "${_c}" = "null" ]; } && st_set '.xpad.enabled = true'
}

st_init() {
    if [ -f "${STATE_FILE}" ]; then
        local _raw; _raw=$(cat "${STATE_FILE}" 2>/dev/null || true)
        if printf '%s' "${_raw}" | jq -e . >/dev/null 2>&1; then
            _G_STATE="${_raw}"
            _st_merge_defaults
            local _u; _u=$(st_get '.uuid')
            [ -z "${_u:-}" ] && st_set '.uuid = $u' --arg u "$(crypto_gen_uuid)"
            return 0
        fi
        log_warn "state.json 损坏，重置为默认值..."
    fi
    _G_STATE="${_STATE_DEFAULT}"
    _st_merge_defaults
    local _u; _u=$(st_get '.uuid')
    [ -z "${_u:-}" ] && st_set '.uuid = $u' --arg u "$(crypto_gen_uuid)"
    [ -d "${WORK_DIR}" ] && { st_persist 2>/dev/null || true; log_info "状态已初始化并持久化"; }
}

# ==============================================================================
# §L6  Firewall — 声明式 reconcile（S1/S2 修复）
# ==============================================================================

# 根据 state 计算「期望开放」端口集合（S1 修复：加入 argo.port）
fw_desired_ports() {
    local _out=""
    # Argo 回源端口（S1 修复：原来遗漏）
    [ "$(st_get '.argo.enabled')" = "true" ] && \
        _out="${_out}$(st_get '.argo.port')\n"
    [ "$(st_get '.reality.enabled')" = "true" ] && \
        _out="${_out}$(st_get '.reality.port')\n"
    [ "$(st_get '.vltcp.enabled')" = "true" ] && \
        _out="${_out}$(st_get '.vltcp.port')\n"
    [ "$(st_get '.ff.enabled')" = "true" ] && \
        [ "$(st_get '.ff.protocol')" != "none" ] && \
        _out="${_out}8080\n"
    printf '%b' "${_out}" | grep -E '^[0-9]+$' | sort -un
}

# 读取已管理的端口集合
_fw_read_managed() {
    grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null | sort -un || true
}

# 检测 nftables 是否可用（S2 修复）
_fw_has_nftables() {
    command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1
}

# 检测 nftables 是否已有 xray2go 专用 table
_fw_nft_table_exists() {
    nft list table inet xray2go >/dev/null 2>&1
}

_fw_nft_ensure_table() {
    _fw_nft_table_exists && return 0
    nft add table inet xray2go 2>/dev/null || return 1
    nft add chain inet xray2go input '{ type filter hook input priority 0; policy accept; }' \
        2>/dev/null || return 1
}

# 开放单个端口（S2 修复：优先 nftables）
_fw_open_port() {
    local _port="$1" _proto="${2:-tcp}"
    local _any=0

    # nftables（优先，S2 修复）
    if _fw_has_nftables; then
        _fw_nft_ensure_table 2>/dev/null || true
        if ! nft list chain inet xray2go input 2>/dev/null \
             | grep -q "tcp dport ${_port} accept"; then
            nft add rule inet xray2go input \
                "${_proto}" dport "${_port}" accept 2>/dev/null && _any=1
        fi
    fi

    # ufw
    if command -v ufw >/dev/null 2>&1 && \
       ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! ufw status numbered 2>/dev/null \
             | grep -qE "^[[:space:]]*[0-9]+.*${_port}/${_proto}"; then
            ufw allow "${_port}/${_proto}" >/dev/null 2>&1 && _any=1
        fi
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && \
       firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --query-port="${_port}/${_proto}" \
             --permanent >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${_port}/${_proto}" >/dev/null 2>&1 && \
                firewall-cmd --reload >/dev/null 2>&1 && _any=1
        fi
    fi

    # iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || {
            iptables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null
            _any=1
        }
        ip6tables -C INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null || {
            ip6tables -I INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null \
                || true
        }
    fi

    [ "${_any}" -eq 1 ] \
        && log_ok  "防火墙已开放: ${_port}/${_proto}" \
        || log_info "防火墙端口已存在: ${_port}/${_proto}"
}

# 关闭单个端口（S2 修复：优先 nftables）
_fw_close_port() {
    local _port="$1" _proto="${2:-tcp}"

    # nftables（S2 修复）
    if _fw_has_nftables && _fw_nft_table_exists; then
        # 找到并删除匹配规则的 handle
        local _handle
        _handle=$(nft -a list chain inet xray2go input 2>/dev/null \
            | grep "${_proto} dport ${_port} accept" \
            | grep -oE 'handle [0-9]+' | awk '{print $2}' | head -1)
        [ -n "${_handle:-}" ] && \
            nft delete rule inet xray2go input handle "${_handle}" 2>/dev/null || true
    fi

    # ufw
    if command -v ufw >/dev/null 2>&1 && \
       ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw delete allow "${_port}/${_proto}" >/dev/null 2>&1 || true
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && \
       firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${_port}/${_proto}" >/dev/null 2>&1 && \
            firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # iptables
    if command -v iptables >/dev/null 2>&1; then
        local _n=0
        while iptables -C INPUT -p "${_proto}" --dport "${_port}" \
              -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null \
                || break
            _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
        done
        _n=0
        while ip6tables -C INPUT -p "${_proto}" --dport "${_port}" \
              -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -p "${_proto}" --dport "${_port}" -j ACCEPT 2>/dev/null \
                || break
            _n=$(( _n + 1 )); [ "${_n}" -gt 20 ] && break
        done
    fi
    log_info "防火墙已关闭: ${_port}/${_proto}"
}

# 声明式 reconcile：diff(期望, 已管理) → open/close
fw_reconcile() {
    log_step "同步防火墙规则..."
    mkdir -p "${WORK_DIR}"
    local _expected _managed _p

    _expected=$(fw_desired_ports)
    _managed=$(_fw_read_managed)

    for _p in ${_managed}; do
        printf '%s\n' ${_expected} | grep -qx "${_p}" || _fw_close_port "${_p}" tcp
    done
    for _p in ${_expected}; do
        _fw_open_port "${_p}" tcp
    done

    if [ -n "${_expected:-}" ]; then
        printf '%s\n' ${_expected} > "${_FW_PORTS_FILE}" 2>/dev/null || true
    else
        rm -f "${_FW_PORTS_FILE}" 2>/dev/null || true
    fi
}

# 强制清理所有托管端口（卸载时）
fw_force_cleanup() {
    log_step "清理 xray2go 托管防火墙规则..."
    local _ports="" _p

    [ -f "${_FW_PORTS_FILE}" ] && \
        _ports=$(grep -E '^[0-9]+$' "${_FW_PORTS_FILE}" 2>/dev/null || true)

    if [ -f "${STATE_FILE}" ]; then
        for _p in \
            "$(st_get '.argo.port'    2>/dev/null || true)" \
            "$(st_get '.reality.port' 2>/dev/null || true)" \
            "$(st_get '.vltcp.port'   2>/dev/null || true)"; do
            case "${_p:-}" in ''|null|*[!0-9]*) continue;; esac
            _ports=$(printf '%s\n%s' "${_ports}" "${_p}")
        done
    fi

    local _uniq
    _uniq=$(printf '%s\n' ${_ports} | grep -E '^[0-9]+$' | sort -un)
    for _p in ${_uniq}; do _fw_close_port "${_p}" tcp 2>/dev/null || true; done

    # nftables：删除整个 xray2go table
    if _fw_has_nftables && _fw_nft_table_exists; then
        nft delete table inet xray2go 2>/dev/null || true
    fi

    rm -f "${_FW_PORTS_FILE}" 2>/dev/null || true
    log_ok "防火墙规则清理完成"
}

# ==============================================================================
# §L_LIFECYCLE  系统变更生命周期（B2/B3/S6 修复）
# ==============================================================================
# 所有系统级修改（sysctl / hosts）必须通过此模块
# 安装时 apply，卸载时 rollback，保证可追踪、可回滚

# 应用 sysctl（B2 修复：写 drop-in 文件，持久化 + 可回滚）
lifecycle_apply_sysctl() {
    is_openrc || return 0  # 仅 OpenRC 需要
    log_step "持久化内核参数..."
    local _content
    _content="# xray2go managed - do not edit manually
net.ipv4.ping_group_range = 0 0
"
    atomic_write "${_SYSCTL_FILE}" "${_content}" || {
        log_warn "sysctl drop-in 写入失败，ping_group_range 可能重启后丢失"
        return 0
    }
    sysctl -p "${_SYSCTL_FILE}" >/dev/null 2>&1 || true
    log_ok "sysctl 已持久化: ${_SYSCTL_FILE}"
}

# 回滚 sysctl（S6/B2 修复：卸载时删除）
lifecycle_rollback_sysctl() {
    [ -f "${_SYSCTL_FILE}" ] || return 0
    rm -f "${_SYSCTL_FILE}" 2>/dev/null || true
    log_info "sysctl drop-in 已清除: ${_SYSCTL_FILE}"
}

# 应用 /etc/hosts 补丁（B3 修复：先备份，再精确修改）
lifecycle_apply_hosts_patch() {
    is_openrc || return 0  # 仅 OpenRC 需要
    # 备份（幂等：若备份已存在则跳过）
    [ -f "${_HOSTS_BAK}" ] || cp -f /etc/hosts "${_HOSTS_BAK}" 2>/dev/null || {
        log_warn "/etc/hosts 备份失败，跳过 hosts 修补"
        return 0
    }
    log_step "修补 /etc/hosts..."
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts 2>/dev/null || true
    sed -i '2s/.*/::1         localhost/'  /etc/hosts 2>/dev/null || true
    log_ok "/etc/hosts 已修补（备份: ${_HOSTS_BAK}）"
}

# 回滚 /etc/hosts（S6/B3 修复：卸载时从备份恢复）
lifecycle_rollback_hosts() {
    [ -f "${_HOSTS_BAK}" ] || return 0
    cp -f "${_HOSTS_BAK}" /etc/hosts 2>/dev/null && {
        rm -f "${_HOSTS_BAK}" 2>/dev/null || true
        log_ok "/etc/hosts 已从备份恢复"
    } || log_warn "/etc/hosts 恢复失败，请手动恢复: ${_HOSTS_BAK}"
}

# 清理 cloudflared 用户目录（S6 修复）
lifecycle_cleanup_cloudflared() {
    local _cf_dir="${HOME}/.cloudflared"
    [ -d "${_cf_dir}" ] && {
        rm -rf "${_cf_dir}" 2>/dev/null || true
        log_info "已清理 cloudflared 用户目录: ${_cf_dir}"
    } || true
}

# ==============================================================================
# §L7  Svc — systemd/OpenRC 统一 Adapter（S7 修复）
# ==============================================================================
# 所有 systemd/OpenRC 差异封装在此层，调用方零感知
# _svc_write_file 返回值语义：始终 return 0；通过 _G_SYSD_DIRTY 标记变更

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

svc_reload_daemon() {
    is_systemd && [ "${_G_SYSD_DIRTY}" -eq 1 ] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
    _G_SYSD_DIRTY=0
}

# S7 修复：函数始终 return 0；内容变更时显式设置 _G_SYSD_DIRTY=1
_svc_write_file() {
    local _dest="$1" _content="$2"
    local _cur; _cur=$(cat "${_dest}" 2>/dev/null || printf '')
    if [ "${_cur}" != "${_content}" ]; then
        atomic_write "${_dest}" "${_content}" || return 0  # 写失败不致命
        is_systemd && _G_SYSD_DIRTY=1
    fi
    return 0  # 始终成功，变更状态由 _G_SYSD_DIRTY 表达
}

# ── 服务单元模板 ──────────────────────────────────────────────────────────────

_svc_tpl_xray_systemd() {
    printf '[Unit]\nDescription=Xray2go Service\nDocumentation=https://github.com/XTLS/Xray-core\nAfter=network.target nss-lookup.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nExecStart=%s run -c %s\nRestart=always\nRestartSec=3\nRestartPreventExitStatus=23\nLimitNOFILE=1048576\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

# systemd tunnel：ExecStart 直接用数组参数，不做 shell 拼接
_svc_tpl_tunnel_systemd() {
    local _cmd="$1"
    printf '[Unit]\nDescription=Cloudflare Tunnel2go\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nExecStart=%s\nRestart=on-failure\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
        "${_cmd}"
}

_svc_tpl_xray_openrc() {
    printf '#!/sbin/openrc-run\ndescription="Xray2go service"\ncommand="%s"\ncommand_args="run -c %s"\ncommand_background=true\noutput_log="/dev/null"\nerror_log="/dev/null"\npidfile="/var/run/xray2go.pid"\n' \
        "${XRAY_BIN}" "${CONFIG_FILE}"
}

# B1 修复：OpenRC tunnel 改用 EnvironmentFile 传参，不再 shell 拼接 token
# token 写入独立 env file，避免单引号注入
_svc_tpl_tunnel_openrc_with_envfile() {
    # $1 = cloudflared 二进制路径
    # token 从 _ARGO_ENV_FILE 中以 ARGO_TOKEN= 形式读取
    printf '#!/sbin/openrc-run\ndescription="Cloudflare Tunnel2go"\ndepend() {\n    need net\n}\nstart() {\n    . %s\n    if [ -f "%s" ]; then\n        ebegin "Starting tunnel2go (config)"\n        start-stop-daemon --start --background \\\n            --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n            --exec %s -- tunnel --no-autoupdate run --config %s\n        eend $?\n    else\n        ebegin "Starting tunnel2go (token)"\n        start-stop-daemon --start --background \\\n            --make-pidfile --pidfile /var/run/tunnel2go.pid \\\n            --exec %s -- tunnel --no-autoupdate run --token "${ARGO_TOKEN}"\n        eend $?\n    fi\n}\nstop() {\n    start-stop-daemon --stop --pidfile /var/run/tunnel2go.pid\n}\n' \
        "${_ARGO_ENV_FILE}" \
        "${WORK_DIR}/tunnel.yml" \
        "${ARGO_BIN}" \
        "${WORK_DIR}/tunnel.yml" \
        "${ARGO_BIN}"
}

# systemd tunnel：根据模式生成正确的 ExecStart（参数列表，非拼接字符串）
_svc_tpl_tunnel_systemd_with_envfile() {
    if [ -f "${WORK_DIR}/tunnel.yml" ]; then
        _svc_tpl_tunnel_systemd \
            "${ARGO_BIN} tunnel --no-autoupdate run --config ${WORK_DIR}/tunnel.yml"
    else
        # systemd 支持 EnvironmentFile，token 不出现在 ExecStart 中
        printf '[Unit]\nDescription=Cloudflare Tunnel2go\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nNoNewPrivileges=yes\nTimeoutStartSec=0\nEnvironmentFile=%s\nExecStart=%s tunnel --no-autoupdate run --token ${ARGO_TOKEN}\nRestart=on-failure\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n' \
            "${_ARGO_ENV_FILE}" \
            "${ARGO_BIN}"
    fi
}

# 写入 argo env file（B1 修复核心：token 存文件，不拼 shell）
_svc_write_argo_env() {
    local _token; _token=$(st_get '.argo.token')
    # 即使 token 为 null 也写文件（tunnel.yml 模式下不使用 ARGO_TOKEN）
    local _content="ARGO_TOKEN=${_token:-}\n"
    atomic_write "${_ARGO_ENV_FILE}" "$(printf '%b' "${_content}")"
    chmod 600 "${_ARGO_ENV_FILE}" 2>/dev/null || true
}

svc_apply_xray() {
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/${_SVC_XRAY}.service" \
            "$(_svc_tpl_xray_systemd)"
    else
        local _f="/etc/init.d/${_SVC_XRAY}"
        _svc_write_file "${_f}" "$(_svc_tpl_xray_openrc)"
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_apply_tunnel() {
    # B1 修复：先写 env file，再写服务单元
    _svc_write_argo_env
    if is_systemd; then
        _svc_write_file "/etc/systemd/system/${_SVC_TUNNEL}.service" \
            "$(_svc_tpl_tunnel_systemd_with_envfile)"
    else
        local _f="/etc/init.d/${_SVC_TUNNEL}"
        _svc_write_file "${_f}" "$(_svc_tpl_tunnel_openrc_with_envfile)"
        chmod +x "${_f}" 2>/dev/null || true
    fi
}

svc_restart_xray() {
    [ -f "${CONFIG_FILE}" ] || { log_error "配置文件不存在，请先完成安装"; return 1; }
    svc_exec restart "${_SVC_XRAY}" \
        && { log_ok "${_SVC_XRAY} 已重启"; svc_verify_health "${_SVC_XRAY}" 6; } \
        || { log_error "${_SVC_XRAY} 重启失败"; return 1; }
}

svc_verify_health() {
    local _svc="${1:-${_SVC_XRAY}}" _max="${2:-8}"
    log_step "验证服务 ${_svc} 就绪（最长 ${_max}s）..."
    local _i=0
    while [ "${_i}" -lt "${_max}" ]; do
        sleep 1; _i=$(( _i + 1 ))
        svc_exec status "${_svc}" >/dev/null 2>&1 && {
            log_ok "${_svc} 运行正常 (${_i}s 内就绪)"; return 0
        }
    done
    log_error "${_svc} 启动失败（等待 ${_max}s 后仍未就绪）"
    if is_systemd; then
        log_error "── journalctl 最近 20 行 ──"
        journalctl -u "${_svc}" --no-pager -n 20 2>/dev/null >&2 || true
        log_error "── systemctl status ──"
        systemctl status "${_svc}" --no-pager -l 2>/dev/null >&2 || true
    else
        log_error "OpenRC 模式下请手动执行: rc-service ${_svc} status"
    fi
    return 1
}

# ==============================================================================
# §L8  Crypto — UUID、x25519、shortId
# ==============================================================================

crypto_gen_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | \
    awk 'BEGIN{srand()}{h=$0;printf "%s-%s-4%s-%s%s-%s\n",
        substr(h,1,8),substr(h,9,4),substr(h,14,3),
        substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

crypto_gen_reality_keypair() {
    [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪，无法生成密钥对"; return 1; }
    local _out _rc
    _out=$("${XRAY_BIN}" x25519 2>&1); _rc=$?
    [ "${_rc}" -ne 0 ] && { log_error "xray x25519 失败 (exit ${_rc})"; return 1; }
    [ -z "${_out:-}" ] && { log_error "xray x25519 无输出"; return 1; }
    local _pvk _pbk
    _pvk=$(printf '%s\n' "${_out}" | grep -i 'private' | awk '{print $NF}' | tr -d '\r\n')
    _pbk=$(printf '%s\n' "${_out}" | grep -i 'public'  | awk '{print $NF}' | tr -d '\r\n')
    if [ -z "${_pvk:-}" ] || [ -z "${_pbk:-}" ]; then
        log_error "密钥解析失败"; return 1
    fi
    local _b64='^[A-Za-z0-9_=-]{20,}$'
    printf '%s' "${_pvk}" | grep -qE "${_b64}" || { log_error "私钥格式异常"; return 1; }
    printf '%s' "${_pbk}" | grep -qE "${_b64}" || { log_error "公钥格式异常"; return 1; }
    st_set '.reality.pvk = $v | .reality.pbk = $b' --arg v "${_pvk}" --arg b "${_pbk}" \
        || return 1
    log_ok "x25519 密钥对已生成 (pubkey: ${_pbk:0:16}...)"
}

crypto_gen_reality_sid() {
    command -v openssl >/dev/null 2>&1 && { openssl rand -hex 8 2>/dev/null; return; }
    command -v xxd    >/dev/null 2>&1 && \
        { head -c 8 /dev/urandom 2>/dev/null | xxd -p | tr -d '\n'; return; }
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# ==============================================================================
# §L9  Protocol — 注册表 + 构建器
# ==============================================================================
# 命名规则：
#   proto_inbound_<n>  → 输出单个 inbound JSON 对象（或空）
#   proto_link_<n>     → 输出节点链接字符串（或空）

_xpad_obj() {
    if [ "$(st_get '.xpad.enabled')" = "true" ]; then
        printf '%s' "${_XPAD_JSON}" | jq -c .
    else
        printf '{}'
    fi
}

_xpad_qs() {
    [ "$(st_get '.xpad.enabled')" = "true" ] && printf '%s' "${_XPAD_QS}" || true
}

# ── Argo ──────────────────────────────────────────────────────────────────────

proto_inbound_argo() {
    [ "$(st_get '.argo.enabled')" = "true" ] || return 0
    local _port _proto _uuid
    _port=$(st_get '.argo.port'); _proto=$(st_get '.argo.protocol')
    _uuid=$(st_get '.uuid')
    case "${_proto}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --argjson x "$(_xpad_obj)" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:"/argo", mode:"auto"} + $x)}}' ;;
        *)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" '{
                port:$port, listen:"127.0.0.1", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"ws",
                    wsSettings:{path:"/argo"}}}' ;;
    esac
}

proto_link_argo() {
    [ "$(st_get '.argo.enabled')" = "true" ] || return 0
    local _domain _proto _uuid _cfip _cfport
    _domain=$(st_get '.argo.domain'); _proto=$(st_get '.argo.protocol')
    _uuid=$(st_get '.uuid');          _cfip=$(st_get '.cfip')
    _cfport=$(st_get '.cfport')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    local _xqs; _xqs=$(_xpad_qs)
    case "${_proto}" in
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto&extra=%%7B%s%%7D#Argo-XHTTP\n' \
                    "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" "${_xqs}"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
                    "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}"
            fi ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
                "${_uuid}" "${_cfip}" "${_cfport}" "${_domain}" "${_domain}" ;;
    esac
}

# ── FreeFlow ──────────────────────────────────────────────────────────────────

proto_inbound_ff() {
    [ "$(st_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(st_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _path _uuid
    _path=$(st_get '.ff.path'); _uuid=$(st_get '.uuid')
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
                streamSettings:{network:"httpupgrade",
                    httpupgradeSettings:{path:$path}}}' ;;
        xhttp)
            jq -n --arg uuid "${_uuid}" --arg path "${_path}" \
                   --argjson x "$(_xpad_obj)" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp",
                    xhttpSettings:({path:$path, mode:"stream-one"} + $x)}}' ;;
        tcphttp)
            local _host; _host=$(st_get '.ff.host')
            jq -n --arg uuid "${_uuid}" --arg host "${_host}" '{
                port:8080, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"tcp",
                    tcpSettings:{header:{
                        type:"http",
                        request:{
                            version:"1.1",
                            method:"GET",
                            path:["/"],
                            headers:{
                                Host:[$host],
                                "User-Agent":["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"],
                                "Accept-Encoding":["gzip, deflate"],
                                Connection:["keep-alive"],
                                Pragma:["no-cache"]
                            }
                        }
                    }}}}' ;;
        *) log_error "proto_inbound_ff: 未知协议 ${_proto}"; return 1 ;;
    esac
}

proto_link_ff() {
    [ "$(st_get '.ff.enabled')" = "true" ] || return 0
    local _proto; _proto=$(st_get '.ff.protocol')
    [ "${_proto}" != "none" ] || return 0
    local _ip; _ip=$(platform_get_realip)
    if [ -z "${_ip:-}" ]; then log_warn "无法获取服务器 IP，FreeFlow 节点已跳过"; return 0; fi
    local _penc _uuid _xqs
    _penc=$(urlencode_path "$(st_get '.ff.path')")
    _uuid=$(st_get '.uuid')
    _xqs=$(_xpad_qs)
    case "${_proto}" in
        ws)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=ws&host=%s&path=%s#FreeFlow-WS\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        httpupgrade)
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FreeFlow-HTTPUpgrade\n' \
                "${_uuid}" "${_ip}" "${_ip}" "${_penc}" ;;
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one&extra=%%7B%s%%7D#FreeFlow-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_ip}" "${_penc}" "${_xqs}"
            else
                printf 'vless://%s@%s:8080?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FreeFlow-XHTTP\n' \
                    "${_uuid}" "${_ip}" "${_ip}" "${_penc}"
            fi ;;
        tcphttp)
            local _henc _host
            _host=$(st_get '.ff.host')
            _henc=$(urlencode_path "${_host}")
            printf 'vless://%s@%s:8080?encryption=none&security=none&type=tcp&headerType=http&host=%s&path=%%2F#FreeFlow-TCP-HTTP\n' \
                "${_uuid}" "${_ip}" "${_henc}" ;;
    esac
}

# ── Reality ───────────────────────────────────────────────────────────────────

proto_inbound_reality() {
    [ "$(st_get '.reality.enabled')" = "true" ] || return 0
    local _pvk; _pvk=$(st_get '.reality.pvk')
    if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
        log_warn "Reality 密钥未就绪，已跳过该入站"; return 0
    fi
    local _port _sni _sid _net _uuid
    _port=$(st_get '.reality.port'); _sni=$(st_get '.reality.sni')
    _sid=$(st_get  '.reality.sid');  _net=$(st_get '.reality.network')
    _net="${_net:-tcp}";              _uuid=$(st_get '.uuid')
    case "${_net}" in
        xhttp)
            jq -n --argjson port "${_port}" --arg uuid "${_uuid}" \
                   --arg sni "${_sni}" --arg pvk "${_pvk}" --arg sid "${_sid}" \
                   --argjson x "$(_xpad_obj)" '{
                port:$port, listen:"::", protocol:"vless",
                settings:{clients:[{id:$uuid}], decryption:"none"},
                streamSettings:{network:"xhttp", security:"reality",
                    realitySettings:{dest:($sni+":443"),
                        serverNames:[$sni], privateKey:$pvk, shortIds:[$sid]},
                    xhttpSettings:({path:"/", mode:"auto"} + $x)}}' ;;
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

proto_link_reality() {
    [ "$(st_get '.reality.enabled')" = "true" ] || return 0
    local _rpbk; _rpbk=$(st_get '.reality.pbk')
    [ -n "${_rpbk:-}" ] && [ "${_rpbk}" != "null" ] || return 0
    local _ip; _ip=$(platform_get_realip)
    if [ -z "${_ip:-}" ]; then log_warn "无法获取服务器 IP，Reality 节点已跳过"; return 0; fi
    local _rnet _uuid _xqs
    _rnet=$(st_get '.reality.network'); _rnet="${_rnet:-tcp}"
    _uuid=$(st_get '.uuid');            _xqs=$(_xpad_qs)
    case "${_rnet}" in
        xhttp)
            if [ -n "${_xqs}" ]; then
                printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=stream-one&extra=%%7B%s%%7D#Reality-XHTTP\n' \
                    "${_uuid}" "${_ip}" "$(st_get '.reality.port')" \
                    "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')" "${_xqs}"
            else
                printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=xhttp&path=%%2F&mode=stream-one#Reality-XHTTP\n' \
                    "${_uuid}" "${_ip}" "$(st_get '.reality.port')" \
                    "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')"
            fi ;;
        *)
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
                "${_uuid}" "${_ip}" "$(st_get '.reality.port')" \
                "$(st_get '.reality.sni')" "${_rpbk}" "$(st_get '.reality.sid')" ;;
    esac
}

# ── VLESS-TCP ─────────────────────────────────────────────────────────────────

proto_inbound_vltcp() {
    [ "$(st_get '.vltcp.enabled')" = "true" ] || return 0
    local _port _listen _uuid
    _port=$(st_get '.vltcp.port'); _listen=$(st_get '.vltcp.listen')
    _uuid=$(st_get '.uuid')
    jq -n --argjson port "${_port}" --arg listen "${_listen}" --arg uuid "${_uuid}" '{
        port:$port, listen:$listen, protocol:"vless",
        settings:{clients:[{id:$uuid}], decryption:"none"}}'
}

proto_link_vltcp() {
    [ "$(st_get '.vltcp.enabled')" = "true" ] || return 0
    local _listen _vhost _uuid
    _listen=$(st_get '.vltcp.listen'); _uuid=$(st_get '.uuid')
    [ "${_listen}" = "0.0.0.0" ] || [ "${_listen}" = "::" ] \
        && _vhost=$(platform_get_realip) || _vhost="${_listen}"
    if [ -z "${_vhost:-}" ]; then
        log_warn "无法获取服务器 IP，VLESS-TCP 节点已跳过"; return 0
    fi
    printf 'vless://%s@%s:%s?type=tcp&security=none#VLESS-TCP\n' \
        "${_uuid}" "${_vhost}" "$(st_get '.vltcp.port')"
}

# ── 注册表遍历 ────────────────────────────────────────────────────────────────

# 遍历注册表，收集所有 inbound，返回 JSON 数组
# B8 修复：_used_keys 改用换行分隔，前置空检查，精确 grep -xF 匹配
proto_build_inbounds() {
    local _ibs="[]" _ib _name
    local _used_keys=""   # 换行分隔的 "listen:port" 集合

    for _name in "${_PROTO_REGISTRY[@]}"; do
        _ib=$(proto_inbound_${_name}) \
            || { log_error "协议配置生成失败 (${_name})"; return 1; }
        [ -n "${_ib:-}" ] || continue

        local _p _l _key
        _p=$(printf '%s' "${_ib}" | jq -r '.port // empty')
        _l=$(printf '%s' "${_ib}" | jq -r '.listen // "0.0.0.0"')
        _key="${_l}:${_p}"

        # B8 修复：空检查 + 换行分隔精确匹配
        if [ -n "${_used_keys:-}" ] && \
           printf '%s\n' "${_used_keys}" | grep -qxF "${_key}"; then
            log_error "端口冲突: ${_key} 已被占用，跳过 [${_name}]"
            log_error "  请在对应管理菜单中修改端口后重新应用配置"
            continue
        fi
        # 追加换行分隔（不用空格）
        if [ -z "${_used_keys:-}" ]; then
            _used_keys="${_key}"
        else
            _used_keys="${_used_keys}
${_key}"
        fi

        _ibs=$(printf '%s' "${_ibs}" | jq --argjson ib "${_ib}" '. + [$ib]') \
            || { log_error "inbounds 组装失败 (${_name})"; return 1; }
    done
    printf '%s' "${_ibs}"
}

# 遍历注册表，输出所有节点链接
proto_print_links() {
    local _name
    for _name in "${_PROTO_REGISTRY[@]}"; do
        proto_link_${_name}
    done
}

# ==============================================================================
# §L10 Config — 配置合成 + 原子提交（with_lock）
# ==============================================================================

config_synthesize() {
    local _ibs
    _ibs=$(proto_build_inbounds) || return 1
    [ "$(printf '%s' "${_ibs}" | jq 'length')" -eq 0 ] && \
        log_warn "所有入站均已禁用，xray 将以零入站模式运行"
    jq -n --argjson inbounds "${_ibs}" '{
        log: { loglevel:"none", access:"none", error:"none" },
        inbounds: $inbounds,
        outbounds: [{ protocol:"freedom", settings:{ domainStrategy:"AsIs" } }],
        policy: {
            levels: { "0": {
                connIdle:300, uplinkOnly:1, downlinkOnly:1,
                statsUserUplink:false, statsUserDownlink:false
            } },
            system: { statsInboundUplink:false, statsInboundDownlink:false }
        }
    }' || { log_error "config JSON 合成失败"; return 1; }
}

# 内部：实际 config 写入逻辑（由 with_lock 包裹）
_config_apply_inner() {
    local _t; _t=$(tmp_file "xray_next_XXXXXX.json") || return 1
    log_step "合成配置..."
    config_synthesize > "${_t}" || return 1

    if [ -x "${XRAY_BIN}" ]; then
        log_step "验证配置 (xray -test)..."
        if ! "${XRAY_BIN}" -test -c "${_t}" >/dev/null 2>&1; then
            log_error "config 验证失败！现场已保留: ${WORK_DIR}/config_failed.json"
            mv "${_t}" "${WORK_DIR}/config_failed.json" 2>/dev/null || true
            return 1
        fi
        log_ok "config 验证通过"
        # B7 修复：验证成功后清理上次失败现场
        rm -f "${WORK_DIR}/config_failed.json" 2>/dev/null || true
    else
        log_warn "xray 未就绪，跳过预检（安装阶段正常）"
    fi

    # B4/B6 修复：atomic_write_with_backup 保证原子写 + 保留 3 份备份
    local _json; _json=$(cat "${_t}")
    atomic_write_with_backup "${CONFIG_FILE}" "${_json}" 3 || {
        log_error "config 写入失败"; return 1
    }
    rm -f "${_t}" 2>/dev/null || true
    log_ok "config.json 已原子更新"

    if svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1; then
        svc_exec restart "${_SVC_XRAY}" || { log_error "xray2go 重启失败"; return 1; }
        log_ok "xray2go 已重启"
    fi
}

# 公开接口：带锁的配置提交
config_apply() {
    with_lock _config_apply_inner
}

# 展示节点链接（B5 修复：使用 _print_link 安全输出）
config_print_nodes() {
    local _links
    _links=$(proto_print_links)
    if [ -z "${_links:-}" ]; then
        echo ""
        log_warn "暂无可用节点（请检查 Argo 域名或服务器 IP）"; return 1
    fi
    echo ""
    # B5 修复：_print_link 格式串固定为 '%s%s%s\n'，颜色作参数，不拼入格式串
    printf '%s\n' "${_links}" | while IFS= read -r _l; do
        _print_link "${_l}"
    done
    echo ""
}

# 组合提交：config_apply + st_persist + fw_reconcile（高频操作封装）
_commit() {
    config_apply  || return 1
    st_persist    || log_warn "state.json 写入失败"
    fw_reconcile
}

# ==============================================================================
# §L11 Download — 统一下载 + 校验 + 重试（S3/S4/S8 修复）
# ==============================================================================

_xray_health_check() {
    local _bin="${1:-${XRAY_BIN}}"
    [ -f "${_bin}" ]  || { log_warn "xray 文件不存在: ${_bin}";         return 1; }
    [ -x "${_bin}" ]  || { log_warn "xray 不可执行: ${_bin}";           return 1; }
    "${_bin}" version >/dev/null 2>&1 \
              || { log_warn "xray version 命令失败，二进制可能已损坏";   return 1; }
    local _tc; _tc=$(tmp_file "xray_hc_XXXXXX.json") || return 1
    printf '{"log":{"loglevel":"none"},"inbounds":[],"outbounds":[{"protocol":"freedom"}]}\n' \
        > "${_tc}"
    "${_bin}" -test -c "${_tc}" >/dev/null 2>&1
    local _rc=$?
    rm -f "${_tc}" 2>/dev/null || true
    [ "${_rc}" -ne 0 ] && { log_warn "xray -test 失败（二进制可能损坏）"; return 1; }
    return 0
}

# S3 修复：加 1 次重试
_xray_latest_tag() {
    local _tag _i
    for _i in 1 2; do
        _tag=$(curl -sfL --max-time 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
            2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null) || true
        [ -n "${_tag:-}" ] && { printf '%s' "${_tag}"; return 0; }
        [ "${_i}" -lt 2 ] && sleep 2
    done
    return 1
}

_xray_download_with_fallback() {
    local _filename="$1" _dest="$2" _tag="$3"
    local _mirror
    for _mirror in "${_XRAY_MIRRORS[@]}"; do
        log_step "下载 ${_filename} ..."
        curl -sfL --connect-timeout 15 --max-time 120 \
            -o "${_dest}" "${_mirror}/${_tag}/${_filename}"
        local _rc=$?
        if [ "${_rc}" -eq 0 ] && [ -s "${_dest}" ]; then
            return 0
        fi
        log_warn "镜像失败，尝试下一个..."
        rm -f "${_dest}" 2>/dev/null || true
    done
    log_error "所有镜像均下载失败: ${_filename}"
    return 1
}

download_xray() {
    platform_detect_arch

    if _xray_health_check "${XRAY_BIN}" 2>/dev/null; then
        local _cur
        _cur=$("${XRAY_BIN}" version 2>/dev/null | head -1 | \
               grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "xray 已存在且健康 (v${_cur:-unknown})，跳过下载"
        return 0
    fi
    log_info "xray 健康检查未通过，重新下载..."
    rm -f "${XRAY_BIN}" 2>/dev/null || true

    local _tag; _tag=$(_xray_latest_tag) || true
    [ -z "${_tag:-}" ] && { log_warn "无法获取版本号，使用 latest"; _tag="latest"; }

    local _zip_name="Xray-linux-${_G_ARCH_XRAY}.zip"
    local _z; _z=$(tmp_file "xray_XXXXXX.zip") || return 1

    _xray_download_with_fallback "${_zip_name}" "${_z}" "${_tag}" || return 1

    if [ "${_tag}" != "latest" ] && command -v sha256sum >/dev/null 2>&1; then
        log_step "校验 SHA256..."
        local _dgst _expected _actual
        _dgst=$(curl -sfL --max-time 15 \
            "https://github.com/XTLS/Xray-core/releases/download/${_tag}/${_zip_name}.dgst" \
            2>/dev/null) || true
        _expected=$(printf '%s' "${_dgst:-}" | grep -i 'SHA2-256' | \
                    awk '{print $NF}' | head -1 | tr -d '[:space:]')
        if [ -n "${_expected:-}" ]; then
            _actual=$(sha256sum "${_z}" | awk '{print $1}')
            if [ "${_actual}" != "${_expected}" ]; then
                log_error "SHA256 校验失败 (期望: ${_expected}, 实际: ${_actual})"
                rm -f "${_z}"; return 1
            fi
            log_ok "SHA256 校验通过"
        else
            log_warn "未获取到 SHA256 校验值，跳过校验"
        fi
    fi

    unzip -t "${_z}" >/dev/null 2>&1 || { log_error "zip 文件损坏"; rm -f "${_z}"; return 1; }
    unzip -o "${_z}" xray -d "${WORK_DIR}/" >/dev/null 2>&1 \
        || { log_error "解压失败"; return 1; }
    [ -f "${XRAY_BIN}" ] || { log_error "解压后未找到 xray 二进制"; return 1; }
    chmod +x "${XRAY_BIN}"

    _xray_health_check "${XRAY_BIN}" \
        || { log_error "新下载的 xray 健康检查失败，已清除"; rm -f "${XRAY_BIN}"; return 1; }
    log_ok "Xray 安装完成 ($("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}'))"
}

# S8 修复：加文件大小下限校验
download_cloudflared() {
    platform_detect_arch
    if [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ]; then
        log_info "cloudflared 已存在，跳过下载"; return 0
    fi
    rm -f "${ARGO_BIN}" 2>/dev/null || true
    local _url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${_G_ARCH_CF}"
    log_step "下载 cloudflared (${_G_ARCH_CF}) ..."
    curl -sfL --connect-timeout 15 --max-time 120 -o "${ARGO_BIN}" "${_url}"
    local _rc=$?
    [ "${_rc}" -ne 0 ] && { rm -f "${ARGO_BIN}"; log_error "cloudflared 下载失败"; return 1; }
    [ -s "${ARGO_BIN}" ] || { rm -f "${ARGO_BIN}"; log_error "cloudflared 文件为空"; return 1; }
    # S8 修复：文件大小下限校验（cloudflared 正常二进制 > 10MB）
    local _size
    _size=$(wc -c < "${ARGO_BIN}" 2>/dev/null || printf '0')
    if [ "${_size}" -lt 5000000 ]; then
        log_error "cloudflared 文件大小异常 (${_size} bytes < 5MB)，可能下载不完整或被替换"
        rm -f "${ARGO_BIN}"; return 1
    fi
    chmod +x "${ARGO_BIN}"
    # 验证可执行性
    "${ARGO_BIN}" --version >/dev/null 2>&1 \
        || { log_warn "cloudflared --version 验证失败，但文件已保留（可能是架构不匹配）"; }
    log_ok "cloudflared 下载完成"
}

# ==============================================================================
# §L12 Install — 安装 / 卸载（含 lifecycle 调用）
# ==============================================================================

# B9 修复：补充 rc-service xray status 检测
_install_detect_existing_xray() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files 2>/dev/null \
            | grep -qiE '^xray[^2]' && return 0
    fi
    [ -f /etc/init.d/xray ] && return 0
    # B9 修复：OpenRC 运行状态检测
    command -v rc-service >/dev/null 2>&1 && \
        rc-service xray status >/dev/null 2>&1 && return 0
    # OpenRC 注册检测
    command -v rc-update >/dev/null 2>&1 && \
        rc-update show 2>/dev/null | grep -q '\bxray\b' && return 0
    local _wx; _wx=$(command -v xray 2>/dev/null || true)
    [ -n "${_wx:-}" ] && [ "${_wx}" != "${XRAY_BIN}" ] && return 0
    pgrep -x xray >/dev/null 2>&1 && return 0
    return 1
}

_install_check_port_conflicts() {
    log_step "检测端口冲突..."
    local _chk_entries=(
        '.argo.port:.argo.enabled'
        '.reality.port:.reality.enabled'
        '.vltcp.port:.vltcp.enabled'
    )
    for _entry in "${_chk_entries[@]}"; do
        local _port_path="${_entry%%:*}" _flag_path="${_entry##*:}"
        [ "$(st_get "${_flag_path}")" = "true" ] || continue
        local _cur; _cur=$(st_get "${_port_path}")
        if port_mgr_in_use "${_cur}"; then
            local _new; _new=$(port_mgr_random) || return 1
            st_set "${_port_path} = (\$p|tonumber)" --arg p "${_new}" || return 1
            log_ok "端口 ${_cur} 已占用，自动分配: ${_new}"
        fi
    done
    if [ "$(st_get '.ff.enabled')" = "true" ] && \
       [ "$(st_get '.ff.protocol')" != "none" ] && \
       port_mgr_in_use 8080; then
        log_warn "FreeFlow 端口 8080 已被占用（固定端口），安装后该协议可能无法正常使用"
    fi
    return 0
}

_install_rollback() {
    local _xray_was="${1:-0}" _argo_was="${2:-0}"
    log_warn "安装中断，回滚本次新建文件..."
    [ "${_xray_was}" -eq 0 ] && rm -f "${XRAY_BIN}" 2>/dev/null || true
    [ "${_argo_was}" -eq 0 ] && rm -f "${ARGO_BIN}" 2>/dev/null || true
    rm -f "${CONFIG_FILE}" "${_ARGO_ENV_FILE}" 2>/dev/null || true
    if is_systemd; then
        rm -f /etc/systemd/system/${_SVC_XRAY}.service   2>/dev/null || true
        rm -f /etc/systemd/system/${_SVC_TUNNEL}.service 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/${_SVC_XRAY}   2>/dev/null || true
        rm -f /etc/init.d/${_SVC_TUNNEL} 2>/dev/null || true
    fi
    # lifecycle 回滚
    lifecycle_rollback_sysctl
    lifecycle_rollback_hosts
}

exec_install() {
    clear; log_title "══════════ 安装 Xray-2go v8.3 ══════════"
    platform_preflight
    mkdir -p "${WORK_DIR}" && chmod 750 "${WORK_DIR}"

    if _install_detect_existing_xray; then
        log_warn "检测到系统已存在 xray 相关组件"
        log_warn "本脚本将以完全隔离模式运行（服务名: ${_SVC_XRAY}，目录: ${WORK_DIR}）"
    fi

    _install_check_port_conflicts \
        || { log_error "端口冲突无法解决，安装中止"; return 1; }

    local _xray_was=0 _argo_was=0
    [ -f "${XRAY_BIN}" ] && [ -x "${XRAY_BIN}" ] && _xray_was=1
    [ -f "${ARGO_BIN}" ] && [ -x "${ARGO_BIN}" ] && _argo_was=1

    download_xray \
        || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }

    [ "$(st_get '.argo.enabled')" = "true" ] && {
        download_cloudflared \
            || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
    }

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        log_step "生成 Reality x25519 密钥对..."
        crypto_gen_reality_keypair \
            || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }
        st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)"
    fi

    config_apply \
        || { _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }

    svc_apply_xray
    [ "$(st_get '.argo.enabled')" = "true" ] && svc_apply_tunnel
    svc_reload_daemon

    # B2/B3 修复：通过 lifecycle 模块处理系统变更（持久化 + 可回滚）
    is_openrc && {
        lifecycle_apply_sysctl
        lifecycle_apply_hosts_patch
    }

    platform_fix_time_sync
    fw_reconcile

    log_step "启动服务..."
    svc_exec enable "${_SVC_XRAY}"
    svc_exec start  "${_SVC_XRAY}" \
        || { log_error "启动命令失败"; _install_rollback "${_xray_was}" "${_argo_was}"; return 1; }

    if ! svc_verify_health "${_SVC_XRAY}" 8; then
        log_error "${_SVC_XRAY} 未正常运行，安装回滚"
        svc_exec stop "${_SVC_XRAY}" 2>/dev/null || true
        _install_rollback "${_xray_was}" "${_argo_was}"
        return 1
    fi

    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        svc_exec enable "${_SVC_TUNNEL}"
        svc_exec start  "${_SVC_TUNNEL}" \
            || { log_error "tunnel 启动失败（不影响 xray）"; }
        log_ok "${_SVC_TUNNEL} 已启动"
    fi

    # S4 修复：网络调优脚本先 bash -n 语法检查再执行
    log_step "网络性能调优"
    printf "是否立即运行 Eric86777 的网络调优脚本？(推荐 Y) [Y/n]: "
    read -r _tune_choice </dev/tty
    case "${_tune_choice:-y}" in
        [yY])
            log_info "下载并校验 net-tcp-tune.sh ..."
            local _tune_t; _tune_t=$(tmp_file "tune_XXXXXX.sh") || true
            if [ -n "${_tune_t:-}" ] && \
               curl -fsSL --max-time 30 \
                   "https://raw.githubusercontent.com/Eric86777/vps-tcp-tune/main/net-tcp-tune.sh?$(date +%s)" \
                   -o "${_tune_t}" 2>/dev/null; then
                # S4 修复：语法检查
                if bash -n "${_tune_t}" 2>/dev/null; then
                    bash "${_tune_t}"
                else
                    log_warn "调优脚本语法检查失败，已跳过"
                fi
                rm -f "${_tune_t}" 2>/dev/null || true
            else
                log_warn "调优脚本下载失败，已跳过"
            fi
            ;;
        *)
            log_info "已跳过网络调优，可后续手动执行"
            ;;
    esac

    st_persist || log_warn "state.json 写入失败（不影响运行）"
    log_ok "══ 安装完成 ══"
}

exec_uninstall() {
    local _a; prompt "确定要卸载 xray2go？(y/N): " _a
    case "${_a:-n}" in y|Y) :;; *) log_info "已取消"; return;; esac
    log_step "卸载中（仅清理 xray2go 自身资源）..."

    for _s in "${_SVC_XRAY}" "${_SVC_TUNNEL}"; do
        svc_exec stop    "${_s}" 2>/dev/null || true
        svc_exec disable "${_s}" 2>/dev/null || true
    done

    fw_force_cleanup
    rm -f "${WORK_DIR}/xray.pid" /var/run/xray2go.pid /var/run/tunnel2go.pid 2>/dev/null || true

    if is_systemd; then
        rm -f /etc/systemd/system/${_SVC_XRAY}.service   2>/dev/null || true
        rm -f /etc/systemd/system/${_SVC_TUNNEL}.service 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    else
        rm -f /etc/init.d/${_SVC_XRAY}   2>/dev/null || true
        rm -f /etc/init.d/${_SVC_TUNNEL} 2>/dev/null || true
    fi

    # S6/B2/B3 修复：完整 lifecycle 回滚
    lifecycle_rollback_sysctl
    lifecycle_rollback_hosts
    lifecycle_cleanup_cloudflared

    if [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}" 2>/dev/null || true
        [ -d "${WORK_DIR}" ] && \
            log_warn "${WORK_DIR} 未能完全删除，请手动执行: rm -rf ${WORK_DIR}" || \
            log_ok "${WORK_DIR} 已清除"
    fi

    rm -f "${SHORTCUT}" "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    log_ok "xray2go 卸载完成，系统无残留"
}

exec_update_shortcut() {
    log_step "拉取最新脚本..."
    local _t; _t=$(tmp_file "xray2go_XXXXXX.sh") || return 1
    curl -sfL --connect-timeout 15 --max-time 60 -o "${_t}" "${UPSTREAM_URL}" \
        || { log_error "拉取失败，请检查网络"; return 1; }
    bash -n "${_t}" 2>/dev/null || { log_error "脚本语法验证失败，已中止"; return 1; }
    [ -f "${SELF_DEST}" ] && cp -f "${SELF_DEST}" "${SELF_DEST}.bak" 2>/dev/null || true
    mv "${_t}" "${SELF_DEST}" && chmod +x "${SELF_DEST}"
    printf '#!/bin/bash\nexec %s "$@"\n' "${SELF_DEST}" > "${SHORTCUT}"
    chmod +x "${SHORTCUT}"
    log_ok "脚本已更新！输入 ${C_GRN}s${C_RST} 快速启动"
}

exec_update_uuid() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先安装 Xray-2go"; return 1; }
    local _v; prompt "新 UUID（回车自动生成）: " _v
    if [ -z "${_v:-}" ]; then
        _v=$(crypto_gen_uuid) || { log_error "UUID 生成失败"; return 1; }
        log_info "已生成 UUID: ${_v}"
    fi
    printf '%s' "${_v}" | grep -qiE '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' \
        || { log_error "UUID 格式不合法"; return 1; }
    st_set '.uuid = $u' --arg u "${_v}" || return 1
    _commit || return 1
    log_ok "UUID 已更新: ${_v}"; config_print_nodes
}

# ==============================================================================
# §L13 Argo — 隧道配置 / 健康检查
# ==============================================================================

# 构建 cloudflared 启动命令
# 两种模式统一使用 --config tunnel.yml，token 由 yml 内 token: 字段提供
argo_build_tunnel_cmd() {
    printf '%s tunnel --no-autoupdate run --config %s' \
        "${ARGO_BIN}" "${WORK_DIR}/tunnel.yml"
}

# json-cred 模式：生成含 tunnel:/credentials-file:/ingress: 的完整 yml
_argo_gen_config_yml_cred() {
    local _domain="$1" _tid="$2" _cred="$3"
    local _port; _port=$(st_get '.argo.port')
    local _new
    _new=$(printf 'tunnel: %s\ncredentials-file: %s\n\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      connectTimeout: 30s\n      noTLSVerify: true\n  - service: http_status:404\n' \
        "${_tid}" "${_cred}" "${_domain}" "${_port}")
    # 幂等：内容未变则跳过写入
    local _cur; _cur=$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || true)
    [ "${_cur}" = "${_new}" ] && return 0
    atomic_write "${WORK_DIR}/tunnel.yml" "${_new}" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已更新 [cred] (${_domain} → localhost:${_port})"
}

# token 模式：生成含 token:/ingress: 的 yml（不含 credentials-file）
# cloudflared 读取本地 ingress 覆盖 Cloudflare 控制台的远端路由，消除端口 desync
_argo_gen_config_yml_token() {
    local _domain="$1" _token="$2"
    local _port; _port=$(st_get '.argo.port')
    local _new
    _new=$(printf 'tunnel: %s\n\ningress:\n  - hostname: %s\n    service: http://localhost:%s\n    originRequest:\n      connectTimeout: 30s\n      noTLSVerify: true\n  - service: http_status:404\n' \
        "${_token}" "${_domain}" "${_port}")
    # 幂等：内容未变则跳过写入
    local _cur; _cur=$(cat "${WORK_DIR}/tunnel.yml" 2>/dev/null || true)
    [ "${_cur}" = "${_new}" ] && return 0
    atomic_write "${WORK_DIR}/tunnel.yml" "${_new}" \
        || { log_error "tunnel.yml 写入失败"; return 1; }
    log_ok "tunnel.yml 已更新 [token] (${_domain} → localhost:${_port})"
}

# 统一同步入口：根据当前 state 中的模式重建 tunnel.yml
# 两种模式均强制执行，不再以 tunnel.yml 是否存在作为门控
# 调用方：exec_update_argo_port / svc_apply_tunnel
_argo_sync_tunnel_yml() {
    [ "$(st_get '.argo.enabled')" = "true" ] || return 0
    local _domain; _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || {
        log_warn "tunnel.yml 同步跳过：domain 未配置"
        return 0
    }

    if [ -f "${WORK_DIR}/tunnel.json" ]; then
        # json-cred 模式
        local _tid
        _tid=$(jq -r 'if (.TunnelID? // "") != "" then .TunnelID
                      elif (.AccountTag? // "") != "" then .AccountTag
                      else empty end' "${WORK_DIR}/tunnel.json" 2>/dev/null) || true
        [ -n "${_tid:-}" ] || { log_warn "tunnel.yml 同步跳过：无法提取 TunnelID"; return 0; }
        _argo_gen_config_yml_cred "${_domain}" "${_tid}" "${WORK_DIR}/tunnel.json"
    else
        # token 模式：从 state 读取 token
        local _token; _token=$(st_get '.argo.token')
        [ -n "${_token:-}" ] && [ "${_token}" != "null" ] || {
            log_warn "tunnel.yml 同步跳过：token 未配置"
            return 0
        }
        _argo_gen_config_yml_token "${_domain}" "${_token}"
    fi
}

argo_apply_fixed_tunnel() {
    log_info "固定隧道 — 协议: $(st_get '.argo.protocol')  回源端口: $(st_get '.argo.port')"
    local _domain _auth
    prompt "请输入 Argo 域名: " _domain
    case "${_domain:-}" in ''|*' '*|*'/'*|*$'\t'*)
        log_error "域名格式不合法"; return 1;; esac
    printf '%s' "${_domain}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { log_error "域名格式不合法"; return 1; }

    prompt "请输入 Argo 密钥 (token 或 JSON 内容): " _auth
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
            log_error "TunnelID 含非法字符，拒绝写入"; return 1;; esac
        local _cred="${WORK_DIR}/tunnel.json"
        atomic_write "${_cred}" "${_auth}" || { log_error "凭证写入失败"; return 1; }
        _argo_gen_config_yml_cred "${_domain}" "${_tid}" "${_cred}" || return 1
        st_set '.argo.token = null | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg d "${_domain}" || return 1
    elif printf '%s' "${_auth}" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        st_set '.argo.token = $t | .argo.domain = $d | .argo.mode = "fixed"' \
            --arg t "${_auth}" --arg d "${_domain}" || return 1
        # 强制生成本地 tunnel.yml，确保 ingress 绑定到当前 .argo.port
        # 不再依赖 Cloudflare 控制台远端路由，消除端口 desync
        rm -f "${WORK_DIR}/tunnel.json" 2>/dev/null || true
        _argo_gen_config_yml_token "${_domain}" "${_auth}" || return 1
    else
        log_error "密钥格式无法识别（JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串）"
        return 1
    fi

    # B1 修复：更新 env file
    _svc_write_argo_env

    svc_apply_tunnel
    svc_reload_daemon
    svc_exec enable "${_SVC_TUNNEL}" 2>/dev/null || true
    config_apply  || return 1
    st_persist    || log_warn "state.json 写入失败"
    svc_exec restart "${_SVC_TUNNEL}" || { log_error "tunnel 重启失败"; return 1; }
    log_ok "固定隧道已配置 (domain=${_domain})"
    argo_check_health || true
}

argo_check_health() {
    local _domain; _domain=$(st_get '.argo.domain')
    [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ] || return 0
    log_step "Argo 健康检查（等待隧道就绪，最长 15s）..."
    local _i
    for _i in 3 6 9 12 15; do
        sleep "${_i}" 2>/dev/null || sleep 3
        local _code
        _code=$(curl -sfL --max-time 5 --connect-timeout 3 \
            -o /dev/null -w '%{http_code}' \
            "https://${_domain}/" 2>/dev/null) || true
        case "${_code:-000}" in
            [2345]??) log_ok "Argo 隧道连通 (HTTP ${_code})"; return 0 ;;
        esac
        [ "${_i}" -lt 15 ] && printf '\r%s' "  等待中... (${_i}s)" >&2
    done
    printf '\n' >&2
    log_warn "Argo 健康检查超时，请稍后通过 [3. Argo 管理] 确认"
    return 1
}

exec_update_argo_port() {
    local _p; _p=$(_menu_input_port '.argo.port') || return 1
    _argo_sync_tunnel_yml || return 1
    config_apply || return 1
    svc_apply_tunnel; svc_reload_daemon
    svc_exec restart "${_SVC_TUNNEL}" || log_warn "tunnel 重启失败，请手动重启"
    st_persist || log_warn "state.json 写入失败"
    fw_reconcile
    log_ok "回源端口已更新: ${_p}"; config_print_nodes
}

# ==============================================================================
# §L14 Menu — 安装向导 + 管理子菜单 + 主菜单
# ==============================================================================

# ── 安装向导 ──────────────────────────────────────────────────────────────────

ask_argo_mode() {
    echo ""; log_title "Argo 固定隧道"
    printf "  ${C_GRN}1.${C_RST} 安装 Argo (VLESS+WS/XHTTP+TLS) ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} 不安装 Argo\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) st_set '.argo.enabled = false'; log_info "已选：不安装 Argo";;
        *) st_set '.argo.enabled = true';  log_info "已选：安装 Argo";;
    esac; echo ""
}

ask_argo_protocol() {
    echo ""; log_title "Argo 传输协议"
    printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP (auto)\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) st_set '.argo.protocol = "xhttp"';;
        *) st_set '.argo.protocol = "ws"';;
    esac
    log_info "已选协议: $(st_get '.argo.protocol')"; echo ""
}

ask_freeflow_mode() {
    echo ""; log_title "FreeFlow（明文 port 8080）"
    printf "  ${C_GRN}1.${C_RST} VLESS + WS\n"
    printf "  ${C_GRN}2.${C_RST} VLESS + HTTPUpgrade\n"
    printf "  ${C_GRN}3.${C_RST} VLESS + XHTTP (stream-one)\n"
    printf "  ${C_GRN}4.${C_RST} VLESS + TCP + HTTP 伪装（免流）\n"
    printf "  ${C_GRN}5.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-5，回车默认5): " _c
    case "${_c:-5}" in
        1) st_set '.ff.enabled = true | .ff.protocol = "ws"';;
        2) st_set '.ff.enabled = true | .ff.protocol = "httpupgrade"';;
        3) st_set '.ff.enabled = true | .ff.protocol = "xhttp"';;
        4)
            st_set '.ff.enabled = true | .ff.protocol = "tcphttp"'
            local _host; prompt "免流 Host（如 realname.1888.com.mo）: " _host
            if [ -z "${_host:-}" ]; then
                log_error "Host 不能为空，已回退到不启用"
                st_set '.ff.enabled = false | .ff.protocol = "none"'
                echo ""; return 0
            fi
            st_set '.ff.host = $h' --arg h "${_host}"
            log_info "已选: TCP + HTTP 伪装（host=${_host}）"; echo ""; return 0 ;;
        *) st_set '.ff.enabled = false | .ff.protocol = "none"'
           log_info "不启用 FreeFlow"; echo ""; return 0;;
    esac
    port_mgr_in_use 8080 && log_warn "端口 8080 已被占用，FreeFlow 可能无法启动"
    local _p; prompt "FreeFlow path（回车默认 /）: " _p
    case "${_p:-/}" in /*) :;; *) _p="/${_p}";; esac
    st_set '.ff.path = $p' --arg p "${_p:-/}"
    log_info "已选: $(st_get '.ff.protocol')（path=${_p:-/}）"; echo ""
}

ask_reality_mode() {
    echo ""; log_title "VLESS + Reality（TCP 直连，独立端口）"
    printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) st_set '.reality.enabled = true';;
        *) st_set '.reality.enabled = false'; log_info "不启用 Reality"; echo ""; return 0;;
    esac

    local _dp; _dp=$(st_get '.reality.port')
    local _rp; prompt "监听端口（回车默认 ${_dp}）: " _rp
    if [ -n "${_rp:-}" ]; then
        case "${_rp}" in
            *[!0-9]*) log_warn "端口无效，使用默认值 ${_dp}";;
            *) if [ "${_rp}" -ge 1 ] && [ "${_rp}" -le 65535 ]; then
                   st_set '.reality.port = ($p|tonumber)' --arg p "${_rp}"
               else log_warn "端口超范围，使用默认值 ${_dp}"; fi;;
        esac
    fi
    port_mgr_in_use "$(st_get '.reality.port')" && \
        log_warn "端口 $(st_get '.reality.port') 已被占用，安装时将自动更换"

    local _ds; _ds=$(st_get '.reality.sni')
    log_info "SNI 建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
    local _sni; prompt "伪装 SNI（回车默认 ${_ds}）: " _sni
    if [ -n "${_sni:-}" ]; then
        printf '%s' "${_sni}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
            && st_set '.reality.sni = $s' --arg s "${_sni}" \
            || log_warn "SNI 格式不合法，使用默认值 ${_ds}"
    fi

    echo ""
    printf "  ${C_GRN}1.${C_RST} TCP + XTLS-Vision ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} XHTTP + Reality (auto)\n"
    local _nc; prompt "传输方式 (1-2，回车默认1): " _nc
    case "${_nc:-1}" in
        2) st_set '.reality.network = "xhttp"'; log_info "已选：XHTTP + Reality";;
        *) st_set '.reality.network = "tcp"';   log_info "已选：TCP + XTLS-Vision";;
    esac
    log_info "Reality 配置完成 — 端口:$(st_get '.reality.port') SNI:$(st_get '.reality.sni') 传输:$(st_get '.reality.network')"
    echo ""
}

ask_vltcp_mode() {
    echo ""; log_title "VLESS-TCP 明文落地（无加密，用于内网/出口落地）"
    printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
    printf "  ${C_GRN}2.${C_RST} 不启用 ${C_YLW}[默认]${C_RST}\n"
    local _c; prompt "请选择 (1-2，回车默认2): " _c
    case "${_c:-2}" in
        1) st_set '.vltcp.enabled = true';;
        *) st_set '.vltcp.enabled = false'; log_info "不启用 VLESS-TCP"; echo ""; return 0;;
    esac

    local _dp; _dp=$(st_get '.vltcp.port')
    local _vp; prompt "监听端口（回车默认 ${_dp}）: " _vp
    if [ -n "${_vp:-}" ]; then
        case "${_vp}" in
            *[!0-9]*) log_warn "端口无效，使用默认值 ${_dp}";;
            *) if [ "${_vp}" -ge 1 ] && [ "${_vp}" -le 65535 ]; then
                   st_set '.vltcp.port = ($p|tonumber)' --arg p "${_vp}"
               else log_warn "端口超范围，使用默认值 ${_dp}"; fi;;
        esac
    fi
    port_mgr_in_use "$(st_get '.vltcp.port')" && \
        log_warn "端口 $(st_get '.vltcp.port') 已被占用，安装时将自动更换"

    local _dl; _dl=$(st_get '.vltcp.listen')
    local _vl; prompt "监听地址（回车默认 ${_dl}，0.0.0.0=所有接口）: " _vl
    [ -n "${_vl:-}" ] && st_set '.vltcp.listen = $l' --arg l "${_vl}"
    log_info "VLESS-TCP 配置完成 — 端口:$(st_get '.vltcp.port') 监听:$(st_get '.vltcp.listen')"
    echo ""
}

ask_xpad_mode() {
    echo ""; log_title "XHTTP xPadding 混淆"
    printf "  ${C_GRN}1.${C_RST} 开启 xPadding（更强的流量伪装） ${C_YLW}[默认]${C_RST}\n"
    printf "  ${C_GRN}2.${C_RST} 关闭 xPadding（纯 XHTTP，兼容性更好）\n"
    local _c; prompt "请选择 (1-2，回车默认1): " _c
    case "${_c:-1}" in
        2) st_set '.xpad.enabled = false'; log_info "已选：关闭 xPadding";;
        *) st_set '.xpad.enabled = true';  log_info "已选：开启 xPadding";;
    esac
    echo ""
}

# ── 管理子菜单辅助 ────────────────────────────────────────────────────────────

_menu_input_port() {
    local _jq_path="$1" _p
    prompt "新端口（回车随机）: " _p
    [ -z "${_p:-}" ] && _p=$(shuf -i 1024-65000 -n 1 2>/dev/null || \
                              awk 'BEGIN{srand();print int(rand()*63976)+1024}')
    case "${_p:-}" in ''|*[!0-9]*) log_error "无效端口"; return 1;; esac
    { [ "${_p}" -ge 1 ] && [ "${_p}" -le 65535 ]; } || { log_error "端口超范围"; return 1; }
    if port_mgr_in_use "${_p}"; then
        log_warn "端口 ${_p} 已被占用"
        local _a; prompt "仍然继续？(y/N): " _a
        case "${_a:-n}" in y|Y) :;; *) return 1;; esac
    fi
    st_set "${_jq_path} = (\$p|tonumber)" --arg p "${_p}" || return 1
    printf '%s' "${_p}"
}

_menu_confirm_uninstall() {
    local _name="$1" _a
    prompt "确定要卸载 ${_name}？此操作将关闭该协议入站 (y/N): " _a
    case "${_a:-n}" in y|Y) return 0;; *) return 1;; esac
}

_menu_toggle_xpad() {
    local _nxp
    [ "$(st_get '.xpad.enabled')" = "true" ] && _nxp="false" || _nxp="true"
    st_set '.xpad.enabled = $v' --arg v "${_nxp}" || return 1
    config_apply || return 1
    st_persist || log_warn "state.json 写入失败"
    log_ok "xPadding 已${_nxp}"; config_print_nodes
}

# ── 状态收集 ──────────────────────────────────────────────────────────────────

check_xray() {
    [ -f "${XRAY_BIN}" ] || { printf 'not installed'; return 2; }
    svc_exec status "${_SVC_XRAY}" \
        && { printf 'running'; return 0; } \
        || { printf 'stopped'; return 1; }
}

check_argo() {
    [ "$(st_get '.argo.enabled')" = "true" ] || { printf 'disabled'; return 3; }
    [ -f "${ARGO_BIN}" ]                      || { printf 'not installed'; return 2; }
    svc_exec status "${_SVC_TUNNEL}" \
        && { printf 'running'; return 0; } \
        || { printf 'stopped'; return 1; }
}

# ── Argo 管理 ─────────────────────────────────────────────────────────────────

manage_argo() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _astat _domain _proto _port _xpad
        _en=$(    st_get '.argo.enabled')
        _astat=$( check_argo)
        _domain=$(st_get '.argo.domain')
        _proto=$( st_get '.argo.protocol')
        _port=$(  st_get '.argo.port')
        _xpad=$(  st_get '.xpad.enabled')

        clear; echo ""; log_title "══ Argo 固定隧道管理 ══"
        if [ "${_en}" = "true" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_astat}"
            printf "  协议: ${C_CYN}%s${C_RST}  回源端口: ${C_YLW}%s${C_RST}\n" "${_proto}" "${_port}"
            if [ -n "${_domain:-}" ] && [ "${_domain}" != "null" ]; then
                printf "  域名: ${C_GRN}%s${C_RST}\n" "${_domain}"
            else
                printf "  域名: ${C_YLW}未配置（请选项 4 配置）${C_RST}\n"
            fi
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Argo\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Argo\n"
        printf "  ${C_GRN}3.${C_RST} 重启隧道服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Argo（停服务 + 删文件）\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 配置/更新固定隧道域名\n"
        printf "  ${C_GRN}5.${C_RST} 切换协议 (WS ↔ XHTTP)\n"
        printf "  ${C_GRN}6.${C_RST} 修改回源端口 (当前: ${C_YLW}${_port}${C_RST})\n"
        printf "  ${C_GRN}7.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST})\n"
        printf "  ${C_GRN}8.${C_RST} 查看节点链接\n"
        printf "  ${C_GRN}a.${C_RST} 健康检查\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                if [ "${_en}" = "true" ]; then
                    log_info "Argo 已处于启用状态"; _pause; continue
                fi
                if [ ! -f "${ARGO_BIN}" ] || [ ! -x "${ARGO_BIN}" ]; then
                    log_step "下载 cloudflared..."
                    download_cloudflared || { _pause; continue; }
                fi
                st_set '.argo.enabled = true' || { _pause; continue; }
                config_apply \
                    || { st_set '.argo.enabled = false'; _pause; continue; }
                svc_apply_tunnel; svc_reload_daemon
                svc_exec enable "${_SVC_TUNNEL}"
                svc_exec start  "${_SVC_TUNNEL}" \
                    && log_ok "Argo 已启用并启动" \
                    || log_warn "Argo 启用成功，但服务启动失败，请检查域名配置"
                st_persist || log_warn "state.json 写入失败" ;;
            2)
                if [ "${_en}" != "true" ]; then
                    log_info "Argo 已处于禁用状态"; _pause; continue
                fi
                svc_exec stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                svc_exec disable "${_SVC_TUNNEL}" 2>/dev/null || true
                st_set '.argo.enabled = false' || { _pause; continue; }
                config_apply  || { _pause; continue; }
                st_persist    || log_warn "state.json 写入失败"
                log_ok "Argo 已禁用（配置和文件保留，可随时重新启用）" ;;
            3)
                if [ "${_en}" != "true" ]; then
                    log_warn "Argo 未启用，请先选项 1 启用"; _pause; continue
                fi
                svc_exec restart "${_SVC_TUNNEL}" \
                    && { log_ok "${_SVC_TUNNEL} 已重启"
                         svc_verify_health "${_SVC_TUNNEL}" 6; } \
                    || log_error "${_SVC_TUNNEL} 重启失败" ;;
            9)
                _menu_confirm_uninstall "Argo" || { _pause; continue; }
                svc_exec stop    "${_SVC_TUNNEL}" 2>/dev/null || true
                svc_exec disable "${_SVC_TUNNEL}" 2>/dev/null || true
                if is_systemd; then
                    rm -f "/etc/systemd/system/${_SVC_TUNNEL}.service" 2>/dev/null || true
                    systemctl daemon-reload >/dev/null 2>&1 || true
                else
                    rm -f "/etc/init.d/${_SVC_TUNNEL}" 2>/dev/null || true
                fi
                rm -f "${ARGO_BIN}"             2>/dev/null || true
                rm -f "${WORK_DIR}/tunnel.yml"  2>/dev/null || true
                rm -f "${WORK_DIR}/tunnel.json" 2>/dev/null || true
                rm -f "${_ARGO_ENV_FILE}"       2>/dev/null || true
                st_set '.argo.enabled = false | .argo.domain = null | .argo.token = null | .argo.mode = "fixed"' \
                    || true
                config_apply  || { _pause; continue; }
                st_persist    || log_warn "state.json 写入失败"
                log_ok "Argo 已完全卸载"
                _pause; return ;;
            4)
                if [ "${_en}" != "true" ]; then
                    log_warn "请先选项 1 启用 Argo"; _pause; continue
                fi
                echo ""
                printf "  ${C_GRN}1.${C_RST} WS ${C_YLW}[默认]${C_RST}\n"
                printf "  ${C_GRN}2.${C_RST} XHTTP\n"
                local _pp; prompt "协议 (回车维持 ${_proto}): " _pp
                case "${_pp:-}" in
                    2) st_set '.argo.protocol = "xhttp"';;
                    1) st_set '.argo.protocol = "ws"';;
                esac
                argo_apply_fixed_tunnel && config_print_nodes \
                    || log_error "固定隧道配置失败" ;;
            5)
                if [ "${_en}" != "true" ]; then
                    log_warn "请先选项 1 启用 Argo"; _pause; continue
                fi
                local _np; [ "${_proto}" = "ws" ] && _np="xhttp" || _np="ws"
                st_set '.argo.protocol = $p' --arg p "${_np}" || { _pause; continue; }
                if config_apply && st_persist; then
                    log_ok "协议已切换: ${_np}"; config_print_nodes
                else
                    log_error "切换失败，回滚"
                    st_set '.argo.protocol = $p' --arg p "${_proto}"
                fi ;;
            6) exec_update_argo_port ;;
            7) _menu_toggle_xpad ;;
            8) config_print_nodes ;;
            a) argo_check_health || true ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── FreeFlow 管理 ─────────────────────────────────────────────────────────────

manage_freeflow() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _proto _path _host _xpad _xstat
        _en=$(   st_get '.ff.enabled')
        _proto=$(st_get '.ff.protocol')
        _path=$( st_get '.ff.path')
        _host=$( st_get '.ff.host')
        _xpad=$( st_get '.xpad.enabled')
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ FreeFlow 管理 ══"
        if [ "${_en}" = "true" ] && [ "${_proto}" != "none" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}"
            if [ "${_proto}" = "tcphttp" ]; then
                printf "  协议: ${C_CYN}%s${C_RST}  host: ${C_YLW}%s${C_RST}  端口: 8080\n" "${_proto}" "${_host}"
            else
                printf "  协议: ${C_CYN}%s${C_RST}  path: ${C_YLW}%s${C_RST}  端口: 8080\n" "${_proto}" "${_path}"
            fi
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 FreeFlow\n"
        printf "  ${C_RED}2.${C_RST} 禁用 FreeFlow\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 FreeFlow\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 变更传输协议\n"
        if [ "${_proto}" = "tcphttp" ]; then
            printf "  ${C_GRN}5.${C_RST} 修改免流 Host（当前: ${C_YLW}${_host}${C_RST}）\n"
        else
            printf "  ${C_GRN}5.${C_RST} 修改 path（当前: ${C_YLW}${_path}${C_RST}）\n"
        fi
        printf "  ${C_GRN}6.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST})\n"
        printf "  ${C_GRN}7.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                if [ "${_en}" = "true" ] && [ "${_proto}" != "none" ]; then
                    log_info "FreeFlow 已处于启用状态"; _pause; continue
                fi
                ask_freeflow_mode
                [ "$(st_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 已启用"; config_print_nodes ;;
            2)
                if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_info "FreeFlow 已处于禁用状态"; _pause; continue
                fi
                st_set '.ff.enabled = false | .ff.protocol = "none"' || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 已禁用（配置保留）" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "FreeFlow" || { _pause; continue; }
                st_set '.ff.enabled = false | .ff.protocol = "none" | .ff.path = "/" | .ff.host = ""' \
                    || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 已卸载（配置已重置）"
                _pause; return ;;
            4)
                ask_freeflow_mode
                [ "$(st_get '.ff.enabled')" = "true" ] || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "FreeFlow 协议已变更"; config_print_nodes ;;
            5)
                if [ "${_en}" != "true" ] || [ "${_proto}" = "none" ]; then
                    log_warn "请先选项 1 启用 FreeFlow"; _pause; continue
                fi
                if [ "${_proto}" = "tcphttp" ]; then
                    local _h; prompt "新免流 Host（回车保持 ${_host}）: " _h
                    if [ -n "${_h:-}" ]; then
                        st_set '.ff.host = $h' --arg h "${_h}" || { _pause; continue; }
                        config_apply  || { _pause; continue; }
                        st_persist    || log_warn "state.json 写入失败"
                        log_ok "Host 已更新: ${_h}"; config_print_nodes
                    fi
                else
                    local _p; prompt "新 path（回车保持 ${_path}）: " _p
                    if [ -n "${_p:-}" ]; then
                        case "${_p}" in /*) :;; *) _p="/${_p}";; esac
                        st_set '.ff.path = $p' --arg p "${_p}" || { _pause; continue; }
                        config_apply  || { _pause; continue; }
                        st_persist    || log_warn "state.json 写入失败"
                        log_ok "path 已更新: ${_p}"; config_print_nodes
                    fi
                fi ;;
            6) _menu_toggle_xpad ;;
            7) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── Reality 管理 ──────────────────────────────────────────────────────────────

manage_reality() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _port _sni _pbk _pvk _sid _net _pbk_disp _xpad _xstat
        _en=$(  st_get '.reality.enabled')
        _port=$(st_get '.reality.port')
        _sni=$( st_get '.reality.sni')
        _pbk=$( st_get '.reality.pbk')
        _pvk=$( st_get '.reality.pvk')
        _sid=$( st_get '.reality.sid')
        _net=$( st_get '.reality.network'); _net="${_net:-tcp}"
        _xpad=$(st_get '.xpad.enabled')
        _pbk_disp="未生成"
        [ -n "${_pbk:-}" ] && [ "${_pbk}" != "null" ] && _pbk_disp="${_pbk:0:16}..."
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ Reality 管理 ══"
        if [ "${_en}" = "true" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}"
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        printf "  端口: ${C_YLW}%s${C_RST}  SNI: ${C_CYN}%s${C_RST}  传输: ${C_GRN}%s${C_RST}\n" \
            "${_port}" "${_sni}" "${_net}"
        printf "  公钥: %s\n" "${_pbk_disp}"
        [ -n "${_sid:-}" ] && [ "${_sid}" != "null" ] \
            && printf "  ShortId: ${C_CYN}%s${C_RST}\n" "${_sid}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 Reality\n"
        printf "  ${C_RED}2.${C_RST} 禁用 Reality\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 Reality（禁用 + 清除密钥）\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改 SNI（当前: ${C_CYN}${_sni}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 切换传输方式（当前: ${C_GRN}${_net}${C_RST}）\n"
        printf "  ${C_GRN}7.${C_RST} 切换 xPadding (当前: ${C_YLW}${_xpad}${C_RST})\n"
        printf "  ${C_GRN}8.${C_RST} 重新生成密钥对\n"
        printf "  ${C_GRN}a.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                if [ "${_en}" = "true" ]; then
                    log_info "Reality 已处于启用状态"; _pause; continue
                fi
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                if [ -z "${_pvk:-}" ] || [ "${_pvk}" = "null" ]; then
                    log_step "首次启用，生成 x25519 密钥对..."
                    crypto_gen_reality_keypair || { _pause; continue; }
                    st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" || true
                fi
                st_set '.reality.enabled = true' || { _pause; continue; }
                config_apply \
                    || { st_set '.reality.enabled = false'; _pause; continue; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "Reality 已启用"; config_print_nodes ;;
            2)
                if [ "${_en}" != "true" ]; then
                    log_info "Reality 已处于禁用状态"; _pause; continue
                fi
                st_set '.reality.enabled = false' || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "Reality 已禁用（端口/SNI/密钥配置保留）" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "Reality" || { _pause; continue; }
                st_set '.reality.enabled = false | .reality.pbk = null | .reality.pvk = null | .reality.sid = null' \
                    || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "Reality 已卸载（端口/SNI 配置保留，密钥已清除）"
                _pause; return ;;
            4)
                local _np; _np=$(_menu_input_port '.reality.port') || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "端口已更新: ${_np}"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            5)
                log_info "建议：addons.mozilla.org / www.microsoft.com / www.apple.com"
                local _s; prompt "新 SNI（回车保持 ${_sni}）: " _s
                if [ -n "${_s:-}" ]; then
                    printf '%s' "${_s}" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
                        || { log_error "SNI 格式不合法"; _pause; continue; }
                    st_set '.reality.sni = $s' --arg s "${_s}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                    st_persist || log_warn "state.json 写入失败"
                    log_ok "SNI 已更新: ${_s}"
                    [ "${_en}" = "true" ] && config_print_nodes
                fi ;;
            6)
                local _nn; [ "${_net}" = "tcp" ] && _nn="xhttp" || _nn="tcp"
                st_set '.reality.network = $n' --arg n "${_nn}" || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                log_ok "传输方式已切换: ${_nn}"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            7) _menu_toggle_xpad ;;
            8)
                [ -x "${XRAY_BIN}" ] || { log_error "xray 未就绪"; _pause; continue; }
                crypto_gen_reality_keypair || { _pause; continue; }
                st_set '.reality.sid = $s' --arg s "$(crypto_gen_reality_sid)" \
                    || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                log_ok "密钥对已更新"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            a) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── VLESS-TCP 管理 ────────────────────────────────────────────────────────────

manage_vltcp() {
    [ -f "${CONFIG_FILE}" ] || { log_warn "请先完成 Xray-2go 安装"; sleep 1; return; }
    while true; do
        local _en _port _listen _xstat
        _en=$(    st_get '.vltcp.enabled')
        _port=$(  st_get '.vltcp.port')
        _listen=$(st_get '.vltcp.listen')
        svc_exec status "${_SVC_XRAY}" >/dev/null 2>&1 && _xstat="running" || _xstat="stopped"

        clear; echo ""; log_title "══ VLESS-TCP 明文落地管理 ══"
        if [ "${_en}" = "true" ]; then
            printf "  模块: ${C_GRN}已启用${C_RST}  服务: ${C_GRN}%s${C_RST}\n" "${_xstat}"
        else
            printf "  模块: ${C_YLW}未启用${C_RST}\n"
        fi
        printf "  端口: ${C_YLW}%s${C_RST}  监听: ${C_CYN}%s${C_RST}\n" "${_port}" "${_listen}"
        _hr
        printf "  ${C_GRN}1.${C_RST} 启用 VLESS-TCP\n"
        printf "  ${C_RED}2.${C_RST} 禁用 VLESS-TCP\n"
        printf "  ${C_GRN}3.${C_RST} 重启 xray2go 服务\n"
        printf "  ${C_RED}9.${C_RST} 卸载 VLESS-TCP\n"
        _hr
        printf "  ${C_GRN}4.${C_RST} 修改端口（当前: ${C_YLW}${_port}${C_RST}）\n"
        printf "  ${C_GRN}5.${C_RST} 修改监听地址（当前: ${C_CYN}${_listen}${C_RST}）\n"
        printf "  ${C_GRN}6.${C_RST} 查看节点链接\n"
        printf "  ${C_PUR}0.${C_RST} 返回\n"; _hr
        local _c; prompt "请输入选择: " _c
        case "${_c:-}" in
            1)
                if [ "${_en}" = "true" ]; then
                    log_info "VLESS-TCP 已处于启用状态"; _pause; continue
                fi
                st_set '.vltcp.enabled = true' || { _pause; continue; }
                config_apply \
                    || { st_set '.vltcp.enabled = false'; _pause; continue; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "VLESS-TCP 已启用 (端口: ${_port})"; config_print_nodes ;;
            2)
                if [ "${_en}" != "true" ]; then
                    log_info "VLESS-TCP 已处于禁用状态"; _pause; continue
                fi
                st_set '.vltcp.enabled = false' || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "VLESS-TCP 已禁用（端口/监听配置保留）" ;;
            3) svc_restart_xray || true ;;
            9)
                _menu_confirm_uninstall "VLESS-TCP" || { _pause; continue; }
                st_set '.vltcp.enabled = false | .vltcp.port = 1234 | .vltcp.listen = "0.0.0.0"' \
                    || { _pause; continue; }
                _commit || { _pause; continue; }
                log_ok "VLESS-TCP 已卸载（端口已重置为默认值）"
                _pause; return ;;
            4)
                local _np; _np=$(_menu_input_port '.vltcp.port') || { _pause; continue; }
                [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                st_persist || log_warn "state.json 写入失败"
                fw_reconcile
                log_ok "端口已更新: ${_np}"
                [ "${_en}" = "true" ] && config_print_nodes ;;
            5)
                local _l; prompt "新监听地址（0.0.0.0=所有，127.0.0.1=仅本地）: " _l
                if [ -n "${_l:-}" ]; then
                    st_set '.vltcp.listen = $l' --arg l "${_l}" || { _pause; continue; }
                    [ "${_en}" = "true" ] && { config_apply || { _pause; continue; }; }
                    st_persist || log_warn "state.json 写入失败"
                    log_ok "监听地址已更新: ${_l}"
                    [ "${_en}" = "true" ] && config_print_nodes
                fi ;;
            6) config_print_nodes ;;
            0) return ;;
            *) log_error "无效选项" ;;
        esac
        _pause
    done
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────

_menu_collect_status() {
    local _xs _cx
    _xs=$(check_xray); _cx=$?
    [ "${_cx}" -eq 0 ] && _MENU_XC="${C_GRN}" || _MENU_XC="${C_RED}"
    _MENU_XS="${_xs}"; _MENU_CX="${_cx}"

    local _as _dom
    _as=$(check_argo); _dom=$(st_get '.argo.domain')
    if [ "$(st_get '.argo.enabled')" = "true" ]; then
        [ -n "${_dom:-}" ] && [ "${_dom}" != "null" ] \
            && _MENU_AD="${_as} [$(st_get '.argo.protocol'), ${_dom}, port=$(st_get '.argo.port')]" \
            || _MENU_AD="${_as} [未配置域名]"
    else
        _MENU_AD="未启用"
    fi

    local _fp _fpa _ffhost
    _fp=$(st_get '.ff.protocol'); _fpa=$(st_get '.ff.path'); _ffhost=$(st_get '.ff.host')
    if [ "$(st_get '.ff.enabled')" = "true" ] && [ "${_fp}" != "none" ]; then
        [ "${_fp}" = "tcphttp" ] \
            && _MENU_FD="${_fp} (host=${_ffhost})" \
            || _MENU_FD="${_fp} (path=${_fpa})"
    else
        _MENU_FD="未启用"
    fi

    [ "$(st_get '.reality.enabled')" = "true" ] \
        && _MENU_RD="已启用 (port=$(st_get '.reality.port'), $(st_get '.reality.network'), sni=$(st_get '.reality.sni'))" \
        || _MENU_RD="未启用"

    [ "$(st_get '.vltcp.enabled')" = "true" ] \
        && _MENU_VD="已启用 (port=$(st_get '.vltcp.port'), listen=$(st_get '.vltcp.listen'))" \
        || _MENU_VD="未启用"
}

_menu_render() {
    clear; echo ""
    printf "${C_BOLD}${C_PUR}  ╔══════════════════════════════════════════╗${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║           Xray-2go v8.3                  ║${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ╠══════════════════════════════════════════╣${C_RST}\n"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Xray     : ${_MENU_XC}%-29s${C_RST}${C_PUR} ${C_RST}\n"  "${_MENU_XS}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Argo     : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_AD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  Reality  : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_RD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  VLESS-TCP: %-29s${C_PUR} ${C_RST}\n"  "${_MENU_VD}"
    printf "${C_BOLD}${C_PUR}  ║${C_RST}  FF       : %-29s${C_PUR} ${C_RST}\n"  "${_MENU_FD}"
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
}

_menu_do_install() {
    if [ "${_MENU_CX}" -eq 0 ]; then
        log_warn "Xray-2go 已安装并运行，如需重装请先卸载 (选项 2)"; return
    fi

    ask_argo_mode
    [ "$(st_get '.argo.enabled')" = "true" ] && ask_argo_protocol
    ask_freeflow_mode
    ask_reality_mode
    ask_vltcp_mode

    local _has_xhttp=false
    [ "$(st_get '.argo.enabled')" = "true" ] && \
        [ "$(st_get '.argo.protocol')" = "xhttp" ] && _has_xhttp=true
    [ "$(st_get '.ff.enabled')" = "true" ] && \
        [ "$(st_get '.ff.protocol')" = "xhttp" ] && _has_xhttp=true
    [ "$(st_get '.reality.enabled')" = "true" ] && \
        [ "$(st_get '.reality.network')" = "xhttp" ] && _has_xhttp=true
    [ "${_has_xhttp}" = "true" ] && ask_xpad_mode

    if [ "$(st_get '.reality.enabled')" = "true" ]; then
        local _rp _ap
        _rp=$(st_get '.reality.port'); _ap=$(st_get '.argo.port')
        [ "${_rp}" = "${_ap}" ] && \
            log_warn "Reality 端口与 Argo 回源端口相同，安装时将自动修正"
    fi

    if ! exec_install; then
        log_error "安装失败"; _pause; return
    fi

    st_persist || log_warn "state.json 写入失败"

    [ "$(st_get '.argo.enabled')" = "true" ] && \
        { argo_apply_fixed_tunnel || \
          log_error "固定隧道配置失败，请从 [3. Argo 管理] 重新配置"; }
    config_print_nodes
}

menu() {
    local _MENU_XS="" _MENU_XC="" _MENU_CX=1
    local _MENU_AD="" _MENU_FD="" _MENU_RD="" _MENU_VD=""
    while true; do
        _menu_collect_status
        _menu_render
        local _c; prompt "请输入选择 (0-8/s): " _c; echo ""
        case "${_c:-}" in
            1) _menu_do_install ;;
            2) exec_uninstall ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_vltcp ;;
            6) manage_freeflow ;;
            7) [ "${_MENU_CX}" -eq 0 ] && config_print_nodes \
                    || log_warn "Xray-2go 未安装或未运行" ;;
            8) [ -f "${CONFIG_FILE}" ] && exec_update_uuid \
                    || log_warn "请先安装 Xray-2go" ;;
            s) exec_update_shortcut ;;
            0) log_info "已退出"; exit 0 ;;
            *) log_error "无效选项，请输入 0-8 或 s" ;;
        esac
        _pause
    done
}

# ==============================================================================
# §L15 Main 入口
# ==============================================================================
main() {
    check_root
    platform_detect_init
    platform_preflight
    st_init
    menu
}
main "$@"
