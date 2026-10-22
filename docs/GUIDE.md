# 日常管理与配置参考

[返回首页](../README.md) · [安装、升级与排障](INSTALL.md)

先用 `sudo /opt/simcard-dns/bin/simcard-dns --status` 检查状态；完整参数可用 `--help` 查看。以下命令中的域名、出口名和节点链接请换成自己的值。

## 出口管理

默认出口为 `local`（本机公网 IP 直出）。

```bash
# WireGuard：导入你自己准备好的 WireGuard client 配置
sudo /opt/simcard-dns/bin/simcard-dns --add-exit us us.conf

# URI 出口
sudo /opt/simcard-dns/bin/simcard-dns --add-exit jp 'socks5://user:pass@1.2.3.4:1080'
sudo /opt/simcard-dns/bin/simcard-dns --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@5.6.7.8:443'

# 切换 / 验证
sudo /opt/simcard-dns/bin/simcard-dns --set-exit hk
curl --interface pgw-hk -4 -s https://api.ipify.org; echo
```

密码含特殊字符时可用多行输入避免 URL 转义：

```bash
printf 'socks5://1.2.3.4:1080
user: myuser
pass: my@p:ss/word
remote-dns: on
' | sudo /opt/simcard-dns/bin/simcard-dns --add-exit jp
```

当前出口记录在 `/opt/simcard-dns/etc/current-exit`，开机自动恢复。

## 智能分流

**分流规则同时决定哪些流量经过服务器**：客户端网段的手机只有访问规则里列出的域名时，DNS 才返回服务器 IP、流量进入服务器并按规则选择出口；**没有命中任何规则的域名一律正常解析，手机通过自己的网络直连**（例如 CTMO 卡直接从澳门出去）。

| 规则目标 | 效果 |
| --- | --- |
| 出口名（如 `tw`、`us`） | 经服务器，从该出口出去 |
| `local` | 经服务器，从服务器本机 IP 出去 |
| `direct` | 不经服务器，手机直连（与没写规则相同，可用来给某个规则集开例外） |
| `block` | DNS 直接拒绝 |

分类（导入规则时的分组名）按分类映射解析成上面的目标。DNS 只能按域名判断，所以 `DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`GEOSITE` 和域名类规则集会决定是否经过服务器；`IP-CIDR`、`GEOIP` 只对已经进入服务器的流量生效，`FINAL` 不再起作用（未命中即直连）。`.mrs` 规则集会改读同目录的 `.list` 文本版本（MetaCubeX meta-rules-dat 均提供），找不到时该规则集只在服务器出口层生效。规则变化后 DNS 名单会自动重建；远程规则集在 `--update-rules` 时刷新。

```bash
cat > rules.conf <<'EOF'
DOMAIN-SUFFIX,google.com,us
DOMAIN-KEYWORD,netflix,jp
GEOSITE,telegram,us
GEOIP,cn,direct
RULE-SET,https://example.com/rules.mrs,jp
FINAL,us
EOF

sudo /opt/simcard-dns/bin/simcard-dns --set-rules rules.conf
sudo /opt/simcard-dns/bin/simcard-dns --set-exit smart
```

单独追加规则或规则集（不覆盖整份文件）：

```bash
sudo /opt/simcard-dns/bin/simcard-dns --add-rule 'DOMAIN-SUFFIX,openai.com,us'
sudo /opt/simcard-dns/bin/simcard-dns --add-rule 'GEOSITE,openai,local'      # 经服务器本机 IP 出去
sudo /opt/simcard-dns/bin/simcard-dns --add-ruleset 'https://example.com/openai.mrs' us
```

规则类型：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOSITE`、`GEOIP`、`RULE-SET`、`FINAL`。

`RULE-SET` 支持 mihomo `.mrs`、Clash YAML 和纯文本列表（不支持旧 sing-box `.srs`）。类型按文件名自动推断，命名不明确时可在 URL 后加 `#domain` / `#ipcidr` / `#classical`。远程规则集由 mihomo 默认每 24 小时更新。

导入整份规则并按分类映射出口：

```bash
sudo /opt/simcard-dns/bin/simcard-dns --import-rules /path/to/rule.conf
sudo /opt/simcard-dns/bin/simcard-dns --set-policy Netflix hk
```

## 手机卡接入

手机卡直接通过公网连接服务器。运营商分配给手机的**公网出口网段**就是客户端网段：这些来源发起的 DoT 查询中，非国内域名会解析为服务器 IP，流量经公网进入服务器的 TCP/QUIC 代理。

