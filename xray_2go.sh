#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo（可选）：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   Reality（可选）：VLESS+TCP+TLS（VLESS Reality）
#   免流（可选）：VLESS+WS 明文（port 80）| VLESS+HTTPUpgrade（port 80）
#   Shadowsocks（可选）：SS+TCP/UDP
# ============================================================

# ── 颜色输出 ─────────────────────────────────────────────────
red()    { printf '\033[1;91m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$*"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$*"; }
gray()   { printf '\033[0;90m%s\033[0m\n' "$*"; }
reading(){ printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ─────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
reality_mode_conf="${work_dir}/reality_mode.conf"
reality_conf="${work_dir}/reality.conf"
reality_keys_conf="${work_dir}/reality_keys.conf"
ss_conf="${work_dir}/ss.conf"
shortcut_path="/usr/local/bin/s"
shortcut_path_upper="/usr/local/bin/S"

# ── 环境变量（可外部注入） ────────────────────────────────────
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ============================================================
# 基础工具函数
# ============================================================

gen_uuid()  { cat /proc/sys/kernel/random/uuid; }
is_alpine() { [ -f /etc/alpine-release ]; }

valid_port() {
    local p="$1"
    echo "${p}" | grep -qE '^[0-9]+$' || return 1
    [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ]
}

load_conf() { sed -n "${2}p" "$1" 2>/dev/null; }

service_cmd() {
    local action="$1" svc="$2"
    if is_alpine; then
        case "${action}" in
            enable)  rc-update add "${svc}" default 2>/dev/null ;;
            disable) rc-update del "${svc}" default 2>/dev/null ;;
            *)       rc-service "${svc}" "${action}" 2>/dev/null ;;
        esac
    else
        systemctl "${action}" "${svc}" 2>/dev/null
    fi
}

service_is_active() {
    if is_alpine; then
        rc-service "$1" status 2>/dev/null | grep -q "started"
    else
        [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]
    fi
}

press_enter() {
    printf '\033[1;91m按回车键继续...\033[0m'
    read -r _dummy
}

# ============================================================
# 配置读取 / 写入
# ============================================================

_load_argo_mode() {
    local v; v=$(cat "${argo_mode_conf}" 2>/dev/null)
    case "${v}" in yes|no) echo "${v}" ;; *) echo "yes" ;; esac
}

_load_reality_mode() {
    local v; v=$(cat "${reality_mode_conf}" 2>/dev/null)
    case "${v}" in yes|no) echo "${v}" ;; *) echo "no" ;; esac
}

_load_freeflow_conf() {
    local mode path
    mode=$(load_conf "${freeflow_conf}" 1)
    path=$(load_conf "${freeflow_conf}" 2)
    case "${mode}" in ws|httpupgrade) ;; *) mode="none" ;; esac
    [ -z "${path}" ] && path="/"
    echo "${mode}"; echo "${path}"
}

_load_reality_conf() {
    local sni port
    sni=$(load_conf "${reality_conf}" 1)
    port=$(load_conf "${reality_conf}" 2)
    [ -z "${sni}" ] && sni="www.cloudflare.com"
    valid_port "${port}" || port="443"
    echo "${sni}"; echo "${port}"
}

_load_ss_conf() {
    local mode port password method
    mode=$(load_conf "${ss_conf}" 1); port=$(load_conf "${ss_conf}" 2)
    password=$(load_conf "${ss_conf}" 3); method=$(load_conf "${ss_conf}" 4)
    case "${mode}" in yes|no) ;; *) mode="no" ;; esac
    valid_port "${port}" || port="8388"
    [ -z "${method}" ] && method="aes-256-gcm"
    echo "${mode}"; echo "${port}"; echo "${password}"; echo "${method}"
}

_save_argo_mode()     { mkdir -p "${work_dir}"; echo "${ARGO_MODE}"    > "${argo_mode_conf}"; }
_save_reality_mode()  { mkdir -p "${work_dir}"; echo "${REALITY_MODE}" > "${reality_mode_conf}"; }
_save_reality_conf()  { mkdir -p "${work_dir}"; printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"; }
_save_freeflow_conf() { mkdir -p "${work_dir}"; printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"; }
_save_ss_conf()       { mkdir -p "${work_dir}"; printf '%s\n%s\n%s\n%s\n' "${SS_MODE}" "${SS_PORT}" "${SS_PASSWORD}" "${SS_METHOD}" > "${ss_conf}"; }

# ── 初始化全局状态变量 ────────────────────────────────────────
_init_globals() {
    ARGO_MODE=$(_load_argo_mode)
    REALITY_MODE=$(_load_reality_mode)
    { read -r REALITY_SNI; read -r REALITY_PORT; } <<< "$(_load_reality_conf)"
    { read -r _ff_mode;    read -r FF_PATH;      } <<< "$(_load_freeflow_conf)"
    FREEFLOW_MODE="${_ff_mode}"; unset _ff_mode
    { read -r SS_MODE; read -r SS_PORT; read -r SS_PASSWORD; read -r SS_METHOD; } <<< "$(_load_ss_conf)"

    # UUID 从已有 config.json 读取，保持重启后一致
    UUID=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' \
        "${config_dir}" 2>/dev/null)
    [ -z "${UUID}" ] || [ "${UUID}" = "null" ] && UUID=$(gen_uuid)
    export UUID

    # 从 config.json 同步实际 ARGO_PORT
    if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
        local _port
        _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
        valid_port "${_port}" && export ARGO_PORT="${_port}"
    fi
}

_init_globals

# ============================================================
# 状态检测
# ============================================================
check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && echo "not installed" && return 2
    service_is_active xray && { echo "running"; return 0; } || { echo "not running"; return 1; }
}

check_argo() {
    [ "${ARGO_MODE}" = "no" ] && echo "disabled" && return 3
    [ ! -f "${work_dir}/argo" ] && echo "not installed" && return 2
    service_is_active tunnel && { echo "running"; return 0; } || { echo "not running"; return 1; }
}

_status_line() {
    local label="$1" val="$2"
    printf ' %-10s: ' "${label}"
    case "${val}" in
        running)         printf '\033[1;32m● running\033[0m\n' ;;
        "not running")   printf '\033[1;91m● not running\033[0m\n' ;;
        "not installed") printf '\033[1;33m○ not installed\033[0m\n' ;;
        disabled|未启用)  printf '\033[0;90m- 未启用\033[0m\n' ;;
        *)               printf '\033[0;90m%s\033[0m\n' "${val}" ;;
    esac
}

