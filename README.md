# simcard-dns

> 手機只改一個「私人 DNS」，指定的網站就自動經由你的伺服器出去；其他流量照舊走手機自己的網路。不用裝任何 App。

simcard-dns 是一套裝在 Linux 伺服器上的閘道。它同時是一台加密 DNS（DoT）伺服器和一台透明代理：你決定哪些網域要「繞到伺服器」，伺服器再決定這些連線從哪個出口離開（代理節點、伺服器本機，或直接拒絕）。

目前版本：**1.1.3**

---

## 運作方式

```text
              ┌──────────── 伺服器 ────────────┐
手機 ──DoT 853──▶ 網域命中分流規則？                │
  │             ├─ 是 → 回答「伺服器 IP」            │
  │             └─ 否 → 回答真實 IP（手機自己直連）  │
  │                                             │
  └──80/443、QUIC──▶ 透明代理 ──▶ 依規則選出口 ─────┼──▶ 節點 / 本機 / 拒絕
              └────────────────────────────────┘
```

重點只有三個：

1. **手機不裝東西**：Android 填私人 DNS、iOS 裝一個描述檔，就完成設定。
2. **只繞規則裡的網域**：沒寫進規則的網站一律正常解析，由手機直連，不會拖慢日常使用。
3. **只服務你的電信卡**：只有「客戶端網段」（你的電信業者公網出口，可用 ASN 一次加入）會拿到伺服器 IP，也只有它們能連到 80/443。其他人用這台 DNS 只會得到普通的解析結果。

## 功能一覽

| 類別 | 內容 |
| --- | --- |
| 分流 | 網域、網域後綴、關鍵字、GEOSITE、遠端規則集；目標可以是節點、伺服器本機（`local`）、不經伺服器（`direct`）或拒絕（`block`） |
| 出口 | 本機直出、WireGuard，以及 SS、VMess、VLESS、Trojan、Hysteria2、TUIC、AnyTLS、SOCKS5、HTTP 節點 |
| 客戶端 | 依 ASN 加入或移除電信業者網段，也可手動指定 CIDR |
| 入口保護 | DoT 入口只放行目前網域的 SNI；接上 Cloudflare 後可一鍵換成新的隨機網域，舊網域立即失效 |
| 港澳台連接 | 可選：SSH、853、8111 只接受香港、澳門、台灣與客戶端網段連入，名單每天自動更新 |
| 管理 | 命令列 `simcard-dns` 與 Telegram Bot（狀態、出口、分流、白名單、連入 IP、網域） |
| 資源 | 1 GB 以下記憶體自動切換低資源模式 |

## 快速開始

### 1. 準備

| 項目 | 需求 |
| --- | --- |
| 系統 | Debian 11+、Ubuntu 20.04+、RHEL 系 8+、Fedora 39+ |
| 架構 | `amd64` 或 `arm64` |
| 記憶體 | 至少 512 MB，建議 1 GB 以上 |
| 網路 | 公網 IPv4、root 權限 |
| Cloudflare | 一個託管在 Cloudflare 的網域，以及一組 API Token（權限：Zone → Zone → Read、Zone → DNS → Edit） |
| Telegram | 向 @BotFather 申請的 Bot Token，以及你自己的 Telegram 數字 ID（可向 @userinfobot 查詢） |

