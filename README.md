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
| 網域 | 一個 A 記錄指向伺服器的網域（安裝時會用它申請憑證） |

### 2. 安裝

```bash
curl -fsSL https://raw.githubusercontent.com/Bibibiibi/simcard-dns/main/install.sh | sudo bash
```

照提示輸入網域即可。之後要升級，再執行同一行指令；現有設定會保留，失敗會自動回滾。

### 3. 告訴伺服器誰是你的手機

預設的客戶端網段是中國電信澳門（CTMO，AS136167）。換成你的電信業者：

```bash
sudo simcard-dns --lookup-client-asn AS9231   # 先看業者名稱與網段數
sudo simcard-dns --add-client-asn AS9231
# 或直接指定網段（會取代整份清單）
sudo simcard-dns --set-client-cidrs "203.0.113.0/24 198.51.100.0/22"
```

### 4. 防火牆

安裝程式預設不碰主機防火牆，只會提示要開哪些連接埠：

| 連接埠 | 開給誰 | 用途 |
| --- | --- | --- |
| TCP 853 | 所有人 | DNS over TLS |
| TCP 80/443、UDP 443 | **只有客戶端網段** | 透明代理（HTTP、HTTPS、QUIC） |
| TCP 8111 | 所有人 | iOS 描述檔下載 |
| TCP 80 | 申請憑證時暫時開放 | Let's Encrypt HTTP-01 |

主機上沒有其他服務要顧的話，建議讓專案接管防火牆，80/443 就只會對客戶端網段開放：

```bash
sudo FIREWALL_MODE=managed simcard-dns --set-client-cidrs "<目前的客戶端網段>"
```

> ⚠️ 80/443 絕不能對全網開放，否則任何人都能把這台伺服器當開放代理用。

### 5. 手機設定

- **Android**：設定 → 網路和網際網路 → 私人 DNS → 填入安裝時的網域。
- **iOS / iPadOS**：掃安裝完成時顯示的 QR Code，或用 Safari 開 `http://<你的網域>:8111/ios-dot.mobileconfig` 安裝描述檔（只在行動網路啟用 DoT）。要重新產生描述檔和 QR Code，執行 `sudo simcard-dns -ios`（原始碼目錄可用 `./install.sh -ios`）。從舊版升級後描述檔識別碼已改變，請先刪除舊的描述檔再重新安裝。
- **電腦**：在系統的 DoT 設定，或用 Stubby、cloudflared 指向 `<你的網域>:853`。

改完規則後如果手機沒有馬上生效，先切一下飛航模式或強制關閉 App：手機和 App 會快取 DNS、保留舊連線。

## 常用指令

所有指令都是 `sudo simcard-dns <選項>`（程式本體在 `/opt/simcard-dns/bin/simcard-dns`，設定在 `/etc/simcard-dns`）。從舊版 5GPN-X 升級的主機，第一次升級時會自動把 `/opt/5gpn`、`/etc/5gpn` 和 `5gpn-*` 服務搬到新名稱，舊版內容備份在 `/var/backups/simcard-dns/migrate.*`。

| 用途 | 選項 |
| --- | --- |
| 看狀態 | `--status` |
| 更新 GFWList / ChinaList | `--update-rules` |
| 新增 / 切換 / 檢查出口 | `--add-exit <名稱> <設定檔或 URI>`、`--set-exit <名稱\|local\|smart>`、`--check-exits` |
| 分流規則 | `--show-rules`、`--add-rule <規則>`、`--add-ruleset <網址> <目標>`、`--set-rules [檔案]` |
| 客戶端白名單 | `--list-client-asns`、`--add-client-asn <ASN>`、`--del-client-asn <ASN>` |
| 港澳台連接 | `--geo-allow on\|off\|update\|status` |
| 網域與憑證 | `--set-dot-domain <網域>`、`--renew-cert` |
| Cloudflare 隨機網域 | `--setup-cloudflare`（權杖以隱藏方式輸入）、`--reset-domain` |
| DNS 上游 | `--set-dns "<國際 DNS>" "<國內 DNS>"` |
| Telegram Bot | `--setup-tgbot` |
| 解除安裝 | `--uninstall` |

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
