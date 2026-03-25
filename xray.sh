#!/bin/bash

# ============================================================
# 优化版 Xray-2go 一键脚本 (Refactored)
# 协议支持：
#   Argo：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   Reality：VLESS+TCP+TLS（VLESS Reality）
#   FreeFlow：VLESS+WS (80) | VLESS+HTTPUpgrade (80)
#   Shadowsocks：SS+TCP/UDP
# ============================================================

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ────────────────────────────────────────────────────
server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
reality_mode_conf="${work_dir}/reality_mode.conf"
reality_conf="${work_dir}/reality.conf"
ss_conf="${work_dir}/ss.conf"
shortcut_path="/usr/local/bin/s"

# ── 环境变量 ────────────────────────────────────────────────
export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 状态读取 ────────────────────────────────────────────────
ARGO_MODE=$(cat "${argo_mode_conf}" 2>/dev/null || echo "yes")
[ "${ARGO_MODE}" != "yes" ] && [ "${ARGO_MODE}" != "no" ] && ARGO_MODE="yes"

if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
    echo "$_port" | grep -qE '^[0-9]+$' && export ARGO_PORT=$_port
fi

FREEFLOW_MODE="none"; FF_PATH="/"
if [ -f "${freeflow_conf}" ]; then
    _l1=$(sed -n '1p' "${freeflow_conf}" 2>/dev/null)
    _l2=$(sed -n '2p' "${freeflow_conf}" 2>/dev/null)
    case "${_l1}" in ws|httpupgrade) FREEFLOW_MODE="${_l1}" ;; esac
    [ -n "${_l2}" ] && FF_PATH="${_l2}"
fi

REALITY_MODE=$(cat "${reality_mode_conf}" 2>/dev/null || echo "no")
[ "${REALITY_MODE}" != "yes" ] && [ "${REALITY_MODE}" != "no" ] && REALITY_MODE="no"

REALITY_SNI="www.cloudflare.com"; REALITY_PORT="443"
if [ -f "${reality_conf}" ]; then
    _sni=$(sed -n '1p' "${reality_conf}" 2>/dev/null)
    _rp=$(sed -n '2p' "${reality_conf}" 2>/dev/null)
    [ -n "${_sni}" ] && REALITY_SNI="${_sni}"
    echo "${_rp}" | grep -qE '^[0-9]+$' && REALITY_PORT="${_rp}"
fi

SS_MODE="no"; SS_PORT="8388"; SS_PASSWORD=""; SS_METHOD="aes-256-gcm"
if [ -f "${ss_conf}" ]; then
    _s1=$(sed -n '1p' "${ss_conf}" 2>/dev/null)
    case "${_s1}" in yes|no) SS_MODE="${_s1}" ;; esac
    _s2=$(sed -n '2p' "${ss_conf}" 2>/dev/null)
    echo "${_s2}" | grep -qE '^[0-9]+$' && SS_PORT="${_s2}"
    _s3=$(sed -n '3p' "${ss_conf}" 2>/dev/null)
    [ -n "${_s3}" ] && SS_PASSWORD="${_s3}"
    _s4=$(sed -n '4p' "${ss_conf}" 2>/dev/null)
    [ -n "${_s4}" ] && SS_METHOD="${_s4}"
fi

# ============================================================
# 辅助函数: 检查状态与获取 IP
# ============================================================
check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && { echo "not installed"; return 2; }
    if [ -f /etc/alpine-release ]; then
        rc-service xray status 2>/dev/null | grep -q "started" && { echo "running"; return 0; }
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && { echo "running"; return 0; }
    fi
    echo "not running"; return 1
}

check_argo() {
    [ "${ARGO_MODE}" != "yes" ] && { echo "disabled"; return 3; }
    [ ! -f "${work_dir}/argo" ] && { echo "not installed"; return 2; }
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel status 2>/dev/null | grep -q "started" && { echo "running"; return 0; }
    else
        [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] && { echo "running"; return 0; }
    fi
    echo "not running"; return 1
}

