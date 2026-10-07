#!/usr/bin/env bash
set -euo pipefail
# install-singbox-SAN-v4v6.sh
# 基于 install-singbox-lite-SANs.sh 修改:
#   1) 隐藏 SS / TUIC 协议选项,仅保留 Hysteria2 (HY2) 与 VLESS Reality
#   2) 支持 IPv4 / IPv6 双栈:自动检测本机 IPv6,若用户使用默认出口 IP 则询问是否一并创建 v6 节点
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

# IPv6 地址在 URL 中需要用方括号包裹
fmt_host() {
    case "$1" in
        *:*) echo "[$1]" ;;
        *)   echo "$1"  ;;
    esac
}

# 判断一个 IPv6 是否属于「公网全局单播」 2000::/3
# 一次性排除: ::1 回环、::ffff: IPv4-mapped、fe80::/10 链路本地、
#            fc00::/7 ULA 内网(含 fd00::/8、Tailscale fd7a: 虚拟网段)、2001:db8 文档保留段
is_global_ipv6() {
    local a="${1%%/*}"
    a="${a%%%*}"
    a="$(printf '%s' "$a" | tr 'A-F' 'a-f')"
    [ -z "$a" ] && return 1

    local first="${a%%:*}"
    if [ -z "$first" ]; then
        # 以 "::" 开头 -> 回环 / IPv4-mapped / 未指定地址,一律不要
        return 1
    fi

    case "$first" in
        *[!0-9a-f]*) return 1 ;;
    esac

    # 2000::/3 => 首段落在 0x2000 - 0x3fff
    local v=$((16#$first))
    if [ "$v" -lt 8192 ] || [ "$v" -gt 16383 ]; then
        return 1
    fi

    # 2001:db8::/32 文档保留段
    if [ "$v" -eq 8193 ]; then
        local second="${a#*:}"; second="${second%%:*}"
        case "$second" in
            db8|0db8) return 1 ;;
        esac
    fi

    return 0
}

# 收集本机所有候选 IPv6 地址(含 ULA 等),逐个过滤出公网全局单播地址
collect_ipv6_candidates() {
    local list=""
    if command -v ip >/dev/null 2>&1; then
        list=$(ip -6 addr show scope global 2>/dev/null \
            | grep 'inet6' \
            | grep -v 'tentative' \
            | grep -v 'dadfailed' \
            | grep -v 'deprecated' \
            | awk '{print $2}' \
            | awk -F'/' '{print $1}' || true)
    fi

    if [ -z "$list" ] && command -v ifconfig >/dev/null 2>&1; then
        list=$(ifconfig 2>/dev/null \
            | awk '/inet6/ {print $2}' \
            | awk -F'/' '{print $1}' || true)
    fi

    if [ -z "$list" ] && [ -r /proc/net/if_inet6 ]; then
        list=$(awk '{print $1}' /proc/net/if_inet6 2>/dev/null \
            | sed 's/.\{4\}/&:/g; s/:$//' || true)
    fi

    printf '%s\n' "$list" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        is_global_ipv6 "$line" && printf '%s\n' "$line"
    done
}

# 检测本机是否存在可用的公网 IPv6 地址
# 主做法:直接问内核「要去公网 IPv6 目标,你会用哪个源地址」——由路由表决定,不靠猜
detect_ipv6_addr() {
    if command -v ip >/dev/null 2>&1; then
        for target in 2001:4860:4860::8888 2606:4700:4700::1111 2400:3200::1; do
            src=$(ip -6 route get "$target" 2>/dev/null \
                | awk '{for(i=1;i<NF;i++){if($i=="src"){print $(i+1); exit}}}' || true)
            if [ -n "$src" ] && is_global_ipv6 "$src"; then
                echo "$src"
                return 0
            fi
        done
    fi

    # 兜底:busybox 的 ip 可能不支持 route get,退回扫描网卡地址并剔除内网地址
    local cands stable_addr="" any_addr="" c
    cands="$(collect_ipv6_candidates || true)"
    [ -z "$cands" ] && return 1

    while IFS= read -r c; do
        [ -z "$c" ] && continue
        [ -z "$any_addr" ] && any_addr="$c"
        stable_addr="$c"
        break
    done <<< "$cands"

    local pick="${stable_addr:-$any_addr}"
    if [ -n "$pick" ] && is_global_ipv6 "$pick"; then
        echo "$pick"
        return 0
    fi
    return 1
}

