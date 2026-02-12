#!/bin/bash

# MeshLink WiFi Gateway - Access Point + Captive Portal Setup
# Tested on: Raspberry Pi 5, Raspberry Pi OS (Debian 13 Trixie), NetworkManager
#
# Sets up:
#   1. WiFi access point (hostapd)
#   2. DHCP + DNS for clients (dnsmasq)
#   3. NAT so clients get internet
#   4. HTTP redirect to captive portal (iptables REDIRECT port 80 → broker)
#   5. Boot persistence (systemd service)
#   6. MeshLink broker (Node.js captive portal app)
#
# Usage: bash install.sh

set -e

# ─── Configuration ────────────────────────────────────────────────────────────

SSID="MeshLink"
WPA_PASSPHRASE="meshlink2025"
AP_IP="192.168.50.1"
AP_NETMASK="255.255.255.0"
DHCP_RANGE_START="192.168.50.10"
DHCP_RANGE_END="192.168.50.100"
DHCP_LEASE="24h"
CHANNEL=6
COUNTRY_CODE="US"
WLAN_IFACE="wlan0"
WAN_IFACE="eth0"
BROKER_PORT=3000

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ─── Pre-flight ───────────────────────────────────────────────────────────────

info "MeshLink WiFi Gateway Installer"
echo "────────────────────────────────────────"
echo "  SSID:       $SSID"
echo "  Password:   $WPA_PASSPHRASE"
echo "  Gateway:    $AP_IP"
echo "  DHCP:       $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "  Channel:    $CHANNEL"
echo "  Broker:     http://$AP_IP:$BROKER_PORT"
echo "────────────────────────────────────────"

[ -d "/sys/class/net/$WLAN_IFACE" ] || fail "$WLAN_IFACE not found"
[ -d "/sys/class/net/$WAN_IFACE" ] || fail "$WAN_IFACE not found"

# ─── 1. Install packages ─────────────────────────────────────────────────────

info "Installing packages..."
sudo apt update -y
sudo apt install -y hostapd dnsmasq iptables iw rfkill
ok "Packages installed"

# ─── 2. Stop services while configuring ───────────────────────────────────────

sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# ─── 3. Tell NetworkManager to ignore wlan0 ─────────────────────────────────

if systemctl is-active --quiet NetworkManager; then
    info "Configuring NetworkManager to ignore $WLAN_IFACE..."
    sudo tee /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf > /dev/null <<NMEOF
[keyfile]
unmanaged-devices=interface-name:$WLAN_IFACE
NMEOF
    sudo systemctl restart NetworkManager
    sleep 2
    ok "NetworkManager ignoring $WLAN_IFACE"
fi

# ─── 4. Unblock WiFi & bring up wlan0 ───────────────────────────────────────
# Must happen AFTER NetworkManager restart (NM can re-block the radio)

info "Unblocking WiFi..."
sudo /usr/sbin/rfkill unblock wlan
sleep 2
ok "WiFi unblocked"

# ─── 5. Static IP on wlan0 ───────────────────────────────────────────────────

info "Setting $AP_IP on $WLAN_IFACE..."
sudo ip link set "$WLAN_IFACE" up
sudo ip addr flush dev "$WLAN_IFACE"
sudo ip addr add "$AP_IP/24" dev "$WLAN_IFACE"
ok "Static IP set"

# ─── 6. hostapd (access point) ───────────────────────────────────────────────

info "Configuring hostapd..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<HAPEOF
interface=$WLAN_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
auth_algs=1
wpa=2
wpa_passphrase=$WPA_PASSPHRASE
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wmm_enabled=1
country_code=$COUNTRY_CODE
ieee80211n=1
HAPEOF

[ -f /etc/default/hostapd ] && sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
ok "hostapd configured"

# ─── 7. dnsmasq (DHCP + DNS) ─────────────────────────────────────────────────
# CRITICAL: bind-interfaces + listen-address keeps dnsmasq off localhost
# so it never breaks the Pi's own DNS / SSH access.

info "Configuring dnsmasq..."

[ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.orig ] && sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

# Disable dnsmasq's resolvconf integration (prevents it from overwriting /etc/resolv.conf)
sudo tee /etc/default/dnsmasq > /dev/null <<'DEFEOF'
DNSMASQ_EXCEPT="lo"
IGNORE_RESOLVCONF=yes
DEFEOF

sudo tee /etc/dnsmasq.conf > /dev/null <<DNSEOF
# MeshLink - DHCP + DNS for WiFi clients only
interface=$WLAN_IFACE
listen-address=$AP_IP
bind-interfaces
no-resolv
server=8.8.8.8
server=8.8.4.4
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$AP_NETMASK,$DHCP_LEASE
domain-needed
bogus-priv
dhcp-option=3,$AP_IP
dhcp-option=6,$AP_IP
DNSEOF

ok "dnsmasq configured"

# ─── 8. IP forwarding ────────────────────────────────────────────────────────

info "Enabling IP forwarding..."
sudo tee /etc/sysctl.d/99-meshlink.conf > /dev/null <<SYSEOF
net.ipv4.ip_forward=1
SYSEOF
sudo /usr/sbin/sysctl -w net.ipv4.ip_forward=1 > /dev/null
ok "IP forwarding enabled"