manage_packages() {
    local action=$1; shift
    [ "$action" != "install" ] && return 1
    for package in "$@"; do
        if command -v "$package" > /dev/null 2>&1; then continue; fi
        yellow "正在安装 ${package}..."
        if command -v apt >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf >/dev/null 2>&1; then dnf install -y "$package"
        elif command -v yum >/dev/null 2>&1; then yum install -y "$package"
        elif command -v apk >/dev/null 2>&1; then apk update && apk add "$package"
        fi
    done
}

get_realip() {
    local ip=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -z "$ip" ]; then
        local ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        [ -n "$ipv6" ] && echo "[$ipv6]"; return
    fi
    if curl -s --max-time 3 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        local ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        [ -n "$ipv6" ] && echo "[$ipv6]" || echo "$ip"
    else echo "$ip"; fi
}

get_current_uuid() {
    local id=$(jq -r '(first(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "${config_dir}" 2>/dev/null)
    echo "${id:-${UUID}}"
}

_save_freeflow_conf() {
    mkdir -p "${work_dir}"; printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}
_save_ss_conf() {
    mkdir -p "${work_dir}"; printf '%s\n%s\n%s\n%s\n' "${SS_MODE}" "${SS_PORT}" "${SS_PASSWORD}" "${SS_METHOD}" > "${ss_conf}"
}

# ============================================================
# 交互式参数获取 (单独提取，支持单独加装某个组件)
# ============================================================
ask_argo_mode() {
    echo ""; green "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green "1. 安装 Argo（VLESS+WS+TLS，默认）"
    green "2. 不安装 Argo（仅其它节点）"
    reading "请输入选择(1-2，回车默认1): " c
    [ "$c" = "2" ] && ARGO_MODE="no" || ARGO_MODE="yes"
    mkdir -p "${work_dir}"; echo "${ARGO_MODE}" > "${argo_mode_conf}"
    [ "${ARGO_MODE}" = "yes" ] && green "已选择：安装 Argo" || yellow "已选择：不安装 Argo"
}

prompt_reality_params() {
    reading "请输入 Reality SNI（回车默认 www.cloudflare.com）: " r_sni
    reading "请输入 Reality 监听端口（回车默认 443）: " r_port
    [ -z "${r_sni}" ] && r_sni="www.cloudflare.com"
    if ! echo "${r_port}" | grep -qE '^[0-9]+$' || [ "${r_port}" -lt 1 ] || [ "${r_port}" -gt 65535 ]; then r_port="443"; fi
    REALITY_SNI="${r_sni}"; REALITY_PORT="${r_port}"
    printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"
    green "已选择：安装 Reality（SNI=${REALITY_SNI}，Port=${REALITY_PORT}）"
}
ask_reality_mode() {
    echo ""; green "是否安装 VLESS Reality 节点？"
    skyblue "----------------------------------------"
    green "1. 安装 Reality（VLESS+TCP+TLS）"
    green "2. 不安装 Reality（默认）"
    reading "请输入选择(1-2，回车默认2): " c
    if [ "$c" = "1" ]; then
        REALITY_MODE="yes"; echo "yes" > "${reality_mode_conf}"; prompt_reality_params
    else
        REALITY_MODE="no"; echo "no" > "${reality_mode_conf}"; yellow "已选择：不安装 Reality"
    fi
}

prompt_freeflow_params() {
    reading "请输入 FreeFlow path（回车默认 /）: " ff_path_input
    if [ -z "${ff_path_input}" ]; then FF_PATH="/"
    else case "${ff_path_input}" in /*) FF_PATH="${ff_path_input}" ;; *) FF_PATH="/${ff_path_input}" ;; esac
    fi
    _save_freeflow_conf
    green "已选择：FreeFlow（模式=${FREEFLOW_MODE}，path=${FF_PATH}）"
}
ask_freeflow_mode() {
    echo ""; green "请选择 FreeFlow 方式："
    skyblue "-----------------------------"
    green "1. VLESS + WS  （明文 WebSocket，port 80）"
    green "2. VLESS + HTTPUpgrade （HTTP 升级，port 80）"
    green "3. 不安装 FreeFlow 节点（默认）"
    reading "请输入选择(1-3，回车默认3): " c
    case "$c" in
        1) FREEFLOW_MODE="ws"; prompt_freeflow_params ;;
        2) FREEFLOW_MODE="httpupgrade"; prompt_freeflow_params ;;
        *) FREEFLOW_MODE="none"; _save_freeflow_conf; yellow "不安装 FreeFlow 节点" ;;
    esac
}

prompt_ss_params() {
    reading "请输入 SS 监听端口（回车默认 8388）: " ss_p
    if ! echo "${ss_p}" | grep -qE '^[0-9]+$' || [ "${ss_p}" -lt 1 ] || [ "${ss_p}" -gt 65535 ]; then ss_p="8388"; fi
    reading "请输入 SS 密码（回车自动生成）: " ss_pw
    [ -z "${ss_pw}" ] && ss_pw=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
    echo ""; green "请选择加密方式："
    skyblue "-----------------------------"
    green "1. aes-256-gcm（默认，推荐）"
    green "2. aes-128-gcm"
    green "3. chacha20-poly1305"
    green "4. xchacha20-poly1305"
    reading "请输入选择(1-4，回车默认1): " ss_m
    case "${ss_m}" in
        2) SS_METHOD="aes-128-gcm" ;; 3) SS_METHOD="chacha20-poly1305" ;; 4) SS_METHOD="xchacha20-poly1305" ;; *) SS_METHOD="aes-256-gcm" ;;
    esac
    SS_PORT="${ss_p}"; SS_PASSWORD="${ss_pw}"; _save_ss_conf
    green "已选择：安装 Shadowsocks（Port=${SS_PORT}，Method=${SS_METHOD}）"
}
ask_ss_mode() {
    echo ""; green "是否安装 Shadowsocks 节点？"
    skyblue "--------------------------------------------"
    green "1. 安装 Shadowsocks（SS+TCP/UDP）"
    green "2. 不安装（默认）"
    reading "请输入选择(1-2，回车默认2): " c
    if [ "$c" = "1" ]; then SS_MODE="yes"; prompt_ss_params
    else SS_MODE="no"; _save_ss_conf; yellow "已选择：不安装 Shadowsocks"; fi
}

# ============================================================
# JSON 生成与组装：使用追加模式极大简化复杂度
# ============================================================
get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws) echo "{\"port\": 80, \"listen\": \"::\", \"protocol\": \"vless\", \"settings\": { \"clients\": [{ \"id\": \"${uuid}\" }], \"decryption\": \"none\" }, \"streamSettings\": { \"network\": \"ws\", \"security\": \"none\", \"wsSettings\": { \"path\": \"${FF_PATH}\" } }, \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"], \"metadataOnly\": false }}" ;;
        httpupgrade) echo "{\"port\": 80, \"listen\": \"::\", \"protocol\": \"vless\", \"settings\": { \"clients\": [{ \"id\": \"${uuid}\" }], \"decryption\": \"none\" }, \"streamSettings\": { \"network\": \"httpupgrade\", \"security\": \"none\", \"httpupgradeSettings\": { \"path\": \"${FF_PATH}\" } }, \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"], \"metadataOnly\": false }}" ;;
    esac
}

get_reality_inbound_json() {
    echo "{\"port\": ${REALITY_PORT}, \"listen\": \"::\", \"protocol\": \"vless\", \"settings\": { \"clients\": [{ \"id\": \"$1\", \"flow\": \"xtls-rprx-vision\" }], \"decryption\": \"none\" }, \"streamSettings\": { \"network\": \"tcp\", \"security\": \"reality\", \"realitySettings\": { \"show\": false, \"dest\": \"${REALITY_SNI}:${REALITY_PORT}\", \"serverNames\": [\"${REALITY_SNI}\"], \"privateKey\": \"$2\", \"shortIds\": [\"$3\"] } }, \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"], \"metadataOnly\": false }}"
}

get_ss_inbound_json() {
    echo "{\"port\": ${SS_PORT}, \"listen\": \"::\", \"protocol\": \"shadowsocks\", \"settings\": { \"method\": \"${SS_METHOD}\", \"password\": \"${SS_PASSWORD}\", \"network\": \"tcp,udp\" }, \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"], \"metadataOnly\": false }}"
}

_jq_append_inbound() {
    jq --argjson ib "$1" '.inbounds += [$ib]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

# 核心构建机制：通过清空所有配置然后追加写入来保持 config 干净。
rebuild_all_configs() {
    local cur_uuid=$(get_current_uuid)
    [ -z "$cur_uuid" ] || [ "$cur_uuid" = "null" ] && cur_uuid="${UUID}"

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > "${config_dir}" << EOF
{ "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" }, "inbounds": [ { "port": ${ARGO_PORT}, "listen": "127.0.0.1", "protocol": "vless", "settings": { "clients": [{ "id": "${cur_uuid}" }], "decryption": "none" }, "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } }, "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false } } ], "dns": { "servers": ["https+local://8.8.8.8/dns-query"] }, "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ] }
EOF
    else
        cat > "${config_dir}" << EOF
{ "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" }, "inbounds": [], "dns": { "servers": ["https+local://8.8.8.8/dns-query"] }, "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ] }
EOF
    fi

    if [ "${REALITY_MODE}" = "yes" ]; then
        local keys_file="${work_dir}/reality_keys.conf"
        if [ ! -f "${keys_file}" ]; then
            local key_out=$("${work_dir}/${server_name}" x25519 2>/dev/null)
            local privkey=$(echo "${key_out}" | grep -i 'Private key' | awk '{print $NF}')
            local pubkey_gen=$(echo "${key_out}" | grep -i 'Public key' | awk '{print $NF}')
            local shortid=$(openssl rand -hex 8 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
            printf '%s\n%s\n%s\n' "${privkey}" "${pubkey_gen}" "${shortid}" > "${keys_file}"
        fi
        _jq_append_inbound "$(get_reality_inbound_json "${cur_uuid}" "$(sed -n '1p' "${keys_file}")" "$(sed -n '3p' "${keys_file}")")"
    fi
    [ "${FREEFLOW_MODE}" != "none" ] && _jq_append_inbound "$(get_freeflow_inbound_json "${cur_uuid}")"
    [ "${SS_MODE}" = "yes" ] && _jq_append_inbound "$(get_ss_inbound_json)"

    # 重启使之生效
    if [ -f /etc/alpine-release ]; then rc-service xray restart
    else systemctl daemon-reload && systemctl restart xray; fi
}

# ============================================================
# 节点链接生成及刷新器 (核心功能：自动刷新保证链接完全同步不丢失)
# ============================================================
build_freeflow_link() {
    local ip="$1" uuid=$(get_current_uuid) path_enc=$(printf '%s' "${FF_PATH}" | sed 's|%|%25|g; s| |%20|g')
    case "${FREEFLOW_MODE}" in
        ws) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${path_enc}#FreeFlow-WS" ;;
        httpupgrade) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${path_enc}#FreeFlow-HTTP" ;;
    esac
}
build_reality_link() {
    local keys_file="${work_dir}/reality_keys.conf"
    echo "vless://$(get_current_uuid)@$1:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=$(sed -n '2p' "${keys_file}")&sid=$(sed -n '3p' "${keys_file}")&type=tcp&flow=xtls-rprx-vision#Reality"
}
build_ss_link() {
    echo "ss://$(printf '%s:%s' "${SS_METHOD}" "${SS_PASSWORD}" | base64 | tr -d '\n')@$1:${SS_PORT}#SS-${SS_METHOD}"
}
print_nodes() {
    echo ""; [ ! -f "${client_dir}" ] && { yellow "节点文件不存在！"; return 1; }
    while IFS= read -r line; do [ -n "$line" ] && printf '\033[1;35m%s\033[0m\n' "$line"; done < "${client_dir}"; echo ""
}

get_argodomain() {
    sleep 3; local domain; local i=1
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "$domain" ] && { echo "$domain"; return 0; }
        sleep 2; i=$((i + 1))
    done; echo ""
}
restart_argo() {
    rm -f "${work_dir}/argo.log"
    if [ -f /etc/alpine-release ]; then rc-service tunnel restart
    else systemctl daemon-reload && systemctl restart tunnel; fi
}

refresh_links() {
    local IP=$(get_realip); local argo_domain
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP，依赖 IP 的节点链接将缺失"
    
    # 智能保留 Argo 临时域名
    if [ "${ARGO_MODE}" = "yes" ]; then
        [ -f "${client_dir}" ] && argo_domain=$(grep '#Argo$' "${client_dir}" | sed -n 's/.*sni=\([^&]*\).*/\1/p' | head -1)
        if [ -z "$argo_domain" ] || [ "$argo_domain" = "<未获取到域名>" ]; then
            purple "正在获取 ArgoDomain..." >&2; restart_argo; argo_domain=$(get_argodomain)
            [ -z "$argo_domain" ] && { yellow "获取失败" >&2; argo_domain="<未获取到域名>"; }
        fi
    fi

    {
        [ "${ARGO_MODE}" = "yes" ] && echo "vless://$(get_current_uuid)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argo_domain}&fp=chrome&type=ws&host=${argo_domain}&path=%2Fvless-argo%3Fed%3D2560#Argo"
        [ "${REALITY_MODE}" = "yes" ] && [ -n "$IP" ] && build_reality_link "${IP}"
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ] && build_freeflow_link "${IP}"
        [ "${SS_MODE}" = "yes" ] && [ -n "$IP" ] && build_ss_link "${IP}"
    } > "${client_dir}"
    print_nodes
}

