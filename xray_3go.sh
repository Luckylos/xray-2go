#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  xray-2go  v3.0  ·  Clean-Slate Architecture  ·  Debian 12+  ·  2025      ║
# ║  Core Engine: State(JSON SSOT) + Transaction + Pre-flight + UI             ║
# ║  Protocol Plugins: argo{ws,xhttp} · freeflow{ws,httpupgrade,xhttp}         ║
# ║                    reality{tcp-vision}                                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
# ── Breaking Changes vs v2 ───────────────────────────────────────────────────
#  · State: 6 flat .conf files → single /opt/xray2go/state.json  (jq SSOT)
#  · Config: incremental patch (apply_*) → pure rebuild (_cfg_build)
#  · Platform: OpenRC/Alpine dual-branch → systemd-only (Debian 12 native)
#  · Ops: ad-hoc &&...|| chains → formal txn_run() atomic transactions
#  · Validation: warn-and-continue → preflight pipeline (block before write)
#  · Services: xray / tunnel → xray2go / xray2go-tunnel (no name collision)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# §0  GLOBAL MUTABLE STATE  (runtime-only; all persistent state lives in JSON)
# ══════════════════════════════════════════════════════════════════════════════
_SP=0          # spinner child PID
_TXN=""        # transaction snapshot of state.json
_DIRTY=0       # deferred systemd daemon-reload flag

# ══════════════════════════════════════════════════════════════════════════════
# §1  CONSTANTS — single declaration point, FHS-compliant layout
# ══════════════════════════════════════════════════════════════════════════════
readonly APP_ROOT="/opt/xray2go"
readonly BIN_XRAY="${APP_ROOT}/bin/xray"
readonly BIN_ARGO="${APP_ROOT}/bin/cloudflared"
readonly XRAY_CONF="${APP_ROOT}/etc/config.json"
readonly STATE_FILE="${APP_ROOT}/etc/state.json"
readonly TUNNEL_JSON="${APP_ROOT}/etc/tunnel.json"
readonly TUNNEL_YML="${APP_ROOT}/etc/tunnel.yml"
readonly DOMAIN_FILE="${APP_ROOT}/etc/domain"
readonly NODE_FILE="${APP_ROOT}/etc/nodes.txt"
readonly ARGO_LOG="${APP_ROOT}/log/argo.log"
readonly SHORTCUT="/usr/local/bin/x2g"
readonly SELF_PATH="/usr/local/bin/xray2go"
readonly UPSTREAM="https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh"
readonly SVC_XRAY="xray2go"
readonly SVC_ARGO="xray2go-tunnel"

# ══════════════════════════════════════════════════════════════════════════════
# §2  UI ENGINE — log levels / spinner / prompt / layout primitives
# ══════════════════════════════════════════════════════════════════════════════
readonly _R=$'\033[0m'
readonly _B=$'\033[1m'
readonly _DIM=$'\033[2m'
readonly _RED=$'\033[1;91m'
readonly _GRN=$'\033[1;32m'
readonly _YLW=$'\033[1;33m'
readonly _PUR=$'\033[1;35m'
readonly _CYN=$'\033[1;36m'

# Log functions — warn/error → stderr; info/ok/step → stdout
ui_ok()    { printf "${_GRN}  ✔  ${_R}%s\n"         "$*"; }
ui_info()  { printf "${_CYN}  ◆  ${_R}%s\n"         "$*"; }
ui_warn()  { printf "${_YLW}  ⚠  ${_R}%s\n"         "$*" >&2; }
ui_err()   { printf "${_RED}  ✘  ${_R}%s\n"         "$*" >&2; }
ui_step()  { printf "${_PUR}  ●  ${_R}${_DIM}%s…${_R}\n" "$*"; }
ui_die()   { ui_err "$1"; exit "${2:-1}"; }
ui_sep()   { printf "${_DIM}  ────────────────────────────────────${_R}\n"; }
ui_nl()    { printf '\n'; }

# prompt: label → stderr, read from /dev/tty (pipeline/redirect safe)
ui_ask() {
    local _v="$2"
    printf "${_RED}  ▶  ${_R}%s " "$1" >&2
    read -r "${_v}" </dev/tty
}

ui_pause() {
    local _d
    printf "${_DIM}  ↵  按回车继续${_R}" >&2
    read -r _d </dev/tty || true
}

# Spinner — subshell, does NOT inherit set -e
_SPIN_CHARS='-\|/'
ui_spin_start() {
    ( i=0
      while true; do
          printf '\r'"${_CYN}  %s  ${_R}${_DIM}%s${_R}   " \
              "${_SPIN_CHARS:$(( i % 4 )):1}" "$*" >&2
          sleep 0.1; i=$(( i + 1 ))
      done
    ) &
    _SP=$!
    disown "$_SP" 2>/dev/null || true
}
ui_spin_stop() {
    [ "$_SP" -ne 0 ] && { kill "$_SP" 2>/dev/null; _SP=0; }
    printf '\r\033[2K' >&2
}

# Status badge (printed inline, no trailing newline)
ui_badge() {
    case "$1" in
        running)         printf "${_GRN}● running${_R}"       ;;
        stopped)         printf "${_RED}○ stopped${_R}"       ;;
        "not installed") printf "${_DIM}─ not installed${_R}" ;;
        disabled)        printf "${_DIM}─ disabled${_R}"      ;;
        *)               printf "${_YLW}? ${1}${_R}"          ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# §3  STATE ENGINE — JSON single source of truth
#     All persistent values live in state.json.
#     Business logic NEVER reads raw files; it calls st_get/st_set.
# ══════════════════════════════════════════════════════════════════════════════

# Default state template — called once on first run
_st_default() {
    local uuid; uuid=$(_uuid_gen)
    jq -n --arg uuid "$uuid" '{
        v:    "3",
        uuid: $uuid,
        argo: { enabled: true,  proto: "ws",   port: 8080, tunnel: "temp" },
        ff:   { enabled: false, proto: "none", path: "/" },
        rl:   { enabled: false, port: 443,     sni: "www.microsoft.com",
                pbk: "", pvk: "", sid: "" },
        sys:  { restart_min: 0 }
    }'
}

st_init() {
    [ -f "$STATE_FILE" ] && return 0
    mkdir -p "${APP_ROOT}/"{bin,etc,log}
    chmod 750 "${APP_ROOT}"
    _st_default > "$STATE_FILE" || ui_die "状态文件初始化失败"
}

# st_get <jq-path>  →  stdout (empty string if missing)
st_get() { jq -r "${1} // empty" "$STATE_FILE" 2>/dev/null || true; }

