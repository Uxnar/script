#!/usr/bin/env bash
set -euo pipefail
# install-cftun.sh
SCRIPT_VERSION="v2611172310"
export SCRIPT_VERSION
# 给已装好的 sing-box 追加一条 Argo 临时隧道（Cloudflare Quick Tunnel）节点。
#
# 做的事情:
#   1) 下载 cloudflared（仅当缺失或 --force）
#   2) 在 config.json 里幂等追加一条 VLESS + WS 入站,只监听 127.0.0.1
#   3) 把 cloudflared 注册为服务,指向该 WS 端口,拿 *.trycloudflare.com 域名
#   4) 生成 vless:// 链接到 /etc/sing-box/cftun.txt
#   5) 安装 cftun 管理命令(独立命令,不改动 sb 面板)
#
# 设计约束:
#   - 不碰已有的 Reality / HY2 / SS / TUIC 入站,也不修改 sb 面板与其它脚本
#   - 唯一会动的现有文件是 /etc/sing-box/config.json(只追加/移除一条 cftun-ws-in)
#   - 不修改 uris.txt(sb 每次生成会整份覆盖),argo 链接单独存 cftun.txt
#   - 临时隧道域名随 cloudflared 重启变化,重装/重启后需在 cftun 里刷新
#
# 用法:
#   bash install-cftun.sh              # 安装或补装
#   bash install-cftun.sh --force      # 重建 WS 入站与隧道
#   bash install-cftun.sh --uninstall  # 移除隧道与 WS 入站
#
# 可选环境变量:
#   CF_MIRROR=https://ghfast.top/      # cloudflared 下载加速前缀(复用 SB_MIRROR)
#   SB_MIRROR=...                      # 与上面等价
#   CFTUN_PORT=10888                   # 指定 WS 本地监听端口(默认随机)
#   CFTUN_NAME=argo-tw                 # 节点名(默认 argo-<IP前两段>)
# =====================================================================

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

SB_DIR="/etc/sing-box"
CONFIG_PATH="$SB_DIR/config.json"
CACHE_FILE="$SB_DIR/.cftun_cache"
URI_FILE="$SB_DIR/cftun.txt"
SB_URIS="$SB_DIR/uris.txt"
MARK_B="# >>> argo-cftun >>>"
MARK_E="# <<< argo-cftun <<<"
CF_BIN="/usr/local/bin/cloudflared"
CF_WRAPPER="/usr/local/bin/cftun-run"
CF_LOG="/var/log/cloudflared-argo.log"
CFTUN_CMD="/usr/local/bin/cftun"
WS_TAG="cftun-ws-in"
SVC_NAME="cloudflared-argo"

FORCE=false
DO_UNINSTALL=false
HOOK_SB=false
UNHOOK_SB=false

usage() {
    cat <<USAGE
用法: bash $0 [选项]
  (无参数)      安装 / 补装 Argo 临时隧道
  --force       重建 WS 入站与隧道(换新参数、换新域名)
  --hook-sb     给 sb 面板打一行钩子:每次生成链接后自动追加 argo 段
  --unhook-sb   移除上面那行钩子
  --uninstall   移除隧道、服务与 WS 入站(不影响其它节点)
  -h, --help    显示本帮助

环境变量:
  CF_MIRROR / SB_MIRROR   cloudflared 下载加速前缀
  CFTUN_PORT              WS 本地监听端口,默认随机
  CFTUN_NAME              节点名,默认 argo-<IP前两段>

说明:
  Argo 临时隧道只能承载 HTTP/WebSocket,Reality、HY2、TUIC 无法套用。
  本脚本追加的是一条独立的 VLESS+WS 入站,与原有节点并存。
  临时域名在 cloudflared 重启后会变,届时执行 cftun 刷新链接。

关于 uris.txt:
  默认只在末尾维护一个带标记的 argo 段(刷新时只替换这一段,
  上方直连链接原样保留),但 sb 面板重新生成链接时会整份覆盖该文件。
  想让 argo 段在 sb 生成后自动补回,加 --hook-sb。
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-f) FORCE=true; shift ;;
        --uninstall) DO_UNINSTALL=true; shift ;;
        --hook-sb) HOOK_SB=true; shift ;;
        --unhook-sb) UNHOOK_SB=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) warn "忽略无法识别的参数: $1"; shift ;;
    esac
