#!/bin/bash
# zzj.sh - Realm 中转管理 (TCP + UDP)
# 相对纯 TCP 版的主要变化:
#   1) [network] 段显式开启 use_udp, HY2 等 UDP 协议可过中转
#   2) 每条规则可选 TCP / UDP / 双栈(endpoint 级 network 覆盖全局)
#   3) 落地链接支持 vless:// 与 hy2:// 两种格式
#   4) 面板顶部显示版本号与服务/UDP 状态
#   5) 新增强制更新脚本(从仓库拉取覆盖自身)
#   6) 新增端口占用校验,TCP 与 UDP 分别计算

SCRIPT_VERSION="v2611202218"

CONFIG="/etc/realm/config.toml"
ZZJ_BIN="/usr/local/bin/zzj"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
REPO_RAW="${SB_MIRROR:-}https://raw.githubusercontent.com/Uxnar/script/main/zzj.sh"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# ==========================================
# 1. 环境初始化与 Realm 安装 (仅首次执行)
# ==========================================
if [ ! -f "/usr/local/bin/realm" ]; then
    echo "初始化环境与安装核心组件..."
    mkdir -p /etc/realm
    touch "$CONFIG"

    if [ -f /etc/alpine-release ]; then
        apk add --no-cache bash curl wget tar
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-musl.tar.gz"
    else
        URL="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    fi

    wget -O realm.tar.gz "$URL"
    tar -xvf realm.tar.gz
    chmod +x realm
    mv realm /usr/local/bin/
    rm -f realm.tar.gz

    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/realm << 'EOF'
#!/sbin/openrc-run
name="realm"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.toml"
command_background=true
pidfile="/run/realm.pid"
EOF
        chmod +x /etc/init.d/realm
        rc-update add realm default
    else
        cat > /etc/systemd/system/realm.service << 'EOF'
[Unit]
Description=Realm Port Forwarding
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable realm
    fi
fi

# ==========================================
# 2. 注册快捷指令
# ==========================================
register_zzj() {
    if [ -s "$SELF" ] && grep -q "Realm 中转管理" "$SELF" 2>/dev/null; then
        if [ "$SELF" != "$ZZJ_BIN" ]; then
            cp -f "$SELF" "$ZZJ_BIN" || return 1
        fi
        chmod +x "$ZZJ_BIN" && return 0
    fi
    # 兜底:从仓库拉取(支持镜像前缀)
    if curl -fsSL --connect-timeout 10 --max-time 60 "$REPO_RAW" -o "$ZZJ_BIN" 2>/dev/null && [ -s "$ZZJ_BIN" ]; then
        chmod +x "$ZZJ_BIN" && return 0
    fi
    return 1
}

if [ ! -s "$ZZJ_BIN" ] || [ ! -x "$ZZJ_BIN" ]; then
    rm -f "$ZZJ_BIN"
    if register_zzj; then
        echo "✓ 快捷指令已注册: 终端输入 zzj 打开面板"
        if ! command -v zzj >/dev/null 2>&1; then
            echo "! 当前 shell 的 PATH 不含 /usr/local/bin,先执行 hash -r,仍不行则:"
            echo "  export PATH=\$PATH:/usr/local/bin"
        fi
    else
        echo "! 快捷指令注册失败,请手动执行:"
        echo "  cp $SELF /usr/local/bin/zzj && chmod +x /usr/local/bin/zzj"
    fi
fi

# ==========================================
# 3. 配置与状态
# ==========================================
ensure_network() {
    if ! grep -q '^\[network\]' "$CONFIG" 2>/dev/null; then
        {
            echo "[network]"
            echo "no_tcp = false"
            echo "use_udp = true"
            echo "udp_timeout = 60"
            echo ""
            cat "$CONFIG" 2>/dev/null
        } > "$CONFIG.tmp" && mv -f "$CONFIG.tmp" "$CONFIG"
    fi
}

