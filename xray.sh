#!/bin/bash

# ============================================================
# Xray-2go 精简版 一键脚本（优化版）
# 协议：
#   Argo：VLESS+WS+TLS（Cloudflare Argo 隧道）
#   FreeFlow：VLESS+WS / VLESS+HTTPUpgrade（port 80，支持自定义 Path）
# ============================================================

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading(){ printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
freeflow_path_conf="${work_dir}/freeflow_path.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请以 root 用户运行" && exit 1

_raw=$(cat "${argo_mode_conf}" 2>/dev/null); case "${_raw}" in yes|no) ARGO_MODE="${_raw}";; *) ARGO_MODE="yes";; esac
_raw=$(cat "${freeflow_conf}" 2>/dev/null); case "${_raw}" in ws|httpupgrade) FREEFLOW_MODE="${_raw}";; *) FREEFLOW_MODE="none";; esac
FREEFLOW_PATH=$(cat "${freeflow_path_conf}" 2>/dev/null || echo "/")

if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port' "${config_dir}" 2>/dev/null)
    echo "$_port" | grep -qE '^[0-9]+$' && ARGO_PORT=$_port
fi

check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && echo "not installed" && return 2
    if [ -f /etc/alpine-release ]; then
        rc-service xray status 2>/dev/null | grep -q "started" && echo "running" && return 0 || echo "not running" && return 1
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && echo "running" && return 0 || echo "not running" && return 1
    fi
}

check_argo() {
    [ "${ARGO_MODE}" = "no" ] && echo "disabled" && return 3
    [ ! -f "${work_dir}/argo" ] && echo "not installed" && return 2
    if [ -f /etc/alpine-release ]; then
        rc-service tunnel status 2>/dev/null | grep -q "started" && echo "running" && return 0 || echo "not running" && return 1
    else
        [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] && echo "running" && return 0 || echo "not running" && return 1
    fi
}

manage_packages() {
    local action=$1; shift
    [ "$action" != "install" ] && return 1
    for p in "$@"; do
        command -v "$p" >/dev/null && continue
        yellow "安装 ${p}..."
        if command -v apt >/dev/null; then DEBIAN_FRONTEND=noninteractive apt install -y "$p"
        elif command -v dnf >/dev/null; then dnf install -y "$p"
        elif command -v yum >/dev/null; then yum install -y "$p"
        elif command -v apk >/dev/null; then apk update && apk add "$p"
        else red "未知系统"; return 1; fi
    done
}

get_realip() {
    local ip=$(curl -s --max-time 2 ipv4.ip.sb)
    [ -z "$ip" ] && ip=$(curl -s --max-time 2 ipv6.ip.sb) && echo "[$ip]" && return
    curl -s --max-time 3 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei' && ip=$(curl -s --max-time 2 ipv6.ip.sb) && echo "[$ip]" || echo "$ip"
}

get_current_uuid() { jq -r '.inbounds[0].settings.clients[0].id' "${config_dir}"; }

ask_argo_mode() {
    echo ""
    green "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green "1. 安装 Argo（默认）"
    green "2. 不安装 Argo（仅 FreeFlow）"
    skyblue "------------------------------------"
    reading "请输入选择(1-2，回车默认1): " c
    ARGO_MODE=$([ "$c" = 2 ] && echo "no" || echo "yes")
    mkdir -p "${work_dir}"; echo "${ARGO_MODE}" > "${argo_mode_conf}"
    [ "${ARGO_MODE}" = "yes" ] && green "已选择：安装 Argo" || yellow "已选择：不安装 Argo"
    echo ""
}

ask_freeflow_mode() {
    echo ""
    green "请选择 FreeFlow 方式："
    skyblue "-----------------------------"
    green "1. VLESS + WS（默认）"
    green "2. VLESS + HTTPUpgrade"
    green "3. 不安装 FreeFlow"
    skyblue "-----------------------------"
    reading "请输入选择(1-3，回车默认1): " c
    case "$c" in 2) FREEFLOW_MODE="httpupgrade";; 3) FREEFLOW_MODE="none";; *) FREEFLOW_MODE="ws";; esac
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        reading "请输入 Path 路径（回车默认 / ）: " p
        FREEFLOW_PATH="${p:-/}"
    else
        FREEFLOW_PATH="/"
    fi
    mkdir -p "${work_dir}"
    echo "${FREEFLOW_MODE}" > "${freeflow_conf}"
    echo "${FREEFLOW_PATH}" > "${freeflow_path_conf}"
    case "${FREEFLOW_MODE}" in ws) green "已选择：VLESS+WS FreeFlow";; httpupgrade) green "已选择：VLESS+HTTPUpgrade FreeFlow";; none) yellow "不安装 FreeFlow";; esac
    echo ""
}