# ============================================================
# 系统服务与二进制模块安装卸载分离
# ============================================================
download_xray_binary() {
    local ARCH=$(uname -m) ARCH_ARG
    case "${ARCH}" in
        'x86_64') ARCH_ARG='64' ;; 'x86'|'i686'|'i386') ARCH_ARG='32' ;;
        'aarch64'|'arm64') ARCH_ARG='arm64-v8a' ;; 'armv7l') ARCH_ARG='arm32-v7a' ;; 's390x') ARCH_ARG='s390x' ;;
        *) red "不支持的架构: ${ARCH}"; exit 1 ;;
    esac
    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"
    if [ ! -f "${work_dir}/${server_name}" ]; then
        curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" || { red "下载失败"; exit 1; }
        unzip "${work_dir}/${server_name}.zip" -d "${work_dir}/" > /dev/null 2>&1
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"
    fi
}
download_argo_if_missing() {
    local ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="amd64" || ARCH="arm64"
    if [ ! -f "${work_dir}/argo" ]; then
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" || { red "cloudflared 下载失败"; exit 1; }
        chmod +x "${work_dir}/argo"
    fi
}
install_xray_service() {
    if command -v systemctl > /dev/null 2>&1; then
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
Type=simple
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        if [ -f /etc/centos-release ]; then yum install -y chrony; systemctl start chronyd && systemctl enable chronyd; chronyc -a makestep; yum update -y ca-certificates; fi
        systemctl daemon-reload; systemctl enable xray && systemctl start xray
    elif command -v rc-update > /dev/null 2>&1; then
        cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray service"
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF
        echo "0 0" > /proc/sys/net/ipv4/ping_group_range
        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
        sed -i '2s/.*/::1         localhost/' /etc/hosts
        chmod +x /etc/init.d/xray; rc-update add xray default; rc-service xray restart
    fi
}
install_argo_service() {
    if command -v systemctl > /dev/null 2>&1; then
        cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
[Service]
Type=simple
TimeoutStartSec=0
ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2
StandardOutput=append:${work_dir}/argo.log
StandardError=append:${work_dir}/argo.log
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable tunnel && systemctl start tunnel
    elif command -v rc-update > /dev/null 2>&1; then
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/tunnel; rc-update add tunnel default; rc-service tunnel restart
    fi
}
remove_argo_service() {
    if command -v systemctl > /dev/null 2>&1; then
        systemctl stop tunnel 2>/dev/null; systemctl disable tunnel 2>/dev/null
        rm -f /etc/systemd/system/tunnel.service; systemctl daemon-reload
    elif command -v rc-update > /dev/null 2>&1; then
        rc-service tunnel stop 2>/dev/null; rc-update del tunnel default 2>/dev/null
        rm -f /etc/init.d/tunnel
    fi
}
uninstall_xray_silent() {
    yellow "正在卸载现有版本..."
    if command -v systemctl > /dev/null 2>&1; then
        systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null
        rm -f /etc/systemd/system/xray.service
        systemctl stop tunnel 2>/dev/null; systemctl disable tunnel 2>/dev/null
        rm -f /etc/systemd/system/tunnel.service; systemctl daemon-reload
    elif command -v rc-update > /dev/null 2>&1; then
        rc-service xray stop 2>/dev/null; rc-update del xray default 2>/dev/null
        rm -f /etc/init.d/xray; rc-service tunnel stop 2>/dev/null
        rc-update del tunnel default 2>/dev/null; rm -f /etc/init.d/tunnel
    fi
    rm -rf "${work_dir}" "${shortcut_path}" /usr/local/bin/xray2go
}
install_shortcut() {
    local wrapper="${work_dir}/s.sh"
    cat > "$wrapper" << 'EOF'
#!/usr/bin/env bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) "$@"
EOF
    chmod +x "$wrapper"; ln -sf "$wrapper" "/usr/local/bin/s"; ln -sf "$wrapper" "/usr/local/bin/S"
    green "快捷指令 s / S 创建成功"
}

