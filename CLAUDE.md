# simcard-dns 專案記憶

> 這份檔案會提交到公開的 GitHub，**不要寫入任何伺服器 IP、網域、權杖或帳號資訊**。
> 環境相關的資訊（伺服器、網域、目前狀態、待辦）放在 `CLAUDE.local.md`（已加入 `.gitignore`）。

## 語言與溝通

- 所有對話、說明、文件、錯誤提示與計畫選項一律使用**繁體中文**，包括工具呼叫之間的進度說明。長任務中途也不能切回英文。
- 程式碼、指令、日誌原文、提交訊息（commit message）可以保持英文。

## 使用者偏好與工作方式

- 修改伺服器防火牆時**不要**設定自動回滾保險，直接改；改完用一個全新的 SSH 連線驗證即可。
- **不要用使用者的 Mac 當測試用戶端**（例如把 Mac 的出口 IP 加進白名單來測試）。改用伺服器本身的公網 IP 或本機測試實例。
- 不替使用者執行第三方腳本（例如 AKDNS 的安裝腳本），也不經手任何權杖、密碼：讓使用者自己在伺服器上輸入（例如 `--setup-cloudflare` 會隱藏輸入）。
- 提交流程：在新分支提交 → `git merge --ff-only` 回 `main`。**未經同意不推送到 GitHub。**
- 每個功能都要：寫測試 → 在伺服器（Linux）跑完整測試與 shellcheck → 部署 → 實測驗證 → 使用者確認後再合併。

## 專案定位（目前）

伺服器端透明代理閘道：手機只設定私人 DNS（DoT），不用安裝任何 App。
**只有命中分流規則的網域**才會被 DNS 引到伺服器，再依規則選出口；其他網域一律正常解析、由手機自己的網路直連。
原本的 `172.22.0.0/16` 5G 內網模式已移除，客戶端改為「電信業者公網出口網段」（預設 CTMO，AS136167）。

## 架構與資料流

```
手機 ──DoT(853)──▶ dot-gate ──▶ mosdns(127.0.0.1:8853) ──▶ 規則命中？──是──▶ 回伺服器 IP
                    │ 只放行 SNI=目前網域                    └─否──▶ 正常解析（ChinaList 走國內 DNS，其他走國際 DNS）
                    │ 白名單內以 127.0.0.2、白名單外以 127.0.0.3 連 mosdns
手機 ──TCP 80/443、UDP 443──▶ wa-shim / sniproxy / quic-proxy（使用者 pxout）
                    ──▶ 出口：nft 打標 0x1 → 路由表 100 → TUN（mihomo smart / 節點）或本機直出
```

| 元件 | 說明 |
|---|---|
| `lib/dot-gate.py` | 公網 853 入口。讀 TLS ClientHello 的 SNI，只放行目前網域；網域變更後約 2 秒切斷舊名稱的既有連線；拒絕紀錄每分鐘每 (IP, 名稱) 只記一筆 |
| `lib/mosdns.yaml.template` | `proxy_client`：規則封鎖→拒絕、規則網域→伺服器 IP、其餘正常解析；`other_client`：正常解析；AAAA 全部過濾 |
| `lib/update-rules.sh` | 產生 mosdns 設定（交易式發佈）；`build_rule_domains` 從分流規則產生 `rule-domains.txt` / `rule-block.txt`（`.mrs` 改讀同目錄 `.list`；`--render-only` 不連網） |
| `lib/mihomo-router-config.py` | smart 出口設定；規則目標 `local`=伺服器本機出口、`direct`=不經伺服器、`block`=拒絕 |
| `lib/host-setup.sh` | 防火牆（preserve / auto / managed）、`pgw_exit` 表（`ct direction reply` 排除回包、`no_self_loop` 禁止代理連回本機 80/443）、地區白名單 `--geo-allow` |
| `lib/dns.sh` | 客戶端網段 `--set-client-cidrs`、ASN 白名單 `--add/--del/--list/--lookup-client-asn`、網域與 DNS 設定 |
| `lib/cert.sh` | 憑證；Cloudflare `--setup-cloudflare`、`--reset-domain`（通配符 `*.dns.<zone>`，新安裝 `.cert_lineage=simcard-dns-wildcard`；從 5GPN-X 搬遷的主機沿用 `5gpn-wildcard`） |
| `lib/tgbot.py` | Telegram Bot：狀態、出口、分流、🛡 白名單、👥 連入 IP（含 SSH 登入狀態）、域名 DNS 管理（重置網域） |

## 重要設計決策