srv_alive() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet realm
    else
        rc-service realm status >/dev/null 2>&1
    fi
}

do_restart() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart realm
    else
        rc-service realm restart
    fi
}

# 重启后校验;若因 UDP 配置启动失败,逐级回退
restart_srv() {
    do_restart >/dev/null 2>&1
    sleep 1
    if srv_alive; then
        return 0
    fi

    # 回退 1: 关闭全局 use_udp(只改第一处,即 [network] 段)
    if grep -q '^use_udp = true' "$CONFIG" 2>/dev/null; then
        warn "realm 启动失败,当前二进制可能不支持 UDP,尝试关闭全局 UDP"
        awk 'BEGIN{d=0} /^use_udp = true/ && d==0 {print "use_udp = false"; d=1; next} {print}' "$CONFIG" > "$CONFIG.tmp" \
            && mv -f "$CONFIG.tmp" "$CONFIG"
        do_restart >/dev/null 2>&1
        sleep 1
        if srv_alive; then
            warn "已全局关闭 UDP 并启动成功;HY2 需换带 udp feature 的 realm"
            return 0
        fi
    fi

    # 回退 2: 移除 endpoint 级 network 覆盖
    if grep -q '^\[endpoints\.network\]' "$CONFIG" 2>/dev/null; then
        warn "endpoint 级 network 覆盖不被支持,已全部移除"
        awk '
            /^\[endpoints\.network\]/ { skip = 1; next }
            skip && /^\[/ { skip = 0 }
            !skip { print }
        ' "$CONFIG" > "$CONFIG.tmp" && cat -s "$CONFIG.tmp" > "$CONFIG" && rm -f "$CONFIG.tmp"
        do_restart >/dev/null 2>&1
        sleep 1
        if srv_alive; then
            warn "已回退为全局配置并启动成功(单协议规则失效,统一走双栈)"
            return 0
        fi
    fi

    err "realm 启动失败,请检查 $CONFIG"
    return 1
}

get_local_ip() {
    curl -s4 api.ipify.org || curl -s4 ifconfig.me
}

# ==========================================
# 4. 核心功能
# ==========================================

# 读取某个端口已登记的模式(both/tcp/udp);旧配置无 # MODE 记录时按 tcp 处理
existing_modes() {
    local p="$1" modes
    modes=$(awk -v p="$p" '
        /^# PORT: / { cur = $3 }
        /^# MODE: / && cur == p { print $3 }
    ' "$CONFIG" 2>/dev/null)

    if [ -z "$modes" ] && grep -q "listen = \"0.0.0.0:$p\"" "$CONFIG" 2>/dev/null; then
        modes="tcp"
    fi

    printf '%s\n' $modes
}

# 检查端口与目标传输类型是否冲突,有冲突时输出原因并返回 0
# TCP 与 UDP 各自独立计数: 同端口已有 tcp 规则时,仍可再加 udp 规则
port_conflict_reason() {
    local port="$1" need="$2" modes m
    local tcp_busy=0 udp_busy=0

    modes=$(existing_modes "$port")
    [ -z "$modes" ] && return 1

    for m in $modes; do
        case "$m" in
            both) tcp_busy=1; udp_busy=1 ;;
            tcp)  tcp_busy=1 ;;
            udp)  udp_busy=1 ;;
        esac
    done

    case "$need" in
        both)
            if [ "$tcp_busy" = 1 ] && [ "$udp_busy" = 1 ]; then
                echo "该端口的 TCP 与 UDP 都已被占用"
                return 0
            elif [ "$tcp_busy" = 1 ]; then
                echo "该端口的 TCP 已被占用（UDP 仍空闲,可选“仅 UDP”）"
                return 0
            elif [ "$udp_busy" = 1 ]; then
                echo "该端口的 UDP 已被占用（TCP 仍空闲,可选“仅 TCP”）"
                return 0
            fi
            ;;
        tcp)
            if [ "$tcp_busy" = 1 ]; then
                echo "该端口的 TCP 已被占用"
                return 0
            fi
            ;;
        udp)
            if [ "$udp_busy" = 1 ]; then
                echo "该端口的 UDP 已被占用"
                return 0
            fi
            ;;
    esac

    return 1
}

