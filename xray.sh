#!/bin/bash

# ============================================================
# 精简版 Xray-2go 一键脚本
# 协议：
#   Argo（可选）：VLESS+WS+TLS 或 VLESS+XHTTP+TLS（同一端口）
#   FreeFlow（可选）：VLESS+WS / HTTPUpgrade / XHTTP（port 80 明文）
# ============================================================

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

server_name="xray"
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
freeflow_conf="${work_dir}/freeflow.conf"
argo_mode_conf="${work_dir}/argo_mode.conf"
restart_conf="${work_dir}/restart.conf"
shortcut_path="/usr/local/bin/s"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export ARGO_PORT=${ARGO_PORT:-'8080'}
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export CFPORT=${CFPORT:-'443'}

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

is_alpine() { [ -f /etc/alpine-release ]; }

service_ctrl() {
    local action="$1" svc="$2"
    if is_alpine; then
        case "$action" in
            enable) rc-update add "$svc" default 2>/dev/null ;;
            disable) rc-update del "$svc" default 2>/dev/null ;;
            *) rc-service "$svc" "$action" 2>/dev/null ;;
        esac
    else
        case "$action" in
            enable) systemctl enable "$svc" 2>/dev/null ;;
            disable) systemctl disable "$svc" 2>/dev/null ;;
            *) systemctl "$action" "$svc" 2>/dev/null ;;
        esac
    fi
}

# 读取配置
_raw=$(cat "${argo_mode_conf}" 2>/dev/null)
case "${_raw}" in yes|no) ARGO_MODE="${_raw}" ;; *) ARGO_MODE="yes" ;; esac

if [ "${ARGO_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
    _port=$(jq -r '.inbounds[0].port // empty' "${config_dir}" 2>/dev/null)
    echo "$_port" | grep -qE '^[0-9]+$' && export ARGO_PORT=$_port
fi

FF_PATH="/"
if [ -f "${freeflow_conf}" ]; then
    _l1=$(sed -n '1p' "${freeflow_conf}" 2>/dev/null)
    _l2=$(sed -n '2p' "${freeflow_conf}" 2>/dev/null)
    case "${_l1}" in ws|httpupgrade|xhttp) FREEFLOW_MODE="${_l1}" ;; *) FREEFLOW_MODE="none" ;; esac
    [ -n "${_l2}" ] && FF_PATH="${_l2}"
else
    FREEFLOW_MODE="none"
fi

RESTART_INTERVAL=0
[ -f "${restart_conf}" ] && _ri=$(cat "${restart_conf}" 2>/dev/null) && echo "${_ri}" | grep -qE '^[0-9]+$' && RESTART_INTERVAL="${_ri}"

check_xray() {
    [ ! -f "${work_dir}/${server_name}" ] && { echo "not installed"; return 2; }
    if is_alpine; then
        rc-service xray status 2>/dev/null | grep -q "started" && { echo "running"; return 0; } || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active xray 2>/dev/null)" = "active" ] && { echo "running"; return 0; } || { echo "not running"; return 1; }
    fi
}

check_argo() {
    [ "${ARGO_MODE}" = "no" ] && { echo "disabled"; return 3; }
    [ ! -f "${work_dir}/argo" ] && { echo "not installed"; return 2; }
    if is_alpine; then
        rc-service tunnel status 2>/dev/null | grep -q "started" && { echo "running"; return 0; } || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active tunnel 2>/dev/null)" = "active" ] && { echo "running"; return 0; } || { echo "not running"; return 1; }
    fi
}

manage_packages() {
    [ "$#" -lt 2 ] && red "未指定包名" && return 1
    local action=$1; shift
    for package in "$@"; do
        command -v "$package" >/dev/null 2>&1 && continue
        yellow "正在安装 ${package}..."
        if command -v apt >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
        elif command -v dnf >/dev/null 2>&1; then dnf install -y "$package"
        elif command -v yum >/dev/null 2>&1; then yum install -y "$package"
        elif command -v apk >/dev/null 2>&1; then apk update && apk add "$package"
        else red "未知系统！"; return 1; fi
    done
}