项目不内置任何运营商的网段。安装后在 Telegram Bot「🛡 白名单」添加运营商 ASN（如 `AS9231`，可加多个），或按下面步骤用命令设置；添加之前不会有设备被引到服务器。

1. **确认手机出口 IP**：关闭 Wi-Fi、只用蜂窝数据，在手机浏览器打开任意 IP 查询网站；或者先把手机私人 DNS 指向服务器，再在服务器上查看 DoT 连接来源：

   ```bash
   sudo ss -tn state established '( sport = :853 )'
   ```

2. **确定网段**：移动网络出口 IP 通常来自运营商 NAT 地址池并会变化。多换几次飞行模式记录 IP，或用 `whois <IP>` / BGP 查询工具找到运营商公布的整段前缀。网段过小会时灵时不灵，过大则会让更多陌生用户能使用你的代理。

3. **写入客户端网段**（会替换整个列表；空格或逗号分隔，单个 IP 自动视为 `/32`）：

   ```bash
   sudo /opt/simcard-dns/bin/simcard-dns --set-client-cidrs "103.143.92.0/23 203.0.113.0/24 198.51.100.0/22"
   sudo /opt/simcard-dns/bin/simcard-dns --status   # 查看 Client CIDRs
   ```

   首次安装也可以预先设置 `CLIENT_CIDRS="203.0.113.0/24 198.51.100.0/22"`。

   也可以按运营商的 ASN 整体加入或删除（网段来自 RIPEstat 公开路由数据，只取 IPv4）。安装时填写的 ASN 也会登记在这里；删除某个 ASN 只移除它自己的网段，其他 ASN 和手动网段保留：

   ```bash
   sudo /opt/simcard-dns/bin/simcard-dns --lookup-client-asn AS63527   # 只查询，不修改
   sudo /opt/simcard-dns/bin/simcard-dns --add-client-asn AS63527
   sudo /opt/simcard-dns/bin/simcard-dns --list-client-asns
   sudo /opt/simcard-dns/bin/simcard-dns --del-client-asn AS63527
   ```

   Telegram Bot 主菜单的「🛡 白名单」提供同样的功能：添加前会显示运营商名称和网段数量，确认后才生效，删除也需要确认。

4. **放行端口**：默认 `preserve` 模式不改主机防火墙，命令会提示需要放行的端口。请在主机防火墙**和云厂商安全组**中，只对这些网段放行 TCP `80/443` 和 UDP `443`；不要对全网开放。`FIREWALL_MODE=auto` 会自动追加放行规则，但修改网段后不会删除旧网段的规则，需要自行清理。

   **注意**：如果主机没有防火墙（INPUT 全部放行），80/443 对所有人开放，任何知道服务器 IP 的人都能直接把它当开放代理用，扫描器很快就会找上门。没有其他防火墙需求时，推荐让项目接管 INPUT：

   ```bash
   sudo simcard-dns --set-firewall managed
   ```

   效果：80/443 和 UDP 443 只放行客户端网段；853、8111 和检测到的 SSH 端口对所有人开放；其余入站全部拒绝，规则开机自动加载。原规则备份为 `/etc/nftables.conf.pgw-backup`。853 不建议限制为客户端网段：Android 私人 DNS 在 Wi-Fi 下同样强制使用，限制后连 Wi-Fi 会无法解析。

   **可选：地区限制**（仅 managed nftables 防火墙）：让 SSH、853 和 8111 只接受香港、澳门、台湾的 IP 与客户端网段连入，其他地区的新连接直接丢弃。地区网段取自 APNIC 每日发布的分配数据（按登记国家，校验 MD5 与记录数），每天自动更新；下载或校验失败时保留旧名单。客户端网段始终放行。

   ```bash
   sudo /opt/simcard-dns/bin/simcard-dns --geo-allow on       # 开启（首次会下载名单）
   sudo /opt/simcard-dns/bin/simcard-dns --geo-allow status   # 状态、名单日期、已拦截包数
   sudo /opt/simcard-dns/bin/simcard-dns --geo-allow update   # 立即更新名单
   sudo /opt/simcard-dns/bin/simcard-dns --geo-allow off      # 关闭
   ```

   Telegram Bot 主菜单的「🌏 港澳台连接」按钮显示当前开关状态，点进去可以开启（需确认）、关闭或更新名单；「🛡 白名单」页也有同一入口。开启前会检查当前 SSH 会话和已登录会话的来源 IP，不在允许范围内就拒绝开启（`PGW_GEO_FORCE=1` 可强制）。注意：
   - 人在其他地区用当地网络时无法 SSH，手机连当地 Wi‑Fi 时私人 DNS 也会连不上；用白名单运营商的流量漫游不受影响。被挡在外面时用 Bot 关闭，或用 VPS 商的网页控制台。
   - 名单按登记国家而不是实际位置：在港台澳使用、但向其他 RIR 登记的地址（常见于云服务器）会被拦截。
   - 只限制新 TCP 连接，ICMP 和 80/443、UDP 443 不受影响（后者本来就只对客户端网段开放）。