# ============================================================
# manage_packages
# ============================================================
manage_packages() {
    [ "$#" -lt 2 ] && red "未指定包名或操作" && return 1
    local action="$1"; shift
    [ "${action}" != "install" ] && red "未知操作: ${action}" && return 1
    local pm=""
    if   command -v apt > /dev/null 2>&1; then pm="apt"
    elif command -v dnf > /dev/null 2>&1; then pm="dnf"
    elif command -v yum > /dev/null 2>&1; then pm="yum"
    elif command -v apk > /dev/null 2>&1; then pm="apk"
    else red "未知包管理器，无法安装依赖"; return 1; fi
    for package in "$@"; do
        command -v "${package}" > /dev/null 2>&1 && { green "${package} 已安装，跳过"; continue; }
        yellow "正在安装 ${package}..."
        case "${pm}" in
            apt) DEBIAN_FRONTEND=noninteractive apt install -y "${package}" ;;
            dnf) dnf install -y "${package}" ;;
            yum) yum install -y "${package}" ;;
            apk) apk update && apk add "${package}" ;;
        esac
        command -v "${package}" > /dev/null 2>&1 || { red "${package} 安装失败"; return 1; }
    done
}

# ============================================================
# get_realip
# ============================================================
get_realip() {
    local ip ipv6 org
    ip=$(curl -s --max-time 3 ipv4.ip.sb)
    if [ -z "${ip}" ]; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb)
        [ -n "${ipv6}" ] && echo "[${ipv6}]" || echo ""; return
    fi
    org=$(curl -s --max-time 3 http://ipinfo.io/org 2>/dev/null)
    if echo "${org}" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -s --max-time 3 ipv6.ip.sb)
        [ -n "${ipv6}" ] && echo "[${ipv6}]" || echo "${ip}"
    else
        echo "${ip}"
    fi
}

get_current_uuid() {
    local id
    id=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' \
        "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

# ============================================================
# install_shortcut
# ============================================================
install_shortcut() {
    local script_wrapper="${work_dir}/s.sh"
    cat > "${script_wrapper}" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) "$@"
EOF
    chmod +x "${script_wrapper}"
    ln -sf "${script_wrapper}" "${shortcut_path}"
    ln -sf "${script_wrapper}" "${shortcut_path_upper}"
    [ -s "${shortcut_path}" ] && green "快捷指令 s / S 创建成功" || red "快捷指令创建失败"
}

# ============================================================
# Inbound JSON 构造
# ============================================================
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            printf '{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}\n' \
                "${uuid}" "${FF_PATH}" ;;
        httpupgrade)
            printf '{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":"%s"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}\n' \
                "${uuid}" "${FF_PATH}" ;;
    esac
}

get_reality_inbound_json() {
    local uuid="$1" privkey="$2" shortid="$3"
    printf '{"port":%s,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"%s","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s:%s","serverNames":["%s"],"privateKey":"%s","shortIds":["%s"]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}\n' \
        "${REALITY_PORT}" "${uuid}" "${REALITY_SNI}" "${REALITY_PORT}" "${REALITY_SNI}" "${privkey}" "${shortid}"
}

get_ss_inbound_json() {
    printf '{"port":%s,"listen":"::","protocol":"shadowsocks","settings":{"method":"%s","password":"%s","network":"tcp,udp"},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}\n' \
        "${SS_PORT}" "${SS_METHOD}" "${SS_PASSWORD}"
}

# ============================================================
# Inbound 下标计算（布局：[Argo?][Reality?][FreeFlow?][SS?]）
# ============================================================
calc_reality_index()  { [ "${ARGO_MODE}" = "yes" ] && echo 1 || echo 0; }

calc_freeflow_index() {
    local i=0
    [ "${ARGO_MODE}"    = "yes" ] && i=$((i+1))
    [ "${REALITY_MODE}" = "yes" ] && i=$((i+1))
    echo $i
}

calc_ss_index() {
    local i=0
    [ "${ARGO_MODE}"       = "yes"  ] && i=$((i+1))
    [ "${REALITY_MODE}"    = "yes"  ] && i=$((i+1))
    [ "${FREEFLOW_MODE}"  != "none" ] && i=$((i+1))
    echo $i
}

_jq_set_inbound() {
    local idx="$1" ib_json="$2"
    jq --argjson ib "${ib_json}" --argjson idx "${idx}" '
        (.inbounds | length) as $len |
        if $len > $idx then .inbounds[$idx] = $ib
        else .inbounds = (.inbounds + [range($idx - $len + 1) | {}]) | .inbounds[$idx] = $ib
        end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

_jq_del_inbound() {
    local idx="$1" match="$2"
    jq --argjson idx "${idx}" --arg match "${match}" '
        if (.inbounds | length) > $idx and
           ((.inbounds[$idx].streamSettings.security // "") == $match or
            (.inbounds[$idx].streamSettings.network  // "") == $match or
            (.inbounds[$idx].protocol                // "") == $match)
        then .inbounds = (.inbounds[:$idx] + .inbounds[$idx+1:])
        else .
        end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

# ============================================================
# apply_*_config
# ============================================================
apply_reality_config() {
    local cur_uuid privkey shortid
    cur_uuid=$(get_current_uuid)
    case "${REALITY_MODE}" in
        yes)
            if [ ! -f "${reality_keys_conf}" ]; then
                local key_out pubkey
                key_out=$("${work_dir}/${server_name}" x25519 2>/dev/null)
                privkey=$(echo "${key_out}" | grep -i 'Private key' | awk '{print $NF}')
                pubkey=$(echo "${key_out}"  | grep -i 'Public key'  | awk '{print $NF}')
                shortid=$(openssl rand -hex 8 2>/dev/null || gen_uuid | tr -d '-' | cut -c1-16)
                printf '%s\n%s\n%s\n' "${privkey}" "${pubkey}" "${shortid}" > "${reality_keys_conf}"
            else
                privkey=$(load_conf "${reality_keys_conf}" 1)
                shortid=$(load_conf "${reality_keys_conf}" 3)
            fi
            _jq_set_inbound "$(calc_reality_index)" \
                "$(get_reality_inbound_json "${cur_uuid}" "${privkey}" "${shortid}")"
            ;;
        no) _jq_del_inbound "$(calc_reality_index)" "reality" ;;
    esac
}

apply_freeflow_config() {
    local cur_uuid; cur_uuid=$(get_current_uuid)
    case "${FREEFLOW_MODE}" in
        ws|httpupgrade)
            _jq_set_inbound "$(calc_freeflow_index)" "$(get_freeflow_inbound_json "${cur_uuid}")" ;;
        none)
            local cur_net
            cur_net=$(jq -r --argjson idx "$(calc_freeflow_index)" \
                '.inbounds[$idx].streamSettings.network // ""' "${config_dir}" 2>/dev/null)
            _jq_del_inbound "$(calc_freeflow_index)" "${cur_net:-ws}"
            ;;
    esac
}

apply_ss_config() {
    case "${SS_MODE}" in
        yes) _jq_set_inbound "$(calc_ss_index)" "$(get_ss_inbound_json)" ;;
        no)  _jq_del_inbound "$(calc_ss_index)" "shadowsocks" ;;
    esac
}