get_realip() {
    local ip=$(curl -s --max-time 3 ipv4.ip.sb 2>/dev/null)
    [ -z "$ip" ] && { curl -s --max-time 3 ipv6.ip.sb 2>/dev/null | sed 's/.*/[&]/'; return; }
    if curl -s --max-time 3 "https://ipinfo.io/${ip}/org" 2>/dev/null | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        local ipv6=$(curl -s --max-time 3 ipv6.ip.sb 2>/dev/null)
        [ -n "$ipv6" ] && echo "[$ipv6]" || echo "$ip"
    else
        echo "$ip"
    fi
}

get_current_uuid() {
    jq -r '(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) // "'"${UUID}"'"' "${config_dir}" 2>/dev/null
}

_save_freeflow_conf() {
    mkdir -p "${work_dir}"
    printf '%s\n%s\n' "${FREEFLOW_MODE}" "${FF_PATH}" > "${freeflow_conf}"
}

install_shortcut() {
    yellow "正在从 GitHub 拉取最新脚本..."
    curl -sL https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh -o /usr/local/bin/xray2go || {
        red "拉取失败，请检查网络"; return 1
    }
    chmod +x /usr/local/bin/xray2go
    cat > "${shortcut_path}" << 'EOF'
#!/bin/bash
exec /usr/local/bin/xray2go "$@"
EOF
    chmod +x "${shortcut_path}"
    green "快捷方式已创建！输入 s 即可快速启动"
}

ask_argo_mode() {
    echo ""
    green  "是否安装 Cloudflare Argo 隧道？"
    skyblue "------------------------------------"
    green  "1. 安装 Argo（默认）"
    green  "2. 不安装 Argo（仅 FreeFlow）"
    skyblue "------------------------------------"
    reading "请输入选择(1-2，回车默认1): " argo_choice
    case "${argo_choice}" in 2) ARGO_MODE="no";; *) ARGO_MODE="yes";; esac
    mkdir -p "${work_dir}"; echo "${ARGO_MODE}" > "${argo_mode_conf}"
    case "${ARGO_MODE}" in yes) green "已选择：安装 Argo";; no) yellow "已选择：不安装 Argo";; esac
    echo ""
}

ask_argo_protocol() {
    echo ""
    green  "请选择 Argo 协议（同一端口）："
    skyblue "-----------------------------"
    green  "1. WS（支持临时隧道，默认）"
    green  "2. XHTTP（仅支持固定隧道）"
    skyblue "-----------------------------"
    reading "请输入选择(1-2，回车默认1): " p
    [ "$p" = "2" ] && ARGO_PROTO="xhttp" || ARGO_PROTO="ws"
    echo "${ARGO_PROTO}" > "${work_dir}/argo_proto.conf"
}

ask_freeflow_mode() {
    echo ""
    green  "请选择 FreeFlow 方式（port 80 明文）："
    skyblue "-----------------------------"
    green  "1. WS"
    green  "2. HTTPUpgrade"
    green  "3. XHTTP"
    green  "4. 不启用（默认）"
    skyblue "-----------------------------"
    reading "请输入选择(1-4，回车默认4): " ff_choice
    case "${ff_choice}" in
        1) FREEFLOW_MODE="ws" ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        3) FREEFLOW_MODE="xhttp" ;;
        *) FREEFLOW_MODE="none" ;;
    esac
    if [ "${FREEFLOW_MODE}" != "none" ]; then
        reading "请输入 path（回车默认 /）: " ff_path_input
        [ -z "${ff_path_input}" ] && FF_PATH="/" || FF_PATH="/${ff_path_input#/}"
    else
        FF_PATH="/"
    fi
    _save_freeflow_conf
    case "${FREEFLOW_MODE}" in
        ws) green "FreeFlow 已设为 WS（path=${FF_PATH}）" ;;
        httpupgrade) green "FreeFlow 已设为 HTTPUpgrade（path=${FF_PATH}）" ;;
        xhttp) green "FreeFlow 已设为 XHTTP（path=${FF_PATH}）" ;;
        none) yellow "不启用 FreeFlow" ;;
    esac
    echo ""
}