### 2. 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/Bibibiibi/simcard-dns/main/install.sh | sudo bash
```

安裝一開始會問三件事，之後全自動完成：

1. **Cloudflare API Token**（輸入時不顯示）。Token 能管理多個網域時會讓你選一個。
2. **Telegram Bot Token**（必填）。
3. **管理員 Telegram ID**。

安裝程式會用 Cloudflare DNS 驗證簽發 `*.dns.<你的網域>` 萬用字元憑證（不用開 80 埠），並自動建立一個隨機的 DoT 網域，例如 `k3x9…q2.dns.example.com`。安裝完成時會顯示這個網域，手機私人 DNS 就填它。

沒有 Cloudflare 的話，可以改用自己的網域（A 記錄要先指向伺服器）：

```bash
curl -fsSL https://raw.githubusercontent.com/Bibibiibi/simcard-dns/main/install.sh | sudo env DOMAIN=dns.example.com bash
```

之後要升級，再執行同一行安裝指令；現有設定會保留，失敗會自動回滾。

### 3. 告訴伺服器誰是你的手機

預設的客戶端網段是中國電信澳門（CTMO，AS136167）。換成你的電信業者：

```bash
sudo simcard-dns --lookup-client-asn AS9231   # 先看業者名稱與網段數
sudo simcard-dns --add-client-asn AS9231
# 或直接指定網段（會取代整份清單）
sudo simcard-dns --set-client-cidrs "203.0.113.0/24 198.51.100.0/22"
```

### 4. 防火牆

安裝一開始會問「讓 simcard-dns 接管防火牆？」。主機上沒有其他對外服務就選 **Y**（預設），會照下表設定好；選 n 則不碰主機防火牆，你要自己照下表開放：

| 連接埠 | 開給誰 | 用途 |
| --- | --- | --- |
| TCP 853 | 所有人 | DNS over TLS |
| TCP 80/443、UDP 443 | **只有客戶端網段** | 透明代理（HTTP、HTTPS、QUIC） |
| TCP 8111 | 所有人 | iOS 描述檔下載 |
| TCP 80 | 只有自有網域模式（`DOMAIN`）申請憑證時暫時開放 | Let's Encrypt HTTP-01（Cloudflare 模式不需要） |

安裝時選了 n、之後想改由專案接管（開「港澳台連接」也需要接管）：

```bash
sudo simcard-dns --set-firewall managed
```

> ⚠️ 80/443 絕不能對全網開放，否則任何人都能把這台伺服器當開放代理用。

### 5. 手機設定

- **Android**：設定 → 網路和網際網路 → 私人 DNS → 填入安裝時的網域。
- **iOS / iPadOS**：掃安裝完成時顯示的 QR Code，或用 Safari 開 `http://<你的網域>:8111/ios-dot.mobileconfig` 安裝描述檔（只在行動網路啟用 DoT）。要重新產生描述檔和 QR Code，執行 `sudo simcard-dns -ios`（原始碼目錄可用 `./install.sh -ios`）。從舊版升級後描述檔識別碼已改變，請先刪除舊的描述檔再重新安裝。
- **電腦**：在系統的 DoT 設定，或用 Stubby、cloudflared 指向 `<你的網域>:853`。

改完規則後如果手機沒有馬上生效，先切一下飛航模式或強制關閉 App：手機和 App 會快取 DNS、保留舊連線。

## 常用指令

以下指令都可以直接複製到伺服器執行，範例值（例如 `AS9231`、`hk`、`example.com`）請換成你自己的。程式本體在 `/opt/simcard-dns/bin/simcard-dns`，設定在 `/etc/simcard-dns`。從舊版 5GPN-X 升級的主機，第一次升級時會自動把 `/opt/5gpn`、`/etc/5gpn` 和 `5gpn-*` 服務搬到新名稱，舊版內容備份在 `/var/backups/simcard-dns/migrate.*`。

**狀態與更新**

```bash
sudo simcard-dns --status                 # 看所有服務狀態
sudo simcard-dns --update-rules           # 更新 GFWList / ChinaList
curl -fsSL https://raw.githubusercontent.com/Bibibiibi/simcard-dns/main/install.sh | sudo bash   # 升級到最新版
```

**出口**

```bash
sudo simcard-dns --list-exits             # 列出出口與目前使用中的出口
sudo simcard-dns --check-exits            # 檢查每個出口節點連不連得上
sudo simcard-dns --add-exit hk 'ss://2022-blake3-aes-128-gcm:PASSWORD@203.0.113.10:443'   # 新增節點出口
sudo simcard-dns --set-exit smart         # 改用智慧分流（也可以填出口名稱或 local）
sudo simcard-dns --del-exit hk            # 刪除出口
```

**分流規則**

```bash
sudo simcard-dns --show-rules                                          # 看目前規則
sudo simcard-dns --add-rule 'DOMAIN-SUFFIX,openai.com,hk'              # 網域走 hk 出口
sudo simcard-dns --add-rule 'DOMAIN-SUFFIX,example.com,local'          # 經伺服器本機 IP 出去
sudo simcard-dns --add-ruleset 'https://example.com/openai.mrs' hk     # 整份規則集走 hk
sudo simcard-dns --set-rules rules.conf                                # 用檔案取代全部規則
```

**客戶端白名單（你的電信卡）**