add_rule() {
    read -p "中转机监听端口: " l_port
    if ! [[ "$l_port" =~ ^[0-9]+$ ]] || [ "$l_port" -lt 1 ] || [ "$l_port" -gt 65535 ]; then
        err "端口无效"
        return 1
    fi

    echo "传输类型:"
    echo "  1) TCP + UDP（默认，同一端口两者都转）"
    echo "  2) 仅 TCP（只转 VLESS）"
    echo "  3) 仅 UDP（只转 HY2）"
    read -p "请选择 [1]: " t_mode
    case "${t_mode:-1}" in
        2) t_type="tcp" ;;
        3) t_type="udp" ;;
        *) t_type="both" ;;
    esac

    local conflict
    conflict="$(port_conflict_reason "$l_port" "$t_type")"
    if [ -n "$conflict" ]; then
        err "端口 $l_port 不可用: $conflict"
        return 1
    fi

    read -p "落地机链接 (vless:// 或 hy2://): " link

    if [[ "$link" =~ ^([a-z0-9]+)://([^@]+)@([^:/]+):([0-9]+)(.*)$ ]]; then
        local proto="${BASH_REMATCH[1]}"
        local user="${BASH_REMATCH[2]}"
        local r_host="${BASH_REMATCH[3]}"
        local r_port="${BASH_REMATCH[4]}"
        local rest="${BASH_REMATCH[5]}"

        local local_ip
        local_ip="$(get_local_ip)"
        if [ -z "$local_ip" ]; then
            err "获取公网 IP 失败,请手动检查网络"
            return 1
        fi

        ensure_network

        local new_link="${proto}://${user}@${local_ip}:${l_port}${rest}"

        cat >> "$CONFIG" <<EOL

# PORT: $l_port
# MODE: $t_type
# LINK: $new_link
[[endpoints]]
listen = "0.0.0.0:$l_port"
remote = "${r_host}:${r_port}"
EOL

        # 单协议规则用 endpoint 级 network 覆盖全局双栈
        case "$t_type" in
            tcp)
                cat >> "$CONFIG" <<EOL
[endpoints.network]
no_tcp = false
use_udp = false
EOL
                ;;
            udp)
                cat >> "$CONFIG" <<EOL
[endpoints.network]
no_tcp = true
use_udp = true
EOL
                ;;
        esac

        if restart_srv; then
            echo ""
            info "添加成功 (${proto} → ${r_host}:${r_port}, ${t_type})"
            if [ "$t_type" = "udp" ]; then
                info "HY2 走 UDP,需在中转机放行 UDP ${l_port}"
            fi
            echo -e "中转链接: \033[32m${new_link}\033[0m"
        fi
    else
        err "无法识别链接,需为 vless:// 或 hy2:// 开头"
    fi
}

list_rules() {
    echo "当前配置的中转链接:"
    if grep -q "^# LINK:" "$CONFIG" 2>/dev/null; then
        awk '
            /^# PORT: / { port = $3 }
            /^# MODE: / { mode = $3 }
            /^# LINK: / { sub(/^# LINK: /, ""); printf "  %-6s %-5s %s\n", port, mode, $0 }
        ' "$CONFIG"
    else
        echo "  暂无规则"
    fi
    echo ""
}

