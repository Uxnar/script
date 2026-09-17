#!/bin/bash

CONFIG="/etc/realm/config.toml"

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
if [ ! -f "/usr/local/bin/zzj" ]; then
    curl -fsSL https://raw.githubusercontent.com/QsSama-W/sbox/refs/heads/main/zzj.sh -o /usr/local/bin/zzj
    chmod +x /usr/local/bin/zzj
fi

# ==========================================
# 3. 核心功能函数
# ==========================================
restart_srv() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart realm
    else
        rc-service realm restart
    fi
}

get_local_ip() {
    # 自动获取当前服务器的公网 IP
    curl -s4 api.ipify.org || curl -s4 ifconfig.me
}

add_rule() {
    read -p "中转机监听端口: " l_port
    read -p "请输入落地机 vless 链接: " vless_link
    
    # 正则提取 vless 链接信息
    if [[ "$vless_link" =~ ^vless://([^@]+)@([^:]+):([0-9]+)(.*)$ ]]; then
        uuid="${BASH_REMATCH[1]}"
        r_ip="${BASH_REMATCH[2]}"
        r_port="${BASH_REMATCH[3]}"
        rest="${BASH_REMATCH[4]}"
        
        local_ip=$(get_local_ip)
        new_vless="vless://${uuid}@${local_ip}:${l_port}${rest}"
        
        # 使用注释记录链接信息，方便后续读取和定向删除
        cat >> "$CONFIG" <<EOL

# PORT: $l_port
# LINK: $new_vless
[[endpoints]]
listen = "0.0.0.0:$l_port"
remote = "${r_ip}:${r_port}"
EOL
        restart_srv
        echo -e "\n添加成功并重启服务！"
        echo -e "中转链接: \033[32m$new_vless\033[0m"
    else
        echo "无效的 vless 链接，请检查格式！"
    fi
}

list_rules() {
    echo "当前配置的中转链接："
    # 直接提取配置里的 LINK 注释展示
    grep "# LINK:" "$CONFIG" | sed 's/# LINK: //' || echo "暂无规则"
    echo ""
}

delete_rule() {
    read -p "请输入要删除的中转机监听端口: " del_port
    # 定位对应端口的配置起始行
    line_num=$(grep -n "# PORT: $del_port" "$CONFIG" | head -n 1 | cut -d: -f1)
    
    if [ -n "$line_num" ]; then
        # 删除包含注释和配置在内的连续5行
        sed -i "$line_num,$((line_num+4))d" "$CONFIG"
        # 清理可能产生的多余空行
        sed -i '/^$/N;/^\n$/D' "$CONFIG"
        restart_srv
        echo "端口 $del_port 的转发规则已删除并重启服务！"
    else
        echo "未找到该端口的规则！"
    fi
}

clear_rules() {
    > "$CONFIG"
    restart_srv
    echo "所有规则已清空并重启服务！"
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
        rm -f /usr/local/bin/zzj
        
        echo "卸载完成！"
        exit 0
    fi
}

# ==========================================
# 4. CLI 交互菜单
# ==========================================
while true; do
    clear
    echo "========================"
    echo "      Realm 中转管理     "
    echo "========================"
    echo "1. 添加转发规则"
    echo "2. 查看当前规则"
    echo "3. 删除指定规则"
    echo "4. 清空所有规则"
    echo "5. 卸载服务"
    echo "0. 退出"
    echo "========================"
    read -p "请选择: " num
    echo ""
    
    case "$num" in
        1) add_rule ;;
        2) list_rules ;;
        3) delete_rule ;;
        4) clear_rules ;;
        5) uninstall_srv ;;
        0) exit 0 ;;
        *) echo "输入错误" ;;
    esac
    
    echo ""
    read -p "按回车键继续..."
done