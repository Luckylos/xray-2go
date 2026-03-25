#!/bin/bash

# ============================================================
# 极简高效版 Xray-2go 一键脚本 (支持 Argo / FreeFlow / Reality)
# ============================================================

red()    { printf '\033[1;91m%s\033[0m\n' "$1"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$1"; }
purple() { printf '\033[1;35m%s\033[0m\n' "$1"; }
skyblue(){ printf '\033[1;36m%s\033[0m\n' "$1"; }
reading() { printf '\033[1;91m%s\033[0m' "$1"; read -r "$2"; }

# ── 常量 ────────────────────────────────────────────────────
work_dir="/etc/xray"
config_dir="${work_dir}/config.json"
client_dir="${work_dir}/url.txt"
argo_conf="${work_dir}/argo.conf"
freeflow_conf="${work_dir}/freeflow.conf"
reality_conf="${work_dir}/reality.conf"

export UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
export CFIP="cdns.doon.eu.org"
export CFPORT="443"

[ "$EUID" -ne 0 ] && red "请在 root 用户下运行脚本" && exit 1

# ── 创建快捷键 ──────────────────────────────────────────────
create_shortcut() {
    if [ "$0" != "/usr/local/bin/s" ]; then
        cp -f "$0" /usr/local/bin/s
        chmod +x /usr/local/bin/s
    fi
}
create_shortcut

# ── 状态读取 ────────────────────────────────────────────────
read_states() {
    ARGO_MODE=$(cat "${argo_conf}" 2>/dev/null || echo "no")
    ARGO_PORT=$(jq -r '.inbounds[] | select(.streamSettings.wsSettings.path=="/vless-argo") | .port' "${config_dir}" 2>/dev/null | grep -E '^[0-9]+$' || echo "8080")

    FREEFLOW_MODE=$(cat "${freeflow_conf}" 2>/dev/null || echo "none")
    
    REALITY_MODE=$(cat "${reality_conf}" 2>/dev/null || echo "no")
    if [ "${REALITY_MODE}" = "yes" ] && [ -f "${config_dir}" ]; then
        REALITY_PORT=$(jq -r '.inbounds[] | select(.streamSettings.security=="reality") | .port' "${config_dir}" 2>/dev/null)
        REALITY_SNI=$(jq -r '.inbounds[] | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.serverNames[0]' "${config_dir}" 2>/dev/null)
        REALITY_PBK=$(jq -r '.inbounds[] | select(.streamSettings.security=="reality") | .streamSettings.realitySettings.publicKey' "${config_dir}" 2>/dev/null) # For URL generation only if stored. Actually PBK is not in config, we need PRK.
        
        # 为了生成链接，我们需要将公钥/私钥等持久化。保存在 conf 中。
        source "${reality_conf}" 2>/dev/null
    fi
    
    if [ -f "${config_dir}" ]; then
        CURRENT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "${config_dir}" 2>/dev/null)
        [ "$CURRENT_UUID" != "null" ] && [ -n "$CURRENT_UUID" ] && UUID=$CURRENT_UUID
    fi
}
read_states

# ── 依赖检测与安装 ──────────────────────────────────────────
check_dependencies() {
    local pkgs=""
    for pkg in curl jq unzip; do
        if ! command -v "$pkg" >/dev/null 2>&1; then pkgs="$pkgs $pkg"; fi
    done
    if [ -n "$pkgs" ]; then
        yellow "正在安装缺失依赖: $pkgs"
        if   command -v apt >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt install -y $pkgs
        elif command -v dnf >/dev/null 2>&1; then dnf install -y $pkgs
        elif command -v yum >/dev/null 2>&1; then yum install -y $pkgs
        elif command -v apk >/dev/null 2>&1; then apk update && apk add $pkgs
        else red "未知系统或包管理器！"; exit 1; fi
    fi
}