done

# -----------------------
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "必须以 root 运行"
        exit 1
    fi
}

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
    elif echo "$ID $ID_LIKE" | grep -Eqi "debian|ubuntu"; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Eqi "centos|rhel|fedora"; then
        OS="redhat"
    else
        OS="unknown"
    fi
    case $(uname -m) in
        amd64|x86_64) ARCH="amd64" ;;
        *aarch64*|*armv8*) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="arm" ;;
        *) err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

check_root
detect_os
info "系统: $OS / $ARCH,脚本版本: $SCRIPT_VERSION"

# -----------------------
install_deps() {
    info "检查系统依赖..."
    case "$OS" in
        alpine)
            apk add --no-cache bash curl wget tar ca-certificates openssl openrc jq gcompat >/dev/null 2>&1 || true
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
            apt-get install -y curl wget tar ca-certificates openssl jq >/dev/null 2>&1 || true
            ;;
        redhat)
            yum install -y curl wget tar ca-certificates openssl jq >/dev/null 2>&1 || true
            ;;
    esac
    for c in curl jq; do
        command -v "$c" >/dev/null 2>&1 || { err "缺少依赖: $c"; exit 1; }
    done
}

install_deps

# -----------------------
check_singbox() {
    if ! command -v sing-box >/dev/null 2>&1; then
        err "未检测到 sing-box"
        err "请先执行: curl -fsSL https://raw.githubusercontent.com/Uxnar/script/main/install-singbox-auto.sh -o /tmp/s.sh && bash /tmp/s.sh"
        exit 1
    fi
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        exit 1
    fi
    info "已检测到 sing-box: $(sing-box version 2>/dev/null | head -n1)"
}