```bash
sudo simcard-dns --list-client-asns                                    # 看目前白名單
sudo simcard-dns --lookup-client-asn AS9231                            # 先查業者名稱與網段數（不修改）
sudo simcard-dns --add-client-asn AS9231                               # 加入整個業者
sudo simcard-dns --del-client-asn AS9231                               # 移除業者
sudo simcard-dns --set-client-cidrs "203.0.113.0/24 198.51.100.0/22"   # 直接指定網段（取代整份清單）
```

**港澳台連接**（SSH、853、8111 只接受香港、澳門、台灣與白名單網段；需要專案接管防火牆）

```bash
sudo simcard-dns --set-firewall managed   # 還沒接管防火牆時先執行這行
sudo simcard-dns --geo-allow status       # 看狀態
sudo simcard-dns --geo-allow on           # 開啟
sudo simcard-dns --geo-allow off          # 關閉
sudo simcard-dns --geo-allow update       # 立即更新地區名單
```

**網域與憑證**

```bash
sudo simcard-dns --set-dot-domain dns.example.com    # 換成自己的網域（A 記錄要先指向伺服器）
sudo simcard-dns --renew-cert                        # 立即續期憑證
sudo simcard-dns --setup-cloudflare                  # 接上 Cloudflare（權杖輸入時不顯示）
sudo simcard-dns --reset-domain                      # 換成新的隨機網域；這台伺服器以前的 DoT 網域記錄會一併刪除
sudo simcard-dns -ios                                # 重新產生 iOS 描述檔與 QR Code
```

**DNS 上游**

```bash
sudo simcard-dns --set-dns "8.8.8.8 1.1.1.1" "223.5.5.5 119.29.29.29"   # 第一組是國際 DNS，第二組是國內 DNS
```

**Telegram Bot**

```bash
sudo simcard-dns --setup-tgbot            # 設定 Bot 權杖與管理員
```

**解除安裝**

```bash
sudo simcard-dns --uninstall              # 完整清除（含 Cloudflare 上這台伺服器的 DoT 記錄）；憑證、備份、Go 會逐項詢問
```

完整說明請看文件：

- [安裝、升級與排障](docs/INSTALL.md)
- [日常管理與設定參考](docs/GUIDE.md)：出口、分流、手機卡接入、Bot、連接埠、環境變數
- [開發與測試](docs/DEVELOPMENT.md)

## 使用前要知道的事

- **只處理 IPv4**：DNS 不回傳 IPv6 位址，透明代理也只走 IPv4。
- **分流只看網域**：IP 類規則（IP-CIDR、GEOIP）只對已經進入伺服器的流量有效，`FINAL` 沒有作用。
- **DNS 洩漏檢測看到伺服器或電信業者的 IP 是正常的**：DNS 在伺服器解析，WebRTC 的 STUN 走非 443 的 UDP，不經過伺服器。
- **港澳台連接按登記國家判斷**：在當地使用、但登記在其他地區的雲端 IP 會被擋；開啟後人在其他地區用當地網路時無法 SSH，手機連當地 Wi‑Fi 時私人 DNS 也會失效（用白名單電信卡漫遊不受影響）。
- **Bot 需要 root**：它要管理服務、路由和防火牆，請只把管理員 ID 給自己。

## 安全設計

- 下載的 Go、mihomo、mosdns 都比對固定的 SHA256，sniproxy 原始碼釘選在固定 commit；安裝也固定在完整的 Git commit。
- 升級前會備份設定與程式碼，失敗時還原；但跨階段的系統套件與網路規則無法整體回滾，建議在維護時段操作並保留主控台存取。
- Bot 與 Cloudflare 的權杖存成僅 root 可讀的檔案；Cloudflare 權杖輸入時不回顯。

## 免責聲明

本專案僅供合法的網路互通、測試與學習使用。部署前請自行確認符合當地法規、雲端業者條款與目標服務的使用條款。專案不保證在所有網路環境下可用，也不承諾規避任何審查或封鎖；因使用或設定錯誤造成的後果由使用者自行承擔。

## 授權與致謝

以 [MIT License](LICENSE) 釋出。本專案衍生自 [Xiuyixx/5GPN-X](https://github.com/Xiuyixx/5GPN-X)，在其基礎上改為電信卡公網接入，並加入規則驅動 DNS、ASN 白名單、DoT 入口守門、Cloudflare 網域重置與港澳台連接等功能。
