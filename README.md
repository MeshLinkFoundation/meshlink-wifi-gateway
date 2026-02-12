# MeshLink WiFi Gateway

WiFi access point setup for MeshLink decentralized internet sharing protocol. Turns a Raspberry Pi into a WiFi hotspot that clients connect to for MeshLink-managed internet access.

## Tested On

| Hardware | OS | Network Manager | Status |
|----------|-----|-----------------|--------|
| Raspberry Pi 5 (4GB) | Debian 13 Trixie (Raspberry Pi OS) | NetworkManager | Working |

## What It Does

The `install.sh` script automates the full AP setup:

1. Installs `hostapd`, `dnsmasq`, `iptables`, `iw`, `rfkill`
2. Unblocks the WiFi radio (Pi 5 has WiFi soft-blocked by default)
3. Tells NetworkManager to ignore `wlan0` so hostapd can control it
4. Assigns a static IP (`192.168.50.1`) to `wlan0`
5. Configures hostapd for WPA2 access point
6. Configures dnsmasq for DHCP (client IP range: `.10`-`.100`)
7. Enables IP forwarding and NAT (masquerade via `eth0`)
8. Creates a `meshlink-network` systemd service for boot persistence
9. Verifies all services are running

## Quick Start

```bash
# SSH into your Pi
ssh meshlink@<pi-ip-address>

# Clone the repo (or copy install.sh)
git clone <repo-url>
cd meshlink/meshlink-wifi-gateway

# Run the installer
bash install.sh
```

## Default Configuration

| Setting | Value |
|---------|-------|
| SSID | `MeshLink` |
| Password | `meshlink2025` |
| AP IP / Gateway | `192.168.50.1` |
| DHCP range | `192.168.50.10` - `192.168.50.100` |
| Channel | 6 (2.4 GHz) |
| WAN interface | `eth0` |
| Security | WPA2-PSK (AES/CCMP) |

Edit the variables at the top of `install.sh` to customize.

## Network Architecture

```
Internet
   |
   | (ethernet)
   |
[eth0] Raspberry Pi 5 [wlan0] ──── WiFi clients
192.168.0.x (DHCP)     192.168.50.1 (AP)
   |                      |
   |    NAT/masquerade     |
   |<──────────────────────|
                     DHCP: 192.168.50.10-100
```

## Files Modified

| File | Purpose |
|------|---------|
| `/etc/hostapd/hostapd.conf` | Access point configuration |
| `/etc/dnsmasq.conf` | DHCP and DNS configuration |
| `/etc/sysctl.d/99-meshlink.conf` | IP forwarding |
| `/etc/iptables/rules.v4` | NAT and forwarding rules |
| `/etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf` | Tells NM to ignore wlan0 |
| `/etc/systemd/system/meshlink-network.service` | Boot persistence for wlan0 setup |

## Services

| Service | Purpose |
|---------|---------|
| `meshlink-network` | Sets up wlan0 IP, rfkill unblock, iptables restore on boot |
| `hostapd` | Manages the WiFi access point |
| `dnsmasq` | DHCP server for connected clients |

## Troubleshooting

### WiFi AP not starting

```bash
# Check hostapd status and logs
sudo systemctl status hostapd
sudo journalctl -u hostapd -n 30

# Verify WiFi is not RF-blocked
sudo rfkill list wlan

# Verify wlan0 has the correct IP
ip addr show wlan0
```

### Clients can't get an IP

```bash
# Check dnsmasq
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -n 30

# Check DHCP leases
cat /var/lib/misc/dnsmasq.leases
```

### Clients can't reach the internet

```bash
# Check IP forwarding
cat /proc/sys/net/ipv4/ip_forward  # should be 1

# Check NAT rules
sudo iptables -t nat -L -n

# Check forwarding rules
sudo iptables -L FORWARD -n

# Test from the Pi itself
ping -c 2 8.8.8.8
```

### After reboot, AP doesn't work

```bash
# Check boot service
sudo systemctl status meshlink-network
sudo journalctl -u meshlink-network -n 20

# Manually restart everything
sudo systemctl restart meshlink-network
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq
```

## Re-running the Installer

The script is idempotent - safe to run multiple times. It flushes iptables rules before re-adding them and backs up config files only once (`.orig` suffix).

## Uninstall

```bash
sudo systemctl stop hostapd dnsmasq meshlink-network
sudo systemctl disable hostapd dnsmasq meshlink-network
sudo rm /etc/systemd/system/meshlink-network.service
sudo rm /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf
sudo rm /etc/sysctl.d/99-meshlink.conf
sudo cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf 2>/dev/null
sudo iptables -t nat -F
sudo iptables -F FORWARD
sudo systemctl restart NetworkManager
sudo systemctl daemon-reload
```
