#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  WireGuard Auto-Setup Script
#  One command → full VPN server + client QR code
#  Usage: sudo bash setup_wireguard.sh
# ============================================================

# --- Config (edit these if you want) ---
WG_PORT="${WG_PORT:-51820}"
SERVER_VPN_IP="${SERVER_VPN_IP:-10.0.0.1}"
CLIENT_VPN_IP="${CLIENT_VPN_IP:-10.0.0.2}"
VPN_SUBNET="${VPN_SUBNET:-10.0.0.0/24}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
OUTPUT_DIR="${OUTPUT_DIR:-/root/wireguard-client}"
# ---------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root (sudo bash $0)"

# --- Detect public IP ---
PUBLIC_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null || \
            ip -4 addr show scope global | grep -oP '(?<=inet\s)\S+' | head -1)
[[ -n "$PUBLIC_IP" ]] || die "Cannot detect public IP"
log "Public IP: $PUBLIC_IP"

# --- Detect OS and install packages ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    die "Cannot detect OS"
fi
log "Detected OS: $NAME $VERSION_ID"

case "$ID" in
    rocky|rhel|centos|fedora|almalinux)
        log "Installing wireguard-tools + qrencode + ImageMagick + xauth (dnf)..."
        dnf install -y wireguard-tools qrencode ImageMagick xorg-x11-xauth &>/dev/null || die "dnf install failed"
        FW_TYPE="firewalld"
        IMG_VIEWER="display"
        ;;
    ubuntu|debian)
        log "Installing wireguard-tools + qrencode + feh (apt)..."
        apt-get update -qq &>/dev/null
        apt-get install -y wireguard-tools qrencode feh &>/dev/null || die "apt install failed"
        # Detect if ufw is active — if so, use ufw for firewall rules
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            FW_TYPE="ufw"
        else
            FW_TYPE="iptables"
        fi
        IMG_VIEWER="feh"
        ;;
    *)
        die "Unsupported OS: $ID"
        ;;
esac

# --- Enable X11 forwarding for QR code display ---
log "Enabling X11 forwarding in sshd..."
if grep -q "^X11Forwarding no" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^X11Forwarding no/X11Forwarding yes/' /etc/ssh/sshd_config
elif ! grep -q "^X11Forwarding yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "X11Forwarding yes" >> /etc/ssh/sshd_config
fi
# Reload instead of restart to keep current connection alive
if command -v systemctl &>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
else
    kill -HUP $(cat /var/run/sshd.pid 2>/dev/null) 2>/dev/null || true
fi
log "X11 forwarding enabled (reconnect with ssh -X to use)"

# --- Generate keys ---
log "Generating WireGuard keys..."
mkdir -p /etc/wireguard
SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)

# --- Server config ---
log "Writing /etc/wireguard/wg0.conf..."
if [ "$FW_TYPE" = "firewalld" ]; then
    POST_UP="firewall-cmd --add-port=${WG_PORT}/udp && firewall-cmd --add-masquerade"
    POST_DOWN="firewall-cmd --remove-port=${WG_PORT}/udp && firewall-cmd --remove-masquerade"
elif [ "$FW_TYPE" = "ufw" ]; then
    # ufw: only FORWARD rules needed in PostUp (INPUT handled separately)
    POST_UP="iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip -4 route show default | awk '{print $5}') -j MASQUERADE"
    POST_DOWN="iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip -4 route show default | awk '{print $5}') -j MASQUERADE"
else
    POST_UP="iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip -4 route show default | awk '{print $5}') -j MASQUERADE"
    POST_DOWN="iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip -4 route show default | awk '{print $5}') -j MASQUERADE"
fi

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = ${SERVER_VPN_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = ${POST_UP}
PostDown = ${POST_DOWN}

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_VPN_IP}/32
EOF

# --- Enable IP forwarding ---
log "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf

# --- Firewall ---
log "Configuring firewall ($FW_TYPE)..."
if [ "$FW_TYPE" = "firewalld" ]; then
    systemctl is-active --quiet firewalld || systemctl start firewalld
    firewall-cmd --add-port=${WG_PORT}/udp --permanent &>/dev/null
    firewall-cmd --add-masquerade --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
elif [ "$FW_TYPE" = "ufw" ]; then
    # ufw: allow WireGuard port on INPUT
    ufw allow ${WG_PORT}/udp &>/dev/null
    log "ufw: allowed ${WG_PORT}/udp (INPUT)"
    # Note: FORWARD rules are handled by PostUp/PostDown via raw iptables
else
    IFACE=$(ip -4 route show default | awk '{print $5}')
    iptables -A FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    # Persist iptables rules
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save &>/dev/null
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
fi

# --- Start WireGuard ---
log "Starting WireGuard..."
wg-quick down wg0 &>/dev/null || true   # tear down if running
wg-quick up wg0 || die "Failed to start wg-quick@wg0"
systemctl enable wg-quick@wg0 &>/dev/null || true

# --- Client config ---
log "Generating client config..."
mkdir -p "$OUTPUT_DIR"
CLIENT_CONF="$OUTPUT_DIR/wg_client.conf"

cat > "$CLIENT_CONF" << EOF
[Interface]
Address = ${CLIENT_VPN_IP}/24
PrivateKey = ${CLIENT_PRIV}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# --- QR code ---
log "Generating QR code..."
if command -v qrencode &>/dev/null; then
    qrencode -t PNG -o "$OUTPUT_DIR/wg_client_qr.png" < "$CLIENT_CONF"
    log "QR code saved: $OUTPUT_DIR/wg_client_qr.png"
else
    warn "qrencode not found, skipping QR code"
fi

# --- Display QR code if X11 available ---
if [ -n "${DISPLAY:-}" ] && command -v "$IMG_VIEWER" &>/dev/null; then
    # Copy X11 cookie for root (sudo loses XAUTHORITY)
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -f "$USER_HOME/.Xauthority" ]; then
            xauth merge "$USER_HOME/.Xauthority" &>/dev/null || true
        fi
    fi
    log "Displaying QR code via $IMG_VIEWER (X11)..."
    "$IMG_VIEWER" "$OUTPUT_DIR/wg_client_qr.png" 2>/dev/null &
else
    warn "X11 display not available (no DISPLAY). QR code saved to file."
    echo -e "  ${YELLOW}To view QR code:${NC}"
    echo -e "    ${YELLOW}qrencode -t ANSIUTF8 < ${OUTPUT_DIR}/wg_client_qr.png 2>/dev/null || cat ${CLIENT_CONF}${NC}"
    echo -e "  ${YELLOW}Or reconnect with: ssh -X user@${PUBLIC_IP}${NC}"
    echo -e "  ${YELLOW}Then: ${IMG_VIEWER} ${OUTPUT_DIR}/wg_client_qr.png${NC}"
fi

# --- Verify ---
log "Verifying..."
wg show

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  WireGuard VPN Setup Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Server:     ${YELLOW}${PUBLIC_IP}:${WG_PORT}${NC}"
echo -e "  VPN subnet: ${YELLOW}${VPN_SUBNET}${NC}"
echo ""
echo -e "  Client config: ${YELLOW}${CLIENT_CONF}${NC}"
echo -e "  QR code:       ${YELLOW}${OUTPUT_DIR}/wg_client_qr.png${NC}"
echo ""
echo -e "  Copy config to your device:"
echo -e "    ${YELLOW}scp root@${PUBLIC_IP}:${CLIENT_CONF} .${NC}"
echo ""
