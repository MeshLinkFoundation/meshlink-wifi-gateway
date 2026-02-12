#!/bin/bash

# MeshLink WiFi Gateway - Access Point + Captive Portal Setup Script
# Tested on: Raspberry Pi 5, Raspberry Pi OS (Debian 13 Trixie), NetworkManager
#
# This script sets up a Raspberry Pi as a WiFi access point with a captive portal
# for MeshLink. New clients are blocked from internet access and redirected to the
# MeshLink broker landing page. Once they select a tier, access is granted.
#
# Components configured:
#   - hostapd:   WiFi access point
#   - dnsmasq:   DHCP + DNS for connected clients
#   - iptables:  Captive portal firewall (block by default, allow authenticated)
#   - ipset:     Tracks authenticated client IPs
#   - systemd:   Boot persistence for all network config
#   - Node.js:   MeshLink broker (captive portal web app)
#
# Usage: bash install.sh

set -e

# ─── Configuration ────────────────────────────────────────────────────────────
# Edit these variables to customize your access point

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

# ─── Helper functions ─────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────

info "MeshLink WiFi Gateway + Captive Portal Installer"
echo "────────────────────────────────────────"
echo "  SSID:         $SSID"
echo "  Password:     $WPA_PASSPHRASE"
echo "  AP IP:        $AP_IP"
echo "  DHCP range:   $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "  Channel:      $CHANNEL"
echo "  WAN:          $WAN_IFACE"
echo "  Broker port:  $BROKER_PORT"
echo "────────────────────────────────────────"

# Verify interfaces exist
if [ ! -d "/sys/class/net/$WLAN_IFACE" ]; then
    fail "Wireless interface $WLAN_IFACE not found. Check your hardware."
fi

if [ ! -d "/sys/class/net/$WAN_IFACE" ]; then
    fail "WAN interface $WAN_IFACE not found."
fi

# ─── Step 1: Update & install packages ────────────────────────────────────────

info "Updating package lists..."
sudo apt update -y

info "Installing required packages..."
sudo apt install -y hostapd dnsmasq iptables ipset iw rfkill

ok "Packages installed"

# ─── Step 2: Stop services while configuring ──────────────────────────────────

info "Stopping services for configuration..."
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# ─── Step 3: Unblock WiFi ────────────────────────────────────────────────────

info "Unblocking WiFi radio..."
sudo /usr/sbin/rfkill unblock wlan
sleep 1

if /usr/sbin/rfkill list wlan 2>/dev/null | grep -q "Soft blocked: yes"; then
    fail "Could not unblock WiFi. Check rfkill status."
fi
ok "WiFi radio unblocked"

# ─── Step 4: Configure NetworkManager to ignore wlan0 ────────────────────────

if systemctl is-active --quiet NetworkManager; then
    info "NetworkManager detected - configuring it to ignore $WLAN_IFACE..."
    sudo tee /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf > /dev/null <<NMEOF
[keyfile]
unmanaged-devices=interface-name:$WLAN_IFACE
NMEOF
    sudo systemctl restart NetworkManager
    sleep 2
    ok "NetworkManager will ignore $WLAN_IFACE"
else
    info "NetworkManager not running - skipping NM configuration"
fi

# ─── Step 5: Configure wlan0 static IP ───────────────────────────────────────

info "Setting static IP $AP_IP on $WLAN_IFACE..."
sudo ip link set "$WLAN_IFACE" up
sudo ip addr flush dev "$WLAN_IFACE"
sudo ip addr add "$AP_IP/24" dev "$WLAN_IFACE"
ok "Static IP configured on $WLAN_IFACE"

# ─── Step 6: Configure hostapd ───────────────────────────────────────────────

info "Configuring hostapd (access point)..."
sudo tee /etc/hostapd/hostapd.conf > /dev/null <<HAPEOF
# MeshLink Access Point Configuration
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

if [ -f /etc/default/hostapd ]; then
    sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
fi

ok "hostapd configured"

# ─── Step 7: Configure dnsmasq ───────────────────────────────────────────────

info "Configuring dnsmasq (DHCP/DNS)..."

if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.orig ]; then
    sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
fi

sudo tee /etc/dnsmasq.conf > /dev/null <<DNSEOF
# MeshLink DHCP/DNS Configuration
interface=$WLAN_IFACE
listen-address=$AP_IP
bind-interfaces
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$AP_NETMASK,$DHCP_LEASE
domain-needed
bogus-priv
dhcp-option=3,$AP_IP
# DNS: clients use the Pi so DNS works even when FORWARD is blocked (captive portal)
dhcp-option=6,$AP_IP
DNSEOF

ok "dnsmasq configured"

# ─── Step 8: Enable IP forwarding ────────────────────────────────────────────

info "Enabling IP forwarding..."

sudo tee /etc/sysctl.d/99-meshlink.conf > /dev/null <<SYSEOF
net.ipv4.ip_forward=1
SYSEOF

sudo /usr/sbin/sysctl -w net.ipv4.ip_forward=1 > /dev/null
ok "IP forwarding enabled"

# ─── Step 9: Configure captive portal firewall ───────────────────────────────
# Unauthenticated clients are blocked from internet and HTTP is redirected to
# the broker landing page. Once a client selects a tier, the broker adds their
# IP to the meshlink_auth ipset, which grants forwarding access.

info "Configuring captive portal firewall..."

# Create ipset for authenticated clients
sudo /usr/sbin/ipset create meshlink_auth hash:ip -exist