# ── 获取 IP ────────────────────────────────────────────────
get_realip() {
    local ip ipv6
    ip=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -z "$ip" ]; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb); echo "${ipv6:+[$ipv6]}"; return
    fi
    if curl -s --max-time 3 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb); echo "${ipv6:+[$ipv6]:-$ip}"
    else
        echo "$ip"
    fi
}

# ── 服务控制模块 ───────────────────────────────────────────
service_ctl() {
    local action=$1 target=$2
    if [ -f /etc/alpine-release ]; then
        rc-service "$target" "$action" >/dev/null 2>&1
    else
        systemctl "$action" "$target" >/dev/null 2>&1
    fi
}

check_service() {
    if [ ! -f "${work_dir}/$1" ]; then echo "not installed"; return 2; fi
    if [ -f /etc/alpine-release ]; then
        rc-service "$1" status 2>/dev/null | grep -q "started" && { echo "running"; return 0; } || { echo "not running"; return 1; }
    else
        [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ] && { echo "running"; return 0; } || { echo "not running"; return 1; }
    fi
}

# ── JSON 构造模块 ──────────────────────────────────────────
build_config() {
    local json_content='{
      "log": { "loglevel": "none" },
      "inbounds": [],
      "dns": { "servers": ["https+local://8.8.8.8/dns-query"] },
      "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
      ]
    }'

    if [ "${ARGO_MODE}" = "yes" ]; then
        local argo_ib='{
          "port": '"${ARGO_PORT:-8080}"', "listen": "127.0.0.1", "protocol": "vless",
          "settings": { "clients": [{ "id": "'"${UUID}"'" }], "decryption": "none" },
          "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vless-argo" } },
          "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
        }'
        json_content=$(echo "$json_content" | jq --argjson ib "$argo_ib" '.inbounds += [$ib]')
    fi

    if [ "${FREEFLOW_MODE}" = "ws" ] || [ "${FREEFLOW_MODE}" = "httpupgrade" ]; then
        local ff_ib='{
          "port": 80, "listen": "::", "protocol": "vless",
          "settings": { "clients": [{ "id": "'"${UUID}"'" }], "decryption": "none" },
          "streamSettings": { "network": "'"${FREEFLOW_MODE}"'", "security": "none" },
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
        json_content=$(echo "$json_content" | jq --argjson ib "$ff_ib" '.inbounds += [$ib]')
    fi

    if [ "${REALITY_MODE}" = "yes" ]; then
        local re_ib='{
          "port": '"${REALITY_PORT:-443}"', "listen": "::", "protocol": "vless",
          "settings": { "clients": [{ "id": "'"${UUID}"'", "flow": "xtls-rprx-vision" }], "decryption": "none" },
          "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {
              "show": false, "dest": "'"${REALITY_SNI:-www.cloudflare.com}:443"'", "xver": 0,
              "serverNames": ["'"${REALITY_SNI:-www.cloudflare.com}"'"],
              "privateKey": "'"${REALITY_PRK}"'", "shortIds": ["'"${REALITY_SID}"'"]
            }
          },
          "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
        }'
        json_content=$(echo "$json_content" | jq --argjson ib "$re_ib" '.inbounds += [$ib]')
    fi

    echo "$json_content" > "${config_dir}"
}