get_freeflow_inbound_json() {
    local uuid="$1" path="$2"
    case "${FREEFLOW_MODE}" in
        ws)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "${path}" } },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
        httpupgrade)
            cat << EOF
{
  "port": 80, "listen": "::", "protocol": "vless",
  "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
  "streamSettings": { "network": "httpupgrade", "security": "none", "httpupgradeSettings": { "path": "${path}" } },
  "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "metadataOnly": false }
}
EOF
            ;;
    esac
}

apply_freeflow_config() {
    local cur_uuid ff_json
    if [ "${ARGO_MODE}" = "yes" ]; then
        cur_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "${config_dir}")
    else
        cur_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "${config_dir}" 2>/dev/null || echo "${UUID}")
    fi
    case "${FREEFLOW_MODE}" in
        ws|httpupgrade)
            ff_json=$(get_freeflow_inbound_json "${cur_uuid}" "${FREEFLOW_PATH}")
            if [ "${ARGO_MODE}" = "yes" ]; then
                jq --argjson ib "${ff_json}" 'if (.inbounds | length) == 1 then .inbounds += [$ib] else .inbounds[1] = $ib end' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            else
                jq --argjson ib "${ff_json}" '.inbounds = [$ib]' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            fi
            ;;
        none)
            if [ "${ARGO_MODE}" = "yes" ]; then
                jq 'if (.inbounds | length) > 1 then .inbounds = [.inbounds[0]] else . end' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            else
                jq '.inbounds = []' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            fi
            ;;
    esac
}

install_xray() {
    clear
    purple "正在安装 Xray-2go（精简版）..."

    local ARCH_RAW ARCH ARCH_ARG
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in x86_64) ARCH='amd64'; ARCH_ARG='64';; x86|i686|i386) ARCH='386'; ARCH_ARG='32';; aarch64|arm64) ARCH='arm64'; ARCH_ARG='arm64-v8a';; armv7l) ARCH='armv7'; ARCH_ARG='arm32-v7a';; s390x) ARCH='s390x'; ARCH_ARG='s390x';; *) red "不支持的架构: ${ARCH_RAW}"; exit 1;; esac

    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" || { red "xray 下载失败"; exit 1; }
    [ "${ARGO_MODE}" = "yes" ] && curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" || { red "cloudflared 下载失败"; exit 1; }

    unzip -o "${work_dir}/${server_name}.zip" -d "${work_dir}/" >/dev/null 2>&1 || { red "xray 解压失败"; exit 1; }
    [ "${ARGO_MODE}" = "yes" ] && chmod +x "${work_dir}/${server_name}" "${work_dir}/argo" || chmod +x "${work_dir}/${server_name}"
    rm -rf "${work_dir}/${server_name}.zip" "${work_dir}/geosite.dat" "${work_dir}/geoip.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [{
    "port": ${ARGO_PORT}, "listen": "127.0.0.1", "protocol": "vless",
    "settings": { "clients": [{ "id": "${UUID}" }], "decryption": "none" },
    "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "metadataOnly": false }
  }],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ]
}
EOF
    else
        cat > "${config_dir}" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [],
  "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
  "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ]
}
EOF
    fi
    apply_freeflow_config
}

main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    [ "${ARGO_MODE}" = "yes" ] && cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
Type=simple
ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now xray
    [ "${ARGO_MODE}" = "yes" ] && systemctl enable --now tunnel
}

alpine_openrc_services() {
    cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF
    [ "${ARGO_MODE}" = "yes" ] && cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
    chmod +x /etc/init.d/xray ${ARGO_MODE="yes" && echo /etc/init.d/tunnel}
    rc-update add xray default
    [ "${ARGO_MODE}" = "yes" ] && rc-update add tunnel default
}