install_xray() {
    clear; purple "正在安装 Xray-2go（精简版），请稍等..."
    manage_packages install jq unzip
    download_xray_binary
    [ "${ARGO_MODE}" = "yes" ] && download_argo_if_missing
    rebuild_all_configs
    install_xray_service
    [ "${ARGO_MODE}" = "yes" ] && install_argo_service
}

# ============================================================
# 分模块管理菜单区 (支持未安装时顺滑加装)
# ============================================================
manage_argo() {
    check_xray >/dev/null 2>&1; [ $? -eq 2 ] && { yellow "请先安装 Xray-2go 主程序！"; return; }
    if [ "${ARGO_MODE}" != "yes" ]; then
        reading "未启用 Argo，是否立即加装并启用？(y/n): " c
        case "$c" in y|Y) ARGO_MODE="yes"; echo "yes" > "${argo_mode_conf}"; manage_packages install jq unzip; download_argo_if_missing; rebuild_all_configs; install_argo_service; refresh_links ;; esac
        return
    fi
    clear; echo ""; green "1. 启动 Argo 服务"; green "2. 停止 Argo 服务"; green "3. 重新获取临时域名"; green "4. 切换为固定隧道（token/json）"
    green "5. 切回临时隧道"; green "6. 修改 Argo 回源端口 (当前: ${ARGO_PORT})"; red "7. 关闭并卸载 Argo"
    purple "0. 返回主菜单"; skyblue "------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1) if [ -f /etc/alpine-release ]; then rc-service tunnel start; else systemctl start tunnel; fi; green "Argo 已启动" ;;
        2) if [ -f /etc/alpine-release ]; then rc-service tunnel stop; else systemctl stop tunnel; fi; green "Argo 已停止" ;;
        3) 
            yellow "正在重启获取新域名..."; restart_argo; local argodomain=$(get_argodomain)
            if [ -n "$argodomain" ]; then
                green "新 ArgoDomain：${argodomain}"
                grep -q '#Argo$' "${client_dir}" && sed -i "s/sni=[^&]*/sni=${argodomain}/g; s/host=[^&]*/host=${argodomain}/g" "${client_dir}"
                print_nodes
            else yellow "获取失败，请稍后重试"; fi ;;
        4)
            yellow "注意: 固定隧道需在 CF 后台配置回源端口至 ${ARGO_PORT}"
            reading "输入你的 Argo 域名: " argo_domain; [ -z "$argo_domain" ] && return
            reading "输入 Argo 密钥(token/json): " argo_auth
            if echo "$argo_auth" | grep -q "TunnelSecret"; then
                echo "$argo_auth" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: $(echo "$argo_auth" | cut -d'"' -f12)