# 是否存在 IPv6 默认路由(有地址不代表能出网)
has_ipv6_default_route() {
    ip -6 route show default 2>/dev/null | grep -q 'via\|dev' && return 0
    return 1
}

# 通过外部回显获取「公网看到的」IPv6 地址,同时验证 IPv6 出网真的可用
# curl -6 强制走 IPv6 传输层,所以 ip.sb 这种双栈域名返回的一定是 IPv6,不存在歧义
# ip.sb 优先,后面依次尝试专属端点与其它常见回显站
get_public_ipv6() {
    local ip=""
    for url in \
        "https://ip.sb" \
        "https://ipv6.ip.sb" \
        "https://api-ipv6.ip.sb" \
        "https://api64.ipify.org" \
        "https://ipv6.icanhazip.com" \
        "https://v6.ident.me" \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me"; do
        ip=$(curl -6 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        # 只用「有没有冒号」这种最朴素的判断区分协议族,能拿到就等于这条 IPv6 通了
        case "$ip" in
            *:*) echo "$ip"; return 0 ;;
        esac
    done
    return 1
}

# 全部探测失败时打印自检信息,方便定位是没路由 / DNS 不通 / 站点被拦
diagnose_ipv6() {
    warn "IPv6 探测全部失败,自检信息如下:"
    local r
    r=$(curl -6 -sS --max-time 6 https://ip.sb 2>&1 | tail -n 1 || true)
    echo "   curl -6 https://ip.sb      => ${r:-无返回}"
    r=$(curl -6 -sS --max-time 6 https://ipv6.ip.sb 2>&1 | tail -n 1 || true)
    echo "   curl -6 https://ipv6.ip.sb => ${r:-无返回}"

    # 用一个不太可能被拦的站点判断 IPv6 出网本身通不通
    local code
    code=$(curl -6 -s -o /dev/null -w '%{http_code}' --max-time 6 https://ipv6.google.com 2>/dev/null || true)
    echo "   IPv6 出网连通性(ipv6.google.com): HTTP ${code:-失败}"

    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {print "   网卡 IPv6 地址: " $2}'
        local rt
        rt=$(ip -6 route show default 2>/dev/null | head -n 1 || true)
        echo "   IPv6 默认路由: ${rt:-无}"
    fi
}

# 综合判定:外部回显优先(公网真实可见),其次本机网卡地址,ULA/内网地址一律忽略
resolve_ipv6() {
    local ext="" loc=""

    info "正在检测 IPv6 可用性..."

    ext="$(get_public_ipv6 || true)"
    if [ -n "$ext" ]; then
        echo "PUBLIC|$ext"
        return 0
    fi

    loc="$(detect_ipv6_addr || true)"
    if [ -n "$loc" ]; then
        echo "LOCAL|$loc"
        return 0
    fi

    return 1
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
# 选择要部署的协议(已隐藏 SS / TUIC)
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Hysteria2 (HY2)"
    echo "2) VLESS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2):"
    read -r protocol_input

    # SS / TUIC 已在该版本中隐藏,强制关闭
    ENABLE_SS=false
    ENABLE_TUIC=false
    ENABLE_HY2=false
    ENABLE_REALITY=false

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_HY2=true ;;
            2) ENABLE_REALITY=true ;;
            *)
                warn "无效选项: $num (本版本仅支持 HY2 与 VLESS Reality)"
                ;;
        esac
    done

    if ! $ENABLE_HY2 && ! $ENABLE_REALITY; then
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
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_REALITY && echo "  - VLESS Reality"

    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
}

mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式(SS 已隐藏,不再询问,仅保留默认值)
select_ss_method() {
    SS_METHOD="2022-blake3-aes-128-gcm"
    export SS_METHOD
}

select_ss_method

# -----------------------
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]' || true)"

