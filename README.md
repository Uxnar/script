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
| `install-singbox-auto.sh` | 半无人值守版。端口走命令行参数，全程零输入，适合批量部署 | 同上 |
| `install-cftun.sh` | 增量版。给已装好的 sing-box 追加 Argo 临时隧道，不重装、不动原有节点 | VLESS + WS / Cloudflare Tunnel |
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

## 自动版（install-singbox-auto.sh）

由双栈版改造的**半无人值守**版本，适合批量、脚本化部署。差别如下：

| 环节 | 双栈版 | 自动版 |
| --- | --- | --- |
| 端口 | 逐个交互输入 | 命令行参数传入，省略才交互问一次 |
| 协议 | 交互选择 | 固定 VLESS Reality + Hysteria2，共用同一端口（TCP / UDP 套接字不同，不冲突） |
| IPv6 | 检测到后询问 | 检测到公网 IPv6 直接开启 |
| 节点名 | 交互输入 | 自动生成 `auto-<IPv4前两段>`，v6 加 `-v6` 后缀 |
| 已装旧版 | 询问是否重装 | 自动卸载后重装 |

```bash
curl -fsSL https://raw.githubusercontent.com/Uxnar/script/main/install-singbox-auto.sh -o /tmp/install.sh && bash /tmp/install.sh 8443
```

带端口号执行即**全程零输入**；省略端口则只问这一次。等价写法 `bash /tmp/install.sh --port 8443`。

可用环境变量覆盖默认值：

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `CUSTOM_IP` | 指定连接 IP / DDNS 域名 | 自动探测公网 IPv4 |
| `REALITY_SNI` | Reality 的 SNI | `addons.mozilla.org` |
| `NODE_NAME` | 强制指定节点名 | 自动生成 |
| `ENABLE_V6` | 强制关闭 IPv6 节点 | 检测到就开 |
| `V6_ADDR` | 指定 IPv6 节点地址 | 探测结果 |

因为两个协议复用同一端口，**防火墙需要同时放行 TCP 和 UDP**：

```bash
ufw allow 8443/tcp && ufw allow 8443/udp
```

## Argo 临时隧道（install-cftun.sh）

给**已经装好 sing-box** 的机器追加一条能走 CDN 的节点，不重装、不覆盖原有 Reality / HY2。

原理：在本机开一个只监听 `127.0.0.1` 的 VLESS+WS 入站，用 `cloudflared` 的临时隧道（`*.trycloudflare.com`）把它暴露到公网。源站不用开任何入站端口，也不需要公网 IP 或独立的 443。

```bash
curl -fsSL https://raw.githubusercontent.com/Uxnar/script/main/install-cftun.sh -o /tmp/install.sh && bash /tmp/install.sh
```

拉下来还是旧版本的话，给 URL 加个随机参数强制回源（CDN 会按完整 URL 缓存）：

```bash
curl -fsSL "https://raw.githubusercontent.com/Uxnar/script/main/install-cftun.sh?v=$(date +%s)" -o /tmp/install.sh && bash /tmp/install.sh
```

装完直接打印 `vless://` 链接，之后输入 `cftun` 打开管理面板（顶部显示脚本版本、cloudflared 本地与远端版本）：

| 选项 | 作用 |
| --- | --- |
| 1 | 查看 / 刷新链接 |
| 2 | 重新拉起隧道（换新域名） |
| 3 | 查看状态（含脚本与 cloudflared 的本地 / 远端版本对比） |
| 4 / 5 | 停止 / 启动隧道 |
| 6 | 重启 sing-box |
| 7 | 强制更新 cloudflared（拉官方最新版，重启隧道，域名会变） |
| 8 | 强制更新脚本（只替换 `cftun` 命令与链接，不重启隧道，域名不变） |
| 9 | 卸载 Argo 隧道 |

远端版本查询结果缓存 10 分钟，避免每次进面板都联网。断网时显示「未知」，不影响其它功能。

**uris.txt 的行为**：脚本在 `/etc/sing-box/uris.txt` 末尾维护一个带标记的 argo 段（`# >>> argo-cftun >>>` 到 `# <<< argo-cftun <<<`），刷新时只替换这一段，上方的直连链接原样保留，刷多少次也只会有一份。

但 sb 面板生成链接时是整份覆盖这个文件，argo 段会被冲掉。需要它一直在的话，装完再执行一次：

```bash
bash /tmp/install.sh --hook-sb
```

这会给 sb 的 `generate_uris` 加一行 `cftun --emit`（带 `# cftun-hook` 标记，幂等，语法校验失败自动回滚）。`--unhook-sb` 可撤销，不加则完全不碰 sb。

**注意**

- 只能承载 HTTP / WebSocket。**Reality、HY2、TUIC 套不上 CDN**，所以这条隧道是独立入站，不是把原节点转成 CDN 节点。
- 临时域名在隧道每次重启后都会变，链接随之失效，用 `cftun` 选 2 重新生成。
- 重装 sing-box 会重写 `config.json`，WS 入站会丢，重跑一次本脚本即可。

卸载（不影响其它节点）：

```bash
bash /tmp/install.sh --uninstall
```

## 中转机（zzj.sh）

基于 Realm 的端口转发管理，装完输入 `zzj` 打开菜单：添加转发规则（本机监听端口 → 落地机 vless 地址）、查看规则、删除规则、清空、卸载。配置文件是 `/etc/realm/config.toml`。

> 旧版的快捷指令注册指向了一个失效地址，`/usr/local/bin/zzj` 可能残留成空文件，导致输入 `zzj` 没反应。现在改为优先自复制、兜底从本仓库拉取，空文件会自动重建——重跑一次脚本即可修好。

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

如果装过 Argo 隧道，先移除它再卸载 sing-box：

```bash
bash /tmp/install.sh --uninstall   # install-cftun.sh
```
