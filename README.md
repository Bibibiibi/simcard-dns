# 5GPN-X

服务器端透明代理网关：mosdns DoT + SNI/QUIC 透明代理 + 可切换多协议出口。客户端只需把 DNS/DoT 指向服务器域名，无需安装任何代理客户端。

## 工作原理

面向 5G NPN / N6 互通、私网终端出海和轻量透明代理场景：

- `172.22.0.0/16` 私网客户端把 DNS/DoT 指向网关。
- ChinaList 域名（所有来源）走国内 DNS 竞速代理（4 路 UDP 并发 + TCP fallback + 海外兜底含 `22.22.22.22`），保持本地访问体验。
- 内网来源非 ChinaList 的 A 查询返回服务器 IP，流量进入 TCP/QUIC 代理。
- 其他来源：被墙域名不劫持，正常海外解析；其他域名也正常海外解析。
- wa-shim / sniproxy / quic-proxy 负责 WhatsApp Noise、SNI/Host 和 QUIC 转发，出站由当前出口控制。
- 仅 `172.22.0.0/16` 内网来源的 AAAA 查询返回 NOERROR/NODATA；其他来源保留正常 IPv6 解析。
- 国内 DNS 三层 fallback：UDP 竞速（4 路）→ 150ms 超时后 TCP 竞速 → 都不通时海外兜底（1.1.1.1、8.8.8.8、22.22.22.22）。国际 DNS primary/secondary fallback。

支持的出口：本机直出、WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP/HTTPS。URI 类出口由锁定版 mihomo `1.19.28` 提供 TUN 出口和智能分流。

出口切换基于 `ip rule fwmark` + 独立路由表，只影响代理进程出站，不影响 SSH、DNS、证书续期。

## 主要功能

- 加密 DNS：客户端统一通过 DoT 853 接入；mosdns 不监听本机 53，因此不会与 `systemd-resolved` 冲突。来源 IP 按段区分解析策略，海外 DNS 池 `1.1.1.1`、`8.8.8.8`、`9.9.9.9`，ChinaList 查询携带 ECS `139.226.48.0/24`；仅内网来源过滤 AAAA。
- iOS WhatsApp Patch：wa-shim 监听 TCP 443，仅分流客户端网段内 `ED`/`WA` 开头的无 SNI Noise 连接，其余 fail-open 交给 sniproxy。
- 智能分流：mihomo `smart` 出口按域名 / IP / GEOSITE / GEOIP / RULE-SET 分流，远程规则集自动更新。
- Telegram Bot：状态、出口管理、分流规则、DNS/DoT 设置、日志、iOS 二维码。
- 供应链校验：mihomo / mosdns 二进制从官方 release 下载并锁定 sha256 校验，不匹配即中止安装。
- 低内存模式：≤ 1 GB 内存自动降低缓存与内核参数，512 MB VPS 可运行。

## 环境要求

主流 Linux 发行版（Ubuntu 20.04+ / Debian 11+ / RHEL 系 8+ / Fedora 39+），`amd64` 或 `arm64`，root 权限，公网 IPv4，以及一个 A 记录指向服务器的域名。内存最低 512 MB，推荐 1 GB+。

## 安装

项目版本：**0.0.5**（见 [CHANGELOG](CHANGELOG.md)）。

一键安装/升级（自动识别首次安装、历史非 Git `/opt/5gpn` 安装和旧提交；升级保留 domain、DNS、exits、rules、证书与 Bot 状态；当前版本则不重复安装）：

```bash
curl -fsSL https://raw.githubusercontent.com/Xiuyixx/5GPN-X/main/quick-install.sh | sudo bash
```