# ============================================================
# 下载二进制
# ============================================================
_detect_arch() {
    case "$(uname -m)" in
        x86_64)          ARCH='amd64'; ARCH_ARG='64'        ;;
        x86|i686|i386)   ARCH='386';   ARCH_ARG='32'        ;;
        aarch64|arm64)   ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        armv7l)          ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        s390x)           ARCH='s390x'; ARCH_ARG='s390x'     ;;
        *) red "不支持的架构: $(uname -m)"; return 1 ;;
    esac
}

download_xray() {
    local ARCH ARCH_ARG; _detect_arch || return 1
    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"
    if [ ! -f "${work_dir}/${server_name}" ]; then
        yellow "正在下载 xray..."
        curl -sLo "${work_dir}/${server_name}.zip" \
            "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" \
            || { red "xray 下载失败"; return 1; }
        unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1 \
            || { red "xray 解压失败"; return 1; }
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" \
              "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
        green "xray 下载完成"
    else
        green "xray 二进制已存在，跳过"
    fi
}

download_argo() {
    local ARCH ARCH_ARG; _detect_arch || return 1
    if [ ! -f "${work_dir}/argo" ]; then
        yellow "正在下载 cloudflared..."
        curl -sLo "${work_dir}/argo" \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
            || { red "cloudflared 下载失败"; return 1; }
        chmod +x "${work_dir}/argo"
        green "cloudflared 下载完成"
    else
        green "cloudflared 二进制已存在，跳过"
    fi
}

# ============================================================
# _ensure_base_config - 保证 config.json 存在
# ============================================================
_ensure_base_config() {
    [ -f "${config_dir}" ] && return 0
    mkdir -p "${work_dir}"
    cat > "${config_dir}" << 'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

# ============================================================
# install_xray - 首次完整安装，重建 config
# ============================================================
install_xray() {
    clear; purple "正在安装 Xray-2go，请稍等..."
    manage_packages install jq unzip || return 1
    download_xray || return 1
    [ "${ARGO_MODE}" = "yes" ] && { download_argo || return 1; }

    mkdir -p "${work_dir}"
    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": ${ARGO_PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
    }
  ],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    else
        _ensure_base_config
    fi

    [ "${REALITY_MODE}"  = "yes"  ] && apply_reality_config
    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
    [ "${SS_MODE}"       = "yes"  ] && apply_ss_config
}

# ============================================================
# 服务注册
# ============================================================
_register_services() {
    if command -v systemctl > /dev/null 2>&1; then
        _register_systemd
    elif command -v rc-update > /dev/null 2>&1; then
        _register_openrc
        change_hosts
        service_cmd restart xray
        [ "${ARGO_MODE}" = "yes" ] && service_cmd restart tunnel
    else
        red "不支持的 init 系统"; return 1
    fi
}

_write_tunnel_service_systemd() {
    cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2
StandardOutput=append:${work_dir}/argo.log
StandardError=append:${work_dir}/argo.log
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
}

_write_tunnel_service_openrc() {
    cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
    chmod +x /etc/init.d/tunnel
    rc-update add tunnel default
}

_register_systemd() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
Wants=network-online.target
[Service]
Type=simple
NoNewPrivileges=yes
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
RestartPreventExitStatus=23
[Install]
WantedBy=multi-user.target
EOF
    [ "${ARGO_MODE}" = "yes" ] && _write_tunnel_service_systemd
    if [ -f /etc/centos-release ]; then
        yum install -y chrony && systemctl start chronyd && systemctl enable chronyd
        chronyc -a makestep; yum update -y ca-certificates
    fi
    systemctl daemon-reload
    systemctl enable xray && systemctl start xray
    [ "${ARGO_MODE}" = "yes" ] && systemctl enable tunnel && systemctl start tunnel
}

_register_openrc() {
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray service"
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default
    [ "${ARGO_MODE}" = "yes" ] && _write_tunnel_service_openrc
}

change_hosts() {
    echo "0 0" > /proc/sys/net/ipv4/ping_group_range
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# ============================================================
# restart helpers
# ============================================================
restart_xray() {
    is_alpine && service_cmd restart xray \
              || { systemctl daemon-reload; service_cmd restart xray; }
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    is_alpine && service_cmd restart tunnel \
              || { systemctl daemon-reload; service_cmd restart tunnel; }
}

reset_tunnel_to_temp() {
    if is_alpine; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" \
            /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" \
            /etc/systemd/system/tunnel.service
    fi
}

# ============================================================
# get_argodomain
# ============================================================
get_argodomain() {
    local domain i=1; sleep 3
    while [ "${i}" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' \
            "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "${domain}" ] && echo "${domain}" && return 0
        sleep 2; i=$((i+1))
    done
    echo ""; return 1
}

# ============================================================
# 节点链接构造
# ============================================================
build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_current_uuid)
    path_enc=$(printf '%s' "${FF_PATH}" | sed 's|%|%25|g; s| |%20|g')
    case "${FREEFLOW_MODE}" in
        ws)          echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${path_enc}#FreeFlow-WS" ;;
        httpupgrade) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${path_enc}#FreeFlow-HTTPUpgrade" ;;
    esac
}

build_reality_link() {
    local ip="$1" uuid pubkey shortid
    uuid=$(get_current_uuid)
    pubkey=$(load_conf "${reality_keys_conf}" 2)
    shortid=$(load_conf "${reality_keys_conf}" 3)
    echo "vless://${uuid}@${ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#Reality"
}