# st_set <jq-filter> [jq-args…]  — atomic write via mktemp + mv
st_set() {
    local filter="$1"; shift
    local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX") \
        || { ui_err "mktemp 失败"; return 1; }
    if jq "$@" "$filter" "$STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mv "$tmp" "$STATE_FILE"
    else
        rm -f "$tmp"; ui_err "状态写入失败: ${filter}"; return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# §4  TRANSACTION ENGINE
#     txn_run <fn> [args…] — execute fn as an atomic unit:
#       • snapshot state.json before call
#       • on failure: restore snapshot, regenerate config, report rollback
# ══════════════════════════════════════════════════════════════════════════════
txn_begin()    { _TXN=$(cat "$STATE_FILE" 2>/dev/null || echo "{}"); }
txn_commit()   { _TXN=""; }
txn_rollback() {
    if [ -n "${_TXN:-}" ]; then
        printf '%s\n' "$_TXN" > "$STATE_FILE"
        _cfg_build 2>/dev/null || true   # best-effort config restore
        ui_warn "操作失败 — 已自动回滚至事务起点"
    fi
    _TXN=""
}

txn_run() {
    txn_begin
    if "$@"; then txn_commit; return 0
    else txn_rollback; return 1; fi
}

# ══════════════════════════════════════════════════════════════════════════════
# §5  PRE-FLIGHT ENGINE
#     preflight fn1 fn2 …  — pipeline: halt on first failure (block before write)
# ══════════════════════════════════════════════════════════════════════════════
_pf_root()      { [ "${EUID:-$(id -u)}" -eq 0 ] || { ui_err "需要 root 权限"; return 1; }; }
_pf_systemd()   { systemctl --version >/dev/null 2>&1 \
                      || { ui_err "需要 systemd (Debian 12+ 系统)"; return 1; }; }
_pf_installed() { [ -f "$STATE_FILE" ] && [ -x "$BIN_XRAY" ] \
                      || { ui_warn "xray-2go 尚未安装"; return 1; }; }
_pf_jq()        { command -v jq >/dev/null 2>&1 || { ui_err "jq 未安装"; return 1; }; }
_pf_cfg_valid() { "$BIN_XRAY" -test -c "$XRAY_CONF" >/dev/null 2>&1 \
                      || { ui_err "配置验证失败 (xray -test)"; return 1; }; }
_pf_port_free() { ! _port_in_use "$1" \
                      || { ui_warn "端口 $1 已被占用"; return 1; }; }

preflight() { local f; for f in "$@"; do "$f" || return 1; done; }

# ══════════════════════════════════════════════════════════════════════════════
# §6  NETWORK LAYER
# ══════════════════════════════════════════════════════════════════════════════
_port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH 2>/dev/null | awk -v p=":${p}" '$4~p"$"||$4~p" "{f=1}END{exit !f}'
        return
    fi
    # fallback: /proc/net/tcp + tcp6 big-endian hex match
    local h; h=$(printf '%04X' "$p")
    awk -v h="$h" 'NR>1 && substr($2,index($2,":")+1,4)==h{f=1}END{exit !f}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

net_realip() {
    local ip org v6
    ip=$(curl -sf --max-time 6 https://api.ipify.org  2>/dev/null) || true
    if [ -z "${ip:-}" ]; then
        v6=$(curl -sf --max-time 6 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${v6:-}" ] && printf '[%s]' "$v6" || printf ''
        return
    fi
    org=$(curl -sf --max-time 6 "https://ipinfo.io/${ip}/org" 2>/dev/null) || true
    echo "${org:-}" | grep -qiE 'Cloudflare|AEZA|Andrei|UnReal' && {
        v6=$(curl -sf --max-time 6 https://api6.ipify.org 2>/dev/null) || true
        [ -n "${v6:-}" ] && printf '[%s]' "$v6" || printf '%s' "$ip"
        return
    }
    printf '%s' "$ip"
}

# Exponential backoff poll of argo log: 3+3+6+8+8+8 = 36s + initial 3s ≈ 39s max
net_argo_domain() {
    local d delay=3 i=1
    sleep 3
    while [ "$i" -le 6 ]; do
        d=$(grep -o 'https://[^[:space:]]*trycloudflare\.com' \
            "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||') || true
        [ -n "${d:-}" ] && { printf '%s' "$d"; return 0; }
        sleep "$delay"
        i=$(( i + 1 ))
        delay=$(( delay < 8 ? delay * 2 : 8 ))
    done
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# §7  UUID & KEY HELPERS
# ══════════════════════════════════════════════════════════════════════════════
_uuid_gen() {
    [ -r /proc/sys/kernel/random/uuid ] \
        && cat /proc/sys/kernel/random/uuid \
        || od -An -N16 -tx1 /dev/urandom | tr -d ' \n' \
           | awk 'BEGIN{srand()}{h=$0; printf "%s-%s-4%s-%s%s-%s\n",
               substr(h,1,8),substr(h,9,4),substr(h,14,3),
               substr("89ab",int(rand()*4)+1,1),substr(h,18,3),substr(h,21,12)}'
}

# Kernel version check: _kver_ge MAJOR MINOR
_kver_ge() {
    local r; r=$(uname -r)
    local ma="${r%%.*}"
    local mi="${r#*.}"; mi="${mi%%.*}"; mi="${mi%%[^0-9]*}"
    [ "$ma" -gt "$1" ] || { [ "$ma" -eq "$1" ] && [ "${mi:-0}" -ge "$2" ]; }
}

# ══════════════════════════════════════════════════════════════════════════════
# §8  PROTOCOL PLUGIN REGISTRY — Inbound builders
#     Naming: _ib_<scope>_<proto>()  →  xray inbound JSON on stdout
#     Adding a protocol = adding one _ib_*() + one _lk_*() function.
#     The config generator and link builder call them by name; zero core changes.
# ══════════════════════════════════════════════════════════════════════════════
readonly _SNIFF='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}'

# ── Argo ─────────────────────────────────────────────────────────────────────
_ib_argo_ws() {
    local uuid port
    uuid=$(st_get .uuid); port=$(st_get .argo.port)
    jq -n --arg u "$uuid" --argjson p "$port" --argjson s "$_SNIFF" '{
        port: $p, listen: "127.0.0.1", protocol: "vless",
        settings:       { clients: [{id: $u}], decryption: "none" },
        streamSettings: { network: "ws", security: "none",
                          wsSettings: { path: "/argo" } },
        sniffing: $s
    }'
}

_ib_argo_xhttp() {
    local uuid port
    uuid=$(st_get .uuid); port=$(st_get .argo.port)
    jq -n --arg u "$uuid" --argjson p "$port" --argjson s "$_SNIFF" '{
        port: $p, listen: "127.0.0.1", protocol: "vless",
        settings:       { clients: [{id: $u}], decryption: "none" },
        streamSettings: { network: "xhttp", security: "none",
                          xhttpSettings: { host: "", path: "/argo", mode: "auto" } },
        sniffing: $s
    }'
}

# ── FreeFlow ──────────────────────────────────────────────────────────────────
_ib_ff_ws() {
    local uuid path
    uuid=$(st_get .uuid); path=$(st_get .ff.path)
    jq -n --arg u "$uuid" --arg p "$path" --argjson s "$_SNIFF" '{
        port: 80, listen: "::", protocol: "vless",
        settings:       { clients: [{id: $u}], decryption: "none" },
        streamSettings: { network: "ws", security: "none",
                          wsSettings: { path: $p } },
        sniffing: $s
    }'
}

_ib_ff_httpupgrade() {
    local uuid path
    uuid=$(st_get .uuid); path=$(st_get .ff.path)
    jq -n --arg u "$uuid" --arg p "$path" --argjson s "$_SNIFF" '{
        port: 80, listen: "::", protocol: "vless",
        settings:       { clients: [{id: $u}], decryption: "none" },
        streamSettings: { network: "httpupgrade", security: "none",
                          httpupgradeSettings: { path: $p } },
        sniffing: $s
    }'
}

_ib_ff_xhttp() {
    local uuid path
    uuid=$(st_get .uuid); path=$(st_get .ff.path)
    jq -n --arg u "$uuid" --arg p "$path" --argjson s "$_SNIFF" '{
        port: 80, listen: "::", protocol: "vless",
        settings:       { clients: [{id: $u}], decryption: "none" },
        streamSettings: { network: "xhttp", security: "none",
                          xhttpSettings: { host: "", path: $p, mode: "stream-one" } },
        sniffing: $s
    }'
}

# ── Reality ───────────────────────────────────────────────────────────────────
_ib_rl_tcp_vision() {
    local uuid port sni pvk sid
    uuid=$(st_get .uuid); port=$(st_get .rl.port)
    sni=$(st_get .rl.sni); pvk=$(st_get .rl.pvk); sid=$(st_get .rl.sid)
    jq -n --arg u "$uuid" --argjson p "$port" --arg sni "$sni" \
          --arg pvk "$pvk" --arg sid "$sid" --argjson s "$_SNIFF" '{
        port: $p, listen: "::", protocol: "vless",
        settings: { clients: [{ id: $u, flow: "xtls-rprx-vision" }],
                    decryption: "none" },
        streamSettings: {
            network: "tcp", security: "reality",
            realitySettings: {
                show: false, dest: ($sni + ":443"), xver: 0,
                serverNames: [$sni], privateKey: $pvk, shortIds: [$sid]
            }
        },
        sniffing: $s
    }'
}