脚本默认解析本仓库 `main` 的完整提交后再检出；这是对本项目 GitHub `main` 的信任，不代表加密认证。安装成功后在 `/opt/5gpn/.installed-commit` 写入真实部署提交，升级失败则留下 `.install-attempt` 和备份/日志供诊断，不会伪装成成功。需要固定到已审阅提交时，可额外设置 `PGW_COMMIT`（40 位完整 SHA）；脚本仍会校验检出后的 HEAD。默认源码目录是 `/opt/5gpn-source`，运行数据目录仍是 `/opt/5gpn`；旧的非 Git `/opt/5gpn` 不需要删除或改名。自定义 `PGW_SRC_DIR` 时必须使用独立源码目录；有未提交修改的 Git 源码目录会先以 root-only、带时间戳的备份目录保留，再原子替换为干净检出，绝不静默丢弃手工修改。已有非 Git 源码目录仍会明确拒绝（不会自动改名），请先人工迁移或指定新的 `PGW_SRC_DIR`；备份/检出失败时旧源码保持不变。源码路径不得是符号链接、路径穿越或其他用户可写的父目录。完整安装的交互输入会从 `/dev/tty` 读取；无 TTY 时请预先设置所需环境变量。`--status` 等管理参数只转发给已有运行目录的管理 CLI，不会触发安装/升级。

升级前会在 `/var/backups/5gpn/upgrade.*` 保存 root-only 配置/代码备份及独立日志。升级不重新运行首次安装向导，不申请新证书，不重建域名/DNS/路由配置，也不重写 `tgbot.env` 或读取执行其中内容；自定义 `TG_STATE_FILE` 保持原位。升级会短暂重启原先正在运行的服务，原先停用的可选服务不会被启用。失败不会自动回滚已部署程序；旧提交标记保持不变，请按输出的备份和日志诊断、修复后重跑同一命令。备份含私钥和 Token，请妥善保管。

仅发现源码目录不算已安装。存在运行配置但不完整时安全拒绝升级，避免误跑首次向导覆盖配置。这里的“当前版本”以成功部署的完整提交 SHA 判定，而非仅比较展示版本号；网络/分支解析失败会退出而不是假称无需升级。升级保留现有配置布局，不自动迁移古老 dnsdist-only 部署或所有手工修改的 systemd 配置。首次安装无 TTY 时需要预先向安装进程提供 `DOMAIN`（可选 `EMAIL`）；日常管理使用下面的运行目录 CLI。

安装前请先把域名 A 记录指向服务器公网 IP；脚本输入域名后会自动验证解析，无需额外确认。已有证书会直接复用，没有证书时才申请 Let's Encrypt 证书。

安装终端仅显示阶段状态和必要交互；完整命令输出写入 `/var/log/5gpn-install.log`。

mihomo 与 mosdns 二进制从官方 release 下载并校验锁定的 sha256 摘要，校验失败会中止安装；使用 `MIHOMO_VERSION` / `MOSDNS_VERSION` 覆盖非锁定版本时会跳过校验（安装时给出警告）。

## 客户端配置

- Android：`设置 -> 网络和互联网 -> 私人 DNS`，填入安装时配置的域名。
- iOS / iPadOS：扫描安装时生成的二维码，或访问 `http://<你的域名>:8111/ios-dot.mobileconfig` 安装描述文件（仅蜂窝网络启用 DoT，Wi-Fi 自动停用）。重新生成：`sudo /opt/5gpn/bin/5gpn-ctl -ios`（源码入口兼容：`./install.sh -ios`）
- Windows / macOS / Linux：系统 DoT 设置或 Stubby / cloudflared 指向服务器域名 `853` 端口。

## 管理命令

```bash
sudo /opt/5gpn/bin/5gpn-ctl --status              # 查看状态
sudo /opt/5gpn/bin/5gpn-ctl --update-rules        # 更新 GFWList/ChinaList 并重载 mosdns
sudo /opt/5gpn/bin/5gpn-ctl --renew-cert          # 续期证书
sudo /opt/5gpn/bin/5gpn-ctl --set-dot-domain dns.example.com
sudo /opt/5gpn/bin/5gpn-ctl --set-dns "1.1.1.1 8.8.8.8" "223.5.5.5 119.29.29.29"
sudo /opt/5gpn/bin/5gpn-ctl -ios                  # 重新生成 iOS 描述文件和二维码
sudo /opt/5gpn/bin/5gpn-ctl --list-exits          # 列出出口
sudo /opt/5gpn/bin/5gpn-ctl --check-exits         # 检测出口连通性
sudo /opt/5gpn/bin/5gpn-ctl --setup-tgbot         # 配置 Telegram Bot
sudo /opt/5gpn/bin/5gpn-ctl --uninstall           # 卸载
```