# -----------------------
svc_start()   { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" start   2>/dev/null || systemctl start "$SVC_NAME"; }
svc_stop()    { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" stop    2>/dev/null || systemctl stop "$SVC_NAME"; }
svc_restart() { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" restart 2>/dev/null || systemctl restart "$SVC_NAME"; }
svc_status()  { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" status  || systemctl status "$SVC_NAME" --no-pager; }
svc_enable()  { [ "$OS" = "alpine" ] && rc-update add "$SVC_NAME" default 2>/dev/null || systemctl enable "$SVC_NAME" 2>/dev/null; }
svc_disable() { [ "$OS" = "alpine" ] && rc-update del "$SVC_NAME" default 2>/dev/null || systemctl disable "$SVC_NAME" 2>/dev/null; }

sb_restart() {
    if [ "$OS" = "alpine" ]; then
        rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || true
    else
        systemctl restart sing-box >/dev/null 2>&1 || true
    fi
}

# -----------------------
load_cache() {
    if [ -f "$CACHE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CACHE_FILE"
    fi
    CFTUN_UUID="${CFTUN_UUID:-}"
    CFTUN_WS_PORT="${CFTUN_WS_PORT:-}"
    CFTUN_WS_PATH="${CFTUN_WS_PATH:-}"
    CFTUN_HOST="${CFTUN_HOST:-}"
    CFTUN_NAME="${CFTUN_NAME:-}"
}

save_cache() {
    mkdir -p "$SB_DIR"
    cat > "$CACHE_FILE" <<CACHEEOF
CFTUN_UUID=$CFTUN_UUID
CFTUN_WS_PORT=$CFTUN_WS_PORT
CFTUN_WS_PATH=$CFTUN_WS_PATH
CFTUN_HOST=$CFTUN_HOST
CFTUN_NAME=$CFTUN_NAME
CACHEEOF
    chmod 600 "$CACHE_FILE"
}

rand_port() {
    local p
    p=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)))
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${p} "; then
        p=$((p + 1))
    fi
    echo "$p"
}

rand_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
}

# 链接里的 path 需要 URL 编码,/ 转成 %2F
url_encode_path() {
    printf '%s' "$1" | sed 's|/|%2F|g'
}

build_uri() {
    local host="$1" uuid="$2" path="$3" name="$4"
    local ep
    ep=$(url_encode_path "$path")
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$host" "$host" "$host" "$ep" "$name"
}

# -----------------------
# 维护 uris.txt 里的 argo 段:只替换自己的标记块,直连链接原样保留
strip_argo_block() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -v b="$MARK_B" -v e="$MARK_E" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip == 1 { next }
        { print }
    ' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

append_argo_block() {
    local f="$1"
    [ -n "${CFTUN_HOST:-}" ] || return 0
    {
        echo ""
        echo "$MARK_B"
        echo "=== Argo 临时隧道 (VLESS + WS + TLS) ==="
        echo "域名: $CFTUN_HOST"
        build_uri "$CFTUN_HOST" "$CFTUN_UUID" "$CFTUN_WS_PATH" "$CFTUN_NAME"
        echo ""
        echo "$MARK_E"
    } >> "$f"
}

sync_uris() {
    [ -f "$SB_URIS" ] || return 0
    strip_argo_block "$SB_URIS"
    append_argo_block "$SB_URIS"
    return 0
}

# -----------------------
remove_ws_inbound() {
    [ -f "$CONFIG_PATH" ] || return 0
    local tmp="$CONFIG_PATH.tmp.$$"
    jq --arg tag "$WS_TAG" '.inbounds = [.inbounds[] | select(.tag != $tag)]' \
        "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH" 2>/dev/null || true
}

merge_ws_inbound() {
    local tmp="$CONFIG_PATH.tmp.$$"
    jq --arg tag "$WS_TAG" \
       --arg uuid "$CFTUN_UUID" \
       --argjson port "$CFTUN_WS_PORT" \
       --arg path "$CFTUN_WS_PATH" '
        .inbounds = (
            [.inbounds[] | select(.tag != $tag)]
            + [{
                "type": "vless",
                "tag": $tag,
                "listen": "127.0.0.1",
                "listen_port": $port,
                "users": [{ "uuid": $uuid }],
                "transport": { "type": "ws", "path": $path }
            }]
        )
    ' "$CONFIG_PATH" > "$tmp"

    if sing-box check -c "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$CONFIG_PATH"
        chmod 600 "$CONFIG_PATH" 2>/dev/null || true
        info "WS 入站已写入: 127.0.0.1:$CFTUN_WS_PORT$CFTUN_WS_PATH"
        return 0
    fi

    warn "sing-box check 未通过,尝试打印错误:"
    sing-box check -c "$tmp" 2>&1 | head -n 10 || true
    rm -f "$tmp"
    err "配置合并失败,未修改原文件"
    return 1
}

# -----------------------
install_cloudflared() {
    if [ -x "$CF_BIN" ] && ! $FORCE; then
        info "已安装 cloudflared: $("$CF_BIN" --version 2>/dev/null | head -n1 || echo unknown)"
        return 0
    fi

    local mirror="${CF_MIRROR:-${SB_MIRROR:-}}"
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    local tmp="/tmp/cloudflared.$$"

    info "下载 cloudflared (linux-${ARCH})"
    info "下载地址: ${mirror}${url}"
    if ! curl -fL --connect-timeout 15 --max-time 300 -o "$tmp" "${mirror}${url}"; then
        warn "curl 下载失败,改用 wget 重试"
        wget -qO "$tmp" "${mirror}${url}" || {
            err "cloudflared 下载失败"
            err "可加镜像重试: CF_MIRROR=https://ghfast.top/ bash $0"
            exit 1
        }
    fi

    chmod +x "$tmp"
    if ! "$tmp" --version >/dev/null 2>&1; then
        err "下载的二进制无法运行,可能架构不匹配"
        rm -f "$tmp"
        exit 1
    fi
    mv -f "$tmp" "$CF_BIN"
    chmod +x "$CF_BIN"
    info "cloudflared 安装完成: $("$CF_BIN" --version 2>/dev/null | head -n1)"
}

# -----------------------
# 启动包装脚本:绕开 openrc / systemd 对 command_args 的引号与重定向解析差异
write_wrapper() {
    cat > "$CF_WRAPPER" <<WRAPPER
#!/bin/sh
exec $CF_BIN tunnel --no-autoupdate --url http://127.0.0.1:$CFTUN_WS_PORT >> $CF_LOG 2>&1
WRAPPER
    chmod +x "$CF_WRAPPER"
}

setup_service() {
    info "配置 cloudflared 服务..."
    mkdir -p "$(dirname "$CF_LOG")"
    touch "$CF_LOG"
    write_wrapper

    if [ "$OS" = "alpine" ]; then
        cat > "/etc/init.d/$SVC_NAME" <<OPENRC
#!/sbin/openrc-run

name="$SVC_NAME"
description="Cloudflare Argo Quick Tunnel"
command="$CF_WRAPPER"
command_background="yes"
pidfile="/run/$SVC_NAME.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
}
OPENRC
        chmod +x "/etc/init.d/$SVC_NAME"
        svc_enable || true
        svc_restart || { warn "服务启动失败,查看 $CF_LOG"; }
    else
        cat > "/etc/systemd/system/$SVC_NAME.service" <<SYSTEMD
[Unit]
Description=Cloudflare Argo Quick Tunnel
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CF_WRAPPER
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        svc_enable || true
        svc_restart || { warn "服务启动失败,查看 $CF_LOG"; }
    fi
}