# ── 交互式安装配置 ──────────────────────────────────────────
interactive_setup() {
    clear
    purple "=== 协议组合选择 (可多选) ==="
    
    # 1. Argo
    reading "是否安装 Argo 隧道(VLESS+WS+TLS)？[y/N, 默认y]: " c_argo
    case "${c_argo}" in
        n|N) ARGO_MODE="no" ;;
        *)   ARGO_MODE="yes"; ARGO_PORT=8080 ;;
    esac
    
    # 2. FreeFlow
    echo ""
    reading "是否安装 FreeFlow 免流(80端口)? [1=WS, 2=HTTPUpgrade, 0=不安装(默认)]: " c_ff
    case "${c_ff}" in
        1) FREEFLOW_MODE="ws" ;;
        2) FREEFLOW_MODE="httpupgrade" ;;
        *) FREEFLOW_MODE="none" ;;
    esac

    # 3. Reality
    echo ""
    reading "是否安装 VLESS-Reality(TCP+TLS)? [y/N, 默认n]: " c_re
    case "${c_re}" in
        y|Y) 
            REALITY_MODE="yes"
            reading "  -> 输入 Reality 端口 [默认 443]: " REALITY_PORT
            REALITY_PORT=${REALITY_PORT:-443}
            reading "  -> 输入 Reality 伪装域名(SNI) [默认 www.cloudflare.com]: " REALITY_SNI
            REALITY_SNI=${REALITY_SNI:-www.cloudflare.com}
            ;;
        *) REALITY_MODE="no" ;;
    esac

    # 保存状态
    mkdir -p "${work_dir}"
    echo "${ARGO_MODE}" > "${argo_conf}"
    echo "${FREEFLOW_MODE}" > "${freeflow_conf}"
    echo "REALITY_MODE=${REALITY_MODE}" > "${reality_conf}"
}

# ── 核心安装逻辑 ────────────────────────────────────────────
install_core() {
    purple "正在下载并配置组件..."
    local ARCH=$(uname -m) ARCH_ARG ARCH_CF
    case "${ARCH}" in
        'x86_64')            ARCH_ARG='64'; ARCH_CF='amd64' ;;
        'x86'|'i686'|'i386') ARCH_ARG='32'; ARCH_CF='386' ;;
        'aarch64'|'arm64')   ARCH_ARG='arm64-v8a'; ARCH_CF='arm64' ;;
        *) red "不支持的架构: ${ARCH}"; exit 1 ;;
    esac

    curl -sLo "${work_dir}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_ARG}.zip" || exit 1
    unzip -o "${work_dir}/xray.zip" -d "${work_dir}/" > /dev/null 2>&1
    chmod +x "${work_dir}/xray"; rm -f "${work_dir}/xray.zip" "${work_dir}/*.dat" "${work_dir}/README.md" "${work_dir}/LICENSE"

    if [ "${ARGO_MODE}" = "yes" ]; then
        curl -sLo "${work_dir}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CF}" || exit 1
        chmod +x "${work_dir}/argo"
    fi

    # 如果启用了 Reality，自动生成密钥对
    if [ "${REALITY_MODE}" = "yes" ]; then
        local keypair=$(${work_dir}/xray x25519)
        REALITY_PRK=$(echo "$keypair" | grep "Private" | awk '{print $3}')
        REALITY_PBK=$(echo "$keypair" | grep "Public" | awk '{print $3}')
        REALITY_SID=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c1-16)
        cat > "${reality_conf}" << EOF
REALITY_MODE=yes
REALITY_PORT=${REALITY_PORT}
REALITY_SNI=${REALITY_SNI}
REALITY_PRK=${REALITY_PRK}
REALITY_PBK=${REALITY_PBK}
REALITY_SID=${REALITY_SID}
EOF
    fi

    build_config
    setup_services
    get_info
}

