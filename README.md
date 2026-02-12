# MeshLink WiFi Gateway

WiFi access point + captive portal setup for the MeshLink decentralized internet sharing protocol. Turns a Raspberry Pi into a WiFi hotspot where clients must authenticate through the MeshLink landing page before getting internet access.

## Tested On

| Hardware | OS | Network Manager | Status |
|----------|-----|-----------------|--------|
| Raspberry Pi 5 (4GB) | Debian 13 Trixie (Raspberry Pi OS) | NetworkManager | Working |

## How It Works

```
Client connects to "MeshLink" WiFi
         |
         v
   Internet blocked (iptables FORWARD DROP)
   HTTP redirected to captive portal
         |
         v
   Device detects captive portal
   Shows "Sign in to WiFi" dialog
         |
         v
   Client sees MeshLink landing page
   Selects tier (Free / Paid)
         |
         v
   Broker adds client IP to meshlink_auth ipset
   iptables allows FORWARD for that IP
         |
         v
   Client has internet access
   (expires after tier duration)
```

## Quick Start

```bash
# SSH into your Pi
ssh meshlink@<pi-ip-address>

# Clone the repo
git clone <repo-url>
cd meshlink/meshlink-wifi-gateway

# Run the AP + captive portal installer
bash install.sh

# Then deploy the broker (captive portal web app)
cd ../broker
npm install
npm run build

# Create the broker service
sudo tee /etc/systemd/system/meshlink-broker.service > /dev/null <<EOF
[Unit]
Description=MeshLink Broker (Captive Portal + API)
After=network.target meshlink-network.service hostapd.service dnsmasq.service
Wants=meshlink-network.service

[Service]
Type=simple
User=meshlink
WorkingDirectory=/home/meshlink/meshlink/broker
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable meshlink-broker
sudo systemctl start meshlink-broker
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
| Broker port | 3000 |

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
   | NAT/masquerade        | FORWARD policy: DROP
   |<──── only for ────────| (allowed only for IPs
   |   meshlink_auth IPs   |  in meshlink_auth ipset)
                     DHCP: 192.168.50.10-100
                     DNS:  192.168.50.1 (Pi)
```

## Captive Portal Flow

1. Client connects to MeshLink WiFi, gets IP via DHCP
2. DNS resolves via the Pi's dnsmasq (works because it's INPUT, not FORWARD)
3. FORWARD chain drops all traffic from unauthenticated clients
4. HTTP (port 80) requests are DNAT'd to the broker on port 3000
5. Device OS detects captive portal, shows "Sign in to WiFi"
6. Client selects tier on the MeshLink landing page
7. Broker calls `ipset add meshlink_auth <client-ip>`
8. FORWARD chain now accepts traffic from that IP
9. Client has internet access until their session expires
10. On expiry, broker calls `ipset del meshlink_auth <client-ip>`

## Files Modified

| File | Purpose |
|------|---------|
| `/etc/hostapd/hostapd.conf` | Access point configuration |
| `/etc/dnsmasq.conf` | DHCP and DNS (clients use Pi as DNS) |
| `/etc/sysctl.d/99-meshlink.conf` | IP forwarding |
| `/etc/iptables/rules.v4` | Captive portal firewall rules |
| `/etc/iptables/ipset.rules` | Persistent ipset rules |
| `/etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf` | NM ignores wlan0 |
| `/etc/systemd/system/meshlink-network.service` | Boot persistence |
| `/etc/systemd/system/meshlink-broker.service` | Broker auto-start |
| `/etc/sudoers.d/meshlink-network` | Broker can manage iptables/ipset |

## Services

| Service | Purpose |
|---------|---------|
| `meshlink-network` | Boot: rfkill, wlan0 IP, ipset restore, iptables restore |
| `hostapd` | WiFi access point |
| `dnsmasq` | DHCP + DNS for clients |
| `meshlink-broker` | Node.js captive portal web app + API |

## Troubleshooting

### Captive portal not showing on device

Make sure the device has **forgotten and reconnected** to MeshLink WiFi to get
the latest DHCP settings (DNS must point to 192.168.50.1).

```bash
# Verify FORWARD policy is DROP
sudo iptables -L FORWARD -n

# Verify PREROUTING redirect exists
sudo iptables -t nat -L PREROUTING -n

# Check that meshlink_auth is empty (no pre-authenticated IPs)
sudo ipset list meshlink_auth

# Check broker is reachable
curl -s http://192.168.50.1:3000/api/health
```

### Client selected tier but still no internet

```bash
# Check broker logs
sudo journalctl -u meshlink-broker -n 30

# Verify client IP was added to ipset
sudo ipset list meshlink_auth

# Manually grant access to test
sudo ipset add meshlink_auth 192.168.50.XX -exist
```

### WiFi AP not starting

```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd -n 30
sudo rfkill list wlan
ip addr show wlan0
```

### After reboot, captive portal doesn't work

```bash
sudo systemctl status meshlink-network
sudo journalctl -u meshlink-network -n 20
sudo systemctl restart meshlink-network hostapd dnsmasq meshlink-broker
```

## Re-running the Installer

The script is idempotent. It flushes iptables/ipset rules before re-adding them and backs up config files only once.

## Uninstall

```bash
sudo systemctl stop meshlink-broker hostapd dnsmasq meshlink-network
sudo systemctl disable meshlink-broker hostapd dnsmasq meshlink-network
sudo rm /etc/systemd/system/meshlink-network.service
sudo rm /etc/systemd/system/meshlink-broker.service
sudo rm /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf
sudo rm /etc/sysctl.d/99-meshlink.conf
sudo rm /etc/sudoers.d/meshlink-network
sudo cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf 2>/dev/null
sudo iptables -P FORWARD ACCEPT
sudo iptables -t nat -F
sudo iptables -F FORWARD
sudo ipset destroy meshlink_auth 2>/dev/null
sudo systemctl restart NetworkManager
sudo systemctl daemon-reload
```