build_ss_link() {
    local ip="$1" userinfo
    userinfo=$(printf '%s:%s' "${SS_METHOD}" "${SS_PASSWORD}" | base64 | tr -d '\n')
    echo "ss://${userinfo}@${ip}:${SS_PORT}#SS-${SS_METHOD}"
}

# ============================================================
# url.txt 操作
# ============================================================
_update_url_line() {
    local pattern="$1" new_link="$2" escaped
    grep -q "${pattern}" "${client_dir}" 2>/dev/null || return 0
    escaped=$(printf '%s\n' "${new_link}" | sed 's/[\/&]/\\&/g')
    sed -i "/${pattern}/c\\${escaped}" "${client_dir}"
}

_update_argo_url() {
    grep -q '#Argo$' "${client_dir}" 2>/dev/null || return 0
    sed -i "1s/sni=[^&]*/sni=$1/; 1s/host=[^&]*/host=$1/" "${client_dir}"
}

_update_reality_url()  { _update_url_line 'security=reality' "$(build_reality_link  "$1")"; }
_update_ss_url()       { _update_url_line '^ss://'           "$(build_ss_link "$1")";       }
_update_freeflow_url() { _update_url_line '#FreeFlow'        "$(build_freeflow_link "$1")"; }

# _rebuild_url_txt <IP> - 完整重建 url.txt（保留 Argo 行已有域名）
_rebuild_url_txt() {
    local IP="$1" cur_uuid; cur_uuid=$(get_current_uuid)
    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            if grep -q '#Argo$' "${client_dir}" 2>/dev/null; then
                grep '#Argo$' "${client_dir}"
            else
                echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=<pending>&fp=chrome&type=ws&host=<pending>&path=%2Fvless-argo%3Fed%3D2560#Argo"
            fi
        fi
        [ "${REALITY_MODE}"  = "yes"  ] && [ -n "${IP}" ] && build_reality_link  "${IP}"
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${IP}" ] && build_freeflow_link "${IP}"
        [ "${SS_MODE}"       = "yes"  ] && [ -n "${IP}" ] && build_ss_link        "${IP}"
    } > "${client_dir}"
}

# ============================================================
# get_info - 获取 Argo 域名，重建 url.txt 并打印
# ============================================================
get_info() {
    clear
    local IP; IP=$(get_realip)
    [ -z "${IP}" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"
    local cur_uuid argodomain; cur_uuid=$(get_current_uuid)

    if [ "${ARGO_MODE}" = "yes" ]; then
        purple "正在获取 ArgoDomain，请稍等..."
        restart_argo; argodomain=$(get_argodomain)
        [ -z "${argodomain}" ] && yellow "未能获取 ArgoDomain，可在 Argo 管理中重新获取" \
                                || green "ArgoDomain：${argodomain}"
    fi

    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            local ad="${argodomain:-<未获取到域名>}"
            echo "vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ad}&fp=chrome&type=ws&host=${ad}&path=%2Fvless-argo%3Fed%3D2560#Argo"
        fi
        [ "${REALITY_MODE}"  = "yes"  ] && [ -n "${IP}" ] && build_reality_link  "${IP}"
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "${IP}" ] && build_freeflow_link "${IP}"
        [ "${SS_MODE}"       = "yes"  ] && [ -n "${IP}" ] && build_ss_link        "${IP}"
    } > "${client_dir}"

    print_nodes
}

# ============================================================
# print_nodes
# ============================================================
print_nodes() {
    echo ""
    if [ ! -f "${client_dir}" ] || [ ! -s "${client_dir}" ]; then
        yellow "暂无节点信息，请先完成安装"; return 1
    fi
    skyblue "══════════════════ 节点信息 ══════════════════"
    while IFS= read -r line; do
        [ -n "${line}" ] && printf '\033[1;35m%s\033[0m\n' "${line}"
    done < "${client_dir}"
    skyblue "════════════════════════════════════════════"
    if command -v qrencode > /dev/null 2>&1; then
        echo ""
        while IFS= read -r line; do
            [ -z "${line}" ] && continue
            local label; label=$(echo "${line}" | sed 's/.*#//')
            skyblue "[ ${label} ]"; qrencode -t ANSIUTF8 "${line}"; echo ""
        done < "${client_dir}"
    fi
    echo ""
}

# ============================================================
# get_quick_tunnel
# ============================================================
get_quick_tunnel() {
    yellow "正在重启 Argo 并获取新临时域名..."
    restart_argo
    local argodomain; argodomain=$(get_argodomain)
    if [ -z "${argodomain}" ]; then yellow "未能获取临时域名，请检查网络或稍后重试"; return 1; fi
    green "ArgoDomain：${argodomain}"
    _update_argo_url "${argodomain}"
    print_nodes
}