get_freeflow_inbound_json() {
    local uuid="$1"
    case "${FREEFLOW_MODE}" in
        ws)
            cat << EOF
{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"${FF_PATH}"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
            ;;
        httpupgrade)
            cat << EOF
{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"httpupgrade","security":"none","httpupgradeSettings":{"path":"${FF_PATH}"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
            ;;
        xhttp)
            cat << EOF
{"port":80,"listen":"::","protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"${FF_PATH}","mode":"auto"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false}}
EOF
            ;;
    esac
}

calc_freeflow_index() { [ "${ARGO_MODE}" = "yes" ] && echo 1 || echo 0; }

_jq_set_inbound() {
    local idx="$1" ib_json="$2"
    jq --argjson ib "${ib_json}" --argjson idx "${idx}" '
        (.inbounds | length) as $len |
        if $len > $idx then .inbounds[$idx] = $ib
        else .inbounds = (.inbounds + [range($idx - $len + 1) | {}]) | .inbounds[$idx] = $ib end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

_jq_del_inbound() {
    local idx="$1" match="$2"
    jq --argjson idx "${idx}" --arg match "${match}" '
        if (.inbounds | length) > $idx and ((.inbounds[$idx].streamSettings.network // "") == $match or (.inbounds[$idx].protocol // "") == $match)
        then .inbounds = (.inbounds[:$idx] + .inbounds[$idx+1:]) else . end
    ' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
}

apply_freeflow_config() {
    local cur_uuid=$(get_current_uuid)
    [ -z "$cur_uuid" ] && cur_uuid="${UUID}"
    case "${FREEFLOW_MODE}" in
        ws|httpupgrade|xhttp)
            _jq_set_inbound "$(calc_freeflow_index)" "$(get_freeflow_inbound_json "${cur_uuid}")"
            ;;
        none)
            local cur_net=$(jq -r --argjson idx "$(calc_freeflow_index)" '.inbounds[$idx].streamSettings.network // ""' "${config_dir}" 2>/dev/null)
            _jq_del_inbound "$(calc_freeflow_index)" "${cur_net:-ws}"
            ;;
    esac
}

install_xray() {
    clear
    purple "正在安装 Xray-2go..."

    local ARCH_RAW ARCH ARCH_ARG
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        x86_64) ARCH='amd64'; ARCH_ARG='64' ;;
        x86|i686|i386) ARCH='386'; ARCH_ARG='32' ;;
        aarch64|arm64) ARCH='arm64'; ARCH_ARG='arm64-v8a' ;;
        armv7l) ARCH='armv7'; ARCH_ARG='arm32-v7a' ;;
        s390x) ARCH='s390x'; ARCH_ARG='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" && chmod 755 "${work_dir}"

    if [ ! -f "${work_dir}/${server_name}" ]; then
        curl -sLo "${work_dir}/${server_name}.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" || { red "xray 下载失败"; exit 1; }
        unzip -q "${work_dir}/${server_name}.zip" -d "${work_dir}/"
        chmod +x "${work_dir}/${server_name}"
        rm -f "${work_dir}/${server_name}.zip" "${work_dir}"/{geosite.dat,geoip.dat,README.md,LICENSE}
    fi

    if [ "${ARGO_MODE}" = "yes" ] && [ ! -f "${work_dir}/argo" ]; then
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" || { red "cloudflared 下载失败"; exit 1; }
        chmod +x "${work_dir}/argo"
    fi

    cat > "${config_dir}" << EOF
{
  "log": {"access":"/dev/null","error":"/dev/null","loglevel":"none"},
  "inbounds": [{
    "port": ${ARGO_PORT},
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {"clients": [{"id": "${UUID}"}],"decryption": "none"},
    "streamSettings": {"network": "ws","security": "none","wsSettings": {"path": "/vless-argo"}},
    "sniffing": {"enabled": true,"destOverride": ["http","tls","quic"],"metadataOnly": false}
  }],
  "dns": {"servers": ["https+local://8.8.8.8/dns-query"]},
  "outbounds": [{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]
}
EOF

    [ "${FREEFLOW_MODE}" != "none" ] && apply_freeflow_config
}