# ── 服务注册 (Systemd / OpenRC) ─────────────────────────────
setup_services() {
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray service"
command="/etc/xray/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/var/run/xray.pid"
EOF
        chmod +x /etc/init.d/xray; rc-update add xray default >/dev/null 2>&1
        
        if [ "${ARGO_MODE}" = "yes" ]; then
            cat > /etc/init.d/tunnel << EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/bin/sh"
command_args="-c '/etc/xray/argo tunnel --url http://localhost:${ARGO_PORT:-8080} --no-autoupdate --edge-ip-version auto --protocol http2 >> /etc/xray/argo.log 2>&1'"
command_background=true
pidfile="/var/run/tunnel.pid"
EOF
            chmod +x /etc/init.d/tunnel; rc-update add tunnel default >/dev/null 2>&1
            # change hosts for alpine argo
            echo "0 0" > /proc/sys/net/ipv4/ping_group_range 2>/dev/null
            sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
        fi
    else
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${work_dir}/xray run -c ${config_dir}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl enable xray >/dev/null 2>&1
        
        if [ "${ARGO_MODE}" = "yes" ]; then
            cat > /etc/systemd/system/tunnel.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=${work_dir}/argo tunnel --url http://localhost:${ARGO_PORT:-8080} --no-autoupdate --edge-ip-version auto --protocol http2
StandardOutput=append:${work_dir}/argo.log
StandardError=append:${work_dir}/argo.log
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
            systemctl enable tunnel >/dev/null 2>&1
        fi
        systemctl daemon-reload
    fi
    service_ctl restart xray
    [ "${ARGO_MODE}" = "yes" ] && service_ctl restart tunnel
}

# ── 节点信息生成 ────────────────────────────────────────────
get_info() {
    clear
    local IP=$(get_realip)
    > "${client_dir}" # 清空文件

    echo ""
    if [ "${ARGO_MODE}" = "yes" ]; then
        purple "正在获取 Argo 临时域名..."
        rm -f "${work_dir}/argo.log"
        service_ctl restart tunnel
        sleep 4
        local argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        if [ -n "$argodomain" ]; then
            echo "vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#Argo" >> "${client_dir}"
            green "ArgoDomain: ${argodomain}"
        else
            yellow "未能获取临时域名，请稍后在面板重新获取。"
        fi
    fi

    if [ "${FREEFLOW_MODE}" != "none" ] && [ -n "$IP" ]; then
        echo "vless://${UUID}@${IP}:80?encryption=none&security=none&type=${FREEFLOW_MODE}&host=${IP}#FreeFlow-${FREEFLOW_MODE^^}" >> "${client_dir}"
    fi

    if [ "${REALITY_MODE}" = "yes" ] && [ -n "$IP" ]; then
        echo "vless://${UUID}@${IP}:${REALITY_PORT}?security=reality&encryption=none&pbk=${REALITY_PBK}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&sid=${REALITY_SID}#Reality" >> "${client_dir}"
    fi

    cat "${client_dir}" | while read line; do printf '\033[1;35m%s\033[0m\n' "$line"; done
    echo ""
}

# ── Argo 管理子菜单 ─────────────────────────────────────────
manage_argo() {
    if [ "${ARGO_MODE}" != "yes" ]; then red "未安装 Argo！"; sleep 1; return; fi
    clear; echo ""
    green "1. 重新获取临时域名"
    green "2. 绑定固定隧道 (Token)"
    green "3. 启停控制"
    purple "0. 返回"
    reading "选择: " ch
    case "$ch" in
        1) get_info ;;
        2) 
            reading "输入 Argo 域名: " d
            reading "输入 Argo Token: " t
            if [ -f /etc/alpine-release ]; then
                sed -i "/^command_args=/c\command_args=\"-c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${t} >> /etc/xray/argo.log 2>&1'\"" /etc/init.d/tunnel
            else
                sed -i "/^ExecStart=/c\\ExecStart=/bin/sh -c '/etc/xray/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${t} >> /etc/xray/argo.log 2>&1'" /etc/systemd/system/tunnel.service
            fi
            service_ctl restart tunnel
            sed -i "1s/sni=[^&]*/sni=${d}/; 1s/host=[^&]*/host=${d}/" "${client_dir}" 2>/dev/null
            green "已绑定固定隧道"; cat "${client_dir}" ;;
        3) 
            reading "1.启动 2.停止 : " sc
            [ "$sc" = "1" ] && service_ctl start tunnel && green "已启动"
            [ "$sc" = "2" ] && service_ctl stop tunnel && yellow "已停止" ;;
        0) return ;;
    esac
}