# ============================================================
# manage_argo
# ============================================================
manage_argo() {
    while true; do
        local argo_status tunnel_type="temp"
        argo_status=$(check_argo)
        if [ "${ARGO_MODE}" = "yes" ]; then
            if is_alpine; then
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/init.d/tunnel 2>/dev/null \
                    && tunnel_type="temp" || tunnel_type="fixed"
            else
                grep -Fq -- "--url http://localhost:${ARGO_PORT}" /etc/systemd/system/tunnel.service 2>/dev/null \
                    && tunnel_type="temp" || tunnel_type="fixed"
            fi
        fi

        clear; echo ""
        purple "── Argo 隧道管理 ─────────────────────────"
        if [ "${ARGO_MODE}" = "yes" ]; then
            printf ' 状态     : '; _status_line "" "${argo_status}"
            skyblue "  回源端口 : ${ARGO_PORT}"
            skyblue "  隧道类型 : $( [ "${tunnel_type}" = "temp" ] && echo "临时隧道" || echo "固定隧道" )"
        else
            gray   "  状态 : 未启用"
        fi
        skyblue "────────────────────────────────────────"

        if [ "${ARGO_MODE}" = "no" ]; then
            green  " 1) 启用 Argo（安装并配置）"
        else
            green  " 1) 启动 Argo 服务"
            green  " 2) 停止 Argo 服务"
            green  " 3) 修改回源端口（当前：${ARGO_PORT}）"
            green  " 4) 配置固定隧道（token/json）"
            green  " 5) 切换回临时隧道"
            green  " 6) 重新获取临时域名"
            red    " 7) 禁用 Argo 并移除节点"
        fi
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────────"
        reading "请输入选择: " choice

        if [ "${ARGO_MODE}" = "no" ]; then
            case "${choice}" in
                1)
                    if [ ! -f "${work_dir}/${server_name}" ]; then
                        yellow "请先在主菜单完成 Xray-2go 基础安装"; press_enter; continue
                    fi
                    manage_packages install jq unzip || { press_enter; continue; }
                    download_argo || { press_enter; continue; }
                    ARGO_MODE="yes"; _save_argo_mode
                    # 在 inbounds 头部插入 Argo inbound
                    local cur_uuid; cur_uuid=$(get_current_uuid)
                    local argo_ib
                    argo_ib=$(printf '{"port":%s,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"%s"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/vless-argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}' \
                        "${ARGO_PORT}" "${cur_uuid}")
                    _ensure_base_config
                    jq --argjson ib "${argo_ib}" '.inbounds = [$ib] + .inbounds' \
                        "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
                    if command -v systemctl > /dev/null 2>&1; then
                        _write_tunnel_service_systemd
                        systemctl daemon-reload && systemctl enable tunnel && systemctl start tunnel
                    else
                        _write_tunnel_service_openrc && service_cmd restart tunnel
                    fi
                    restart_xray
                    green "Argo 已启用，正在获取域名..."
                    local argodomain; argodomain=$(get_argodomain)
                    local ad="${argodomain:-<未获取到域名>}"
                    [ -n "${argodomain}" ] && green "ArgoDomain：${argodomain}" \
                                           || yellow "未能获取 ArgoDomain，可在此菜单重新获取"
                    local argo_line
                    argo_line="vless://${cur_uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ad}&fp=chrome&type=ws&host=${ad}&path=%2Fvless-argo%3Fed%3D2560#Argo"
                    if [ -f "${client_dir}" ]; then
                        { echo "${argo_line}"; cat "${client_dir}"; } > "${client_dir}.new" \
                            && mv "${client_dir}.new" "${client_dir}"
                    else
                        echo "${argo_line}" > "${client_dir}"
                    fi
                    print_nodes
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        else
            case "${choice}" in
                1) service_cmd start tunnel; green "Argo 已启动" ;;
                2) service_cmd stop  tunnel; green "Argo 已停止" ;;
                3)
                    reading "请输入新的回源端口 [回车随机]: " new_port
                    [ -z "${new_port}" ] && new_port=$(shuf -i 2000-65000 -n 1)
                    if ! valid_port "${new_port}"; then red "端口无效"; press_enter; continue; fi
                    jq --argjson p "${new_port}" '.inbounds[0].port = $p' "${config_dir}" \
                        > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
                    if is_alpine; then
                        sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" /etc/init.d/tunnel
                    else
                        sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" \
                            /etc/systemd/system/tunnel.service
                    fi
                    export ARGO_PORT="${new_port}"
                    restart_xray && restart_argo
                    green "回源端口已修改为：${new_port}"
                    ;;
                4)
                    yellow "固定隧道回源端口为 ${ARGO_PORT}，请在 CF 后台配置对应 ingress"
                    reading "请输入你的 Argo 域名: " argo_domain
                    [ -z "${argo_domain}" ] && red "域名不能为空" && press_enter && continue
                    reading "请输入 Argo 密钥（token 或 json）: " argo_auth
                    local exec_str
                    if echo "${argo_auth}" | grep -q "TunnelSecret"; then
                        local tunnel_id
                        tunnel_id=$(echo "${argo_auth}" | cut -d'"' -f12)
                        echo "${argo_auth}" > "${work_dir}/tunnel.json"
                        cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2
ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                        exec_str="/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1"
                    elif echo "${argo_auth}" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
                        exec_str="/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1"
                    else
                        yellow "token 或 json 格式不匹配"; press_enter; continue
                    fi
                    if is_alpine; then
                        sed -i "/^command_args=/c\command_args=\"-c '${exec_str}'\"" /etc/init.d/tunnel
                    else
                        sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '${exec_str}'" /etc/systemd/system/tunnel.service
                    fi
                    restart_argo
                    _update_argo_url "${argo_domain}"
                    print_nodes; green "固定隧道已配置"
                    ;;
                5)
                    [ "${tunnel_type}" = "temp" ] && { yellow "当前已是临时隧道"; press_enter; continue; }
                    reset_tunnel_to_temp; get_quick_tunnel
                    ;;
                6)
                    [ "${tunnel_type}" = "fixed" ] && { yellow "当前使用固定隧道，无法获取临时域名"; press_enter; continue; }
                    get_quick_tunnel
                    ;;
                7)
                    reading "确定要禁用 Argo 并移除节点吗？(y/n): " yn
                    [ "${yn}" != "y" ] && [ "${yn}" != "Y" ] && continue
                    service_cmd stop tunnel 2>/dev/null; service_cmd disable tunnel 2>/dev/null
                    if is_alpine; then rm -f /etc/init.d/tunnel
                    else rm -f /etc/systemd/system/tunnel.service; systemctl daemon-reload; fi
                    rm -f "${work_dir}/argo" "${work_dir}/argo.log" \
                          "${work_dir}/tunnel.json" "${work_dir}/tunnel.yml"
                    # 移除 inbounds[0]（Argo 入口，listen=127.0.0.1）
                    jq 'if (.inbounds[0].listen // "") == "127.0.0.1" then .inbounds = .inbounds[1:] else . end' \
                        "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
                    ARGO_MODE="no"; _save_argo_mode
                    [ -f "${client_dir}" ] && sed -i '/#Argo$/d' "${client_dir}"
                    restart_xray; green "Argo 已禁用"
                    press_enter; return
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        fi
        press_enter
    done
}