main_systemd_services() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit] Description=Xray Service After=network.target
[Service] Type=simple ExecStart=${work_dir}/xray run -c ${config_dir} Restart=on-failure
[Install] WantedBy=multi-user.target
EOF

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > /etc/systemd/system/tunnel.service << EOF
[Unit] Description=Cloudflare Tunnel After=network.target
[Service] Type=simple ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 Restart=on-failure RestartSec=5s
[Install] WantedBy=multi-user.target
EOF
    fi

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
    chmod +x /etc/init.d/xray; rc-update add xray default

    if [ "${ARGO_MODE}" = "yes" ]; then
        cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
        chmod +x /etc/init.d/tunnel; rc-update add tunnel default
    fi
}

restart_xray() {
    if is_alpine; then rc-service xray restart; else systemctl restart xray; fi
}

restart_argo() {
    rm -f "${work_dir}/argo.log"
    if is_alpine; then rc-service tunnel restart; else systemctl restart tunnel; fi
}

get_argodomain() {
    sleep 3
    local domain i=1
    while [ "$i" -le 5 ]; do
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -n "$domain" ] && echo "$domain" && return 0
        sleep 2; i=$((i+1))
    done
    echo ""
}

print_nodes() {
    echo ""
    [ ! -f "${client_dir}" ] && { yellow "节点文件不存在"; return 1; }
    while IFS= read -r line; do [ -n "$line" ] && printf '\033[1;35m%s\033[0m\n' "$line"; done < "${client_dir}"
    echo ""
}

build_freeflow_link() {
    local ip="$1" uuid path_enc
    uuid=$(get_current_uuid)
    path_enc=$(printf '%s' "${FF_PATH}" | sed 's/%/%25/g; s/ /%20/g')
    case "${FREEFLOW_MODE}" in
        ws) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=ws&host=${ip}&path=${path_enc}#FreeFlow-WS" ;;
        httpupgrade) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=httpupgrade&host=${ip}&path=${path_enc}#FreeFlow-HTTPUpgrade" ;;
        xhttp) echo "vless://${uuid}@${ip}:80?encryption=none&security=none&type=xhttp&host=${ip}&path=${path_enc}#FreeFlow-XHTTP" ;;
    esac
}

get_info() {
    clear
    local IP=$(get_realip)
    [ -z "$IP" ] && yellow "无法获取服务器 IP"

    {
        if [ "${ARGO_MODE}" = "yes" ]; then
            local proto="ws"
            [ -f "${work_dir}/argo_proto.conf" ] && proto=$(cat "${work_dir}/argo_proto.conf")
            if [ "${proto}" = "xhttp" ]; then
                yellow "当前使用 XHTTP 协议，仅支持固定隧道（临时隧道不可用）" >&2
            else
                purple "正在获取临时 ArgoDomain..." >&2
                restart_argo
                local domain=$(get_argodomain)
                [ -z "$domain" ] && domain="<未获取到域名>"
                echo "vless://$(get_current_uuid)@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${domain}&fp=chrome&type=ws&host=${domain}&path=%2Fvless-argo%3Fed%3D2560#Argo-WS"
            fi
        fi
        [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ] && build_freeflow_link "${IP}"
    } > "${client_dir}"

    print_nodes
}