# 从日志里抓最新的 trycloudflare 域名
# 优先匹配带连字符的隧道域名(形如 word-word-word.trycloudflare.com),
# 避免误抓日志里出现的 api.trycloudflare.com 这类固定子域
extract_host() {
    local h=""
    h=$(grep -oE 'https://[A-Za-z0-9]+(-[A-Za-z0-9]+)+\.trycloudflare\.com' "$1" 2>/dev/null \
        | tail -n1 | sed 's|https://||' || true)
    if [ -z "$h" ]; then
        h=$(grep -oE 'https://[A-Za-z0-9._-]+\.trycloudflare\.com' "$1" 2>/dev/null \
            | grep -vE '//(api|admin|www|dash|developers)\.' \
            | tail -n1 | sed 's|https://||' || true)
    fi
    printf '%s' "$h"
}

wait_host() {
    local i h=""
    for i in $(seq 1 30); do
        h=$(extract_host "$CF_LOG")
        if [ -n "$h" ]; then
            printf '%s' "$h"
            return 0
        fi
        sleep 2
    done
    return 1
}

# 临时隧道有速率限制,失败时给出明确原因
start_tunnel() {
    info "启动 Argo 临时隧道,等待分配域名..."
    : > "$CF_LOG"
    svc_restart >/dev/null 2>&1 || true

    local host
    if ! host=$(wait_host); then
        err "未能在 60 秒内拿到 trycloudflare 域名"
        echo "----- cloudflared 日志尾部 -----"
        tail -n 20 "$CF_LOG" 2>/dev/null || true
        echo "-------------------------------"
        err "常见原因: 出口 IP 被 Cloudflare 限流、DNS 不通、cloudflared 架构不匹配"
        err "重试: cftun -> 2) 重新拉起隧道"
        return 1
    fi

    CFTUN_HOST="$host"
    save_cache
    info "临时域名: $CFTUN_HOST"
    return 0
}

write_uri() {
    [ -n "$CFTUN_HOST" ] || return 1
    {
        echo "=== Argo 临时隧道 (VLESS + WS + TLS) ==="
        echo "域名: $CFTUN_HOST"
        echo "ws 端口(本地,勿外传): 127.0.0.1:$CFTUN_WS_PORT$CFTUN_WS_PATH"
        echo ""
        build_uri "$CFTUN_HOST" "$CFTUN_UUID" "$CFTUN_WS_PATH" "$CFTUN_NAME"
        echo ""
        echo "提示: cloudflared 重启后域名会变,执行 cftun -> 2) 重新拉起隧道 刷新本文件。"
    } > "$URI_FILE"
    chmod 600 "$URI_FILE"
    sync_uris
}