delete_rule() {
    read -p "请输入要删除的中转机监听端口: " del_port

    if ! grep -q "^# PORT: $del_port$" "$CONFIG" 2>/dev/null; then
        err "未找到该端口的规则"
        return 1
    fi

    # 按块删除: 从 "# PORT: 端口" 起到下一个空行前的全部内容
    awk -v p="# PORT: $del_port" '
        $0 == p { skip = 1; next }
        skip && $0 == "" { skip = 0; print ""; next }
        skip { next }
        { print }
    ' "$CONFIG" > "$CONFIG.tmp" && cat -s "$CONFIG.tmp" > "$CONFIG" && rm -f "$CONFIG.tmp"

    restart_srv >/dev/null
    info "端口 $del_port 的转发规则已删除并重启服务"
}

clear_rules() {
    # 只清 endpoints 与注释,保留开头的 [network] 段
    sed -i '/^\[\[endpoints\]\]/,$d' "$CONFIG"
    sed -i '/^# PORT:/d;/^# MODE:/d;/^# LINK:/d' "$CONFIG"
    restart_srv >/dev/null
    info "所有规则已清空,[network] 配置保留"
}

# 强制更新:不比较版本,直接覆盖
update_self() {
    info "当前版本: $SCRIPT_VERSION"
    local tmp="/tmp/zzj.sh.new.$$"
    rm -f "$tmp"

    if ! curl -fsSL --connect-timeout 10 --max-time 90 "$REPO_RAW" -o "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        err "下载失败,请检查网络或设置镜像: SB_MIRROR=https://ghfast.top/"
        rm -f "$tmp"
        return 1
    fi

    if ! grep -q "Realm 中转管理" "$tmp" 2>/dev/null; then
        err "下载内容校验失败,已放弃覆盖"
        rm -f "$tmp"
        return 1
    fi

    local new_ver
    new_ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    [ -z "$new_ver" ] && new_ver="未知"

    install -m 755 "$tmp" "$ZZJ_BIN" || { err "写入 $ZZJ_BIN 失败"; rm -f "$tmp"; return 1; }
    if [ "$SELF" != "$ZZJ_BIN" ] && [ -d "$(dirname "$SELF")" ] && [ -w "$(dirname "$SELF")" ]; then
        install -m 755 "$tmp" "$SELF" 2>/dev/null || true
    fi
    rm -f "$tmp"

    info "已更新: $SCRIPT_VERSION → $new_ver"
    info "正在重启面板..."
    sleep 1
    exec "$ZZJ_BIN"
}

uninstall_srv() {
    read -p "确定要卸载 Realm 并清空所有配置吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        echo "正在停止服务并取消开机自启..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop realm
            systemctl disable realm
            rm -f /etc/systemd/system/realm.service
            systemctl daemon-reload
        else
            rc-service realm stop
            rc-update del realm default
            rm -f /etc/init.d/realm
        fi

        echo "清理核心文件及配置..."
        rm -rf /etc/realm
        rm -f /usr/local/bin/realm
        rm -f "$ZZJ_BIN"

        echo "卸载完成！"
        exit 0
    fi
}

# ==========================================
# 5. CLI 交互菜单
# ==========================================
while true; do
    clear
    srv_txt="未运行"
    srv_alive && srv_txt="运行中"
    if grep -q '^use_udp = true' "$CONFIG" 2>/dev/null; then
        udp_txt="UDP 开"
    else
        udp_txt="UDP 关"
    fi

    echo "================================"
    echo "    Realm 中转管理  $SCRIPT_VERSION"
    echo "    realm: $srv_txt · $udp_txt"
    echo "================================"
    echo "1. 添加转发规则"
    echo "2. 查看当前规则"
    echo "3. 删除指定规则"
    echo "4. 清空所有规则"
    echo "5. 更新脚本（强制）"
    echo "6. 卸载服务"
    echo "0. 退出"
    echo "================================"
    read -p "请选择: " num
    echo ""

    case "$num" in
        1) add_rule ;;
        2) list_rules ;;
        3) delete_rule ;;
        4) clear_rules ;;
        5) update_self ;;
        6) uninstall_srv ;;
        0) exit 0 ;;
        *) echo "输入错误" ;;
    esac

    echo ""
    read -p "按回车键继续..."
done