## 出口管理

默认出口为 `local`（本机公网 IP 直出）。

```bash
# WireGuard：导入你自己准备好的 WireGuard client 配置
sudo /opt/5gpn/bin/5gpn-ctl --add-exit us us.conf

# URI 出口
sudo /opt/5gpn/bin/5gpn-ctl --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
sudo /opt/5gpn/bin/5gpn-ctl --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'

# 切换 / 验证
sudo /opt/5gpn/bin/5gpn-ctl --set-exit hk
curl --interface pgw-hk -4 -s https://api.ipify.org; echo
```

密码含特殊字符时可用多行输入避免 URL 转义：

```bash
printf 'socks5://1.2.3.4:1080
user: myuser
pass: my@p:ss/word
remote-dns: on
' | sudo /opt/5gpn/bin/5gpn-ctl --add-exit jp
```

当前出口记录在 `/opt/5gpn/etc/current-exit`，开机自动恢复。

## 智能分流

`smart` 出口可把不同域名 / 规则集分配到不同出口。策略可以是已配置的出口名、`direct` 或 `block`。

```bash
cat > rules.conf <<'EOF'
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,jp
GEOSITE,telegram,us
GEOIP,cn,direct
RULE-SET,https://example.com/rules.mrs,jp
FINAL,us
EOF

sudo /opt/5gpn/bin/5gpn-ctl --set-rules rules.conf
sudo /opt/5gpn/bin/5gpn-ctl --set-exit smart
```

单独追加规则或规则集（不覆盖整份文件）：

```bash
sudo /opt/5gpn/bin/5gpn-ctl --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo /opt/5gpn/bin/5gpn-ctl --add-ruleset 'https://example.com/openai.mrs' us
```

规则类型：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOSITE`、`GEOIP`、`RULE-SET`、`FINAL`。

`RULE-SET` 支持 mihomo `.mrs`、Clash YAML 和纯文本列表（不支持旧 sing-box `.srs`）。类型按文件名自动推断，命名不明确时可在 URL 后加 `#domain` / `#ipcidr` / `#classical`。远程规则集由 mihomo 默认每 24 小时更新。

导入整份规则并按分类映射出口：

```bash
sudo /opt/5gpn/bin/5gpn-ctl --import-rules /path/to/rule.conf
sudo /opt/5gpn/bin/5gpn-ctl --set-policy Netflix hk
```

## Telegram Bot

```bash
export TG_BOT_TOKEN="123456:ABC-your-bot-token"
export TG_ADMIN_IDS="11111111,22222222"
sudo /opt/5gpn/bin/5gpn-ctl --setup-tgbot
```

不知道自己的数字 ID 时，先启用 Bot 后发送 `/id`，把返回的 ID 写入 `/opt/5gpn/etc/tgbot.env` 并 `sudo systemctl restart 5gpn-tgbot`。

命令：`/start` 打开面板、`/status` 状态、`/exits` 出口、`/rules` 分流、`/cancel` 取消输入、`/id` 查 ID。

添加出口：`🌐 出口 -> ➕ 添加出口`，直接粘贴节点链接（`ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://`），备注会自动作为出口名。

轮询进度持久化在 `/var/lib/5gpn/tgbot-state.json`（权限 600），服务重启后从断点继续；停机期间尚未确认的积压更新仍可能被处理。Telegram 的下一次 `getUpdates(offset)` 即确认更小 ID，并不是本地保存 offset 才确认。被 Telegram 限流（429）时按 `retry_after` 等待，其他轮询失败指数退避（上限 60s）。如需自定义状态文件路径，把 `TG_STATE_FILE` 写入 `/opt/5gpn/etc/tgbot.env` 后重启服务。

点击 iOS 二维码会先发送新图片，再删除主菜单；旧菜单超过 Telegram 删除时限时会改为无按钮的提示。返回时删除二维码并恢复主菜单，重启后仍可返回。超过删除时限或 API 拒绝时会清除二维码按钮并提示手动删除；网络故障也可能阻止清除按钮或恢复菜单，此时请重试 `/menu`。