# -----------------------
install_cftun_cmd() {
    info "安装管理命令: $CFTUN_CMD"
    cat > "$CFTUN_CMD" <<'CFTUN_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

SB_DIR="/etc/sing-box"
CONFIG_PATH="$SB_DIR/config.json"
CACHE_FILE="$SB_DIR/.cftun_cache"
URI_FILE="$SB_DIR/cftun.txt"
CF_BIN="/usr/local/bin/cloudflared"
CF_WRAPPER="/usr/local/bin/cftun-run"
CF_LOG="/var/log/cloudflared-argo.log"
SB_URIS="$SB_DIR/uris.txt"
MARK_B="# >>> argo-cftun >>>"
MARK_E="# <<< argo-cftun <<<"
WS_TAG="cftun-ws-in"
SVC_NAME="cloudflared-argo"

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"; ID_LIKE="${ID_LIKE:-}"
    else
        ID=""; ID_LIKE=""
    fi
    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Eqi "debian|ubuntu"; then OS="debian"
    else OS="other"; fi
}
detect_os

svc_start()   { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" start   2>/dev/null || systemctl start "$SVC_NAME"; }
svc_stop()    { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" stop    2>/dev/null || systemctl stop "$SVC_NAME"; }
svc_restart() { [ "$OS" = "alpine" ] && rc-service "$SVC_NAME" restart 2>/dev/null || systemctl restart "$SVC_NAME"; }
svc_disable() { [ "$OS" = "alpine" ] && rc-update del "$SVC_NAME" default 2>/dev/null || systemctl disable "$SVC_NAME" 2>/dev/null; }

load_cache() {
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    CFTUN_UUID="${CFTUN_UUID:-}"
    CFTUN_WS_PORT="${CFTUN_WS_PORT:-}"
    CFTUN_WS_PATH="${CFTUN_WS_PATH:-}"
    CFTUN_HOST="${CFTUN_HOST:-}"
    CFTUN_NAME="${CFTUN_NAME:-argo}"
}

save_cache() {
    cat > "$CACHE_FILE" <<CACHEEOF
CFTUN_UUID=$CFTUN_UUID
CFTUN_WS_PORT=$CFTUN_WS_PORT
CFTUN_WS_PATH=$CFTUN_WS_PATH
CFTUN_HOST=$CFTUN_HOST
CFTUN_NAME=$CFTUN_NAME
CACHEEOF
    chmod 600 "$CACHE_FILE"
}

url_encode_path() { printf '%s' "$1" | sed 's|/|%2F|g'; }

build_uri() {
    local host="$1" uuid="$2" path="$3" name="$4" ep
    ep=$(url_encode_path "$path")
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=ws&host=%s&path=%s#%s' \
        "$uuid" "$host" "$host" "$host" "$ep" "$name"
}

strip_argo_block() {
    local f="$1"
    [ -f "$f" ] || return 0
    awk -v b="$MARK_B" -v e="$MARK_E" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip == 1 { next }
        { print }
    ' "$f" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

append_argo_block() {
    local f="$1"
    [ -n "${CFTUN_HOST:-}" ] || return 0
    {
        echo ""
        echo "$MARK_B"
        echo "=== Argo 临时隧道 (VLESS + WS + TLS) ==="
        echo "域名: $CFTUN_HOST"
        build_uri "$CFTUN_HOST" "$CFTUN_UUID" "$CFTUN_WS_PATH" "$CFTUN_NAME"
        echo ""
        echo "$MARK_E"
    } >> "$f"
}

sync_uris() {
    [ -f "$SB_URIS" ] || return 0
    strip_argo_block "$SB_URIS"
    append_argo_block "$SB_URIS"
    return 0
}

get_host() {
    local h=""
    h=$(grep -oE 'https://[A-Za-z0-9]+(-[A-Za-z0-9]+)+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
        | tail -n1 | sed 's|https://||' || true)
    if [ -z "$h" ]; then
        h=$(grep -oE 'https://[A-Za-z0-9._-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
            | grep -vE '//(api|admin|www|dash|developers)\.' \
            | tail -n1 | sed 's|https://||' || true)
    fi
    printf '%s' "$h"
}

refresh_host() {
    local h
    h=$(get_host)
    if [ -n "$h" ] && [ "$h" != "$CFTUN_HOST" ]; then
        CFTUN_HOST="$h"
        save_cache
        info "域名已更新: $CFTUN_HOST"
    fi
}

write_uri() {
    [ -n "$CFTUN_HOST" ] || { err "尚无可用域名,请先重新拉起隧道"; return 1; }
    {
        echo "=== Argo 临时隧道 (VLESS + WS + TLS) ==="
        echo "域名: $CFTUN_HOST"
        echo "ws 端口(本地,勿外传): 127.0.0.1:$CFTUN_WS_PORT$CFTUN_WS_PATH"
        echo ""
        build_uri "$CFTUN_HOST" "$CFTUN_UUID" "$CFTUN_WS_PATH" "$CFTUN_NAME"
        echo ""
        echo "提示: cloudflared 重启后域名会变,执行 cftun -> 2) 重新拉起隧道 刷新本文件。"
    } > "$URI_FILE"
    chmod 600 "$URI_FILE"
    sync_uris
}

action_uri() {
    load_cache
    refresh_host
    if [ -z "$CFTUN_HOST" ]; then
        err "没有可用域名,先执行「2) 重新拉起隧道」"
        return 1
    fi
    write_uri
    echo ""
    cat "$URI_FILE"
}

action_rebuild() {
    load_cache
    info "重启隧道并重新分配域名(旧链接立即失效)..."
    : > "$CF_LOG"
    svc_restart >/dev/null 2>&1 || { err "服务重启失败,查看 $CF_LOG"; return 1; }

    local i h=""
    for i in $(seq 1 30); do
        h=$(get_host)
        if [ -n "$h" ]; then break; fi
        sleep 2
    done
    if [ -z "$h" ]; then
        err "未拿到新域名,日志尾部:"
        tail -n 15 "$CF_LOG" 2>/dev/null || true
        return 1
    fi
    CFTUN_HOST="$h"
    save_cache
    write_uri
    info "新域名: $CFTUN_HOST"
    echo ""
    cat "$URI_FILE"
}

action_status() {
    load_cache
    refresh_host
    echo ""
    echo "  二进制 : $([ -x "$CF_BIN" ] && "$CF_BIN" --version 2>/dev/null | head -n1 || echo 未安装)"
    echo "  服务   : $([ "$OS" = "alpine" ] && rc-service "$SVC_NAME" status 2>&1 | head -n1 || systemctl is-active "$SVC_NAME" 2>/dev/null || echo inactive)"
    echo "  域名   : ${CFTUN_HOST:-无}"
    echo "  本地 WS: 127.0.0.1:${CFTUN_WS_PORT:-?}${CFTUN_WS_PATH:-}"
    echo "  WS 入站: $(jq -r --arg t "$WS_TAG" '[.inbounds[] | select(.tag==$t)] | length' "$CONFIG_PATH" 2>/dev/null || echo 0) 条"
    echo "  日志   : $CF_LOG"
}

action_uninstall() {
    read -rp "确认移除 Argo 隧道与 WS 入站?(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消"
        return 0
    fi

    info "停止并移除服务..."
    svc_stop >/dev/null 2>&1 || true
    svc_disable || true
    rm -f "/etc/init.d/$SVC_NAME" "/etc/systemd/system/$SVC_NAME.service"
    [ "$OS" != "alpine" ] && systemctl daemon-reload 2>/dev/null || true

    info "移除 WS 入站..."
    if [ -f "$CONFIG_PATH" ]; then
        local tmp="$CONFIG_PATH.tmp.$$"
        jq --arg t "$WS_TAG" '.inbounds = [.inbounds[] | select(.tag != $t)]' "$CONFIG_PATH" > "$tmp" \
            && mv "$tmp" "$CONFIG_PATH"
        if [ "$OS" = "alpine" ]; then
            rc-service sing-box restart >/dev/null 2>&1 || true
        else
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
    fi

    strip_argo_block "$SB_URIS"
    rm -f "$CACHE_FILE" "$URI_FILE" "$CF_WRAPPER" 2>/dev/null || true
    rm -f "$0" 2>/dev/null || true
    info "已移除(cloudflared 二进制保留在 $CF_BIN,不需要可自行删除)"
    exit 0
}

# 非交互接口,供 sb 面板生成链接后追加 argo 段:
#   cftun --emit [/etc/sing-box/uris.txt]
if [ "${1:-}" = "--emit" ]; then
    load_cache
    refresh_host
    if [ -n "${2:-}" ]; then SB_URIS="$2"; fi
    strip_argo_block "$SB_URIS"
    append_argo_block "$SB_URIS"
    exit 0
fi

show_menu() {
    load_cache
    refresh_host
    echo ""
    echo "=========================="
    echo " Argo 临时隧道 (CFTun)"
    echo "=========================="
    echo "  域名: ${CFTUN_HOST:-未分配}"
    echo "  本地: 127.0.0.1:${CFTUN_WS_PORT:-?}${CFTUN_WS_PATH:-}"
    echo ""
    echo "1) 查看 / 刷新链接"
    echo "2) 重新拉起隧道(换新域名)"
    echo "3) 查看状态"
    echo "4) 停止隧道"
    echo "5) 启动隧道"
    echo "6) 重启 sing-box"
    echo "7) 卸载 Argo 隧道"
    echo "0) 退出"
    echo "=========================="
}

while true; do
    show_menu
    read -rp "请输入选项: " opt
    case "$opt" in
        1) action_uri ;;
        2) action_rebuild ;;
        3) action_status ;;
        4) svc_stop >/dev/null 2>&1 && info "已停止" || warn "停止失败" ;;
        5) svc_start >/dev/null 2>&1 && info "已启动" || warn "启动失败" ;;
        6)
            if [ "$OS" = "alpine" ]; then
                rc-service sing-box restart >/dev/null 2>&1 && info "sing-box 已重启" || warn "重启失败"
            else
                systemctl restart sing-box >/dev/null 2>&1 && info "sing-box 已重启" || warn "重启失败"
            fi
            ;;
        7) action_uninstall ;;
        0) exit 0 ;;
        *) warn "无效选项: $opt" ;;
    esac
    echo ""