# Flush existing rules to avoid duplicates on re-run
sudo iptables -F FORWARD
sudo iptables -F INPUT 2>/dev/null || true
sudo iptables -t nat -F PREROUTING
sudo iptables -t nat -F POSTROUTING

# Default FORWARD policy: DROP (no internet until authenticated)
sudo iptables -P FORWARD DROP

# Allow authenticated clients (in meshlink_auth ipset) to reach the internet
sudo iptables -A FORWARD -i "$WLAN_IFACE" -o "$WAN_IFACE" -m set --match-set meshlink_auth src -j ACCEPT

# Allow return traffic for established connections
sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$WLAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# NAT: masquerade outgoing traffic
sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

# Captive portal redirect: send HTTP (port 80) from unauthenticated clients to broker
sudo iptables -t nat -A PREROUTING -i "$WLAN_IFACE" -p tcp --dport 80 \
    -m set ! --match-set meshlink_auth src -j DNAT --to-destination "$AP_IP:$BROKER_PORT"

# Allow all wlan0 clients to reach the broker, DNS, and DHCP on the Pi
sudo iptables -A INPUT -i "$WLAN_IFACE" -p tcp --dport "$BROKER_PORT" -j ACCEPT
sudo iptables -A INPUT -i "$WLAN_IFACE" -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i "$WLAN_IFACE" -p udp --dport 67 -j ACCEPT

# Persist iptables and ipset rules across reboots
sudo mkdir -p /etc/iptables
sudo sh -c "iptables-save > /etc/iptables/rules.v4"
sudo sh -c "ipset save > /etc/iptables/ipset.rules"

ok "Captive portal firewall configured"

# ─── Step 10: Configure sudoers for broker ────────────────────────────────────
# The MeshLink broker runs as non-root but needs to manage ipset entries
# to grant/revoke internet access when clients authenticate.

info "Configuring sudoers for network management..."

CURRENT_USER=$(whoami)
sudo tee /etc/sudoers.d/meshlink-network > /dev/null <<SUDEOF
# Allow MeshLink broker to manage captive portal network rules
$CURRENT_USER ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/ipset, /usr/sbin/iptables-save, /usr/sbin/iptables-restore
SUDEOF
sudo chmod 440 /etc/sudoers.d/meshlink-network

ok "Sudoers configured for $CURRENT_USER"

# ─── Step 11: Create boot persistence service ────────────────────────────────

info "Creating meshlink-network boot service..."

sudo tee /etc/systemd/system/meshlink-network.service > /dev/null <<SVCEOF
[Unit]
Description=MeshLink Network Setup (wlan0 AP + captive portal)
Before=hostapd.service dnsmasq.service meshlink-broker.service
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/rfkill unblock wlan
ExecStart=/usr/sbin/ip link set $WLAN_IFACE up
ExecStart=/usr/sbin/ip addr flush dev $WLAN_IFACE
ExecStart=/usr/sbin/ip addr add $AP_IP/24 dev $WLAN_IFACE
ExecStart=/bin/bash -c '/usr/sbin/ipset restore < /etc/iptables/ipset.rules || /usr/sbin/ipset create meshlink_auth hash:ip -exist'
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4

[Install]
WantedBy=multi-user.target
SVCEOF

ok "Boot service created"

# ─── Step 12: Enable and start everything ─────────────────────────────────────

info "Enabling services for boot..."
sudo systemctl daemon-reload
sudo systemctl unmask hostapd
sudo systemctl enable meshlink-network.service
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

info "Starting services..."
sudo systemctl start meshlink-network.service
sudo systemctl start hostapd
sudo systemctl start dnsmasq

# ─── Step 13: Verify ─────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────"
ERRORS=0

for svc in meshlink-network hostapd dnsmasq; do
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is running"
    else
        warn "$svc failed to start"
        ERRORS=$((ERRORS + 1))
    fi
done

if ip addr show "$WLAN_IFACE" | grep -q "$AP_IP"; then
    ok "$WLAN_IFACE has IP $AP_IP"
else
    warn "$WLAN_IFACE does not have expected IP"
    ERRORS=$((ERRORS + 1))
fi

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    ok "IP forwarding enabled"
else
    warn "IP forwarding not enabled"
    ERRORS=$((ERRORS + 1))
fi

if sudo iptables -L FORWARD -n | grep -q "meshlink_auth"; then
    ok "Captive portal firewall active"
else
    warn "Captive portal firewall not configured"
    ERRORS=$((ERRORS + 1))
fi

echo "────────────────────────────────────────"

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "============================================"
    echo "  MeshLink WiFi Gateway Setup Complete!"
    echo "============================================"
    echo "  SSID:         $SSID"
    echo "  Password:     $WPA_PASSPHRASE"
    echo "  Gateway IP:   $AP_IP"
    echo "  DHCP range:   $DHCP_RANGE_START - $DHCP_RANGE_END"
    echo "  Portal:       http://$AP_IP:$BROKER_PORT"
    echo "============================================"
    echo ""
    echo "  Captive portal is ACTIVE."
    echo "  Clients are blocked until they authenticate"
    echo "  via the MeshLink landing page."
    echo ""
    echo "  Next: deploy the MeshLink broker to serve"
    echo "  the captive portal web app on port $BROKER_PORT."
    echo ""
else
    warn "Setup completed with $ERRORS error(s). Check service logs:"
    echo "  sudo journalctl -u hostapd -n 20"
    echo "  sudo journalctl -u dnsmasq -n 20"
    echo "  sudo journalctl -u meshlink-network -n 20"
fi