# ── Keygen helpers ────────────────────────────────────────────────────────────
_rl_gen_keypair() {
    [ -x "$BIN_XRAY" ] || { ui_err "xray 未就绪，无法生成 Reality 密钥对"; return 1; }
    local out; out=$("$BIN_XRAY" x25519 2>/dev/null) \
        || { ui_err "xray x25519 执行失败"; return 1; }
    local pvk pbk
    pvk=$(printf '%s' "$out" | awk '/Private key:/{print $NF}')
    pbk=$(printf '%s' "$out" | awk '/Public key:/{print $NF}')
    [ -n "${pvk:-}" ] && [ -n "${pbk:-}" ] || { ui_err "密钥解析失败"; return 1; }
    # Write into state atomically
    st_set ".rl.pvk = \"${pvk}\" | .rl.pbk = \"${pbk}\""
    ui_ok "x25519 密钥对已生成"
}

_rl_gen_sid() {
    local sid; sid=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    st_set ".rl.sid = \"${sid}\""
}

# ══════════════════════════════════════════════════════════════════════════════
# §9  CONFIG GENERATOR  (pure function: state.json → XRAY_CONF)
#     Never patches. Rebuilds from scratch on every call.
#     This eliminates the entire class of "partial-apply" bugs from v2.
# ══════════════════════════════════════════════════════════════════════════════
_cfg_build() {
    local inbounds='[]' ib proto

    # ── Argo inbound
    if [ "$(st_get .argo.enabled)" = "true" ]; then
        proto=$(st_get .argo.proto)
        ib=$("_ib_argo_${proto}") || { ui_err "Argo inbound 构建失败 (proto=${proto})"; return 1; }
        inbounds=$(jq -n --argjson a "$inbounds" --argjson x "$ib" '$a + [$x]')
    fi

    # ── FreeFlow inbound
    if [ "$(st_get .ff.enabled)" = "true" ]; then
        proto=$(st_get .ff.proto)
        ib=$("_ib_ff_${proto}") || { ui_err "FreeFlow inbound 构建失败 (proto=${proto})"; return 1; }
        inbounds=$(jq -n --argjson a "$inbounds" --argjson x "$ib" '$a + [$x]')
    fi

    # ── Reality inbound (only if keys are ready)
    if [ "$(st_get .rl.enabled)" = "true" ]; then
        local pvk sid
        pvk=$(st_get .rl.pvk); sid=$(st_get .rl.sid)
        if [ -n "${pvk:-}" ] && [ -n "${sid:-}" ]; then
            ib=$(_ib_rl_tcp_vision) || { ui_err "Reality inbound 构建失败"; return 1; }
            inbounds=$(jq -n --argjson a "$inbounds" --argjson x "$ib" '$a + [$x]')
        else
            ui_warn "Reality 密钥未就绪，跳过 Reality inbound（请先生成密钥对）"
        fi
    fi

    # Warn if no inbound at all
    [ "$(printf '%s' "$inbounds" | jq 'length')" -eq 0 ] && \
        ui_warn "所有协议均已禁用，xray 将以零 inbound 模式运行（无可用节点）"

    # Write config atomically
    local tmp; tmp=$(mktemp "${XRAY_CONF}.XXXXXX") || { ui_err "mktemp 失败"; return 1; }
    jq -n --argjson ibs "$inbounds" '{
        log:      { access: "/dev/null", error: "/dev/null", loglevel: "none" },
        inbounds: $ibs,
        dns:      { servers: ["https+local://1.1.1.1/dns-query"] },
        outbounds: [
            { protocol: "freedom",   tag: "direct" },
            { protocol: "blackhole", tag: "block"  }
        ]
    }' > "$tmp" || { rm -f "$tmp"; ui_err "config.json 生成失败"; return 1; }
    mv "$tmp" "$XRAY_CONF"

    # Post-write syntax validation
    [ -x "$BIN_XRAY" ] && ! "$BIN_XRAY" -test -c "$XRAY_CONF" >/dev/null 2>&1 \
        && { ui_err "config.json 验证失败 (xray -test)"; return 1; }
    ui_ok "config.json 已重建并验证"
}

# ══════════════════════════════════════════════════════════════════════════════
# §10 LINK BUILDER  (protocol plugins — link side)
#     Naming: _lk_<scope>_<proto>()
# ══════════════════════════════════════════════════════════════════════════════
_urlencode() {
    printf '%s' "$1" | sed \
        's/%/%25/g;s/ /%20/g;s/!/%21/g;s/"/%22/g;s/#/%23/g;s/\$/%24/g;
         s/&/%26/g;s/+/%2B/g;s/,/%2C/g;s/:/%3A/g;s/;/%3B/g;s/=/%3D/g;
         s/?/%3F/g;s/@/%40/g;s/\[/%5B/g;s/\]/%5D/g'
}

_lk_argo_ws() {
    local uuid="$1" domain="$2"
    local cfip="${CFIP:-cdns.doon.eu.org}" cfport="${CFPORT:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=ws&host=%s&path=%%2Fargo%%3Fed%%3D2560#Argo-WS\n' \
        "$uuid" "$cfip" "$cfport" "$domain" "$domain"
}

_lk_argo_xhttp() {
    local uuid="$1" domain="$2"
    local cfip="${CFIP:-cdns.doon.eu.org}" cfport="${CFPORT:-443}"
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=firefox&type=xhttp&host=%s&path=%%2Fargo&mode=auto#Argo-XHTTP\n' \
        "$uuid" "$cfip" "$cfport" "$domain" "$domain"
}

_lk_ff() {
    local uuid="$1" ip="$2"
    local proto path enc
    proto=$(st_get .ff.proto)
    path=$(st_get .ff.path)
    enc=$(_urlencode "$path")
    case "$proto" in
        ws)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=ws&host=%s&path=%s#FF-WS\n' \
                "$uuid" "$ip" "$ip" "$enc" ;;
        httpupgrade)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=httpupgrade&host=%s&path=%s#FF-HTTPUpgrade\n' \
                "$uuid" "$ip" "$ip" "$enc" ;;
        xhttp)
            printf 'vless://%s@%s:80?encryption=none&security=none&type=xhttp&host=%s&path=%s&mode=stream-one#FF-XHTTP\n' \
                "$uuid" "$ip" "$ip" "$enc" ;;
    esac
}

_lk_rl_tcp_vision() {
    local uuid="$1" ip="$2"
    local port sni pbk sid
    port=$(st_get .rl.port); sni=$(st_get .rl.sni)
    pbk=$(st_get .rl.pbk);   sid=$(st_get .rl.sid)
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-Vision\n' \
        "$uuid" "$ip" "$port" "$sni" "$pbk" "$sid"
}

# Rebuild node file from current state + live IP/domain
nodes_build() {
    local uuid domain ip
    uuid=$(st_get .uuid)
    domain=$(cat "$DOMAIN_FILE" 2>/dev/null || true)
    ip=$(net_realip)

    {
        # Argo
        if [ "$(st_get .argo.enabled)" = "true" ] && [ -n "${domain:-}" ]; then
            local ap; ap=$(st_get .argo.proto)
            "_lk_argo_${ap}" "$uuid" "$domain"
        fi

        # FreeFlow
        if [ "$(st_get .ff.enabled)" = "true" ]; then
            if [ -n "${ip:-}" ]; then
                _lk_ff "$uuid" "$ip"
            else
                ui_warn "FreeFlow: 无法获取服务器 IP，节点链接跳过"
            fi
        fi

        # Reality
        if [ "$(st_get .rl.enabled)" = "true" ] \
            && [ -n "$(st_get .rl.pbk)" ] && [ -n "$(st_get .rl.sid)" ]; then
            if [ -n "${ip:-}" ]; then
                _lk_rl_tcp_vision "$uuid" "$ip"
            else
                ui_warn "Reality: 无法获取服务器 IP，节点链接跳过"
            fi
        fi
    } > "$NODE_FILE"
}