done
CFTUN_EOF

    chmod +x "$CFTUN_CMD"
    info "✅ 管理命令已就绪,输入 cftun 打开面板"
}

# -----------------------
# 可选:给 sb 面板打一行钩子,使其每次生成链接后自动补回 argo 段
# 只加一行,不加时 sb 行为完全不变
hook_sb() {
    local sb="/usr/local/bin/sb"
    if [ ! -f "$sb" ]; then
        warn "未找到 sb 面板,跳过打钩"
        return 0
    fi
    if grep -q 'cftun-hook' "$sb" 2>/dev/null; then
        info "sb 已经打过钩子,无需重复"
        return 0
    fi

    cp "$sb" "$sb.bak.$(date +%s)"

    awk '
        /info "URI 已保存到/ && !done {
            print "    if [ -x /usr/local/bin/cftun ]; then /usr/local/bin/cftun --emit \"$URI_FILE\" >/dev/null 2>&1 || true; fi  # cftun-hook"
            done = 1
        }
        { print }
    ' "$sb" > "$sb.tmp" && mv "$sb.tmp" "$sb"

    if bash -n "$sb" 2>/dev/null && grep -q 'cftun-hook' "$sb"; then
        chmod +x "$sb"
        info "✅ sb 已打钩:生成链接后自动追加 argo 段"
    else
        err "注入失败或语法异常,已回滚"
        local bak
        bak=$(ls -1t "$sb".bak.* 2>/dev/null | head -n1 || true)
        if [ -n "$bak" ]; then
            cp "$bak" "$sb"
            chmod +x "$sb"
        fi
        return 1
    fi
}

