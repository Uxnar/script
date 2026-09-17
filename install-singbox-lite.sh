#!/usr/bin/env bash
set -euo pipefail
# 2
# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型与架构
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi

    case $(uname -m) in
        amd64 | x86_64) ARCH="amd64" ;;
        *aarch64* | *armv8*) ARCH="arm64" ;;
        *) err "此脚本目前仅支持 64 位 (amd64/arm64) 系统"; exit 1 ;;
    esac
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown}) | 架构: $ARCH"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖 (引入 gcompat 适配 Alpine)
install_deps() {
    info "安装系统依赖..."

    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl wget tar ca-certificates openssl openrc jq tzdata gcompat || {
                err "依赖安装失败"
                exit 1
            }
            
            # 终极防线：强制补齐 Alpine arm64/amd64 下缺少的动态链接器
            if [ "$ARCH" = "arm64" ] && [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
                mkdir -p /lib
                ln -s /lib/libc.musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1 2>/dev/null || true
            elif [ "$ARCH" = "amd64" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
                mkdir -p /lib64
                ln -s /lib/libc.musl-x86_64.so.1 /lib64/ld-linux-x86-64.so.2 2>/dev/null || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl wget tar ca-certificates openssl jq tzdata || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl wget tar ca-certificates openssl jq tzdata || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac

    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认无后缀):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
    rm -f /root/node_names.txt
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input

    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY; then
        err "未选择任何协议,退出安装"
        exit 1
    fi

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
EOF

    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"

    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
}

mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi

    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice

    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *)
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac

    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

REALITY_SNI=""
if $ENABLE_REALITY; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    REALITY_SNI="addons.mozilla.org"
fi

mkdir -p /etc/sing-box
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
if [ -f /etc/sing-box/.config_cache ]; then
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."

    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
        PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS | 加密方式: $SS_METHOD | 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
        PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2 | 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
        PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC | UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
        PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        UUID=$(rand_uuid)
        info "Reality 端口: $PORT_REALITY | UUID 已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box (二进制包)..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    SB_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$SB_VER" ]; then
        err "获取最新版本号失败，请检查网络"
        exit 1
    fi

    SB_FILE="sing-box-${SB_VER}-linux-${ARCH}.tar.gz"
    SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${SB_FILE}"

    # 隔离下载目录和解压目录
    DOWN_DIR="/root/sb_down"
    EXT_DIR="/root/sb_ext"
    rm -rf "$DOWN_DIR" "$EXT_DIR"
    mkdir -p "$DOWN_DIR" "$EXT_DIR"

    info "正在下载 sing-box v${SB_VER} ($ARCH)..."
    if ! wget -qO "$DOWN_DIR/$SB_FILE" "$SB_URL"; then
        curl -L -o "$DOWN_DIR/$SB_FILE" "$SB_URL" || { err "下载失败"; exit 1; }
    fi

    info "解压并部署..."
    tar -xzf "$DOWN_DIR/$SB_FILE" -C "$EXT_DIR" --strip-components 1
    mv -f "$EXT_DIR/sing-box" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    rm -rf "$DOWN_DIR" "$EXT_DIR"

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 二进制部署失败"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "✅ sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对
generate_reality_keys() {
    if ! $ENABLE_REALITY; then
        return 0
    fi

    info "生成 Reality 密钥对..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }

    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }

    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi

    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid

    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        return 0
    fi

    info "生成 HY2/TUIC 自签证书..."
    mkdir -p /etc/sing-box/certs

    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
    > "$TEMP_INBOUNDS"

    local need_comma=false

    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
    fi

    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
CONFIG_HEAD

    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"

    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache
    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

create_config
info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."

    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"

        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC

        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            exit 1
        }

        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi

    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"

        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            exit 1
        }

        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi

    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接
