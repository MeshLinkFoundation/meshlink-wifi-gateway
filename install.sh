#!/bin/bash

# MeshLink WiFi Gateway - Access Point Setup Script
# Tested on: Raspberry Pi 5, Raspberry Pi OS (Debian 13 Trixie), NetworkManager
#
# This script sets up a Raspberry Pi as a WiFi access point for MeshLink.
# It configures hostapd (AP), dnsmasq (DHCP/DNS), iptables (NAT), and
# creates a systemd service for boot persistence.
#
# Usage: sudo bash install.sh
#   or:  bash install.sh  (script uses sudo internally)

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

# ─── Helper functions ─────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# ─── Pre-flight checks ───────────────────────────────────────────────────────

info "MeshLink WiFi Gateway Installer"
echo "────────────────────────────────────────"
echo "  SSID:       $SSID"
echo "  Password:   $WPA_PASSPHRASE"
echo "  AP IP:      $AP_IP"
echo "  DHCP range: $DHCP_RANGE_START - $DHCP_RANGE_END"
echo "  Channel:    $CHANNEL"
echo "  WAN:        $WAN_IFACE"
echo "────────────────────────────────────────"

# Verify wlan0 exists
if [ ! -d "/sys/class/net/$WLAN_IFACE" ]; then
    fail "Wireless interface $WLAN_IFACE not found. Check your hardware."
fi

# Verify eth0 (WAN) is connected
if [ ! -d "/sys/class/net/$WAN_IFACE" ]; then
    fail "WAN interface $WAN_IFACE not found."
fi

# ─── Step 1: Update & install packages ────────────────────────────────────────

info "Updating package lists..."
sudo apt update -y

info "Installing required packages..."
sudo apt install -y hostapd dnsmasq iptables iw rfkill

ok "Packages installed"

# ─── Step 2: Stop services while configuring ──────────────────────────────────

info "Stopping services for configuration..."
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true

# ─── Step 3: Unblock WiFi ────────────────────────────────────────────────────

info "Unblocking WiFi radio..."
sudo /usr/sbin/rfkill unblock wlan
sleep 1

# Verify unblocked
if /usr/sbin/rfkill list wlan 2>/dev/null | grep -q "Soft blocked: yes"; then
    fail "Could not unblock WiFi. Check rfkill status."
fi
ok "WiFi radio unblocked"

# ─── Step 4: Configure NetworkManager to ignore wlan0 ────────────────────────
# On Raspberry Pi OS (Debian Trixie+), NetworkManager manages all interfaces.
# We must tell it to leave wlan0 alone so hostapd can control it.

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

# Point hostapd daemon to our config file
if [ -f /etc/default/hostapd ]; then
    sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
fi

ok "hostapd configured"

# ─── Step 7: Configure dnsmasq ───────────────────────────────────────────────

info "Configuring dnsmasq (DHCP/DNS)..."

# Back up original config if it exists and hasn't been backed up yet
if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.orig ]; then
    sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
fi

sudo tee /etc/dnsmasq.conf > /dev/null <<DNSEOF
# MeshLink DHCP/DNS Configuration
interface=$WLAN_IFACE
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$AP_NETMASK,$DHCP_LEASE
domain-needed
bogus-priv
dhcp-option=3,$AP_IP
dhcp-option=6,8.8.8.8,8.8.4.4
DNSEOF

ok "dnsmasq configured"

# ─── Step 8: Enable IP forwarding ────────────────────────────────────────────

info "Enabling IP forwarding..."

# Use sysctl.d drop-in (works on all modern systems)
sudo tee /etc/sysctl.d/99-meshlink.conf > /dev/null <<SYSEOF
net.ipv4.ip_forward=1
SYSEOF

# Apply immediately
sudo /usr/sbin/sysctl -w net.ipv4.ip_forward=1 > /dev/null
ok "IP forwarding enabled"

# ─── Step 9: Configure iptables NAT ──────────────────────────────────────────

info "Configuring iptables for NAT..."

# Flush existing rules to avoid duplicates on re-run
sudo iptables -t nat -F POSTROUTING
sudo iptables -F FORWARD

# NAT: masquerade outgoing traffic on WAN interface
sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE

# Forward: allow traffic from AP clients to WAN
sudo iptables -A FORWARD -i "$WLAN_IFACE" -o "$WAN_IFACE" -j ACCEPT

# Forward: allow return traffic for established connections
sudo iptables -A FORWARD -i "$WAN_IFACE" -o "$WLAN_IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Persist iptables rules across reboots
sudo mkdir -p /etc/iptables
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

ok "NAT and forwarding rules configured"

# ─── Step 10: Create boot persistence service ────────────────────────────────
# This systemd service ensures wlan0 is properly configured on every boot
# before hostapd and dnsmasq start.

info "Creating meshlink-network boot service..."

sudo tee /etc/systemd/system/meshlink-network.service > /dev/null <<SVCEOF
[Unit]
Description=MeshLink Network Setup (wlan0 AP interface)
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

# ─── Step 11: Enable and start everything ─────────────────────────────────────

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

# ─── Step 12: Verify ─────────────────────────────────────────────────────────

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

# Check wlan0 has correct IP
if ip addr show "$WLAN_IFACE" | grep -q "$AP_IP"; then
    ok "$WLAN_IFACE has IP $AP_IP"
else
    warn "$WLAN_IFACE does not have expected IP"
    ERRORS=$((ERRORS + 1))
fi

# Check IP forwarding
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    ok "IP forwarding enabled"
else
    warn "IP forwarding not enabled"
    ERRORS=$((ERRORS + 1))
fi

echo "────────────────────────────────────────"

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "============================================"
    echo "  MeshLink WiFi Gateway Setup Complete!"
    echo "============================================"
    echo "  SSID:       $SSID"
    echo "  Password:   $WPA_PASSPHRASE"
    echo "  Gateway IP: $AP_IP"
    echo "  DHCP range: $DHCP_RANGE_START - $DHCP_RANGE_END"
    echo "============================================"
    echo ""
    echo "  Connect a device to '$SSID' to test."
    echo ""
else
    warn "Setup completed with $ERRORS error(s). Check service logs:"
    echo "  sudo journalctl -u hostapd -n 20"
    echo "  sudo journalctl -u dnsmasq -n 20"
    echo "  sudo journalctl -u meshlink-network -n 20"
fi