credentials-file: ${work_dir}/tunnel.json
protocol: http2
ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
                if [ -f /etc/alpine-release ]; then sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
                else sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'" /etc/systemd/system/tunnel.service; systemctl daemon-reload; fi
            elif echo "$argo_auth" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
                if [ -f /etc/alpine-release ]; then sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
                else sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth} >> /etc/xray/argo.log 2>&1'" /etc/systemd/system/tunnel.service; systemctl daemon-reload; fi
            else yellow "格式不匹配"; return; fi
            restart_argo
            grep -q '#Argo$' "${client_dir}" && sed -i "s/sni=[^&]*/sni=${argo_domain}/g; s/host=[^&]*/host=${argo_domain}/g" "${client_dir}"
            green "固定隧道已配置"
            print_nodes ;;
        5)
            if [ -f /etc/alpine-release ]; then sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
            else sed -i "/^ExecStart=/c\\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" /etc/systemd/system/tunnel.service; systemctl daemon-reload; fi
            green "已恢复临时隧道配置，可利用选项 3 重新获取域名" ;;
        6)
            reading "请输入新回源端口(回车随机): " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            ! echo "$new_port" | grep -qE '^[0-9]+$' && return
            export ARGO_PORT=$new_port
            if [ -f /etc/alpine-release ]; then sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" /etc/init.d/tunnel
            else sed -i "s|http://localhost:[0-9]*|http://localhost:${new_port}|g" /etc/systemd/system/tunnel.service; systemctl daemon-reload; fi
            rebuild_all_configs; restart_argo; green "Argo 端口已修改为: ${new_port}" ;;
        7) ARGO_MODE="no"; echo "no" > "${argo_mode_conf}"; remove_argo_service; rebuild_all_configs; refresh_links; green "Argo 已关闭" ;;
        0) return ;;
    esac
}