# ─── 9. iptables (NAT + captive portal redirect) ─────────────────────────────
# All clients get internet. HTTP port 80 is redirected to the broker so
# devices auto-detect the captive portal and show "Sign in to WiFi".

info "Configuring iptables..."

sudo iptables -F FORWARD 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true

# FORWARD: allow all traffic (no blocking for now)
sudo iptables -P FORWARD ACCEPT
sudo iptables -A FORWARD -i "$WLAN_IFACE" -o "$WAN_IFACE" -j ACCEPT
sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$WLAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# NAT
sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

# Captive portal: redirect HTTP (port 80) to the broker
# Devices check http://connectivitycheck.gstatic.com/generate_204 (Android),
# http://captive.apple.com/hotspot-detect.html (Apple), etc.
# REDIRECT intercepts any port 80 traffic and sends it to the broker.
# The broker returns 200 HTML instead of 204, triggering "Sign in to WiFi".
sudo iptables -t nat -A PREROUTING -i "$WLAN_IFACE" -p tcp --dport 80 -j REDIRECT --to-port "$BROKER_PORT"

# Save rules
sudo mkdir -p /etc/iptables
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

ok "iptables configured (NAT + captive portal redirect)"

# ─── 10. Boot persistence ────────────────────────────────────────────────────

info "Creating boot service..."

sudo tee /etc/systemd/system/meshlink-network.service > /dev/null <<SVCEOF
[Unit]
Description=MeshLink Network Setup
Before=hostapd.service dnsmasq.service
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/rfkill unblock wlan
ExecStart=/usr/sbin/ip link set $WLAN_IFACE up
ExecStart=/usr/sbin/ip addr flush dev $WLAN_IFACE
ExecStart=/usr/sbin/ip addr add $AP_IP/24 dev $WLAN_IFACE
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
SVCEOF

ok "Boot service created"

# ─── 11. Enable & start ──────────────────────────────────────────────────────

info "Enabling services..."
sudo systemctl daemon-reload
sudo systemctl unmask hostapd
sudo systemctl enable meshlink-network.service hostapd dnsmasq

info "Starting services..."
sudo systemctl start meshlink-network.service
sudo systemctl start hostapd
sudo systemctl start dnsmasq

# ─── 12. Install Node.js & deploy broker ─────────────────────────────────────

if ! command -v node &>/dev/null; then
    info "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
fi
ok "Node.js $(node --version)"

BROKER_DIR="$(cd "$(dirname "$0")/../broker" 2>/dev/null && pwd)" || true

if [ -d "$BROKER_DIR" ]; then
    info "Building MeshLink broker..."
    cd "$BROKER_DIR"

    # Remove macOS-specific esbuild if present
    sed -i '/@esbuild\/darwin-arm64/d' package.json 2>/dev/null || true

    npm install
    npm run build

    # Sudoers for broker network management
    CURRENT_USER=$(whoami)
    sudo tee /etc/sudoers.d/meshlink-network > /dev/null <<SUDEOF
$CURRENT_USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/ipset, /usr/sbin/iptables-save, /usr/sbin/iptables-restore
SUDEOF
    sudo chmod 440 /etc/sudoers.d/meshlink-network

    # Create broker service
    sudo tee /etc/systemd/system/meshlink-broker.service > /dev/null <<BRKEOF
[Unit]
Description=MeshLink Broker
After=network.target meshlink-network.service hostapd.service dnsmasq.service

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$BROKER_DIR
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$BROKER_PORT

[Install]
WantedBy=multi-user.target
BRKEOF

    sudo systemctl daemon-reload
    sudo systemctl enable meshlink-broker
    sudo systemctl start meshlink-broker
    sleep 2
    ok "Broker running on port $BROKER_PORT"
else
    warn "Broker directory not found at $BROKER_DIR - skipping broker setup"
    echo "  Deploy the broker manually, then create the meshlink-broker service."
fi

# ─── 13. Verify ──────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
ERRORS=0

for svc in meshlink-network hostapd dnsmasq; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc running"
    else
        warn "$svc not running"
        ERRORS=$((ERRORS + 1))
    fi
done

systemctl is-active --quiet meshlink-broker && ok "meshlink-broker running" || warn "meshlink-broker not running"

ip addr show "$WLAN_IFACE" 2>/dev/null | grep -q "$AP_IP" && ok "$WLAN_IFACE has $AP_IP" || warn "$WLAN_IFACE missing IP"
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && ok "IP forwarding on" || warn "IP forwarding off"

# Verify Pi's own DNS still works (the bug that broke SSH last time)
if host google.com > /dev/null 2>&1 || dig +short google.com > /dev/null 2>&1 || getent hosts google.com > /dev/null 2>&1; then
    ok "Pi DNS resolution works"
else
    warn "Pi DNS may be broken - check /etc/resolv.conf"
fi

echo "────────────────────────────────────────"

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "============================================"
    echo "  MeshLink WiFi Gateway Ready!"
    echo "============================================"
    echo "  SSID:       $SSID"
    echo "  Password:   $WPA_PASSPHRASE"
    echo "  Portal:     http://$AP_IP:$BROKER_PORT"
    echo "============================================"
    echo ""
    echo "  Clients get internet + HTTP redirects"
    echo "  to the captive portal landing page."
    echo ""
fi