- **規則驅動 DNS**：規則變更（`regen_smart`）後自動 `update-mosdns-rules.sh --offline` 重建 DNS 名單。IP 類規則（IP-CIDR、GEOIP）只對已進入伺服器的流量有效，`FINAL` 無作用。
- **重置網域**：憑證用通配符（不洩漏具體名稱到憑證透明度日誌），解析用具體 A 記錄（TTL 60、僅 DNS），重置時刪除舊名稱指向本機的 A 記錄；真正讓舊名稱「立即」失效的是 dot-gate 的 SNI 檢查。
- **managed 防火牆**：修改客戶端網段時只就地改寫 `/etc/nftables.conf` 中 80/443 兩行放行規則（`refresh_managed_client_rules`），不整份覆寫。主機上有其他服務（轉發、代理）時不要用 managed。
- **地區白名單（`--geo-allow`）**：只支援 managed nft。SSH、853、8111 的新 TCP 連線只接受港澳台（APNIC 登記國家，IPv4＋IPv6）與客戶端網段。規則全在 `/etc/simcard-dns/geo-allow.nft`（集合 `geo_allow4/6`＋鏈 `geo_gate`，先宣告再 flush，可單獨重載）；`/etc/nftables.conf` 只就地加 `include` 與 `ct state` 後的 `jump geo_gate`，關閉時鏈為空、掛鉤保留，開關與更新都不重載整份規則。客戶端網段在產生時併入集合，`set_client_cidrs` 會同步。下載驗 MD5、記錄數、縮水一半以上拒絕，失敗保留舊名單；`simcard-dns-geo-update.timer` 每日更新。開啟前檢查 `SSH_CONNECTION` 與 `who --ips` 來源，不在範圍內拒絕（`PGW_GEO_FORCE=1` 強制）。限制：登記在其他 RIR 的港台澳雲端 IP 會被擋（例如伺服器本身的 IP 不在名單內，本機連線走 lo 不受影響）。
- **命名**：專案原名 5GPN-X，已全面改名 simcard-dns：程式 `/opt/simcard-dns`（CLI `bin/simcard-dns`，另有 `/usr/local/bin/simcard-dns` 包裝腳本，不能用符號連結，因為入口靠自身路徑找 `lib/`）、設定 `/etc/simcard-dns`、單元與輔助腳本 `simcard-dns-*`、iOS 識別碼 `com.simcard-dns.*`。內部前綴 `PGW_`、`pgw_exit`、使用者 `pxout` 沒改。
- **舊主機搬遷（`lib/migrate.sh`）**：`--upgrade` 一開始呼叫 `migrate_legacy_layout`：先把所有會動到的檔案打包到 `/var/backups/simcard-dns/migrate.*/legacy.tar.gz`，停掉專案服務，搬目錄、改單元與啟用連結、certbot hook、輔助腳本名稱，再用 perl 改寫專案檔案（含舊程式 `bin/`）裡的舊名稱，重載 nft，以新名稱啟動原本在跑的服務；任何一步失敗就整包還原並啟動舊服務。憑證 lineage `5gpn-wildcard` 不改名（`cert.sh` 偵測到就沿用）。一行安裝指令看到 `/opt/5gpn` 也會判定為升級。
- **白名單是安全邊界**：80/443 只對客戶端網段開放；`0.0.0.0/0`（含合併後等於它的清單）會被拒絕。
- 升級（`--upgrade`）會重新產生 `pgw-exit.nft`、啟用 dot-gate；失敗回滾時先停 dot-gate 再還原 mosdns。

## 開發與測試

- 測試：`tests/*.sh`、`tests/*.py`。很多測試需要 Linux／root，macOS 上會失敗：**以伺服器（Linux）的結果為準**。
- 在伺服器跑：把工作目錄打包上傳到 `/tmp/simcard-dns-tests` 後逐一執行，再 `shellcheck -x install.sh lib/*.sh tests/*.sh`。
- 已知環境性失敗：`test_checksum_abort.sh` 在已安裝 mosdns 的主機上必然失敗，與修改無關。
- 部署：上傳到伺服器 `/root/simcard-dns-x` 後執行 `bash install.sh --upgrade`（有交易快照與回滾）。
- macOS 的 bash 是 3.2：不支援 `${var^^}`、`${var,,}`；`sed -i` 需要 `-i ''`；沒有 `timeout`（可用 `perl -e 'alarm 60; exec @ARGV' 指令`）。
- 測試不可讀取主機真實設定：`test_dns_transaction.py` 已用 `PGW_RULES_FILE`、`PGW_POLICY_MAP` 等環境變數隔離。
- awk 擷取函式（`/^name\(\)/,/^}/`）遇到 heredoc 或 Python 內有行首 `}` 時會截斷，改用「擷取到下一個函式為止」。
- `set -o pipefail` 下 `nft list … | grep -q` 可能因 SIGPIPE 回傳失敗：先把輸出存進變數再比對。
- 需要真實 nft 行為的測試，在 Linux/root 下用拋棄式 network namespace（veth 兩端各一個 netns）載入規則並送封包，不碰主機防火牆（見 `tests/test_geo_allow_policy.sh`）。

## 踩過的坑（排查時先想到這些）

- **規則改了但手機沒分流**：手機和 App 會快取 DNS 結果、保持舊連線。先開關飛航模式或強制關閉 App 再測。
- **Bot「更新規則」卡住**：曾是 apply-exit 以 `ExecStartPost` 阻塞啟動自己造成的死鎖，已改 `systemctl start --no-block`。
- **sniproxy 啟動失敗「compiled without libudns」**：上游 `--enable-dns` 反而關閉 DNS，不要傳；編譯前需要 `gettext`。
- **80 連接埠被掃到後連線暴增**：Host/SNI 指向本機會讓 sniproxy 自己連自己，已由 `no_self_loop` 防止。
- **系統 DNS 被第三方腳本（如 AKDNS）接管**：mosdns 不讀系統 DNS 不受影響，但 smart 引擎的 `local` 出口和伺服器自身的解析會改用它；AKDNS 不解析使用者自己的網域，重置網域的生效檢查依賴 `dig` 對公共 DNS 查詢。
- **WebRTC／DNS 洩漏檢測顯示香港或手機業者 IP**：這是設計使然（DNS 在伺服器解析、STUN 走 UDP 非 443 不經伺服器），不是故障。
- OpenSSH ≥ 9.8 的連線程序叫 `sshd-session`，判斷登入狀態要一併辨識。