manage_reality() {
    check_xray >/dev/null 2>&1; [ $? -eq 2 ] && { yellow "请先安装主程序！"; return; }
    if [ "${REALITY_MODE}" != "yes" ]; then
        reading "未启用 Reality，是否立即加装？(y/n): " c
        case "$c" in y|Y) REALITY_MODE="yes"; echo "yes" > "${reality_mode_conf}"; prompt_reality_params; rebuild_all_configs; refresh_links ;; esac
        return
    fi
    clear; echo ""; green "Reality 当前配置："
    skyblue "  SNI  : ${REALITY_SNI}"
    skyblue "  Port : ${REALITY_PORT}"
    echo "=========================="
    green "1. 修改 SNI"; green "2. 修改监听端口"; red "3. 关闭并卸载 Reality"; purple "0. 返回主菜单"
    reading "请输入选择: " choice
    case "${choice}" in
        1) reading "输入新 SNI: " ns; [ -n "$ns" ] && REALITY_SNI="$ns" && printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"; rebuild_all_configs; refresh_links ;;
        2) reading "输入新端口: " np; echo "$np" | grep -qE '^[0-9]+$' && REALITY_PORT="$np" && printf '%s\n%s\n' "${REALITY_SNI}" "${REALITY_PORT}" > "${reality_conf}"; rebuild_all_configs; refresh_links ;;
        3) REALITY_MODE="no"; echo "no" > "${reality_mode_conf}"; rebuild_all_configs; refresh_links; green "Reality 已关闭" ;;
        0) return ;;
    esac
}