unhook_sb() {
    local sb="/usr/local/bin/sb"
    [ -f "$sb" ] || { warn "未找到 sb 面板"; return 0; }
    if ! grep -q 'cftun-hook' "$sb" 2>/dev/null; then
        info "sb 当前没有 cftun 钩子"
        return 0
    fi
    cp "$sb" "$sb.bak.$(date +%s)"
    grep -v 'cftun-hook' "$sb" > "$sb.tmp" && mv "$sb.tmp" "$sb"
    chmod +x "$sb"
    info "✅ 已移除 sb 中的 cftun 钩子"
}

# -----------------------
do_uninstall() {
    check_singbox
    info "开始移除 Argo 隧道..."
    svc_stop >/dev/null 2>&1 || true
    svc_disable || true
    rm -f "/etc/init.d/$SVC_NAME" "/etc/systemd/system/$SVC_NAME.service"
    if [ "$OS" != "alpine" ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    remove_ws_inbound
    sb_restart
    strip_argo_block "$SB_URIS"
    rm -f "$CACHE_FILE" "$URI_FILE" "$CFTUN_CMD" "$CF_WRAPPER" 2>/dev/null || true
    info "已移除隧道服务、WS 入站与 cftun 命令"
    info "cloudflared 二进制仍在 $CF_BIN,不需要可执行: rm -f $CF_BIN"
}

if $DO_UNINSTALL; then
    do_uninstall
    exit 0
fi

if $UNHOOK_SB; then
    unhook_sb
    exit 0
fi

# -----------------------
# 主流程
check_singbox
install_cloudflared

load_cache
if $FORCE || [ -z "$CFTUN_UUID" ]; then
    CFTUN_UUID=$(rand_uuid)
fi
if $FORCE || [ -z "$CFTUN_WS_PORT" ]; then
    CFTUN_WS_PORT="${CFTUN_PORT:-$(rand_port)}"
fi
if $FORCE || [ -z "$CFTUN_WS_PATH" ]; then
    CFTUN_WS_PATH="/ws-$(openssl rand -hex 4 2>/dev/null || echo $RANDOM$RANDOM | head -c 8)"
fi
if [ -z "$CFTUN_NAME" ]; then
    _ip=$(curl -4 -s --max-time 5 https://ip.sb 2>/dev/null | tr -d '[:space:]' || true)
    case "$_ip" in
        *.*.*.*) CFTUN_NAME="argo-$(echo "$_ip" | cut -d. -f1)-$(echo "$_ip" | cut -d. -f2)" ;;
        *) CFTUN_NAME="argo" ;;
    esac
fi
save_cache

info "参数: uuid=$CFTUN_UUID 本地端口=$CFTUN_WS_PORT path=$CFTUN_WS_PATH 名称=$CFTUN_NAME"

info "合并 WS 入站到 $CONFIG_PATH"
merge_ws_inbound
sb_restart
info "sing-box 已重启"

setup_service
if ! start_tunnel; then
    err "隧道未就绪,但服务已注册。稍后可执行 cftun 重试。"
fi

write_uri || true
install_cftun_cmd
if $HOOK_SB; then hook_sb || true; fi

echo ""
echo "=================================================="
info "✅ Argo 临时隧道部署完成"
echo "=================================================="
if [ -n "${CFTUN_HOST:-}" ]; then cat "$URI_FILE"; fi
echo ""
echo "入口: 输入 cftun 打开管理面板(本脚本未改动 sb 面板)"
echo "注意: 临时隧道域名在 cloudflared 重启后会变化,届时 cftun -> 2 刷新"
echo "=================================================="