## 配置参考

### 仓库结构

```text
install.sh        # 安装/管理入口（唯一需要直接运行的脚本）
quick-install.sh  # 一键安装引导
lib/              # 组件源码与模板（tgbot、wa-shim、Go 代理、mosdns 模板等）
tests/            # 策略测试
```

### 关键路径

| 路径 | 说明 |
| --- | --- |
| `/opt/5gpn-source` | 默认固定提交源码目录（与运行数据分离） |
| `/opt/5gpn` | 运行时主目录（`bin/5gpn-ctl`、`bin/tgbot.py`、`bin/mihomo` 等） |
| `/opt/5gpn/etc/current-exit` | 当前出口 |
| `/opt/5gpn/etc/tgbot.env` | Bot Token 和管理员 ID（权限 600） |
| `/var/lib/5gpn/tgbot-state.json` | tgbot 轮询断点，重启续传（权限 600） |
| `/etc/mosdns/config.yaml` | mosdns 实际配置 |
| `/etc/mosdns/gfwlist-extra-local.txt` | 本地补充 GFWList 域名 |
| `/etc/sniproxy.conf` | sniproxy 配置（resolver 强制 `ipv4_only`） |

### 端口

| 端口 | 协议 | 范围 | 用途 |
| --- | --- | --- | --- |
| 80 | TCP | 私网（ACME 时临时公网） | HTTP 透明代理 / HTTP-01 |
| 443 | TCP | `172.22.0.0/16` | wa-shim（无 SNI / HTTPS fail-open 到 sniproxy 回环 8443） |
| 443 | UDP | `172.22.0.0/16` | QUIC 透明代理 |
| 853 | TCP | 公网 | DNS over TLS |
| 8111 | TCP | 公网 | iOS 描述文件下载 |

### 环境变量

```bash
DOMAIN="dns.example.com"        # DoT 域名（必需）
EMAIL="admin@example.com"       # ACME 邮箱
REMOTE_DNS="1.1.1.1,8.8.8.8,9.9.9.9"     # 海外 DNS 池
LOCAL_DNS="101.226.4.6,218.30.118.6,180.76.76.76,119.29.29.29"  # 国内 DNS 竞速池（4路 UDP 并发）
LOWMEM=1                        # 强制低内存模式（≤1GB 自动启用）
MIHOMO_VERSION="1.19.28"        # 覆盖锁定版；非锁定版本跳过 sha256 校验（安装时 warn）
MOSDNS_VERSION="5.3.4"          # 覆盖锁定版；行为同 MIHOMO_VERSION
TG_BOT_TOKEN="123456:ABC"
TG_ADMIN_IDS="11111111,22222222"
TG_STATE_FILE="/var/lib/5gpn/tgbot-state.json"  # tgbot 轮询断点路径；自定义时写入 tgbot.env
FIREWALL_MODE=preserve          # preserve(默认)/auto/managed，见下方说明
PGW_TUNING=essential            # essential(默认)/performance 内核调优档位
```

旧兼容变量 `DNS_UPSTREAMS`、`OVERSEAS_DNS`、`PRIVATE_OVERSEAS_DNS`、`SNIPROXY_DNS` 等同于 `REMOTE_DNS`。也支持 `https://`、`tls://`、`udp://`、`tcp://` 协议前缀。

### 防火墙与内核调优

安装脚本默认**不接管**主机防火墙（`FIREWALL_MODE=preserve`）：只维护项目自己的
出口打标规则（`pgw_exit` 表），并提示需要放行的端口，不会覆盖 `/etc/nftables.conf`、
不会 `flush ruleset`、不会修改 INPUT 默认策略。

- `FIREWALL_MODE=auto`：在现有防火墙（UFW / firewalld / nftables / iptables）里
  **增量**放行所需端口，不清空任何已有规则。
