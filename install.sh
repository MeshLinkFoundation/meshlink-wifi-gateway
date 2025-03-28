#!/bin/bash

# MeshLink Hotspot Setup Script for Raspberry Pi
# This script automates the process of setting up a Raspberry Pi as a Wi-Fi hotspot.

set -e  # Exit immediately if a command exits with a non-zero status


echo "Updating system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing required packages..."
sudo apt install -y hostapd dnsmasq iptables vim

echo "Enabling hostapd and dnsmasq..."
sudo systemctl unmask hostapd
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq


sudo apt-get install libmicrohttpd-dev

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
ignore_broadcast_ssid=0
beacon_int=100
EOF

echo "Updating hostapd defaults..."
sudo sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

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

echo "Configuring IP forwarding..."
sudo sed -i 's|#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|' /etc/sysctl.conf
sudo sysctl -p



echo "Configuring iptables for NAT..."


sudo mkdir -p /etc/iptables
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state ESTABLISHED,RELATED -j ACCEPT

sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

sudo sh -c "iptables-save > /etc/iptables/rules.v4"

echo "Configuring wireless interface for AP mode..."
# Unblock wireless interface
sudo rfkill unblock wifi
# Bring down the interface
sudo ifconfig wlan0 down
# Configure the interface with a static IP
sudo ifconfig wlan0 192.168.50.1 netmask 255.255.255.0
# Bring up the interface
sudo ifconfig wlan0 up
# Wait a moment for the interface to stabilize
sleep 2

echo "Starting services..."
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq

echo "Hotspot setup complete! Please connect to the SSID 'project123' using the password 'meshlink2025'."