reset_tunnel_to_temp() {
    if [ -f /etc/alpine-release ]; then
        sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
    else
        sed -i "/^ExecStart=/c\ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2" /etc/systemd/system/tunnel.service
    fi
}

restart_xray() { [ -f /etc/alpine-release ] && rc-service xray restart || systemctl restart xray; }
restart_argo() { rm -f "${work_dir}/argo.log"; [ -f /etc/alpine-release ] && rc-service tunnel restart || systemctl restart tunnel; }

get_argodomain() {
    sleep 3
    local i=1 domain
    while [ $i -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "$domain" ] && echo "$domain" && return 0
        sleep 2; i=$((i+1))
    done
    echo ""
}

print_nodes() {
    echo ""
    [ ! -f "${client_dir}" ] && yellow "节点文件不存在" && return
    while IFS= read -r line; do [ -n "$line" ] && purple "$line"; done < "${client_dir}"
    echo ""
}

build_freeflow_link() {
    local ip="$1" uuid
    uuid=$(get_current_uuid)
    case "${FREEFLOW_MODE}" in
        ws) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${FREEFLOW_PATH}#FreeFlow-WS";;
        httpupgrade) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${FREEFLOW_PATH}#FreeFlow-HTTPUpgrade";;
    esac
}

get_info() {
    clear
    local IP=$(get_realip)
    [ -z "$IP" ] && yellow "警告：无法获取服务器 IP"

    if [ "${ARGO_MODE}" = "yes" ]; then
        local argodomain
        purple "正在获取 ArgoDomain..."
        restart_argo
        argodomain=$(get_argodomain)
        [ -z "$argodomain" ] && argodomain="<未获取到>" || green "ArgoDomain：${argodomain}"
        {
            echo "vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo"
            [ -n "$IP" ] && build_freeflow_link "${IP}"
        } > "${client_dir}"
    else
        { [ -n "$IP" ] && build_freeflow_link "${IP}"; } > "${client_dir}"
    fi
    print_nodes
}

get_quick_tunnel() {
    [ "${ARGO_MODE}" != "yes" ] && yellow "未安装 Argo" && return
    [ ! -f "${client_dir}" ] && yellow "请先安装" && return
    yellow "正在获取新临时域名..."
    restart_argo
    local argodomain=$(get_argodomain)
    [ -z "$argodomain" ] && yellow "获取失败" && return
    green "ArgoDomain：${argodomain}"
    sed -i "1s/sni=[^&]*/sni=${argodomain}/;1s/host=[^&]*/host=${argodomain}/" "${client_dir}"
    print_nodes
}

manage_argo() {
    [ "${ARGO_MODE}" != "yes" ] && yellow "未安装 Argo" && menu && return
    check_argo >/dev/null 2>&1; [ $? -eq 2 ] && yellow "Argo 未安装" && menu && return
    clear; echo ""
    green "1. 启动 Argo"; skyblue "----------------"
    green "2. 停止 Argo"; skyblue "----------------"
    green "3. 添加固定隧道（token/json）"; skyblue "----------------------------------"
    green "4. 切换回临时隧道"; skyblue "-----------------------"
    green "5. 重新获取临时域名"; skyblue "------------------------"
    purple "6. 返回"; skyblue "------------"
    reading "请输入选择: " c
    case "$c" in
        1) [ -f /etc/alpine-release ] && rc-service tunnel start || systemctl start tunnel; green "Argo 已启动";;
        2) [ -f /etc/alpine-release ] && rc-service tunnel stop || systemctl stop tunnel; green "Argo 已停止";;
        3)
            yellow "回源端口为 ${ARGO_PORT}"
            reading "Argo 域名: " d; [ -z "$d" ] && red "域名不能为空" && manage_argo && return
            reading "密钥（token/json）: " a
            if echo "$a" | grep -q "TunnelSecret"; then
                local tid=$(echo "$a" | cut -d'"' -f12)
                echo "$a" > "${work_dir}/tunnel.json"
                cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tid}
credentials-file: ${work_dir}/tunnel.json
protocol: http2
ingress:
  - hostname: ${d}
    service: http://localhost:${ARGO_PORT}
    originRequest: { noTLSVerify: true }
  - service: http_status:404