manage_freeflow() {
    check_xray >/dev/null 2>&1; [ $? -eq 2 ] && { yellow "请先安装主程序！"; return; }
    if [ "${FREEFLOW_MODE}" = "none" ]; then
        reading "未启用 FreeFlow，是否立即加装？(y/n): " c
        case "$c" in y|Y) ask_freeflow_mode; rebuild_all_configs; refresh_links ;; esac
        return
    fi
    clear; echo ""; green "FreeFlow 当前配置："
    skyblue "  模式 : ${FREEFLOW_MODE}"
    skyblue "  Path : ${FF_PATH}"
    echo "=========================="
    green "1. 修改协议与 Path (WS/HTTPUpgrade)"; red "2. 关闭并卸载 FreeFlow"; purple "0. 返回主菜单"
    reading "请输入选择: " choice
    case "${choice}" in
        1) ask_freeflow_mode; rebuild_all_configs; refresh_links ;;
        2) FREEFLOW_MODE="none"; _save_freeflow_conf; rebuild_all_configs; refresh_links; green "FreeFlow 已关闭" ;;
        0) return ;;
    esac
}

manage_ss() {
    check_xray >/dev/null 2>&1; [ $? -eq 2 ] && { yellow "请先安装主程序！"; return; }
    if [ "${SS_MODE}" != "yes" ]; then
        reading "未启用 Shadowsocks，是否立即加装？(y/n): " c
        case "$c" in y|Y) SS_MODE="yes"; prompt_ss_params; rebuild_all_configs; refresh_links ;; esac
        return
    fi
    clear; echo ""; green "Shadowsocks 当前配置：(Port: ${SS_PORT})"
    echo "=========================="
    green "1. 修改端口/密码/加密方式"; red "2. 关闭并卸载 Shadowsocks"; purple "0. 返回主菜单"
    reading "请输入选择: " choice
    case "${choice}" in
        1) prompt_ss_params; rebuild_all_configs; refresh_links ;;
        2) SS_MODE="no"; _save_ss_conf; rebuild_all_configs; refresh_links; green "Shadowsocks 已关闭" ;;
        0) return ;;
    esac
}