generate_uris() {
    local host="$PUB_IP"

    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi

    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi

    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""

info "📜 客户端链接:"
generate_uris | tee /etc/sing-box/uris.txt | while IFS= read -r line; do
    echo "   $line"
done
chmod 600 /etc/sing-box/uris.txt
info "协议链接已保存到: /etc/sing-box/uris.txt"

echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi

    case $(uname -m) in
        amd64 | x86_64) ARCH="amd64" ;;
        *aarch64* | *armv8*) ARCH="arm64" ;;
        *) ARCH="amd64" ;;
    esac
}

detect_os

service_start() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"; }
service_stop() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"; }
service_restart() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"; }
service_status() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager; }

rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'; }

url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    PROTOCOL_FILE="/etc/sing-box/.protocols"
    [ -f "$PROTOCOL_FILE" ] && . "$PROTOCOL_FILE"
    [ -f "$CACHE_FILE" ] && . "$CACHE_FILE"

    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    CUSTOM_IP="${CUSTOM_IP:-}"

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
        REALITY_SID=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1)
        [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
    fi
}

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

generate_uris() {
    read_config || return 1

    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

action_view_config() { echo "$CONFIG_PATH"; }

action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"

    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

action_reset_ss() {
    read_config || return 1
    [ "${ENABLE_SS:-false}" != "true" ] && { err "SS 协议未启用"; return 1; }
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --argjson port "$new_port" '.inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    service_start || warn "启动服务失败"
    generate_uris || warn "生成 URI 失败"
}

action_reset_hy2() {
    read_config || return 1
    [ "${ENABLE_HY2:-false}" != "true" ] && { err "HY2 协议未启用"; return 1; }
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --argjson port "$new_port" '.inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    service_start || warn "启动服务失败"
    generate_uris || warn "生成 URI 失败"
}

action_reset_tuic() {
    read_config || return 1
    [ "${ENABLE_TUIC:-false}" != "true" ] && { err "TUIC 协议未启用"; return 1; }
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --argjson port "$new_port" '.inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    service_start || warn "启动服务失败"
    generate_uris || warn "生成 URI 失败"
}

action_reset_reality() {
    read_config || return 1
    [ "${ENABLE_REALITY:-false}" != "true" ] && { err "Reality 协议未启用"; return 1; }
    read -p "输入新的 Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    service_stop || warn "停止服务失败"
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    jq --argjson port "$new_port" '.inbounds |= map(if .type=="vless" then .listen_port = $port else . end)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    service_start || warn "启动服务失败"
    generate_uris || warn "生成 URI 失败"
}

action_update() {
    info "开始更新 sing-box (二进制包)..."
    SB_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty' | sed 's/v//')
    if [ -z "$SB_VER" ]; then
        err "获取最新版本号失败"
        return 1
    fi
    SB_FILE="sing-box-${SB_VER}-linux-${ARCH}.tar.gz"
    SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${SB_FILE}"

    DOWN_DIR="/root/sb_down_up"
    EXT_DIR="/root/sb_ext_up"
    rm -rf "$DOWN_DIR" "$EXT_DIR"
    mkdir -p "$DOWN_DIR" "$EXT_DIR"
    
    info "正在下载: $SB_FILE"
    if ! wget -qO "$DOWN_DIR/$SB_FILE" "$SB_URL"; then
        curl -L -o "$DOWN_DIR/$SB_FILE" "$SB_URL" || { err "下载失败"; return 1; }
    fi

    service_stop
    tar -xzf "$DOWN_DIR/$SB_FILE" -C "$EXT_DIR" --strip-components 1
    mv -f "$EXT_DIR/sing-box" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    rm -rf "$DOWN_DIR" "$EXT_DIR"

    info "更新完成,已重启服务..."
    service_start
    NEW_VER=$(sing-box version 2>/dev/null | head -n1)
    info "当前版本: $NEW_VER"
}

action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0

    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

action_generate_relay() {
    read_config || return 1

    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"

            service_stop || warn "停止服务失败"
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"

            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi

            ENABLE_SS=true
            service_start || warn "启动服务失败"
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi

    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    RELAY_SCRIPT="/tmp/relay-install.sh"
    info "正在生成线路机脚本: $RELAY_SCRIPT"

    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }
[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
    case $(uname -m) in
        amd64|x86_64) ARCH="amd64" ;;
        *aarch64*|*armv8*) ARCH="arm64" ;;
        *) err "不支持的架构"; exit 1 ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) 
        apk update; apk add --no-cache curl jq bash openssl ca-certificates wget tar tzdata gcompat
        if [ "$ARCH" = "arm64" ] && [ ! -e /lib/ld-linux-aarch64.so.1 ]; then
            mkdir -p /lib && ln -s /lib/libc.musl-aarch64.so.1 /lib/ld-linux-aarch64.so.1 2>/dev/null || true
        elif [ "$ARCH" = "amd64" ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ]; then
            mkdir -p /lib64 && ln -s /lib/libc.musl-x86_64.so.1 /lib64/ld-linux-x86-64.so.2 2>/dev/null || true
        fi
        ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates wget tar tzdata ;;
    redhat) yum install -y curl jq bash openssl ca-certificates wget tar tzdata ;;