EOF
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
                else
                    sed -i "/^ExecStart=/c\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --config /etc/xray/tunnel.yml run >> /etc/xray/argo.log 2>&1'" /etc/systemd/system/tunnel.service
                fi
            elif echo "$a" | grep -qE '^[A-Z0-9a-z=]{120,250}$'; then
                if [ -f /etc/alpine-release ]; then
                    sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${a} >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
                else
                    sed -i "/^ExecStart=/c\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${a} >> /etc/xray/argo.log 2>&1'" /etc/systemd/system/tunnel.service
                fi
            else
                yellow "格式错误"; manage_argo; return
            fi
            restart_argo
            [ -f "${client_dir}" ] && sed -i "1s/sni=[^&]*/sni=${d}/;1s/host=[^&]*/host=${d}/" "${client_dir}" && print_nodes
            green "固定隧道已配置"
            ;;
        4) reset_tunnel_to_temp; get_quick_tunnel;;
        5) get_quick_tunnel;;
        6) menu;;
        *) red "无效选项";;
    esac
}

manage_freeflow() {
    clear; echo ""
    green "1. 变更 FreeFlow 方式 & Path"
    green "2. 修改 FreeFlow Path（当前：${FREEFLOW_PATH}）"
    purple "3. 返回"
    skyblue "-----------------------------"
    reading "请输入选择: " c
    case "$c" in
        1)
            local old="${FREEFLOW_MODE}"
            ask_freeflow_mode
            [ "${FREEFLOW_MODE}" = "${old}" ] && yellow "未变更" && manage_freeflow && return
            apply_freeflow_config
            local ip=$(get_realip)
            if [ "${ARGO_MODE}" = "yes" ]; then
                local argo_line=$(head -1 "${client_dir}")
                { echo "${argo_line}"; [ -n "$ip" ] && build_freeflow_link "${ip}"; } > "${client_dir}"
            else
                { [ -n "$ip" ] && build_freeflow_link "${ip}"; } > "${client_dir}"
            fi
            restart_xray
            green "FreeFlow 已变更"
            print_nodes
            ;;
        2)
            [ "${FREEFLOW_MODE}" = "none" ] && yellow "当前无 FreeFlow" && manage_freeflow && return
            reading "新 Path（回车默认 / ）: " p
            FREEFLOW_PATH="${p:-/}"
            echo "${FREEFLOW_PATH}" > "${freeflow_path_conf}"
            apply_freeflow_config
            local ip=$(get_realip)
            if [ "${ARGO_MODE}" = "yes" ]; then
                local argo_line=$(head -1 "${client_dir}")
                { echo "${argo_line}"; [ -n "$ip" ] && build_freeflow_link "${ip}"; } > "${client_dir}"
            else
                { [ -n "$ip" ] && build_freeflow_link "${ip}"; } > "${client_dir}"
            fi
            restart_xray
            green "Path 已修改为 ${FREEFLOW_PATH}"
            print_nodes
            ;;
        3) menu;;
        *) red "无效选项";;
    esac
}

change_config() {
    clear; echo ""
    green "1. 修改 UUID"
    [ "${ARGO_MODE}" = "yes" ] && green "2. 修改 Argo 回源端口（当前：${ARGO_PORT}）"
    purple "0. 返回"
    skyblue "-----------------------------"
    reading "请输入选择: " c
    case "$c" in
        1)
            reading "新 UUID（回车自动生成）: " u
            [ -z "$u" ] && u=$(cat /proc/sys/kernel/random/uuid) && green "生成 UUID：$u"
            sed -i "s/[a-fA-F0-9-]\{36\}/$u/g" "${config_dir}" "${client_dir}" 2>/dev/null
            export UUID=$u
            restart_xray
            green "UUID 已修改"
            print_nodes
            ;;
        2)
            [ "${ARGO_MODE}" != "yes" ] && red "无效" && return
            reading "新端口（回车随机）: " p
            [ -z "$p" ] && p=$(shuf -i 2000-65000 -n 1)
            [ "$p" -lt 1 ] || [ "$p" -gt 65535 ] && red "端口无效" && return
            jq --argjson p "$p" '.inbounds[0].port = $p' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
            if [ -f /etc/alpine-release ]; then
                sed -i "s|http://localhost:[0-9]*|http://localhost:${p}|g" /etc/init.d/tunnel
            else
                sed -i "s|http://localhost:[0-9]*|http://localhost:${p}|g" /etc/systemd/system/tunnel.service
            fi
            ARGO_PORT=$p
            restart_xray && restart_argo
            green "Argo 端口已修改为 ${p}"
            ;;
        0) menu;;
        *) red "无效选项";;
    esac
}