# ============================================================
# manage_reality
# ============================================================
manage_reality() {
    while true; do
        clear; echo ""
        purple "── Reality 管理 ──────────────────────────"
        if [ "${REALITY_MODE}" = "yes" ]; then
            skyblue "  状态 : 已启用"
            skyblue "  SNI  : ${REALITY_SNI}"
            skyblue "  Port : ${REALITY_PORT}"
        else
            gray   "  状态 : 未启用"
        fi
        skyblue "────────────────────────────────────────"
        if [ "${REALITY_MODE}" = "no" ]; then
            green  " 1) 启用 Reality（添加节点）"
        else
            green  " 1) 修改 SNI（当前：${REALITY_SNI}）"
            green  " 2) 修改监听端口（当前：${REALITY_PORT}）"
            red    " 3) 禁用 Reality 并移除节点"
        fi
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────────"
        reading "请输入选择: " choice

        if [ "${REALITY_MODE}" = "no" ]; then
            case "${choice}" in
                1)
                    if [ ! -f "${work_dir}/${server_name}" ]; then
                        yellow "请先在主菜单完成 Xray-2go 基础安装"; press_enter; continue
                    fi
                    reading "请输入 Reality SNI [回车默认 www.cloudflare.com]: " r_sni
                    reading "请输入 Reality 监听端口 [回车默认 443]: " r_port
                    [ -z "${r_sni}" ] && r_sni="www.cloudflare.com"
                    valid_port "${r_port}" || r_port="443"
                    REALITY_SNI="${r_sni}"; REALITY_PORT="${r_port}"; REALITY_MODE="yes"
                    _save_reality_mode; _save_reality_conf
                    rm -f "${reality_keys_conf}"
                    _ensure_base_config; apply_reality_config; restart_xray
                    local IP; IP=$(get_realip); _rebuild_url_txt "${IP}"
                    green "Reality 已启用（SNI=${REALITY_SNI}，Port=${REALITY_PORT}）"
                    print_nodes
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        else
            case "${choice}" in
                1)
                    reading "请输入新的 SNI [回车保持 ${REALITY_SNI}]: " new_sni
                    [ -z "${new_sni}" ] && new_sni="${REALITY_SNI}"
                    REALITY_SNI="${new_sni}"; _save_reality_conf
                    apply_reality_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_reality_url "${IP}"
                    green "SNI 已修改为：${REALITY_SNI}"; print_nodes
                    ;;
                2)
                    reading "请输入新的监听端口 [回车保持 ${REALITY_PORT}]: " new_rp
                    if [ -z "${new_rp}" ]; then new_rp="${REALITY_PORT}"
                    elif ! valid_port "${new_rp}"; then red "端口无效"; press_enter; continue; fi
                    REALITY_PORT="${new_rp}"; _save_reality_conf
                    apply_reality_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_reality_url "${IP}"
                    green "端口已修改为：${REALITY_PORT}"; print_nodes
                    ;;
                3)
                    reading "确定要禁用 Reality 并移除节点吗？(y/n): " yn
                    [ "${yn}" != "y" ] && [ "${yn}" != "Y" ] && continue
                    REALITY_MODE="no"; _save_reality_mode
                    apply_reality_config; restart_xray
                    [ -f "${client_dir}" ] && sed -i '/security=reality/d' "${client_dir}"
                    green "Reality 已禁用"
                    press_enter; return
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        fi
        press_enter
    done
}