nodes_print() {
    ui_nl
    [ -s "$NODE_FILE" ] || { ui_warn "节点文件为空"; return 1; }
    while IFS= read -r line; do
        [ -n "${line:-}" ] && printf "${_CYN}  %s${_R}\n" "$line"
    done < "$NODE_FILE"
    ui_nl
}

# ══════════════════════════════════════════════════════════════════════════════
# §11 SYSTEMD SERVICE LAYER
#     Idempotent writes: content-aware diff before write; deferred daemon-reload
# ══════════════════════════════════════════════════════════════════════════════

# Returns 0 if unchanged (no reload needed), 1 if file was written
_svc_write() {
    local dest="$1" content="$2"
    local cur; cur=$(cat "$dest" 2>/dev/null || true)
    [ "$cur" = "$content" ] && return 0
    printf '%s\n' "$content" > "$dest"
    _DIRTY=1
}

_reload_if_dirty() {
    [ "$_DIRTY" -eq 1 ] || return 0
    systemctl daemon-reload 2>/dev/null || true
    _DIRTY=0
}

_tpl_xray_unit() { cat <<EOF
[Unit]
Description=xray-2go Core
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${BIN_XRAY} run -c ${XRAY_CONF}
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF
}

_tpl_argo_unit() { cat <<EOF
[Unit]
Description=xray-2go Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/sh -c '${1} >> ${ARGO_LOG} 2>&1'
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}

_argo_cmd_temp() {
    printf '%s tunnel --url http://localhost:%s --no-autoupdate --edge-ip-version auto --protocol http2' \
        "$BIN_ARGO" "$(st_get .argo.port)"
}

svc_reg_xray() {
    _svc_write "/etc/systemd/system/${SVC_XRAY}.service" "$(_tpl_xray_unit)"
}

svc_reg_argo() {
    local cmd="${1:-$(_argo_cmd_temp)}"
    _svc_write "/etc/systemd/system/${SVC_ARGO}.service" "$(_tpl_argo_unit "$cmd")"
}

# Unified control
svc_ctrl() { systemctl "$1" "$2" 2>/dev/null; }

svc_restart_xray() {
    ui_step "重启 xray"
    _reload_if_dirty
    svc_ctrl restart "$SVC_XRAY" \
        && ui_ok "xray 已重启" \
        || { ui_err "xray 重启失败"; return 1; }
}

svc_restart_argo() {
    rm -f "$ARGO_LOG"
    ui_step "重启 Argo 隧道"
    _reload_if_dirty
    svc_ctrl restart "$SVC_ARGO" \
        && ui_ok "Argo 隧道已重启" \
        || { ui_err "Argo 隧道重启失败"; return 1; }
}

_svc_status() {  # _svc_status <binary> <unit>
    [ -x "$1" ] || { printf 'not installed'; return 2; }
    [ "$(systemctl is-active "$2" 2>/dev/null)" = "active" ] \
        && printf 'running' || printf 'stopped'
}

# ══════════════════════════════════════════════════════════════════════════════
# §12 DEPENDENCY & BINARY MANAGER
# ══════════════════════════════════════════════════════════════════════════════
dep_require() {
    local pkg="$1" bin="${2:-$1}"
    command -v "$bin" >/dev/null 2>&1 && return 0
    ui_step "安装依赖: ${pkg}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
    hash -r 2>/dev/null || true
    command -v "$bin" >/dev/null 2>&1 || ui_die "${pkg} 安装失败，请手动安装后重试"
    ui_ok "${pkg} 已就绪"
}

dep_check() {
    dep_require curl
    dep_require unzip
    dep_require jq
}

_arch() {
    case "$(uname -m)" in
        x86_64)        printf '%s|%s' amd64 64          ;;
        aarch64|arm64) printf '%s|%s' arm64 arm64-v8a   ;;
        armv7l)        printf '%s|%s' armv7 arm32-v7a   ;;
        x86|i686)      printf '%s|%s' 386   32           ;;
        s390x)         printf '%s|%s' s390x s390x        ;;
        *) ui_die "不支持的架构: $(uname -m)" ;;
    esac
}

bin_install_xray() {
    [ -x "$BIN_XRAY" ] && { ui_info "xray 已存在，跳过下载"; return 0; }
    local a; a=$(_arch)
    local xarch="${a##*|}"
    local zip="${APP_ROOT}/bin/xray.zip"
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xarch}.zip"
    ui_spin_start "下载 Xray (${xarch})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "$zip" "$url"
    local rc=$?; ui_spin_stop
    [ "$rc" -ne 0 ] && { rm -f "$zip"; ui_err "Xray 下载失败"; return 1; }
    unzip -t "$zip" >/dev/null 2>&1 || { rm -f "$zip"; ui_err "Xray 压缩包损坏"; return 1; }
    unzip -o "$zip" xray -d "${APP_ROOT}/bin/" >/dev/null 2>&1
    rm -f "$zip"
    [ -f "$BIN_XRAY" ] || { ui_err "解压后未找到 xray 二进制"; return 1; }
    chmod +x "$BIN_XRAY"
    ui_ok "Xray 安装完成 ($("$BIN_XRAY" version 2>/dev/null | head -1 | awk '{print $2}'))"
}

bin_install_argo() {
    [ -x "$BIN_ARGO" ] && { ui_info "cloudflared 已存在，跳过下载"; return 0; }
    local a; a=$(_arch)
    local carch="${a%%|*}"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${carch}"
    ui_spin_start "下载 cloudflared (${carch})"
    curl -sfL --connect-timeout 15 --max-time 120 -o "$BIN_ARGO" "$url"
    local rc=$?; ui_spin_stop
    [ "$rc" -ne 0 ] && { rm -f "$BIN_ARGO"; ui_err "cloudflared 下载失败"; return 1; }
    [ -s "$BIN_ARGO" ]  || { rm -f "$BIN_ARGO"; ui_err "cloudflared 文件为空"; return 1; }
    chmod +x "$BIN_ARGO"
    ui_ok "cloudflared 安装完成"
}

# ══════════════════════════════════════════════════════════════════════════════
# §13 ENVIRONMENT SELF-HEAL  (BBR / systemd-resolved / Debian-specific)
# ══════════════════════════════════════════════════════════════════════════════
env_check_bbr() {
    local algo; algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    [ "$algo" = "bbr" ] && { ui_ok "TCP BBR 已启用"; return; }
    ui_warn "TCP 拥塞控制: ${algo}（推荐 BBR）"
    _kver_ge 4 9 || { ui_warn "内核 $(uname -r) < 4.9，跳过 BBR 配置"; return; }
    ui_ask "是否立即启用 BBR？(y/N):" _a
    case "${_a:-n}" in y|Y)
        modprobe tcp_bbr 2>/dev/null || true
        mkdir -p /etc/modules-load.d /etc/sysctl.d
        printf 'tcp_bbr\n' > /etc/modules-load.d/xray2go-bbr.conf
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
            > /etc/sysctl.d/88-xray2go-bbr.conf
        sysctl -p /etc/sysctl.d/88-xray2go-bbr.conf >/dev/null 2>&1
        ui_ok "BBR 已启用（重启后持久生效）"
    ;; esac
}

env_check_resolved() {
    [ -f /etc/debian_version ] || return 0
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    local stub; stub=$(awk -F= '/^DNSStubListener/{gsub(/ /,"",$2); print $2}' \
                       /etc/systemd/resolved.conf 2>/dev/null)
    [ "${stub:-yes}" != "no" ] && \
        ui_info "systemd-resolved stub 已激活 — xray 使用 DoH，无端口冲突"
}

# ══════════════════════════════════════════════════════════════════════════════
# §14 INTERACTIVE ASK FUNCTIONS  (pure input collection — no side effects)
# ══════════════════════════════════════════════════════════════════════════════
ask_argo_mode() {
    ui_nl
    printf "${_B}${_PUR}  ▸ Argo 隧道${_R}\n"
    printf "  ${_GRN}1${_R}  安装 Argo (VLESS+WS/XHTTP+TLS)  ${_DIM}[默认]${_R}\n"
    printf "  ${_GRN}2${_R}  不安装 Argo\n"
    ui_ask "选择 (1-2):" _c
    case "${_c:-1}" in
        2) st_set '.argo.enabled = false'; ui_info "跳过 Argo" ;;
        *) st_set '.argo.enabled = true';  ui_info "安装 Argo"  ;;
    esac
}