# ── 协议修改子菜单 ─────────────────────────────────────────
modify_configs() {
    clear; echo ""
    green "1. 更换 UUID (全局)"
    green "2. 修改 Argo 回源端口"
    green "3. 变更 FreeFlow 模式"
    green "4. 修改 Reality 端口和伪装域名"
    purple "0. 返回"
    reading "选择: " ch
    case "$ch" in
        1)
            UUID=$(cat /proc/sys/kernel/random/uuid)
            build_config && service_ctl restart xray && get_info
            green "UUID已变更为: $UUID" ;;
        2)
            [ "${ARGO_MODE}" != "yes" ] && { red "未安装Argo"; return; }
            reading "新端口(1-65535): " p
            ARGO_PORT=$p; build_config && setup_services && get_info ;;
        3)
            interactive_setup # 这里可以复用重新配置
            build_config && setup_services && get_info ;;
        4)
            [ "${REALITY_MODE}" != "yes" ] && { red "未安装Reality"; return; }
            reading "新端口: " np; REALITY_PORT=${np:-$REALITY_PORT}
            reading "新SNI: " ns; REALITY_SNI=${ns:-$REALITY_SNI}
            sed -i "s/^REALITY_PORT=.*/REALITY_PORT=${REALITY_PORT}/" "$reality_conf"
            sed -i "s/^REALITY_SNI=.*/REALITY_SNI=${REALITY_SNI}/" "$reality_conf"
            build_config && service_ctl restart xray && get_info ;;
        0) return ;;
    esac
}

# ── 卸载模块 ───────────────────────────────────────────────
uninstall_all() {
    reading "确定卸载全部组件并删除配置吗？(y/N): " c
    if [[ "$c" =~ ^[yY]$ ]]; then
        service_ctl stop xray; service_ctl stop tunnel
        if [ -f /etc/alpine-release ]; then
            rc-update del xray default 2>/dev/null; rm -f /etc/init.d/xray
            rc-update del tunnel default 2>/dev/null; rm -f /etc/init.d/tunnel
        else
            systemctl disable xray tunnel 2>/dev/null
            rm -f /etc/systemd/system/xray.service /etc/systemd/system/tunnel.service
            systemctl daemon-reload
        fi
        rm -rf "${work_dir}" /usr/local/bin/s
        green "卸载完成！快捷键 s 已失效。"
        exit 0
    fi
}

# ── 主菜单 ─────────────────────────────────────────────────
menu() {
    while true; do
        read_states
        local sx=$(check_service xray)
        local sa=$([ "${ARGO_MODE}" = "yes" ] && check_service tunnel || echo "未安装")
        
        clear; echo ""
        purple "=== Xray-2go 全栈极简版 (快捷命令: s) ==="
        skyblue " Xray:    ${sx} "
        skyblue " Argo:    ${sa} "
        skyblue " FreeFlow: ${FREEFLOW_MODE^^} "
        skyblue " Reality:  ${REALITY_MODE^^} "
        echo "======================================"
        green "1. 安装 / 重新配置协议组合"
        green "2. 查看当前节点链接"
        echo "--------------------------------------"
        green "3. Argo 隧道专项管理"
        green "4. 节点协议参数修改 (UUID/端口/SNI)"
        echo "--------------------------------------"
        red   "9. 完全卸载"
        red   "0. 退出"
        echo "======================================"
        reading "选择操作(0-9): " choice

        case "$choice" in
            1) check_dependencies; interactive_setup; install_core ;;
            2) [ -f "$client_dir" ] && cat "$client_dir" | while read line; do printf '\033[1;35m%s\033[0m\n' "$line"; done || red "暂无节点信息" ;;
            3) manage_argo ;;
            4) modify_configs ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) red "无效选择" ;;
        esac
        printf '\n\033[1;91m按回车键继续...\033[0m'; read -r _dummy
    done
}

menu