manage_argo() {
    if [ "${ARGO_MODE}" != "yes" ]; then yellow "未安装 Argo"; sleep 1; menu; return; fi
    clear; echo ""
    green  "1. 启动 Argo 服务"
    green  "2. 停止 Argo 服务"
    green  "3. 切换 Argo 协议（WS ↔ XHTTP）"
    green  "4. 添加/更新固定隧道"
    green  "5. 重新获取临时域名（仅 WS 有效）"
    green  "6. 修改回源端口（当前：${ARGO_PORT}）"
    purple "0. 返回主菜单"
    reading "请输入选择: " choice

    case "${choice}" in
        1) service_ctrl start tunnel; green "Argo 已启动" ;;
        2) service_ctrl stop tunnel; green "Argo 已停止" ;;
        3)
            local old=$( [ -f "${work_dir}/argo_proto.conf" ] && cat "${work_dir}/argo_proto.conf" || echo "ws" )
            ask_argo_protocol
            local new=$(cat "${work_dir}/argo_proto.conf")
            [ "${new}" = "xhttp" ] && [ "${old}" = "ws" ] && yellow "注意：XHTTP 模式不支持临时隧道"
            restart_xray
            green "Argo 协议已切换为 ${new}"
            ;;
        4)
            yellow "固定隧道回源端口为 ${ARGO_PORT}"
            reading "请输入你的 Argo 域名: " argo_domain
            [ -z "$argo_domain" ] && { red "域名不能为空"; return; }
            reading "请输入 Argo 密钥（token 或 json）: " argo_auth
            if echo "$argo_auth" | grep -qE '^[A-Za-z0-9=_-]{120,250}$'; then
                if is_alpine; then
                    sed -i "s|--url http://localhost:${ARGO_PORT}|--token ${argo_auth} --url http://localhost:${ARGO_PORT}|" /etc/init.d/tunnel 2>/dev/null
                else
                    sed -i "s|--url http://localhost:${ARGO_PORT}|--token ${argo_auth} --url http://localhost:${ARGO_PORT}|" /etc/systemd/system/tunnel.service
                fi
                restart_argo
                echo "$argo_domain" > "${work_dir}/domain.txt"
                green "固定隧道已配置，域名：${argo_domain}"
            else
                yellow "密钥格式错误"
            fi
            ;;
        5)
            if [ -f "${work_dir}/argo_proto.conf" ] && [ "$(cat "${work_dir}/argo_proto.conf")" = "xhttp" ]; then
                yellow "XHTTP 模式不支持临时隧道"
            else
                restart_argo
                local domain=$(get_argodomain)
                [ -n "$domain" ] && green "新临时域名：${domain}" || yellow "获取失败"
            fi
            ;;
        6)
            reading "请输入新端口（回车随机）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
            if echo "$new_port" | grep -qE '^[0-9]+$' && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                jq --argjson p "$new_port" '.inbounds[0].port = $p' "${config_dir}" > "${config_dir}.tmp" && mv "${config_dir}.tmp" "${config_dir}"
                export ARGO_PORT=$new_port
                restart_xray && restart_argo
                green "回源端口已修改为：${new_port}"
            else
                red "端口无效"
            fi
            ;;
        0) menu ;;
        *) red "无效选项" ;;
    esac
}

manage_freeflow() {
    if [ "${FREEFLOW_MODE}" = "none" ]; then yellow "未启用 FreeFlow"; sleep 1; menu; return; fi
    clear; echo ""
    green  "FreeFlow 当前：${FREEFLOW_MODE}（path=${FF_PATH}）"
    green  "1. 变更方式"
    green  "2. 修改 path"
    purple "3. 返回"
    reading "选择: " choice
    case "${choice}" in
        1)
            ask_freeflow_mode
            apply_freeflow_config
            restart_xray
            green "FreeFlow 方式已变更"
            ;;
        2)
            reading "新 path（回车保持）: " new_path
            [ -n "${new_path}" ] && {
                case "${new_path}" in /*) ;; *) new_path="/${new_path}" ;; esac
                FF_PATH="${new_path}"
                _save_freeflow_conf
                apply_freeflow_config
                restart_xray
                green "path 已修改为 ${FF_PATH}"
            }
            ;;
        3) menu ;;
        *) red "无效" ;;
    esac
}

manage_restart() {
    clear; echo ""
    green  "当前重启间隔：${RESTART_INTERVAL} 分钟 (0=关闭)"
    green  "1. 设置间隔"
    purple "2. 返回"
    reading "选择: " choice
    case "${choice}" in
        1)
            reading "间隔分钟（0关闭，推荐60）: " new_int
            if echo "${new_int}" | grep -qE '^[0-9]+$' && [ "${new_int}" -ge 0 ]; then
                RESTART_INTERVAL="${new_int}"
                echo "${RESTART_INTERVAL}" > "${restart_conf}"
                if [ "${RESTART_INTERVAL}" -eq 0 ]; then
                    remove_auto_restart
                    green "自动重启已关闭"
                else
                    setup_auto_restart
                fi
            else
                red "输入无效"
            fi
            ;;
        2) menu ;;
    esac
}

# 自动重启函数（简化版）
check_and_install_cron() {
    command -v crontab >/dev/null 2>&1 && return 0
    yellow "cron 未安装"
    reading "是否安装 cron？(y/n，回车 y): " choice
    case "${choice}" in n|N) red "自动重启不可用"; return 1 ;; esac
    yellow "正在安装 cron..."
    if command -v apt >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y cron && systemctl enable --now cron
    elif command -v dnf >/dev/null 2>&1; then dnf install -y cronie && systemctl enable --now crond
    elif command -v yum >/dev/null 2>&1; then yum install -y cronie && systemctl enable --now crond
    elif command -v apk >/dev/null 2>&1; then apk add dcron && rc-service dcron start && rc-update add dcron default
    else red "无法安装 cron"; return 1; fi
    green "cron 已安装"
}

setup_auto_restart() {
    check_and_install_cron || return 1
    local cmd
    if is_alpine; then cmd="rc-service xray restart"; else cmd="systemctl restart xray"; fi
    (crontab -l 2>/dev/null | sed '/xray-restart/d'; echo "*/${RESTART_INTERVAL} * * * * ${cmd} >/dev/null 2>&1 #xray-restart") | crontab -
    green "已设置每 ${RESTART_INTERVAL} 分钟重启 Xray"
}

