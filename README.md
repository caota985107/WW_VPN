# WW_VPN

日區 VPN 環境 — 自建 WireGuard VPN 伺服器，用於解決特定手機遊戲海外連線時商城幣值跑掉的問題。

## 為什麼要自己架 VPN？

- 部分手機遊戲商城幣值根據 IP 地理位置判定（PC/官網版）
- 在海外使用 eSIM 或當地網路時，IP 被判定為其他地區 → 商城幣值跑掉
- 掛日本 VPS 的 WireGuard VPN → IP 變日本 → 商城回到日圓
- 比商用 VPN 穩定，不會被遊戲偵測到共用 IP

## 檔案說明

| 檔案 | 用途 |
|------|------|
| `setup_wireguard.sh` | 一鍵架設 WireGuard 伺服器，支援 Rocky Linux / Ubuntu，自動偵測 firewalld / ufw / iptables |

## 快速開始

```bash
# 在 VPS 上執行（需要 root）
sudo bash setup_wireguard.sh
```

腳本會自動：
1. 偵測 OS 並安裝 WireGuard + 相關套件
2. 產生伺服器與客戶端金鑰
3. 設定防火牆（firewalld / ufw / iptables）
4. 啟動 WireGuard 並設為開機自動啟動
5. 輸出客戶端設定檔（含 QR code）

客戶端設定檔會存在 `/root/wireguard-client/wg_client.conf`，匯入 WireGuard App 即可連線。

## 自訂參數

```bash
WG_PORT=51821 CLIENT_DNS=8.8.8.8 sudo -E bash setup_wireguard.sh
```

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `WG_PORT` | 51820 | WireGuard 監聽埠 |
| `SERVER_VPN_IP` | 10.0.0.1 | VPN 伺服器內部 IP |
| `CLIENT_VPN_IP` | 10.0.0.2 | VPN 客戶端內部 IP |
| `CLIENT_DNS` | 1.1.1.1 | 客戶端 DNS |
