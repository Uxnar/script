# SingBox · 一键部署

一套用于快速部署 sing-box 节点的 Shell 脚本集合，纯命令行交互，装完即用。

- 在线页面（含一键复制命令）：<https://uxnar.github.io/script/>
- 源码仓库：<https://github.com/Uxnar/script>

## 脚本清单

| 脚本 | 说明 | 协议 |
| --- | --- | --- |
| `install-singbox-lite.sh` | 基础版，适合常规环境 | SS / HY2 / TUIC / VLESS Reality |
| `install-singbox-lite-SAN.sh` | 在基础版之上为自签证书补上 SAN 字段 | 同上 |
| `install-singbox-SAN-v4v6.sh` | 推荐。含 SAN，支持 IPv4 / IPv6 双栈，已隐藏 SS 与 TUIC | HY2 / VLESS Reality |
| `zzj.sh` | 中转机脚本（基于 Realm 做端口转发） | 端口转发 |

> SAN = 证书的主题备用名称（Subject Alternative Name）。现在的 TLS 客户端已不再认 CN，缺 SAN 的证书会被判定为不合法，HY2 需要它。

## 快速开始

以 **root** 用户执行，系统需为 Alpine 3.20+ / Debian 11+ / Ubuntu 18+，内存 ≥ 100M、磁盘 ≥ 1G，且能正常访问 GitHub。

```bash
curl -fsSL https://raw.githubusercontent.com/Uxnar/script/main/install-singbox-SAN-v4v6.sh -o /tmp/install.sh && bash /tmp/install.sh
```

机器还没装 `curl` 或 `bash` 的话，直接复制网页上的完整命令，它会先自动补齐依赖。

安装过程按提示输入：节点名称 → 协议编号（如 `1 2`）→ 连接 IP / 域名（留空自动获取）→ 各协议端口（留空随机）。装完直接打印可用的客户端链接。

## 日常管理

装好后终端输入 `sb` 打开管理面板：

| 选项 | 作用 |
| --- | --- |
| 1 | 查看 / 重新生成协议链接 |
| 2 | 查看配置文件路径 |
| 3 | 编辑配置文件（保存后自动校验并重启） |
| 4+ | 重置各协议端口、启停 / 重启服务、更新 sing-box、IPv6 节点开关、生成线路机脚本、卸载 |

常用文件：

```
/etc/sing-box/config.json      主配置
/etc/sing-box/uris.txt         客户端链接
/etc/sing-box/.config_cache    端口、密码、UUID 等参数缓存
/etc/sing-box/certs/           HY2 自签证书
```

服务控制（Alpine 走 OpenRC，其余走 systemd）：

```bash
systemctl restart sing-box      # Alpine: rc-service sing-box restart
journalctl -u sing-box -f       # Alpine: tail -f /var/log/sing-box.log
```

## 双栈版（v4v6）说明

**协议**：只保留 Hysteria2（UDP）与 VLESS Reality（TCP），SS 与 TUIC 已从选项中移除。

**IPv6 逻辑**：依赖装完后脚本会自动探测 IPv6。只有当你**连接地址留空**（即使用默认出口 IP）且探测到公网 IPv6 时，才会询问是否一并创建 v6 节点。

- v6 节点**复用同一个入站、同一个端口**（`listen: "::"` 本身就是双栈），只在链接层面多生成一份，节点名带 `-v6` 后缀，地址按规范用方括号包裹。
- 探测走真实外部回显（`curl -6 https://ip.sb` 优先，失败再试其它回显站），**不做地址格式推断**；能通就直接用，不问地址是原生还是隧道转发来的。
- 手动填写连接 IP 或 DDNS 域名时，不会触发 v6 询问。
- 事后可用 `sb` 面板里的「IPv6 节点开关 / 地址」随时开启、修改或关闭。

**下载慢或失败**：设置镜像后再执行，线路机脚本同样支持。

```bash
SB_MIRROR=https://ghfast.top/ bash install-singbox-SAN-v4v6.sh
```

## 中转机（zzj.sh）

基于 Realm 的端口转发管理，装完输入 `zzj` 打开菜单：添加转发规则（本机监听端口 → 落地机 vless 地址）、查看规则、删除规则、清空、卸载。配置文件是 `/etc/realm/config.toml`。

## 协议与端口

| 协议 | 传输层 | 认证 |
| --- | --- | --- |
| Hysteria2 | UDP (QUIC) | 密码 + TLS(alpn h3) + 自签证书 |
| VLESS Reality | TCP | UUID + xtls-rprx-vision + Reality |

HY2 走 UDP、Reality 走 TCP，两者端口空间独立，**想用同一个端口号时在两个提示里填相同的数字即可**。

## 卸载

```bash
sb   # 选择「卸载 sing-box」
```

会停止并移除服务、配置、证书、链接文件以及 `sb` 命令本身。