remove_auto_restart() {
    crontab -l 2>/dev/null | sed '/xray-restart/d' | crontab -
}

uninstall_xray() {
    reading "确定卸载？(y/n): " choice
    [ "${choice}" != "y" ] && [ "${choice}" != "Y" ] && return
    remove_auto_restart
    service_ctrl stop xray; service_ctrl disable xray
    service_ctrl stop tunnel; service_ctrl disable tunnel
    rm -rf "${work_dir}"
    rm -f "${shortcut_path}" /usr/local/bin/xray2go
    green "Xray-2go 卸载完成"
}

menu() {
    while true; do
        local xray_status=$(check_xray)
        local argo_status=$(check_argo)
        local ff_display="${FREEFLOW_MODE}（path=${FF_PATH}）"
        [ "${FREEFLOW_MODE}" = "none" ] && ff_display="未启用"

        clear
        purple "=== Xray-2go 精简版 ==="
        purple " Xray: ${xray_status}"
        purple " Argo: ${argo_status}"
        purple " FreeFlow: ${ff_display}"
        purple " 重启间隔: ${RESTART_INTERVAL} 分钟"
        echo "========================"
        green  "1. 安装 Xray-2go"
        red    "2. 卸载 Xray-2go"
        echo "================="
        green  "3. Argo 管理"
        green  "4. FreeFlow 管理"
        echo "================="
        green  "5. 查看节点信息"
        green  "6. 修改 UUID"
        green  "7. 自动重启管理"
        green  "8. 创建快捷方式 (s)"
        red    "0. 退出"
        reading "选择(0-8): " choice

        case "${choice}" in
            1)
                ask_argo_mode
                ask_argo_protocol
                ask_freeflow_mode
                manage_packages install jq unzip
                install_xray
                if command -v systemctl >/dev/null 2>&1; then
                    main_systemd_services
                else
                    alpine_openrc_services
                    [ -f /etc/alpine-release ] && change_hosts
                    rc-service xray restart
                    [ "${ARGO_MODE}" = "yes" ] && rc-service tunnel restart
                fi
                get_info
                ;;
            2) uninstall_xray ;;
            3) manage_argo ;;
            4) manage_freeflow ;;
            5) [ "$(check_xray)" = "running" ] && print_nodes || { yellow "Xray 未运行"; sleep 1; menu; } ;;
            6)
                reading "新 UUID（回车自动生成）: " new_uuid
                [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
                jq --arg u "$new_uuid" '(.inbounds[] | select(.protocol=="vless") | .settings.clients[0].id) = $u' "${config_dir}" > tmp.json && mv tmp.json "${config_dir}"
                export UUID=$new_uuid
                restart_xray
                green "UUID 已更新为 ${new_uuid}"
                ;;
            7) manage_restart ;;
            8) install_shortcut ;;
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
        printf '\033[1;91m按回车继续...\033[0m'
        read -r _
    done
}

menu