ask_argo_proto() {
    ui_nl
    printf "${_B}${_PUR}  ▸ Argo 传输协议${_R}\n"
    printf "  ${_GRN}1${_R}  WS    (临时 + 固定隧道均支持)  ${_DIM}[默认]${_R}\n"
    printf "  ${_GRN}2${_R}  XHTTP (auto 模式，仅固定隧道)\n"
    ui_ask "选择 (1-2):" _c
    case "${_c:-1}" in
        2) st_set '.argo.proto = "xhttp"'; ui_warn "XHTTP 仅支持固定隧道！" ;;
        *) st_set '.argo.proto = "ws"'                                       ;;
    esac
    ui_info "Argo 协议: $(st_get .argo.proto)"
}

ask_ff_mode() {
    ui_nl
    printf "${_B}${_PUR}  ▸ FreeFlow (明文 port 80)${_R}\n"
    printf "  ${_GRN}1${_R}  WS\n"
    printf "  ${_GRN}2${_R}  HTTPUpgrade\n"
    printf "  ${_GRN}3${_R}  XHTTP (stream-one)\n"
    printf "  ${_GRN}4${_R}  不启用  ${_DIM}[默认]${_R}\n"
    ui_ask "选择 (1-4):" _c
    local proto
    case "${_c:-4}" in
        1) proto="ws"          ;;
        2) proto="httpupgrade" ;;
        3) proto="xhttp"       ;;
        *) st_set '.ff.enabled = false | .ff.proto = "none"'
           ui_info "跳过 FreeFlow"; return ;;
    esac
    ui_ask "Path (回车默认 /):" _p
    local path; case "${_p:-/}" in /*) path="${_p:-/}" ;; *) path="/${_p}" ;; esac
    st_set ".ff.enabled = true | .ff.proto = \"${proto}\" | .ff.path = \"${path}\""
    ui_info "FreeFlow: ${proto}  path=${path}"
}

# ══════════════════════════════════════════════════════════════════════════════
# §15 INSTALL / UNINSTALL
# ══════════════════════════════════════════════════════════════════════════════
cmd_install() {
    clear
    printf "\n${_B}${_PUR}  ══  安装 xray-2go  ══${_R}\n\n"
    preflight _pf_root _pf_systemd || return 1

    dep_check

    mkdir -p "${APP_ROOT}/"{bin,etc,log}
    chmod 750 "${APP_ROOT}"

    # Collect user preferences (writes into state.json)
    ask_argo_mode
    [ "$(st_get .argo.enabled)" = "true" ] && ask_argo_proto
    ask_ff_mode

    # Non-blocking port warnings
    [ "$(st_get .argo.enabled)" = "true" ] && \
        { _port_in_use "$(st_get .argo.port)" && \
          ui_warn "端口 $(st_get .argo.port) 已被占用，可安装后在 Argo 管理中修改"; } || true
    [ "$(st_get .ff.enabled)" = "true" ] && \
        { _port_in_use 80 && ui_warn "端口 80 已被占用，FreeFlow 可能无法启动"; } || true

    # Environment self-healing (Debian 12 specific)
    env_check_resolved
    env_check_bbr

    # ── Core installation transaction
    txn_begin
    {
        bin_install_xray                                                     \
        && {
            [ "$(st_get .argo.enabled)" = "true" ] \
                && bin_install_argo || true
           }                                                                 \
        && _cfg_build                                                        \
        && svc_reg_xray                                                      \
        && {
            [ "$(st_get .argo.enabled)" = "true" ] \
                && svc_reg_argo || true
           }                                                                 \
        && _reload_if_dirty                                                  \
        && { svc_ctrl enable "$SVC_XRAY"; svc_ctrl start "$SVC_XRAY"; }     \
        && {
            [ "$(st_get .argo.enabled)" = "true" ] && {
                svc_ctrl enable "$SVC_ARGO"; svc_ctrl start "$SVC_ARGO"
            } || true
           }
    } || { txn_rollback; ui_err "安装失败，所有变更已回滚"; return 1; }
    txn_commit

    # ── Post-install: domain acquisition
    if [ "$(st_get .argo.enabled)" = "true" ]; then
        if [ "$(st_get .argo.proto)" = "xhttp" ]; then
            ui_warn "XHTTP 仅支持固定隧道，即将进入配置流程…"
            cmd_tunnel_fixed \
                || ui_err "固定隧道配置失败，请从 [Argo 管理→1] 重试"
        else
            _domain_acquire_post_install
        fi
    fi

    nodes_build
    nodes_print
    ui_ok "══  安装完成  ══"
}

_domain_acquire_post_install() {
    ui_nl
    printf "  ${_GRN}1${_R}  临时隧道 (WS，自动生成域名)  ${_DIM}[默认]${_R}\n"
    printf "  ${_GRN}2${_R}  固定隧道 (自有 token / JSON)\n"
    ui_ask "隧道类型 (1-2):" _tc
    case "${_tc:-1}" in
        2)
            cmd_tunnel_fixed || {
                ui_warn "固定隧道配置失败，回退临时隧道"
                _domain_from_temp
            } ;;
        *) _domain_from_temp ;;
    esac
}

_domain_from_temp() {
    ui_step "等待 Argo 临时域名（约 39s）"
    local d; d=$(net_argo_domain) || { ui_warn "未获取到临时域名，可从 Argo 管理刷新"; return 1; }
    printf '%s\n' "$d" > "$DOMAIN_FILE"
    st_set '.argo.tunnel = "temp"'
    ui_ok "ArgoDomain: ${d}"
}

cmd_uninstall() {
    ui_nl; ui_ask "确认卸载 xray-2go？(y/N):" _c
    case "${_c:-n}" in y|Y) : ;; *) ui_info "已取消"; return ;; esac
    ui_step "卸载中"
    _cron_remove
    local s; for s in "$SVC_XRAY" "$SVC_ARGO"; do
        svc_ctrl stop    "$s" 2>/dev/null || true
        svc_ctrl disable "$s" 2>/dev/null || true
    done
    rm -f "/etc/systemd/system/${SVC_XRAY}.service" \
          "/etc/systemd/system/${SVC_ARGO}.service"
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$APP_ROOT"
    rm -f  "$SHORTCUT" "$SELF_PATH" "${SELF_PATH}.bak"
    ui_ok "卸载完成"
}

# ══════════════════════════════════════════════════════════════════════════════
# §16 TUNNEL MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════
cmd_tunnel_fixed() {
    local port proto
    port=$(st_get .argo.port); proto=$(st_get .argo.proto)
    ui_info "固定隧道  协议:${proto}  回源端口:${port}"
    ui_info "请确认 Cloudflare 后台 ingress 已指向 http://localhost:${port}"
    ui_nl

    local domain auth
    ui_ask "Argo 域名:" domain
    case "${domain:-}" in ''|*[[:space:]]*|*'/'*)
        ui_err "域名格式不合法"; return 1 ;; esac
    printf '%s' "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$' \
        || { ui_err "域名格式不合法"; return 1; }

    ui_ask "密钥 (token 或 JSON):" auth
    [ -z "${auth:-}" ] && { ui_err "密钥不能为空"; return 1; }

    local exec_cmd
    if printf '%s' "$auth" | grep -q "TunnelSecret"; then
        printf '%s' "$auth" | jq . >/dev/null 2>&1 \
            || { ui_err "JSON 凭证格式不合法"; return 1; }
        local tid; tid=$(printf '%s' "$auth" | jq -r '
            if (.TunnelID?//"")!="" then .TunnelID
            elif (.AccountTag?//"")!="" then .AccountTag
            else empty end' 2>/dev/null)
        [ -z "${tid:-}" ] && { ui_err "无法从 JSON 提取 TunnelID"; return 1; }
        # YAML injection guard
        case "$tid" in *$'\n'*|*'"'*|*"'"*|*':'*)
            ui_err "TunnelID 含非法字符，拒绝写入"; return 1 ;; esac

        printf '%s\n' "$auth" > "$TUNNEL_JSON"
        cat > "$TUNNEL_YML" <<EOF
tunnel: ${tid}
credentials-file: ${TUNNEL_JSON}
protocol: http2
ingress:
  - hostname: ${domain}
    service: http://localhost:${port}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        exec_cmd="${BIN_ARGO} tunnel --edge-ip-version auto --config ${TUNNEL_YML} run"
    elif printf '%s' "$auth" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
        exec_cmd="${BIN_ARGO} tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${auth}"
    else
        ui_err "密钥格式无法识别 (JSON 需含 TunnelSecret；Token 为 120-250 位字母数字串)"
        return 1
    fi

    txn_run _tunnel_fixed_commit "$exec_cmd" "$domain"
}

_tunnel_fixed_commit() {
    local exec_cmd="$1" domain="$2"
    svc_reg_argo "$exec_cmd"
    _reload_if_dirty
    svc_ctrl enable "$SVC_ARGO" 2>/dev/null || true
    printf '%s\n' "$domain" > "$DOMAIN_FILE"
    st_set ".argo.tunnel = \"fixed\""
    _cfg_build || return 1
    svc_restart_xray || return 1
    svc_restart_argo  || return 1
    ui_ok "固定隧道 ($(st_get .argo.proto)) 已配置  域名: ${domain}"
}

cmd_tunnel_temp_reset() {
    [ "$(st_get .argo.proto)" != "xhttp" ] \
        || { ui_err "XHTTP 不支持临时隧道，请先在 [2. 切换协议] 改回 WS"; return 1; }
    txn_begin
    svc_reg_argo "$(_argo_cmd_temp)"
    _reload_if_dirty
    rm -f "$DOMAIN_FILE" "$TUNNEL_JSON" "$TUNNEL_YML"
    st_set '.argo.tunnel = "temp" | .argo.proto = "ws"'
    _cfg_build && svc_restart_xray && svc_restart_argo || { txn_rollback; return 1; }
    txn_commit
    _domain_from_temp && { nodes_build; nodes_print; } \
        || ui_warn "域名未获取，可稍后用 [刷新临时域名] 操作"
}

cmd_tunnel_refresh() {
    [ "$(st_get .argo.tunnel)" = "temp" ] \
        || { ui_err "当前为固定隧道，无需刷新"; return 1; }
    [ "$(st_get .argo.proto)"  = "ws"   ] \
        || { ui_err "XHTTP 不支持临时隧道"; return 1; }
    svc_restart_argo || return 1
    _domain_from_temp || return 1
    nodes_build; nodes_print; ui_ok "节点已刷新"
}

# ══════════════════════════════════════════════════════════════════════════════
# §17 CRON AUTO-RESTART
# ══════════════════════════════════════════════════════════════════════════════
_cron_available() {
    command -v crontab >/dev/null 2>&1 \
        && { systemctl is-active --quiet cron  2>/dev/null \
             || systemctl is-active --quiet crond 2>/dev/null; }
}

_cron_ensure() {
    _cron_available && return 0
    ui_warn "cron 未运行"
    ui_ask "是否安装 cron？(Y/n):" _a
    case "${_a:-y}" in n|N)
        ui_err "cron 不可用，自动重启无法配置"; return 1 ;; esac
    DEBIAN_FRONTEND=noninteractive apt-get install -y cron >/dev/null 2>&1
    systemctl enable --now cron 2>/dev/null || true
    _cron_available || { ui_err "cron 安装失败"; return 1; }
}

_cron_set() {
    _cron_ensure || return 1
    local min="$1"
    local tmp; tmp=$(mktemp) || return 1
    {   crontab -l 2>/dev/null | grep -v '#xray2go-restart'
        [ "$min" -gt 0 ] && printf '*/%s * * * * systemctl restart %s >/dev/null 2>&1 #xray2go-restart\n' \
            "$min" "$SVC_XRAY"
    } > "$tmp"
    crontab "$tmp" && rm -f "$tmp" || { rm -f "$tmp"; ui_err "crontab 写入失败"; return 1; }
}

_cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp; tmp=$(mktemp) || return 0
    crontab -l 2>/dev/null | grep -v '#xray2go-restart' > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# §18 SELF-UPDATE / SHORTCUT
# ══════════════════════════════════════════════════════════════════════════════
cmd_update() {
    ui_step "拉取最新脚本"
    local tmp="${SELF_PATH}.tmp"
    curl -sfL --connect-timeout 15 --max-time 60 -o "$tmp" "$UPSTREAM" \
        || { rm -f "$tmp"; ui_err "下载失败，请检查网络"; return 1; }
    bash -n "$tmp" 2>/dev/null \
        || { rm -f "$tmp"; ui_err "脚本语法验证失败，已中止"; return 1; }
    [ -f "$SELF_PATH" ] && cp -f "$SELF_PATH" "${SELF_PATH}.bak" 2>/dev/null || true
    mv "$tmp" "$SELF_PATH" && chmod +x "$SELF_PATH"
    printf '#!/bin/bash\nexec %s "$@"\n' "$SELF_PATH" > "$SHORTCUT"
    chmod +x "$SHORTCUT"
    ui_ok "脚本已更新  ·  输入 ${_B}x2g${_R} 快速启动"
}

# ══════════════════════════════════════════════════════════════════════════════
# §19 MENU SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

# ── Main menu ─────────────────────────────────────────────────────────────────
menu_main() {
    while true; do
        local xs as argo_en ff_en rl_en domain ri

        xs=$(_svc_status "$BIN_XRAY" "$SVC_XRAY")
        as=$(_svc_status "$BIN_ARGO" "$SVC_ARGO")
        argo_en=$(st_get .argo.enabled  2>/dev/null || echo false)
        ff_en=$( st_get .ff.enabled    2>/dev/null || echo false)
        rl_en=$(  st_get .rl.enabled    2>/dev/null || echo false)
        domain=$( cat "$DOMAIN_FILE" 2>/dev/null   || echo '─')
        ri=$(     st_get .sys.restart_min 2>/dev/null || echo 0)

        clear
        printf "\n${_B}${_PUR}"
        printf "  ╔═══════════════════════════════════════════╗\n"
        printf "  ║  xray-2go  v3.0                           ║\n"
        printf "  ╠═══════════════════════════════════════════╣\n"
        printf "  ║${_R}  Xray     "; ui_badge "$xs";     printf "\n"
        printf "${_B}${_PUR}  ║${_R}  Argo     "
        if [ "$argo_en" = "true" ]; then
            ui_badge "$as"
            printf "  ${_DIM}[%s · %s]${_R}\n" "$(st_get .argo.proto)" "$(st_get .argo.tunnel)"
        else
            printf "${_DIM}─ disabled${_R}\n"
        fi
        printf "${_B}${_PUR}  ║${_R}  FreeFlow "
        [ "$ff_en" = "true" ] \
            && printf "${_GRN}● ${_R}${_DIM}%s  path=%s${_R}\n" \
               "$(st_get .ff.proto)" "$(st_get .ff.path)" \
            || printf "${_DIM}─ disabled${_R}\n"
        printf "${_B}${_PUR}  ║${_R}  Reality  "
        [ "$rl_en" = "true" ] \
            && printf "${_GRN}● ${_R}${_DIM}%s:%s${_R}\n" "$(st_get .rl.sni)" "$(st_get .rl.port)" \
            || printf "${_DIM}─ disabled${_R}\n"
        printf "${_B}${_PUR}  ║${_R}  Domain   ${_DIM}%s${_R}\n" "$domain"
        printf "${_B}${_PUR}  ║${_R}  Cron     ${_DIM}%s min${_R}\n" "$ri"
        printf "${_B}${_PUR}  ╚═══════════════════════════════════════════╝${_R}\n\n"

        printf "  ${_GRN}1${_R}  安装        ${_RED}2${_R}  卸载\n"
        ui_sep
        printf "  ${_GRN}3${_R}  Argo 管理   ${_GRN}4${_R}  FreeFlow 管理\n"
        printf "  ${_GRN}5${_R}  Reality 管理\n"
        ui_sep
        printf "  ${_GRN}6${_R}  查看节点    ${_GRN}7${_R}  修改 UUID\n"
        printf "  ${_GRN}8${_R}  自动重启    ${_GRN}9${_R}  更新脚本\n"
        ui_sep
        printf "  ${_RED}0${_R}  退出\n\n"
        ui_ask "选择 (0-9):" _c; ui_nl

        case "${_c:-}" in
            1) if preflight _pf_installed 2>/dev/null
               then ui_warn "已安装，如需重装请先卸载 (选项 2)"
               else cmd_install; fi ;;
            2) cmd_uninstall ;;
            3) menu_argo      ;;
            4) menu_freeflow  ;;
            5) menu_reality   ;;
            6) preflight _pf_installed && nodes_build && nodes_print ;;
            7) cmd_change_uuid ;;
            8) menu_restart    ;;
            9) cmd_update      ;;
            0) exit 0          ;;
            *) ui_err "无效选项 (0-9)" ;;
        esac
        ui_pause
    done
}