5. **手机设置**：Android 私人 DNS 或 iOS 描述文件按[客户端配置](../README.md#客户端配置)填写即可，手机上不用安装代理软件。

注意事项：

- 这个模式依赖 SNI 透明代理，TLS 握手中的域名是明文。只有当手机到服务器这一段公网**不经过会按 SNI 阻断的网络**时才稳定可用。例如手机卡漫游时数据回到归属地出口，就满足这个条件；如果数据在本地出网，被封锁域名的握手可能被重置。DoT（853）是加密的，不受此影响。
- 网段内任何人都能使用这台服务器的 80/443 代理，所以网段越精确越好。为防止成为开放代理，`0.0.0.0/0` 会被拒绝。
- 连接 Wi-Fi 时，查询来自家里的宽带 IP，不在客户端网段内，会自动按普通公网来源解析，不会把流量送进代理。
- 当前出口（WireGuard / URI 节点 / smart）对这些客户端同样生效。发往客户端网段的回包不会被打标进出口隧道。

## 一键重置域名（Cloudflare）

域名托管在 Cloudflare 时，可以随时把私人 DNS 换成新的随机域名，旧域名立即失效（例如域名泄露或定期更换）。

1. 在 Cloudflare 创建 API Token：模板选「编辑区域 DNS」，区域资源只选你的域名（只需要 Zone → DNS → Edit 权限）。
2. 在服务器上接入（Token 输入时不显示，不要写在命令行参数里）：

   ```bash
   sudo /opt/simcard-dns/bin/simcard-dns --setup-cloudflare
   ```

   程序会根据当前域名自动找到 Cloudflare 区域，并通过 DNS 验证签发通配符证书 `*.dns.<你的域名>`，之后自动续期（不需要开放 80 端口）。

3. 重置：Telegram Bot「🛠️ 域名 DNS 管理 → 🔄 重置域名」，或执行 `sudo /opt/simcard-dns/bin/simcard-dns --reset-domain`。会生成 `<20 位随机>.dns.<你的域名>`，在 Cloudflare 添加解析（仅 DNS，不开代理），切换私人 DNS 并删除旧域名指向本机的解析；任何一步失败都会回滚。

用通配符证书的好处：重置不需要重新签证书，新域名也不会出现在公开的证书透明度日志里。

**旧域名立即失效**：公网 853 由 DoT 入口守门服务 `dot-gate` 接管，只放行 TLS 握手中 SNI 等于当前域名的连接，再原样转给只监听 `127.0.0.1:8853` 的 mosdns；旧域名、其他名字或不带 SNI（扫描器）的连接直接断开。重置后约 2 秒内，仍使用旧域名的已建立连接也会被切断，即使客户端缓存了服务器 IP。客户端网段的判断由 `dot-gate` 完成（网段内以 `127.0.0.2`、网段外以 `127.0.0.3` 连接 mosdns）。重置后所有设备都要更新：Android 修改私人 DNS 域名，iPhone 重新安装描述文件（Bot 会给出二维码）。

## Telegram Bot

```bash
sudo /opt/simcard-dns/bin/simcard-dns --setup-tgbot
```

按提示输入 Bot Token 和管理员数字 ID。可先通过 Telegram 的 ID 查询机器人获取自己的 ID；启用后也可向本 Bot 发送 `/id` 核对。不要公开 Token。已有配置会用于后续设置。

主菜单「🛡 白名单」可按 ASN 添加或删除客户端白名单（见[手机卡接入](#手机卡接入)）。

命令：`/start` 打开面板、`/status` 状态、`/clients` 当前连入 IP（同主菜单 👥 按钮，标出是否在客户端网段内）、`/exits` 出口、`/rules` 分流、`/cancel` 取消输入、`/id` 查 ID。

添加出口：`🌐 出口 -> ➕ 添加出口`，直接粘贴节点链接（`ss:// vmess:// trojan:// vless:// hysteria2:// tuic:// anytls:// socks5:// http://`），备注会自动作为出口名。

轮询进度持久化在 `/var/lib/simcard-dns/tgbot-state.json`（权限 600），服务重启后从断点继续；停机期间尚未确认的积压更新仍可能被处理。Telegram 的下一次 `getUpdates(offset)` 即确认更小 ID，并不是本地保存 offset 才确认。被 Telegram 限流（429）时按 `retry_after` 等待，其他轮询失败指数退避（上限 60s）。如需自定义状态文件路径，把 `TG_STATE_FILE` 写入 `/opt/simcard-dns/etc/tgbot.env` 后重启服务。

点击 iOS 二维码会先发送新图片，再删除主菜单；旧菜单超过 Telegram 删除时限时会改为无按钮的提示。返回时删除二维码并恢复主菜单，重启后仍可返回。超过删除时限或 API 拒绝时会清除二维码按钮并提示手动删除；网络故障也可能阻止清除按钮或恢复菜单，此时请重试 `/menu`。

## 配置参考

### 关键路径

| 路径 | 说明 |
| --- | --- |
| `/opt/simcard-dns-source` | 默认固定提交源码目录（与运行数据分离） |
| `/opt/simcard-dns` | 运行时主目录（`bin/simcard-dns`、`bin/tgbot.py`、`bin/mihomo` 等） |
| `/opt/simcard-dns/etc/current-exit` | 当前出口 |
| `/opt/simcard-dns/etc/tgbot.env` | Bot Token 和管理员 ID（权限 600） |
| `/var/lib/simcard-dns/tgbot-state.json` | tgbot 轮询断点，重启续传（权限 600） |
| `/etc/mosdns/config.yaml` | mosdns 实际配置 |
| `/etc/mosdns/domain-overrides.conf` | `--proxy-domain` 写入的单域名覆盖（`域名=proxy/direct/block`） |
| `/etc/sniproxy.conf` | sniproxy 配置（resolver 强制 `ipv4_only`） |

### 端口

| 端口 | 协议 | 范围 | 用途 |
| --- | --- | --- | --- |
| 80 | TCP | 客户端网段（ACME 时临时全网） | HTTP 透明代理 / HTTP-01 |
| 443 | TCP | 客户端网段 | wa-shim（无 SNI / HTTPS fail-open 到 sniproxy 回环 8443） |
| 443 | UDP | 客户端网段 | QUIC 透明代理 |
| 853 | TCP | 公网 | DNS over TLS |
| 8111 | TCP | 公网 | iOS 描述文件下载 |

### 环境变量

```bash
DOMAIN="dns.example.com"        # DoT 域名（必需）
CLIENT_CIDRS="203.0.113.0/24 ..."   # 可选：客户端网段（通常装好后在 Bot 添加 ASN）
EMAIL="admin@example.com"       # ACME 邮箱
REMOTE_DNS="1.1.1.1,8.8.8.8,9.9.9.9"     # 海外 DNS 池
LOCAL_DNS="223.5.5.5,119.29.29.29"  # 国内 DNS（默认阿里 + 腾讯，UDP 并发竞速）
LOWMEM=1                        # 强制低内存模式（≤1GB 自动启用）
MIHOMO_VERSION="1.19.28"        # 覆盖锁定版；非锁定版本跳过 sha256 校验（安装时 warn）
MOSDNS_VERSION="5.3.4"          # 覆盖锁定版；行为同 MIHOMO_VERSION
TG_BOT_TOKEN="123456:ABC"
TG_ADMIN_IDS="11111111,22222222"
TG_STATE_FILE="/var/lib/simcard-dns/tgbot-state.json"  # tgbot 轮询断点路径；自定义时写入 tgbot.env
FIREWALL_MODE=preserve          # preserve(默认)/auto/managed，见下方说明
PGW_TUNING=essential            # essential(默认)/performance 内核调优档位
```

旧兼容变量 `DNS_UPSTREAMS`、`OVERSEAS_DNS`、`PRIVATE_OVERSEAS_DNS`、`SNIPROXY_DNS` 等同于 `REMOTE_DNS`。DNS 上游统一使用纯 IP 或 `IP:53`；不接受 DoH/DoT 或其他协议前缀，避免不同 DNS 消费者产生不一致行为。

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

**为什么不返回 IPv6？** 当前透明代理路径按 IPv4 设计；所有来源的 AAAA 均返回 NOERROR/NODATA。这是保留既有行为，不会自动开放 IPv6 绕过代理。

**为什么国内网站直连？** ChinaList 域名由 mosdns 转发到国内 DNS 竞速代理（默认 223.5.5.5、119.29.29.29）（携带 ECS `139.226.48.0/24`），获得更适合大陆访问的结果。UDP 150ms 无响应后自动切 TCP，都不通才走海外兜底（含 `22.22.22.22`），避免单一国内 DNS 故障卡住页面。

**如何更新 DNS 规则？**

```bash
sudo /opt/simcard-dns/bin/simcard-dns --update-rules
```

**服务、证书或 DoT 出问题？** 先看 [安装与排障指南](INSTALL.md#5-失败排查)。

**从旧 sing-box 版本升级？** 内核级迁移：旧 sing-box 服务和二进制会被移除，旧配置备份到 `/etc/simcard-dns/exits/singbox-backup/`。URI 出口需用原节点链接重新 `--add-exit`；`rules.conf` 和策略映射保留，出口补齐后重新 `--set-rules` / `--set-exit smart`。当前 WireGuard 出口不受影响。

**WhatsApp Patch 的风险控制？** wa-shim 仅对客户端网段和 loopback 来源启用 ED/WA 分流；未知协议、TLS ClientHello、短包和超时都 fail-open 到 sniproxy；以 `pxout` 用户运行，跟随当前出口出站。


## 运行原理

面向手机卡经公网接入的轻量透明代理场景：

- 客户端网段（运营商公网出口网段，安装时由操作者指定）的手机把私人 DNS（DoT）指向网关。
- ChinaList 域名（所有来源）走国内 DNS 竞速代理（UDP 并发 + TCP fallback + 海外兜底含 `22.22.22.22`），保持本地访问体验。
- 客户端网段来源只有命中分流规则（含规则集、GEOSITE）的 A 查询返回服务器 IP，流量进入 TCP/QUIC 代理并按规则选择出口；规则目标为 `block` 的直接拒绝；其余域名正常解析（ChinaList 走国内 DNS，其他走海外 DNS），手机直连。
- 其他来源：被墙域名不劫持，正常海外解析；其他域名也正常海外解析。
- wa-shim / sniproxy / quic-proxy 负责 WhatsApp Noise、SNI/Host 和 QUIC 转发，出站由当前出口控制。
- 所有来源的 AAAA 查询返回 NOERROR/NODATA，保持现有 IPv4-only 透明代理策略，避免 IPv6 绕过代理。
- 国内 DNS 三层 fallback：UDP 竞速（所有国内 DNS 并发）→ 150ms 超时后 TCP 竞速 → 都不通时海外兜底（1.1.1.1、8.8.8.8、22.22.22.22）。国际 DNS primary/secondary fallback。

支持的出口：本机直出、WireGuard、SOCKS5/SOCKS5H、SS/SS2022、VMess、Trojan、VLESS、Hysteria2、TUIC、AnyTLS、HTTP/HTTPS。URI 类出口由锁定版 mihomo `1.19.28` 提供 TUN 出口和智能分流。

出口切换基于 `ip rule fwmark` + 独立路由表，只影响代理进程出站，不影响 SSH、DNS、证书续期。

### 组件能力

- 加密 DNS：客户端统一通过 DoT 853 接入；mosdns 不监听本机 53，因此不会与 `systemd-resolved` 冲突。来源 IP 按段区分解析策略，海外 DNS 池 `1.1.1.1`、`8.8.8.8`、`9.9.9.9`，ChinaList 查询携带 ECS `139.226.48.0/24`；所有来源过滤 AAAA（IPv4-only）。
- iOS WhatsApp Patch：wa-shim 监听 TCP 443，仅分流客户端网段内 `ED`/`WA` 开头的无 SNI Noise 连接，其余 fail-open 交给 sniproxy。
- 智能分流：mihomo `smart` 出口按域名 / IP / GEOSITE / GEOIP / RULE-SET 分流，远程规则集自动更新。
- Telegram Bot：状态、出口管理、分流规则、DNS/DoT 设置、日志、iOS 二维码。
- 供应链校验：mihomo / mosdns 二进制从官方 release 下载并锁定 sha256 校验，不匹配即中止安装。
- 低内存模式：≤ 1 GB 内存自动降低缓存与内核参数，512 MB VPS 可运行。