# -----------------------
# IPv6 双栈选项:仅在用户留空(使用默认出口 IP)且本机检测到 IPv6 时才询问
ENABLE_V6=false
V6_ADDR=""

if [ -z "$CUSTOM_IP" ]; then
    DETECTED_V6=""
    V6_SOURCE=""
    V6_RESULT="$(resolve_ipv6 || true)"
    case "$V6_RESULT" in
        PUBLIC\|*) V6_SOURCE="公网回显"; DETECTED_V6="${V6_RESULT#PUBLIC|}" ;;
        LOCAL\|*)  V6_SOURCE="网卡地址"; DETECTED_V6="${V6_RESULT#LOCAL|}" ;;
        *)         V6_SOURCE=""; DETECTED_V6="" ;;
    esac

    if [ -n "$DETECTED_V6" ]; then
        info "检测到可用公网 IPv6: $DETECTED_V6 (来源: $V6_SOURCE)"
        # 只有网卡地址、没有通过公网回显验证时给出提醒
        if [ "$V6_SOURCE" = "网卡地址" ]; then
            if has_ipv6_default_route; then
                warn "该地址未能通过公网回显验证(外网检测接口可能被拦),请确认它能被公网访问"
            else
                warn "未检测到 IPv6 默认路由,该地址大概率无法出网"
            fi
        fi
        echo ""
        echo "是否同时创建 IPv6 节点?(同一端口 v4/v6 双栈监听,会额外生成一份 v6 链接)(y/N):"
        read -r USE_V6
        if [[ "$USE_V6" =~ ^[Yy]$ ]]; then
            ENABLE_V6=true
            echo "请输入 IPv6 节点连接地址(留空则使用检测到的 $DETECTED_V6):"
            read -r V6_INPUT
            V6_INPUT="$(echo "$V6_INPUT" | tr -d '[:space:]' || true)"
            V6_ADDR="${V6_INPUT:-$DETECTED_V6}"
            if ! is_global_ipv6 "$V6_ADDR"; then
                warn "注意: $V6_ADDR 不是公网全局单播地址(ULA/内网地址无法被外部访问)"
            fi
            info "IPv6 节点连接地址: $V6_ADDR"
        else
            info "跳过 IPv6 节点,仅创建 IPv4 节点"
        fi
    else
        diagnose_ipv6
        info "未检测到可用的公网 IPv6,仅创建 IPv4 节点"
    fi
else
    info "已手动指定连接地址,跳过 IPv6 创建选项"
fi

export ENABLE_V6
export V6_ADDR

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
echo "ENABLE_V6=$ENABLE_V6" >> /etc/sing-box/.config_cache.tmp || true
echo "V6_ADDR=$V6_ADDR" >> /etc/sing-box/.config_cache.tmp || true
if [ -f /etc/sing-box/.config_cache ]; then
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
        PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2 | 密码已自动生成"
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
# 生成 HY2 自签证书
generate_cert() {
    if ! $ENABLE_HY2; then
        return 0
    fi

    info "生成 HY2 自签证书..."
    mkdir -p /etc/sing-box/certs

    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" \
          -addext "subjectAltName = DNS:www.bing.com" || {
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

    # 入站统一监听 "::"(IPv4 + IPv6 双栈),v6 节点复用同一入站,仅链接层面生成一份 v6 地址
    if $ENABLE_HY2; then
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
ENABLE_V6=$ENABLE_V6
V6_ADDR=$V6_ADDR
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
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
    echo "SS_METHOD=$SS_METHOD" >> /etc/sing-box/.config_cache
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
# curl -4 强制走 IPv4 传输层,所以连 ip.sb 这种双栈域名返回的也一定是 IPv4,不存在歧义
# ip.sb 优先,后面依次尝试专属端点与其它常见回显站
get_public_ip() {
    local ip=""
    for url in \
        "https://ip.sb" \
        "https://ipv4.ip.sb" \
        "https://api-ipv4.ip.sb" \
        "https://ipv4.icanhazip.com" \
        "https://v4.ident.me" \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://ipecho.net/plain"; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        case "$ip" in
            *:*) continue ;;              # 万一拿到 IPv6,丢弃换下一个
            *.*.*.*) echo "$ip"; return 0 ;;
        esac
    done
    return 1
}