manage_global_config() {
    clear; echo ""; green "1. 修改全局 UUID"; purple "0. 返回主菜单"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            reading "输入新 UUID (回车自动生成): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            sed -i "s/[a-fA-F0-9]\{8\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{4\}-[a-fA-F0-9]\{12\}/$new_uuid/g" "$config_dir" "$client_dir" 2>/dev/null
            export UUID=$new_uuid
            rebuild_all_configs; refresh_links; green "UUID 已修改" ;;
        0) return ;;
    esac
}

# ============================================================
# 主菜单
# ============================================================
trap 'red "已取消操作"; exit' INT

menu() {
    while true; do
        local cx argo_status ff_display argo_display reality_display ss_display
        local xray_status=$(check_xray); cx=$?
        argo_status=$(check_argo)

        [ "${FREEFLOW_MODE}" = "none" ] && ff_display="未启用" || ff_display="已启用 (${FREEFLOW_MODE})"
        [ "${ARGO_MODE}" = "yes" ] && argo_display="${argo_status}" || argo_display="未启用"
        [ "${REALITY_MODE}" = "yes" ] && reality_display="已启用 (Port:${REALITY_PORT})" || reality_display="未启用"
        [ "${SS_MODE}" = "yes" ] && ss_display="已启用 (${SS_METHOD})" || ss_display="未启用"

        clear; echo ""
        purple "=== Xray-2go 精简版 ==="
        purple " Xray 状态:   ${xray_status}"
        purple " Argo 状态:   ${argo_display}"
        purple " Reality:     ${reality_display}"
        purple " FreeFlow:    ${ff_display}"
        purple " Shadowsocks: ${ss_display}"
        echo   "========================"
        green  "1. 安装 / 重装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "--- 节点与协议管理 ---"
        green  "3. Argo 隧道管理"
        green  "4. Reality 管理"
        green  "5. FreeFlow 管理"
        green  "6. Shadowsocks 管理"
        echo   "--- 系统与配置管理 ---"
        green  "7. 查看最新节点信息"
        green  "8. 修改全局配置 (UUID)"
        echo   "========================"
        red    "0. 退出脚本"
        echo   "========================"
        reading "请输入选择(0-8): " choice
        echo ""

        case "${choice}" in
            1)
                if [ "$cx" -eq 0 ]; then
                    reading "检测到已安装 Xray-2go，是否先卸载再重新安装防出错？(y/n): " c
                    case "$c" in y|Y) uninstall_xray_silent ;; *) continue ;; esac
                fi
                ask_argo_mode; ask_reality_mode; ask_freeflow_mode; ask_ss_mode
                install_xray; refresh_links; install_shortcut
                ;;
            2) reading "确定卸载?(y/n): " c; [ "$c" = "y" ] && { uninstall_xray_silent; green "卸载完成"; } ;;
            3) manage_argo ;;
            4) manage_reality ;;
            5) manage_freeflow ;;
            6) manage_ss ;;
            7) [ "$cx" -eq 2 ] && yellow "请先安装主程序" || print_nodes ;;
            8) [ "$cx" -eq 2 ] && yellow "请先安装主程序" || manage_global_config ;;
            0) exit 0 ;;
            *) red "无效选择" ;;
        esac
        printf '\033[1;91m按回车键继续...\033[0m'
        read -r _dummy
    done
}

[ ! -f "${shortcut_path}" ] && install_shortcut 2>/dev/null || true
menu