# ── Argo menu ─────────────────────────────────────────────────────────────────
menu_argo() {
    preflight _pf_installed || return

    while true; do
        local as tunnel proto port domain
        as=$(    _svc_status "$BIN_ARGO" "$SVC_ARGO")
        tunnel=$(st_get .argo.tunnel); proto=$(st_get .argo.proto)
        port=$(  st_get .argo.port)
        domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo '─')

        clear
        printf "\n${_B}${_PUR}  ▸ Argo 隧道管理${_R}\n"
        printf "  状态:"; ui_badge "$as"
        printf "  协议: ${_CYN}%s${_R}  类型: ${_DIM}%s${_R}  端口: ${_YLW}%s${_R}\n" \
            "$proto" "$tunnel" "$port"
        printf "  域名: ${_DIM}%s${_R}\n" "$domain"
        ui_sep
        printf "  ${_GRN}1${_R}  添加/更新固定隧道\n"
        printf "  ${_GRN}2${_R}  切换协议 WS ↔ XHTTP  (仅固定隧道)\n"
        printf "  ${_GRN}3${_R}  切换回临时隧道 (WS)\n"
        printf "  ${_GRN}4${_R}  刷新临时域名\n"
        printf "  ${_GRN}5${_R}  修改回源端口  (当前: ${_YLW}%s${_R})\n" "$port"
        printf "  ${_GRN}6${_R}  启动隧道    ${_GRN}7${_R}  停止隧道\n"
        ui_sep
        printf "  ${_PUR}0${_R}  返回\n\n"
        ui_ask "选择:" _c

        case "${_c:-}" in
            1)  _ask_argo_proto_inline
                cmd_tunnel_fixed \
                    && { nodes_build; nodes_print; } ;;
            2)  txn_run _argo_toggle_proto ;;
            3)  cmd_tunnel_temp_reset      ;;
            4)  cmd_tunnel_refresh         ;;
            5)  txn_run _argo_change_port  ;;
            6)  svc_ctrl start "$SVC_ARGO" \
                    && ui_ok "隧道已启动" \
                    || ui_err "启动失败，请检查日志" ;;
            7)  svc_ctrl stop  "$SVC_ARGO" \
                    && ui_ok "隧道已停止" \
                    || ui_err "停止失败" ;;
            0)  return ;;
            *)  ui_err "无效选项" ;;
        esac
        ui_pause
    done
}

_ask_argo_proto_inline() {
    printf "  ${_GRN}1${_R} WS  ${_DIM}[默认]${_R}   ${_GRN}2${_R} XHTTP\n"
    ui_ask "协议 (回车维持当前 $(st_get .argo.proto)):" _p
    case "${_p:-}" in
        1) st_set '.argo.proto = "ws"'    ;;
        2) st_set '.argo.proto = "xhttp"' ;;
    esac
}

_argo_toggle_proto() {
    [ "$(st_get .argo.tunnel)" = "fixed" ] \
        || { ui_err "仅固定隧道支持切换协议"; return 1; }
    local cur; cur=$(st_get .argo.proto)
    local new; [ "$cur" = "ws" ] && new="xhttp" || new="ws"
    st_set ".argo.proto = \"${new}\""
    _cfg_build && svc_restart_xray || return 1
    ui_ok "协议已切换: ${new}"
    nodes_build; nodes_print
}

_argo_change_port() {
    local old_port; old_port=$(st_get .argo.port)
    ui_ask "新端口 (回车随机生成):" _p
    [ -z "${_p:-}" ] && \
        _p=$(shuf -i 2000-65000 -n 1 2>/dev/null \
             || awk 'BEGIN{srand();print int(rand()*63000)+2000}')
    case "${_p:-}" in ''|*[!0-9]*) ui_err "无效端口"; return 1 ;; esac
    { [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; } \
        || { ui_err "端口须在 1-65535 之间"; return 1; }
    _port_in_use "$_p" && {
        ui_warn "端口 ${_p} 已被占用"
        ui_ask "仍然继续？(y/N):" _a
        case "${_a:-n}" in y|Y) : ;; *) return 1 ;; esac
    }
    st_set ".argo.port = ${_p}"

    # Update service file (and tunnel.yml for JSON-credential fixed tunnels)
    local tunnel; tunnel=$(st_get .argo.tunnel)
    if [ "$tunnel" = "fixed" ] && [ -f "$TUNNEL_YML" ]; then
        sed -i "s|localhost:${old_port}|localhost:${_p}|g" "$TUNNEL_YML" 2>/dev/null || true
        local exec_cmd="${BIN_ARGO} tunnel --edge-ip-version auto --config ${TUNNEL_YML} run"
        svc_reg_argo "$exec_cmd"
    else
        svc_reg_argo "$(_argo_cmd_temp)"
    fi

    _reload_if_dirty
    _cfg_build && svc_restart_xray && svc_restart_argo || return 1
    ui_ok "回源端口已修改: ${_p}"
}

# ── FreeFlow menu ─────────────────────────────────────────────────────────────
menu_freeflow() {
    preflight _pf_installed || return

    while true; do
        clear
        printf "\n${_B}${_PUR}  ▸ FreeFlow 管理${_R}\n"
        if [ "$(st_get .ff.enabled)" = "true" ]; then
            printf "  状态: ${_GRN}● 启用${_R}  协议: ${_CYN}%s${_R}  path: ${_DIM}%s${_R}\n" \
                "$(st_get .ff.proto)" "$(st_get .ff.path)"
        else
            printf "  状态: ${_DIM}─ 未启用${_R}\n"
        fi
        ui_sep
        printf "  ${_GRN}1${_R}  添加/变更方式\n"
        printf "  ${_GRN}2${_R}  修改 path\n"
        printf "  ${_RED}3${_R}  卸载 FreeFlow\n"
        ui_sep
        printf "  ${_PUR}0${_R}  返回\n\n"
        ui_ask "选择:" _c

        case "${_c:-}" in
            1) txn_run _ff_change_mode   ;;
            2) txn_run _ff_change_path   ;;
            3) txn_run _ff_uninstall     ;;
            0) return ;;
            *) ui_err "无效选项" ;;
        esac
        ui_pause
    done
}

_ff_change_mode() {
    ask_ff_mode
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print; ui_ok "FreeFlow 已变更"
}