- `FIREWALL_MODE=managed`：由项目完整接管 INPUT 防火墙（旧版行为），每次运行安装器都必须显式指定，历史标记不会自动启用。应用前会
  自动识别并放行**所有检测到的 SSH 端口**（当前会话端口、`sshd -T` 配置、实际
  监听端口的并集，检测失败才回落 22），校验新规则并备份原有
  `/etc/nftables.conf` 到 `/etc/nftables.conf.pgw-backup`。
- 从旧版本升级或重装也默认保持 `preserve`；历史标记不会自动触发 `managed`，
  避免覆盖用户后来添加的规则。

内核参数同理分档：默认 `PGW_TUNING=essential` 只设置网关必需项（转发、
`rp_filter`、可用时启用 BBR）；`PGW_TUNING=performance` 使用旧版激进吞吐调优
（大连接表、短超时等）。旧版本升级时沿用 performance，不会悄悄改变内核行为。

## 常见问题

**为什么内网客户端不返回 IPv6？** 透明代理路径按 IPv4 设计；只有 `172.22.0.0/16` 来源的 AAAA 返回 NOERROR/NODATA。Wi-Fi、公网及其他来源正常返回 IPv6。

**为什么国内网站直连？** ChinaList 域名由 mosdns 转发到 4 路国内 DNS 竞速代理（携带 ECS `139.226.48.0/24`），获得更适合大陆访问的结果。UDP 150ms 无响应后自动切 TCP，都不通才走海外兜底（含 `22.22.22.22`），避免单一国内 DNS 故障卡住页面。

**如何更新 DNS 规则？**

```bash
sudo /opt/5gpn/bin/5gpn-ctl --update-rules
```

**如何查看日志？** 相关服务：`mosdns`、`sniproxy`、`wa-shim`、`quic-proxy`、`5gpn-tgbot`、`5gpn-mihomo@*`，用 `systemctl status` / `journalctl -u <服务> -f` 查看。

**如何测试 DoT？**

```bash
dig +tls @dns.example.com -p 853 youtube.com
curl -I --resolve youtube.com:443:127.0.0.1 https://youtube.com
```

**证书签发失败？** 确认域名 A 记录指向服务器公网 IP 且 TCP 80 可被公网访问。签发/续期时脚本会临时停止 sniproxy 并放行公网 80，完成后恢复 80/443 白名单。

**从旧 sing-box 版本升级？** 内核级迁移：旧 sing-box 服务和二进制会被移除，旧配置备份到 `/etc/5gpn/exits/singbox-backup/`。URI 出口需用原节点链接重新 `--add-exit`；`rules.conf` 和策略映射保留，出口补齐后重新 `--set-rules` / `--set-exit smart`。当前 WireGuard 出口不受影响。

**WhatsApp Patch 的风险控制？** wa-shim 仅对私网和 loopback 来源启用 ED/WA 分流；未知协议、TLS ClientHello、短包和超时都 fail-open 到 sniproxy；以 `pxout` 用户运行，跟随当前出口出站。

## 免责声明

本项目仅用于合法的网络互通、企业专网、测试和学习场景。使用者需自行确认部署和使用行为符合所在地法律法规、云服务商条款及目标网络服务条款。项目不保证在所有网络环境下可用，也不承诺规避封锁、审查或主动探测；因误用、配置错误、服务中断等造成的后果由使用者自行承担。

### 加固边界

- Go 下载使用官方 SHA256，sniproxy 源码固定 commit；修改依赖版本必须同步核验摘要，固定旧版本不等于自动获得上游安全更新。
- Certbot 优先使用系统包；Python 依赖不兼容时停止并提示人工修复，不以 root 无约束升级 pip 包。
- Telegram Bot 仍需要 root 执行服务管理、路由、防火墙及 `/etc` 配置写入。仅限制新文件权限和 core dump，不宣称已做非 root helper 隔离；贸然使用只读系统、私有网络或设备隔离会破坏现有管理功能。
- 安装阶段失败会中止并报告。系统包、运行时网络规则和服务变更不支持跨阶段的全量事务回滚；请保留配置备份和控制台访问，在维护窗口安装。现有 DNS/出口局部恢复不等于整个安装可原子回退。
- 项目版本见本页与 CHANGELOG；安装仍固定完整 Git commit，依赖版本不是项目版本。