esac

info "安装 sing-box (防爆内存版)..."
SB_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
SB_FILE="sing-box-${SB_VER}-linux-${ARCH}.tar.gz"

DOWN_DIR="/root/sb_down_relay"
EXT_DIR="/root/sb_ext_relay"
rm -rf "$DOWN_DIR" "$EXT_DIR"
mkdir -p "$DOWN_DIR" "$EXT_DIR"

wget -qO "$DOWN_DIR/${SB_FILE}" "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${SB_FILE}"
tar -xzf "$DOWN_DIR/${SB_FILE}" -C "$EXT_DIR" --strip-components 1
mv "$EXT_DIR/sing-box" /usr/bin/sing-box
chmod +x /usr/bin/sing-box
rm -rf "$DOWN_DIR" "$EXT_DIR"

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "sniff": true,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt
echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
RELAY_EOF

    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-addons.mozilla.org}|g" "$RELAY_SCRIPT"
    chmod +x "$RELAY_SCRIPT"

    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
}

REMOTE_VER=$(curl -sf --max-time 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || echo "获取失败")

show_menu() {
    read_config 2>/dev/null || true
    local local_ver
    local_ver=$(sing-box version 2>/dev/null | head -1 || echo "未知")

    echo ""
    echo "=========================="
    echo " Sing-box 管理面板 (快速指令sb)"
    echo "=========================="
    echo "  本地版本: $local_ver"
    echo "  最新版本: ${REMOTE_VER:-获取失败}"

    if [ -n "${REMOTE_VER:-}" ] && [ "$REMOTE_VER" != "获取失败" ]; then
        local remote_num="${REMOTE_VER#v}"
        if ! echo "$local_ver" | grep -qF "$remote_num"; then
            echo -e "   \033[1;33m⬆ 有新版本可用\033[0m"
        fi
    fi
    echo ""

    cat <<'MENU'
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    declare -g -A MENU_MAP
    local option=4

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    MENU_MAP[$option]="start"; echo "$option) 启动服务"; option=$((option + 1))
    MENU_MAP[$option]="stop"; echo "$((option))) 停止服务"; option=$((option + 1))
    MENU_MAP[$option]="restart"; echo "$((option))) 重启服务"; option=$((option + 1))
    MENU_MAP[$option]="status"; echo "$((option))) 查看状态"; option=$((option + 1))
    MENU_MAP[$option]="update"; echo "$((option))) 更新 sing-box"; option=$((option + 1))
    MENU_MAP[$option]="relay"; echo "$((option))) 生成线路机脚本(出口为本机ss)"; option=$((option + 1))
    MENU_MAP[$option]="uninstall"; echo "$((option))) 卸载 sing-box"

    cat <<MENU2
0) 退出
==========================
MENU2
}

while true; do
    show_menu
    read -p "请输入选项: " opt

    if [ "$opt" = "0" ]; then exit 0; fi

    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
info "✅ 管理面板已创建,可输入 sb 打开管理面板"
