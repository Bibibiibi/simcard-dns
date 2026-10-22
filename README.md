# simcard-dns

> 手機只改一個「私人 DNS」，指定的網站就自動經由你的伺服器出去；其他流量照舊走手機自己的網路。不用裝任何 App。

simcard-dns 裝在一台 Linux 伺服器上，同時是加密 DNS（DoT）伺服器和透明代理：你決定哪些網域要「繞到伺服器」，伺服器再決定這些連線從哪個出口離開（代理節點、伺服器本機，或拒絕）。

目前版本：**1.1.3**

## 功能

- 分流：網域、後綴、關鍵字、GEOSITE、遠端規則集；目標可以是節點、伺服器本機、直連或拒絕
- 出口：本機直出、WireGuard，以及 SS、VMess、VLESS、Trojan、Hysteria2、TUIC、AnyTLS、SOCKS5、HTTP 節點
- 入口保護：DoT 入口只放行目前網域；接上 Cloudflare 後可一鍵換成新的隨機網域
- 港澳台連接（可選）：SSH、853、8111 只接受香港、澳門、台灣與白名單網段連入
- 管理：命令列 `simcard-dns` 與 Telegram Bot
- 1 GB 以下記憶體自動切換低資源模式

## 快速開始

**需要準備**：一台有公網 IPv4 的 Debian / Ubuntu / RHEL 系伺服器（`amd64` 或 `arm64`，建議 1 GB 記憶體）、一個託管在 Cloudflare 的網域與 API Token（Zone Read、DNS Edit）、一個 Telegram Bot Token 與你的 Telegram 數字 ID。

**1. 安裝**

```bash
curl -fsSL https://raw.githubusercontent.com/Bibibiibi/simcard-dns/main/install.sh | sudo bash
```

開頭會問 Cloudflare Token、Bot Token、管理員 ID，以及要不要讓專案接管防火牆，之後全自動。完成時會顯示一個隨機的 DoT 網域（例如 `k3x9…q2.dns.example.com`），手機就填它。升級時再執行同一行指令即可，失敗會自動回滾。

沒有 Cloudflare 的話可以用自己的網域（A 記錄先指向伺服器）：在指令前加 `env DOMAIN=dns.example.com`。

**2. 加入你的電信卡**

專案沒有內建任何電信業者。在 Telegram Bot「🛡 白名單」按「➕ 添加 ASN」，輸入手機卡業者的 ASN（例如 `AS9231`）。不知道 ASN 的話，手機關掉 Wi‑Fi 用瀏覽器打開 https://ipinfo.io ，`org` 欄開頭的 AS 號碼就是。

```bash
sudo simcard-dns --lookup-client-asn AS9231   # 先看業者名稱與網段數
sudo simcard-dns --add-client-asn AS9231
sudo simcard-dns --set-client-cidrs "203.0.113.0/24"   # 或直接指定網段（取代整份清單）
```

**3. 手機設定**

- **Android**：設定 → 網路和網際網路 → 私人 DNS → 填入 DoT 網域。
- **iOS / iPadOS**：掃安裝完成時的 QR Code，或用 Safari 開 `https://<DoT 網域>:8111/ios-dot.mobileconfig`。要重新產生描述檔與 QR Code，執行 `sudo simcard-dns -ios`（原始碼目錄可用 `./install.sh -ios`）。
- **電腦**：系統的 DoT 設定或 Stubby、cloudflared 指向 `<DoT 網域>:853`。

改完規則後手機沒有馬上生效，先切一下飛航模式或強制關閉 App（手機會快取 DNS、保留舊連線）。

## 常用指令

```bash
sudo simcard-dns --status                                     # 服務狀態
sudo simcard-dns --add-exit hk 'ss://…'                       # 新增出口節點
sudo simcard-dns --set-exit smart                             # 改用智慧分流
sudo simcard-dns --add-rule 'DOMAIN-SUFFIX,openai.com,hk'     # 網域走 hk 出口
sudo simcard-dns --add-ruleset 'https://example.com/x.mrs' hk # 整份規則集走 hk
sudo simcard-dns --geo-allow on                               # 開啟港澳台連接（需接管防火牆）
sudo simcard-dns --reset-domain                               # 換成新的隨機 DoT 網域
sudo simcard-dns --uninstall                                  # 完整清除
```

更多指令與說明：

- [安裝、升級與排障](docs/INSTALL.md)
- [日常管理與設定參考](docs/GUIDE.md)：出口、分流、手機卡接入、Bot、連接埠、環境變數
- [開發與測試](docs/DEVELOPMENT.md)

## 使用前要知道的事

- **80/443 絕不能對全網開放**，否則任何人都能把伺服器當開放代理用；專案接管防火牆時只對白名單網段放行。
- 只處理 IPv4；分流只看網域，IP 類規則只對已進入伺服器的流量有效。
- DNS 洩漏檢測看到伺服器或電信業者的 IP 是正常的（DNS 在伺服器解析，WebRTC 不經伺服器）。
- 港澳台連接按 IP 登記國家判斷，開啟後人在其他地區用當地網路時無法 SSH，請保留主控台存取。
- Bot 需要 root 權限，管理員 ID 只填自己。

## 免責聲明

本專案僅供合法的網路互通、測試與學習使用。部署前請自行確認符合當地法規、雲端業者條款與目標服務的使用條款。專案不保證在所有網路環境下可用，也不承諾規避任何審查或封鎖；因使用或設定錯誤造成的後果由使用者自行承擔。

## 授權與致謝

以 [MIT License](LICENSE) 釋出。本專案衍生自 [Xiuyixx/5GPN-X](https://github.com/Xiuyixx/5GPN-X)，在其基礎上改為電信卡公網接入，並加入規則驅動 DNS、ASN 白名單、DoT 入口守門、Cloudflare 網域重置與港澳台連接等功能。