if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IPv4,请手动替换"
    else
        info "检测到公网 IPv4: $PUB_IP"
    fi
fi

if $ENABLE_V6; then
    info "IPv6 节点地址: $V6_ADDR"
fi

# -----------------------
# 生成链接
# $1 = 主机地址(v4 或 v6)  $2 = 节点名后缀("" 或 "-v6")
emit_links() {
    local host="$1"
    local tag_suffix="$2"
    local h
    h=$(fmt_host "$host")

    if [ "$tag_suffix" = "-v6" ]; then
        echo "========== IPv6 节点 =========="
        echo ""
    fi

    if $ENABLE_HY2; then
        local hy2_encoded
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${h}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}${tag_suffix}"
        echo ""
    fi

    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${h}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}${tag_suffix}"
        echo ""
    fi
}

generate_uris() {
    emit_links "$PUB_IP" ""
    if $ENABLE_V6 && [ -n "$V6_ADDR" ]; then
        emit_links "$V6_ADDR" "-v6"
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
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
echo "   服务器(IPv4): $PUB_IP"
if $ENABLE_V6; then
    echo "   服务器(IPv6): $V6_ADDR"
else
    echo "   IPv6 节点: 未创建"
fi
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
$ENABLE_HY2 && echo "   证书: /etc/sing-box/certs/"
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

fmt_host() {
    case "$1" in
        *:*) echo "[$1]" ;;
        *)   echo "$1"  ;;
    esac
}

read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    PROTOCOL_FILE="/etc/sing-box/.protocols"
    [ -f "$PROTOCOL_FILE" ] && . "$PROTOCOL_FILE"
    [ -f "$CACHE_FILE" ] && . "$CACHE_FILE"

    ENABLE_SS="${ENABLE_SS:-false}"
    ENABLE_HY2="${ENABLE_HY2:-false}"
    ENABLE_TUIC="${ENABLE_TUIC:-false}"
    ENABLE_REALITY="${ENABLE_REALITY:-false}"
    ENABLE_V6="${ENABLE_V6:-false}"
    V6_ADDR="${V6_ADDR:-}"

    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    CUSTOM_IP="${CUSTOM_IP:-}"
    SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"

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
    for url in "https://ip.sb" "https://ipv4.ip.sb" "https://api-ipv4.ip.sb" \
               "https://ipv4.icanhazip.com" "https://v4.ident.me" \
               "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        case "$ip" in
            *:*) continue ;;                # 万一拿到 IPv6,丢弃换下一个
            *.*.*.*) echo "$ip"; return 0 ;;
        esac
    done
    echo "YOUR_SERVER_IP"
}