_ff_change_path() {
    [ "$(st_get .ff.enabled)" = "true" ] \
        || { ui_err "FreeFlow 未启用，请先选择方式 (选项 1)"; return 1; }
    ui_ask "新 path (回车保持 $(st_get .ff.path)):" _p
    [ -z "${_p:-}" ] && return 0
    case "$_p" in /*) : ;; *) _p="/${_p}" ;; esac
    st_set ".ff.path = \"${_p}\""
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print; ui_ok "path 已修改: ${_p}"
}

_ff_uninstall() {
    st_set '.ff.enabled = false | .ff.proto = "none"'
    _cfg_build && svc_restart_xray || return 1
    # Atomically strip FreeFlow lines from node file
    if [ -f "$NODE_FILE" ]; then
        local tmp; tmp=$(mktemp "${NODE_FILE}.XXXXXX") || return 0
        grep -v '#FF-' "$NODE_FILE" > "$tmp" \
            && mv "$tmp" "$NODE_FILE" \
            || rm -f "$tmp"
    fi
    ui_ok "FreeFlow 已卸载"
}

# ── Reality menu ──────────────────────────────────────────────────────────────
menu_reality() {
    preflight _pf_installed || return

    while true; do
        local rl_en port sni pbk
        rl_en=$(st_get .rl.enabled)
        port=$(  st_get .rl.port);  sni=$(st_get .rl.sni)
        pbk=$(   st_get .rl.pbk)

        clear
        printf "\n${_B}${_PUR}  ▸ Reality 管理  (VLESS + TCP + XTLS-Vision)${_R}\n"
        if [ "$rl_en" = "true" ]; then
            printf "  状态: ${_GRN}● 启用${_R}  端口: ${_CYN}%s${_R}  SNI: ${_DIM}%s${_R}\n" \
                "$port" "$sni"
            [ -n "${pbk:-}" ] \
                && printf "  PBK:  ${_DIM}%s…${_R}\n" "${pbk:0:24}" \
                || printf "  ${_YLW}  ⚠  密钥对尚未生成${_R}\n"
        else
            printf "  状态: ${_DIM}─ 未启用${_R}\n"
        fi
        ui_sep
        printf "  ${_GRN}1${_R}  启用 / 配置 Reality\n"
        printf "  ${_GRN}2${_R}  重新生成密钥对\n"
        printf "  ${_GRN}3${_R}  修改端口\n"
        printf "  ${_GRN}4${_R}  修改 SNI (伪装站点)\n"
        printf "  ${_RED}5${_R}  卸载 Reality\n"
        ui_sep
        printf "  ${_PUR}0${_R}  返回\n\n"
        ui_ask "选择:" _c

        case "${_c:-}" in
            1) txn_run _rl_enable   ;;
            2) txn_run _rl_regen    ;;
            3) txn_run _rl_chg_port ;;
            4) txn_run _rl_chg_sni  ;;
            5) txn_run _rl_uninstall ;;
            0) return ;;
            *) ui_err "无效选项" ;;
        esac
        ui_pause
    done
}

_rl_enable() {
    # Port
    ui_ask "监听端口 (回车默认 $(st_get .rl.port)):" _p
    if [ -n "${_p:-}" ]; then
        case "${_p}" in ''|*[!0-9]*) ui_err "无效端口"; return 1 ;; esac
        { [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; } \
            || { ui_err "端口须在 1-65535 之间"; return 1; }
        _port_in_use "$_p" && ui_warn "端口 ${_p} 已被占用"
        st_set ".rl.port = ${_p}"
    fi
    # SNI
    ui_ask "伪装 SNI (回车默认 $(st_get .rl.sni)):" _s
    [ -n "${_s:-}" ] && st_set ".rl.sni = \"${_s}\""

    # Generate keys if not present
    local pvk; pvk=$(st_get .rl.pvk)
    if [ -z "${pvk:-}" ]; then
        ui_step "生成 x25519 密钥对"
        _rl_gen_keypair || return 1
        _rl_gen_sid     || return 1
    fi

    st_set '.rl.enabled = true'
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print
    ui_ok "Reality 已启用"
}

_rl_regen() {
    ui_step "重新生成 x25519 密钥对 + shortId"
    _rl_gen_keypair || return 1
    _rl_gen_sid     || return 1
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print
    ui_ok "密钥对已更新（请同步更新客户端配置）"
}

_rl_chg_port() {
    ui_ask "新端口:" _p
    case "${_p:-}" in ''|*[!0-9]*) ui_err "无效端口"; return 1 ;; esac
    { [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; } \
        || { ui_err "端口须在 1-65535 之间"; return 1; }
    _port_in_use "$_p" && ui_warn "端口 ${_p} 已被占用"
    st_set ".rl.port = ${_p}"
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print; ui_ok "Reality 端口已修改: ${_p}"
}

_rl_chg_sni() {
    ui_ask "新伪装 SNI (如 www.microsoft.com):" _s
    [ -z "${_s:-}" ] && { ui_err "SNI 不能为空"; return 1; }
    st_set ".rl.sni = \"${_s}\""
    _cfg_build && svc_restart_xray || return 1
    nodes_build; nodes_print; ui_ok "SNI 已修改: ${_s}"
}

_rl_uninstall() {
    st_set '.rl.enabled = false'
    _cfg_build && svc_restart_xray || return 1
    # Strip Reality lines from node file
    if [ -f "$NODE_FILE" ]; then
        local tmp; tmp=$(mktemp "${NODE_FILE}.XXXXXX") || return 0
        grep -v '#Reality-' "$NODE_FILE" > "$tmp" \
            && mv "$tmp" "$NODE_FILE" \
            || rm -f "$tmp"
    fi
    ui_ok "Reality 已卸载"
}

# ── UUID change ───────────────────────────────────────────────────────────────
cmd_change_uuid() {
    preflight _pf_installed || return
    ui_ask "新 UUID (回车自动生成):" _v
    if [ -z "${_v:-}" ]; then
        _v=$(_uuid_gen)
        ui_info "生成: ${_v}"
    fi
    printf '%s' "$_v" | grep -qiE \
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
        || { ui_err "UUID 格式不合法"; return; }
    txn_begin
    st_set ".uuid = \"${_v}\""
    _cfg_build && svc_restart_xray || { txn_rollback; return 1; }
    txn_commit
    nodes_build; nodes_print
    ui_ok "UUID 已修改: ${_v}"
}

# ── Auto-restart menu ─────────────────────────────────────────────────────────
menu_restart() {
    while true; do
        clear
        printf "\n${_B}${_PUR}  ▸ 自动重启管理${_R}\n"
        printf "  当前间隔: ${_CYN}%s 分钟${_R}  (0 = 关闭)\n\n" "$(st_get .sys.restart_min)"
        printf "  ${_GRN}1${_R}  设置间隔\n"
        printf "  ${_PUR}0${_R}  返回\n\n"
        ui_ask "选择:" _c
        case "${_c:-}" in
            1)
                ui_ask "间隔分钟 (0=关闭，推荐 60):" _v
                case "${_v:-}" in ''|*[!0-9]*) ui_err "无效输入"; ui_pause; continue ;; esac
                st_set ".sys.restart_min = ${_v}"
                _cron_set "$_v" && {
                    [ "$_v" -eq 0 ] \
                        && ui_ok "自动重启已关闭" \
                        || ui_ok "已设置每 ${_v} 分钟重启 xray"
                } || ui_err "cron 配置失败"
                ;;
            0) return ;;
            *) ui_err "无效选项" ;;
        esac
        ui_pause
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# §20 BOOTSTRAP & MAIN
# ══════════════════════════════════════════════════════════════════════════════
_boot_cleanup() {
    [ "$_SP" -ne 0 ] && { kill "$_SP" 2>/dev/null; _SP=0; }
    tput cnorm 2>/dev/null || true
}
_boot_sigint() {
    _boot_cleanup
    printf '\n'; ui_err "已中断"
    exit 130
}

trap '_boot_cleanup' EXIT
trap '_boot_sigint'  INT TERM

main() {
    # ① Hard requirements: must pass before anything else
    preflight _pf_root _pf_systemd || exit 1

    # ② Bootstrap jq (state engine dependency — install if missing)
    command -v jq >/dev/null 2>&1 || {
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null 2>&1 \
            || ui_die "jq 安装失败，无法继续"
        ui_ok "jq 已自动安装"
    }

    # ③ Initialize state file on first run (idempotent)
    st_init

    # ④ Enter interactive menu loop
    menu_main
}

main "$@"