# ============================================================
# manage_freeflow
# ============================================================
manage_freeflow() {
    while true; do
        clear; echo ""
        purple "── 免流节点管理 ──────────────────────────"
        if [ "${FREEFLOW_MODE}" != "none" ]; then
            skyblue "  协议 : $( [ "${FREEFLOW_MODE}" = "ws" ] && echo "VLESS+WS" || echo "VLESS+HTTPUpgrade" )"
            skyblue "  Path : ${FF_PATH}"
            skyblue "  端口 : 80（明文）"
        else
            gray   "  状态 : 未启用"
        fi
        skyblue "────────────────────────────────────────"
        if [ "${FREEFLOW_MODE}" = "none" ]; then
            green  " 1) 启用免流节点"
        else
            green  " 1) 切换协议（当前：$( [ "${FREEFLOW_MODE}" = "ws" ] && echo "WS" || echo "HTTPUpgrade" )）"
            green  " 2) 修改 Path（当前：${FF_PATH}）"
            red    " 3) 禁用免流并移除节点"
        fi
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────────"
        reading "请输入选择: " choice

        if [ "${FREEFLOW_MODE}" = "none" ]; then
            case "${choice}" in
                1)
                    if [ ! -f "${work_dir}/${server_name}" ]; then
                        yellow "请先在主菜单完成 Xray-2go 基础安装"; press_enter; continue
                    fi
                    green  " 1) VLESS + WS（明文 WebSocket）"
                    green  " 2) VLESS + HTTPUpgrade"
                    reading "请选择协议 [1-2，回车默认 1]: " ff_c
                    [ "${ff_c}" = "2" ] && FREEFLOW_MODE="httpupgrade" || FREEFLOW_MODE="ws"
                    reading "请输入 Path [回车默认 /]: " ff_p
                    if [ -z "${ff_p}" ]; then FF_PATH="/"
                    else case "${ff_p}" in /*) FF_PATH="${ff_p}" ;; *) FF_PATH="/${ff_p}" ;; esac; fi
                    _save_freeflow_conf; _ensure_base_config
                    apply_freeflow_config; restart_xray
                    local IP; IP=$(get_realip); _rebuild_url_txt "${IP}"
                    green "免流节点已启用（${FREEFLOW_MODE}，path=${FF_PATH}）"
                    print_nodes
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        else
            case "${choice}" in
                1)
                    green " 1) VLESS + WS   2) VLESS + HTTPUpgrade"
                    reading "请选择协议 [1-2]: " ff_c
                    [ "${ff_c}" = "2" ] && FREEFLOW_MODE="httpupgrade" || FREEFLOW_MODE="ws"
                    _save_freeflow_conf; apply_freeflow_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_freeflow_url "${IP}"
                    green "协议已切换为：${FREEFLOW_MODE}"; print_nodes
                    ;;
                2)
                    reading "请输入新的 Path [回车保持 ${FF_PATH}]: " new_path
                    if [ -z "${new_path}" ]; then new_path="${FF_PATH}"
                    else case "${new_path}" in /*) : ;; *) new_path="/${new_path}" ;; esac; fi
                    FF_PATH="${new_path}"; _save_freeflow_conf
                    apply_freeflow_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_freeflow_url "${IP}"
                    green "Path 已修改为：${FF_PATH}"; print_nodes
                    ;;
                3)
                    reading "确定要禁用免流节点吗？(y/n): " yn
                    [ "${yn}" != "y" ] && [ "${yn}" != "Y" ] && continue
                    FREEFLOW_MODE="none"; FF_PATH="/"; _save_freeflow_conf
                    apply_freeflow_config; restart_xray
                    [ -f "${client_dir}" ] && sed -i '/#FreeFlow/d' "${client_dir}"
                    green "免流节点已禁用"
                    press_enter; return
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        fi
        press_enter
    done
}

# ============================================================
# manage_ss
# ============================================================
manage_ss() {
    while true; do
        clear; echo ""
        purple "── Shadowsocks 管理 ──────────────────────"
        if [ "${SS_MODE}" = "yes" ]; then
            skyblue "  Port    : ${SS_PORT}"
            skyblue "  Method  : ${SS_METHOD}"
            skyblue "  Password: ${SS_PASSWORD}"
        else
            gray   "  状态 : 未启用"
        fi
        skyblue "────────────────────────────────────────"
        if [ "${SS_MODE}" = "no" ]; then
            green  " 1) 启用 Shadowsocks（添加节点）"
        else
            green  " 1) 修改端口（当前：${SS_PORT}）"
            green  " 2) 修改密码"
            green  " 3) 修改加密方式（当前：${SS_METHOD}）"
            red    " 4) 禁用 Shadowsocks 并移除节点"
        fi
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────────"
        reading "请输入选择: " choice

        if [ "${SS_MODE}" = "no" ]; then
            case "${choice}" in
                1)
                    if [ ! -f "${work_dir}/${server_name}" ]; then
                        yellow "请先在主菜单完成 Xray-2go 基础安装"; press_enter; continue
                    fi
                    reading "请输入 SS 监听端口 [回车默认 8388]: " ss_p
                    valid_port "${ss_p}" || ss_p="8388"
                    reading "请输入 SS 密码 [回车自动生成]: " ss_pw
                    [ -z "${ss_pw}" ] && ss_pw=$(gen_uuid | tr -d '-' | cut -c1-16)
                    green " 1) aes-256-gcm（推荐）  2) aes-128-gcm  3) chacha20-poly1305  4) xchacha20-poly1305"
                    reading "请选择加密方式 [1-4，回车默认 1]: " ss_m
                    case "${ss_m}" in
                        2) SS_METHOD="aes-128-gcm"        ;;
                        3) SS_METHOD="chacha20-poly1305"  ;;
                        4) SS_METHOD="xchacha20-poly1305" ;;
                        *) SS_METHOD="aes-256-gcm"        ;;
                    esac
                    SS_PORT="${ss_p}"; SS_PASSWORD="${ss_pw}"; SS_MODE="yes"
                    _save_ss_conf; _ensure_base_config
                    apply_ss_config; restart_xray
                    local IP; IP=$(get_realip); _rebuild_url_txt "${IP}"
                    green "Shadowsocks 已启用（Port=${SS_PORT}，Method=${SS_METHOD}）"
                    print_nodes
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        else
            case "${choice}" in
                1)
                    reading "请输入新的端口 [回车保持 ${SS_PORT}]: " new_sp
                    if [ -z "${new_sp}" ]; then new_sp="${SS_PORT}"
                    elif ! valid_port "${new_sp}"; then red "端口无效"; press_enter; continue; fi
                    SS_PORT="${new_sp}"; _save_ss_conf; apply_ss_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_ss_url "${IP}"
                    green "端口已修改为：${SS_PORT}"; print_nodes
                    ;;
                2)
                    reading "请输入新的密码 [回车自动生成]: " new_pw
                    [ -z "${new_pw}" ] && new_pw=$(gen_uuid | tr -d '-' | cut -c1-16)
                    SS_PASSWORD="${new_pw}"; _save_ss_conf; apply_ss_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_ss_url "${IP}"
                    green "密码已修改"; print_nodes
                    ;;
                3)
                    green " 1) aes-256-gcm  2) aes-128-gcm  3) chacha20-poly1305  4) xchacha20-poly1305"
                    reading "请选择 [1-4]: " m_c
                    case "${m_c}" in
                        2) SS_METHOD="aes-128-gcm"        ;;
                        3) SS_METHOD="chacha20-poly1305"  ;;
                        4) SS_METHOD="xchacha20-poly1305" ;;
                        *) SS_METHOD="aes-256-gcm"        ;;
                    esac
                    _save_ss_conf; apply_ss_config; restart_xray
                    local IP; IP=$(get_realip); [ -n "${IP}" ] && _update_ss_url "${IP}"
                    green "加密方式已修改为：${SS_METHOD}"; print_nodes
                    ;;
                4)
                    reading "确定要禁用 Shadowsocks 并移除节点吗？(y/n): " yn
                    [ "${yn}" != "y" ] && [ "${yn}" != "Y" ] && continue
                    SS_MODE="no"; _save_ss_conf; apply_ss_config; restart_xray
                    [ -f "${client_dir}" ] && sed -i '/^ss:\/\//d' "${client_dir}"
                    green "Shadowsocks 已禁用"
                    press_enter; return
                    ;;
                0) return ;;
                *) red "无效的选项" ;;
            esac
        fi
        press_enter
    done
}

# ============================================================
# manage_system - 系统设置（UUID / Xray 服务控制 / 更新）
# ============================================================
manage_system() {
    while true; do
        local xray_status; xray_status=$(check_xray)
        clear; echo ""
        purple "── 系统设置 ──────────────────────────────"
        printf ' Xray 状态 : '; _status_line "" "${xray_status}"
        skyblue "  UUID     : $(get_current_uuid)"
        skyblue "────────────────────────────────────────"
        green  " 1) 修改 UUID（全局替换）"
        green  " 2) 启动 Xray 服务"
        green  " 3) 停止 Xray 服务"
        green  " 4) 重启 Xray 服务"
        green  " 5) 更新 xray 二进制"
        purple " 0) 返回主菜单"
        skyblue "────────────────────────────────────────"
        reading "请输入选择: " choice

        case "${choice}" in
            1)
                reading "请输入新的 UUID [回车自动生成]: " new_uuid
                [ -z "${new_uuid}" ] && new_uuid=$(gen_uuid) && green "生成的 UUID：${new_uuid}"
                [ -f "${config_dir}" ] && \
                    sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/${new_uuid}/g" \
                        "${config_dir}"
                [ -f "${client_dir}" ] && \
                    sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/${new_uuid}/g" \
                        "${client_dir}"
                export UUID="${new_uuid}"; restart_xray
                green "UUID 已修改为：${new_uuid}"; print_nodes
                ;;
            2) service_cmd start xray;  green "Xray 已启动" ;;
            3) service_cmd stop  xray;  green "Xray 已停止" ;;
            4) restart_xray;            green "Xray 已重启" ;;
            5)
                yellow "正在更新 xray 二进制..."
                service_cmd stop xray 2>/dev/null
                rm -f "${work_dir}/${server_name}"
                download_xray && restart_xray && green "xray 更新完成" || red "更新失败"
                ;;
            0) return ;;
            *) red "无效的选项" ;;
        esac
        press_enter
    done
}

# ============================================================
# uninstall_xray
# ============================================================
uninstall_xray() {
    reading "确定要卸载 xray-2go 吗？(y/n) [回车取消]: " choice
    case "${choice}" in y|Y) ;; *) purple "已取消"; return ;; esac
    yellow "正在卸载..."
    service_cmd stop    xray   2>/dev/null; service_cmd disable xray   2>/dev/null
    service_cmd stop    tunnel 2>/dev/null; service_cmd disable tunnel 2>/dev/null
    if is_alpine; then rm -f /etc/init.d/xray /etc/init.d/tunnel
    else rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
         systemctl daemon-reload; fi
    rm -rf "${work_dir}"
    rm -f "${shortcut_path}" "${shortcut_path_upper}" /usr/local/bin/xray2go
    green "Xray-2go 卸载完成"
}

trap 'echo ""; red "已取消操作"; exit 1' INT

# ============================================================
# menu
# ============================================================
menu() {
    while true; do
        local xray_status argo_status cx
        xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)

        local ff_display reality_display ss_display argo_display
        case "${FREEFLOW_MODE}" in
            ws)          ff_display="WS  path=${FF_PATH}" ;;
            httpupgrade) ff_display="HTTPUpgrade  path=${FF_PATH}" ;;
            *)           ff_display="未启用" ;;
        esac
        [ "${ARGO_MODE}"    = "yes" ] && argo_display="${argo_status}" || argo_display="未启用"
        [ "${REALITY_MODE}" = "yes" ] && reality_display="SNI=${REALITY_SNI}  Port=${REALITY_PORT}" \
                                      || reality_display="未启用"
        [ "${SS_MODE}"      = "yes" ] && ss_display="Port=${SS_PORT}  ${SS_METHOD}" \
                                      || ss_display="未启用"

        clear
        printf '\033[1;35m╔══════════════════════════════════════╗\n'
        printf '║        Xray-2go  精简版              ║\n'
        printf '╚══════════════════════════════════════╝\033[0m\n'
        _status_line "Xray"    "${xray_status}"
        _status_line "Argo"    "${argo_display}"
        _status_line "Reality" "${reality_display}"
        _status_line "免流"    "${ff_display}"
        _status_line "SS"      "${ss_display}"
        skyblue "──────────────────────────────────────"
        green  " 1) 安装 Xray-2go（首次/重装）"
        red    " 2) 卸载 Xray-2go"
        skyblue "──────────────────────────────────────"
        green  " 3) Argo 隧道管理"
        green  " 4) Reality 管理"
        green  " 5) 免流节点管理"
        green  " 6) Shadowsocks 管理"
        skyblue "──────────────────────────────────────"
        green  " 7) 查看节点信息"
        green  " 8) 系统设置"
        skyblue "──────────────────────────────────────"
        red    " 0) 退出"
        skyblue "──────────────────────────────────────"
        reading "请输入选择 [0-8]: " choice
        echo ""

        case "${choice}" in
            1)
                if [ "${cx}" -eq 0 ]; then
                    yellow "Xray-2go 当前已在运行"
                    reading "是否重新安装？这将重置 config.json (y/n): " reinstall
                    [ "${reinstall}" != "y" ] && [ "${reinstall}" != "Y" ] && continue
                fi
                echo ""
                green "── 安装配置向导 ──────────────────────────"
                reading " 是否安装 Argo？[1=是（默认）  2=否]: " argo_c
                [ "${argo_c}" = "2" ] && ARGO_MODE="no" || ARGO_MODE="yes"; _save_argo_mode

                reading " 是否安装 Reality？[1=是  2=否（默认）]: " reality_c
                [ "${reality_c}" = "1" ] && REALITY_MODE="yes" || REALITY_MODE="no"; _save_reality_mode
                if [ "${REALITY_MODE}" = "yes" ]; then
                    reading " Reality SNI [回车默认 www.cloudflare.com]: " r_sni
                    reading " Reality 端口 [回车默认 443]: " r_port
                    [ -z "${r_sni}" ] && r_sni="www.cloudflare.com"
                    valid_port "${r_port}" || r_port="443"
                    REALITY_SNI="${r_sni}"; REALITY_PORT="${r_port}"
                    _save_reality_conf; rm -f "${reality_keys_conf}"
                fi

                reading " 免流方式 [1=WS  2=HTTPUpgrade  3=不安装（默认）]: " ff_c
                case "${ff_c}" in 1) FREEFLOW_MODE="ws" ;; 2) FREEFLOW_MODE="httpupgrade" ;; *) FREEFLOW_MODE="none" ;; esac
                if [ "${FREEFLOW_MODE}" != "none" ]; then
                    reading " 免流 Path [回车默认 /]: " ff_p
                    if [ -z "${ff_p}" ]; then FF_PATH="/"
                    else case "${ff_p}" in /*) FF_PATH="${ff_p}" ;; *) FF_PATH="/${ff_p}" ;; esac; fi
                fi
                _save_freeflow_conf

                reading " 是否安装 Shadowsocks？[1=是  2=否（默认）]: " ss_c
                [ "${ss_c}" = "1" ] && SS_MODE="yes" || SS_MODE="no"
                if [ "${SS_MODE}" = "yes" ]; then
                    reading " SS 端口 [回车默认 8388]: " ss_p
                    valid_port "${ss_p}" || ss_p="8388"
                    reading " SS 密码 [回车自动生成]: " ss_pw
                    [ -z "${ss_pw}" ] && ss_pw=$(gen_uuid | tr -d '-' | cut -c1-16)
                    SS_PORT="${ss_p}"; SS_PASSWORD="${ss_pw}"; SS_METHOD="aes-256-gcm"
                fi
                _save_ss_conf

                echo ""
                install_xray    || { press_enter; continue; }
                _register_services || { press_enter; continue; }
                get_info
                install_shortcut
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_freeflow ;;
            6) manage_ss ;;
            7)
                if [ "${cx}" -eq 2 ]; then yellow "Xray-2go 尚未安装"
                else print_nodes; fi
                ;;
            8) manage_system ;;
            0) exit 0 ;;
            *) red "无效的选项，请输入 0 到 8" ;;
        esac
        press_enter
    done
}

[ ! -f "${shortcut_path}" ] && install_shortcut 2>/dev/null || true

menu