# 按指定地址写出一组链接: $1=地址 $2=后缀标识(空或 -v6) $3=输出文件
emit_uris() {
    local host="$1"
    local tag_suffix="$2"
    local uri_file="$3"
    local h
    h=$(fmt_host "$host")

    if [ "$tag_suffix" = "-v6" ]; then
        echo "========== IPv6 节点 ==========" >> "$uri_file"
        echo "" >> "$uri_file"
    fi

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        echo "=== Shadowsocks (SS) ===" >> "$uri_file"
        echo "ss://${ss_encoded}@${h}:${SS_PORT}#ss${node_suffix}${tag_suffix}" >> "$uri_file"
        echo "ss://${ss_b64}@${h}:${SS_PORT}#ss${node_suffix}${tag_suffix}" >> "$uri_file"
        echo "" >> "$uri_file"
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$uri_file"
        echo "hy2://${hy2_encoded}@${h}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}${tag_suffix}" >> "$uri_file"
        echo "" >> "$uri_file"
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$uri_file"
        echo "vless://${REALITY_UUID}@${h}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}${tag_suffix}" >> "$uri_file"
        echo "" >> "$uri_file"
    fi
}

action_set_v6() {
    read_config || return 1

    echo ""
    echo "当前 IPv6 节点状态: ${ENABLE_V6}"
    [ -n "${V6_ADDR:-}" ] && echo "当前 IPv6 地址: $V6_ADDR"
    echo ""
    echo "1) 开启 / 修改 IPv6 节点地址"
    echo "2) 关闭 IPv6 节点"
    echo "0) 返回上级菜单"
    read -p "请输入选项: " v6_opt

    case "$v6_opt" in
        1)
            read -p "请输入 IPv6 节点连接地址: " new_v6
            new_v6="$(echo "$new_v6" | tr -d '[:space:]' || true)"
            [ -z "$new_v6" ] && { err "地址不能为空"; return 1; }
            V6_ADDR="$new_v6"
            ENABLE_V6=true
            ;;
        2)
            ENABLE_V6=false
            V6_ADDR=""
            ;;
        0) return 0 ;;
        *) warn "无效选项"; return 1 ;;
    esac

    touch "$CACHE_FILE" 2>/dev/null || true
    sed -i '/^ENABLE_V6=/d; /^V6_ADDR=/d' "$CACHE_FILE" 2>/dev/null || true
    echo "ENABLE_V6=$ENABLE_V6" >> "$CACHE_FILE"
    echo "V6_ADDR=$V6_ADDR" >> "$CACHE_FILE"
    info "IPv6 节点配置已更新: ENABLE_V6=$ENABLE_V6 ${V6_ADDR:-}"
    generate_uris || true
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

    emit_uris "$PUBLIC_IP" "" "$URI_FILE"

    if [ "${ENABLE_V6:-false}" = "true" ] && [ -n "${V6_ADDR:-}" ]; then
        emit_uris "$V6_ADDR" "-v6" "$URI_FILE"
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

action_generate_relay() {
    read_config || return 1

    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 入站,生成线路机需要先把本机 SS 作为中转入站"
        read -p "是否在本机部署 SS 入站用于中转?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 入站..."
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

            touch "$CACHE_FILE" 2>/dev/null || true
            sed -i '/^ENABLE_SS=/d' "$CACHE_FILE" 2>/dev/null || true
            echo "ENABLE_SS=true" >> "$CACHE_FILE"
            sed -i '/^SS_METHOD=/d' "$CACHE_FILE" 2>/dev/null || true
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"

            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi

            ENABLE_SS=true
            service_start || warn "启动服务失败"
            read_config || true
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

info "安装 sing-box..."
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

PUB_IP=$(curl -4 -s --max-time 5 https://ip.sb 2>/dev/null \
         || curl -4 -s --max-time 5 https://ipv4.ip.sb 2>/dev/null \
         || curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null \
         || echo "YOUR_RELAY_IP")
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

    echo "  IPv6 节点: ${ENABLE_V6:-false} ${V6_ADDR:-}"
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
    MENU_MAP[$option]="v6"; echo "$((option))) IPv6 节点开关/地址"; option=$((option + 1))
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
                reset_reality) action_reset_reality ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                v6) action_set_v6 ;;
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