check_nodes() {
    check_xray >/dev/null 2>&1; [ $? -eq 0 ] && print_nodes || { yellow "Xray 未运行"; menu; }
}

uninstall_xray() {
    reading "确定卸载？(y/n): " c
    [ "$c" != y ] && [ "$c" != Y ] && purple "已取消" && return
    yellow "正在卸载..."
    if [ -f /etc/alpine-release ]; then
        rc-service xray stop 2>/dev/null; rc-update del xray default 2>/dev/null; rm -f /etc/init.d/xray
        [ "${ARGO_MODE}" = "yes" ] && rc-service tunnel stop 2>/dev/null; rc-update del tunnel default 2>/dev/null; rm -f /etc/init.d/tunnel
    else
        systemctl stop xray 2>/dev/null; systemctl disable xray 2>/dev/null; rm -f /etc/systemd/system/xray.service
        [ "${ARGO_MODE}" = "yes" ] && systemctl stop tunnel 2>/dev/null; systemctl disable tunnel 2>/dev/null; rm -f /etc/systemd/system/tunnel.service
        systemctl daemon-reload
    fi
    rm -rf "${work_dir}"
    green "Xray-2go 卸载完成"
}

menu() {
    while true; do
        local xray_status=$(check_xray) argo_status=$(check_argo) ff_display
        case "${FREEFLOW_MODE}" in ws) ff_display="WS";; httpupgrade) ff_display="HTTPUpgrade";; none) ff_display="无";; *) ff_display="未知";; esac
        [ "${ARGO_MODE}" = "yes" ] || argo_status="未启用"
        clear; echo ""
        purple "=== Xray-2go 精简版 ==="
        purple " Xray 状态: ${xray_status}"
        purple " Argo 状态: ${argo_status}"
        purple " FreeFlow:  ${ff_display} (${FREEFLOW_PATH})"
        echo "========================"
        green  "1. 安装 / 重装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo   "================="
        green  "3. Argo 管理"
        green  "4. FreeFlow 管理"
        echo   "================="
        green  "5. 查看节点信息"
        green  "6. 修改配置（UUID / Argo端口）"
        echo   "================="
        red    "0. 退出"
        echo   "==========="
        reading "请输入选择(0-6): " c
        case "$c" in
            1)
                check_xray >/dev/null 2>&1; [ $? -eq 0 ] && yellow "已安装" || {
                    ask_argo_mode
                    ask_freeflow_mode
                    manage_packages install jq unzip
                    install_xray
                    if command -v systemctl >/dev/null; then
                        main_systemd_services
                    elif command -v rc-update >/dev/null; then
                        alpine_openrc_services
                        echo "0 0" > /proc/sys/net/ipv4/ping_group_range
                        sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
                        sed -i '2s/.*/::1         localhost/' /etc/hosts
                        rc-service xray restart
                        [ "${ARGO_MODE}" = "yes" ] && rc-service tunnel restart
                    else
                        red "不支持的 init 系统"; exit 1
                    fi
                    # 创建快捷方式 s
                    [ -w /usr/local/bin ] && [ ! -L /usr/local/bin/s ] && ln -sf "$(readlink -f "$0" 2>/dev/null || echo "$0")" /usr/local/bin/s && green "快捷方式 s 已添加（直接输入 s 运行）"
                    get_info
                }
                ;;
            2) uninstall_xray;;
            3) manage_argo;;
            4) manage_freeflow;;
            5) check_nodes;;
            6) change_config;;
            0) exit 0;;
            *) red "无效选项";;
        esac
        printf '\033[1;91m按回车继续...\033[0m'
        read -r _
    done
}

# 首次运行即创建快捷方式
[ -w /usr/local/bin ] && [ ! -L /usr/local/bin/s ] && ln -sf "$(readlink -f "$0" 2>/dev/null || echo "$0")" /usr/local/bin/s 2>/dev/null

menu
