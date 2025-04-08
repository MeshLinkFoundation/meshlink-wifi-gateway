#!/bin/bash

# MeshLink Hotspot Setup Script for Raspberry Pi
# This script automates the process of setting up a Raspberry Pi as a Wi-Fi hotspot.
# It configures hostapd for the access point, dnsmasq for DHCP and DNS, and iptables for NAT.

# Exit immediately if any command fails to prevent partial installations
set -e

# Update the system's package list and upgrade existing packages
# This ensures we have the latest security patches and software versions
echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install required packages:
# - hostapd: Creates and manages the wireless access point
# - dnsmasq: Provides DHCP and DNS services
# - iptables: Handles network address translation (NAT)
# - vim: Text editor for manual configuration if needed
echo "Installing required packages..."
sudo apt install -y hostapd dnsmasq iptables vim

# Enable the hostapd and dnsmasq services to start on boot
# Unmask hostapd as it's masked by default on some systems
echo "Enabling hostapd and dnsmasq..."
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq

# Configure hostapd with wireless access point settings:
# - interface: Use wlan0 for wireless interface
# - driver: Use nl80211 driver for modern wireless cards
# - ssid: Network name that will be visible to users
# - hw_mode: Use 2.4GHz band (g)
# - channel: Use channel 6 (can be changed if there's interference)
# - wpa: Enable WPA2 security
# - wpa_passphrase: Network password
# - wpa_key_mgmt: Use WPA-PSK authentication
# - rsn_pairwise: Use CCMP (AES) encryption
echo "Configuring hostapd..."
cat <<EOF | sudo tee /etc/hostapd/hostapd.conf
interface=wlan0
driver=nl80211
ssid=project123
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_passphrase=meshlink2025
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# Update the hostapd default configuration to use our custom config file
echo "Updating hostapd defaults..."
sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

# Configure dnsmasq for DHCP and DNS services:
# - interface: Use wlan0 for wireless interface
# - dhcp-range: Assign IPs from 192.168.50.10 to 192.168.50.100
# - domain-needed: Don't forward queries without a domain
# - bogus-priv: Don't forward private IP ranges
# - dhcp-option=3: Set default gateway to 192.168.50.1
# - dhcp-option=6: Set DNS servers to Google's public DNS
echo "Configuring dnsmasq..."
sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
cat <<EOF | sudo tee /etc/dnsmasq.conf
interface=wlan0
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
domain-needed
bogus-priv
dhcp-option=3,192.168.50.1
dhcp-option=6,8.8.8.8,8.8.4.4
EOF

# Enable IP forwarding to allow traffic to pass between interfaces
# This is required for NAT to work properly
echo "Configuring IP forwarding..."
sudo sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sysctl -p

echo "Configuring iptables for NAT..."

# Create directory for iptables rules if it doesn't exist
sudo mkdir -p /etc/iptables

# Configure NAT rules:
# - Enable masquerading for outgoing traffic on eth0
# - Allow forwarding from wlan0 to eth0
# - Allow return traffic from eth0 to wlan0 for established connections
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Save iptables rules to make them persistent across reboots
sudo sh -c "iptables-save > /etc/iptables/rules.v4"

# Start the configured services
echo "Starting services..."
sudo systemctl start hostapd
sudo systemctl start dnsmasq

# Display completion message with connection instructions
echo "Hotspot setup complete! Please connect to the SSID 'MeshLink-Hotspot' using the password 'meshlink2025'."
