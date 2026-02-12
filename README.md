# MeshLink WiFi Gateway

WiFi access point + captive portal setup for the MeshLink decentralized internet sharing protocol. Turns a Raspberry Pi into a WiFi hotspot that shows a "Sign in to WiFi" landing page when clients connect.

## Tested On

| Hardware | OS | Network Manager | Status |
|----------|-----|-----------------|--------|
| Raspberry Pi 5 (4GB) | Debian 13 Trixie (Raspberry Pi OS) | NetworkManager | Working |

## How It Works

```
Client connects to "MeshLink" WiFi
         |
         v
   Gets IP via DHCP, internet works immediately
   (FORWARD policy: ACCEPT)
         |
         v
   Device does HTTP captive portal check
   (e.g. GET http://connectivitycheck.gstatic.com/generate_204)
         |
         v
   iptables REDIRECT intercepts port 80 traffic
   Sends it to the MeshLink broker on port 3000
         |
         v
   Broker returns 200 HTML instead of 204
   Device detects captive portal
   Shows "Sign in to WiFi" dialog
         |
         v
   Client sees MeshLink landing page
   Selects tier (Free / Paid)
```

## Quick Start

The `install.sh` script handles everything end-to-end: AP setup, DHCP/DNS, NAT, captive portal redirect, Node.js install, broker build, and systemd services.

```bash
# SSH into your Pi
ssh meshlink@<pi-ip-address>

# Clone the repo
git clone <repo-url>
cd meshlink/meshlink-wifi-gateway

# Run the installer
bash install.sh
```

That's it. The script installs all packages, configures the AP, builds the broker, and starts all services.

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
   | NAT/masquerade        | FORWARD policy: ACCEPT
   |<─────────────────────-| (all clients get internet)
   |                      |
                     DHCP: 192.168.50.10-100
                     DNS:  192.168.50.1 (Pi → 8.8.8.8)
                     Port 80: REDIRECT → broker:3000
```

## Captive Portal Flow

1. Client connects to MeshLink WiFi, gets IP via DHCP
2. DNS resolves normally via the Pi's dnsmasq (forwards to 8.8.8.8)
3. Device does HTTP captive portal check (e.g. `GET /generate_204` to Google)
4. iptables `REDIRECT` intercepts port 80 traffic and sends it to broker on port 3000
5. Broker returns 200 HTML (not 204), triggering captive portal detection
6. Device shows "Sign in to WiFi" dialog with the MeshLink landing page
7. Client selects a tier on the landing page

### Important: Why REDIRECT, not DNAT or DNS hijacking

- **REDIRECT** (not DNAT) is required because DNAT to a local IP can have routing issues
- **Do NOT hijack DNS** for captive portal detection domains — Android/MIUI switches to HTTPS-only when it sees local IPs in DNS responses, which breaks detection since we don't have a TLS cert
- **Do NOT redirect port 443** — TLS handshake failures are not interpreted as "captive portal" by Android
- The working approach: let DNS resolve normally, REDIRECT port 80 only, broker returns HTML

## Files Modified

| File | Purpose |
|------|---------|
| `/etc/hostapd/hostapd.conf` | Access point configuration |
| `/etc/dnsmasq.conf` | DHCP and DNS for WiFi clients only |
| `/etc/default/dnsmasq` | Disables resolvconf integration (prevents DNS breakage) |
| `/etc/sysctl.d/99-meshlink.conf` | IP forwarding |
| `/etc/iptables/rules.v4` | NAT + captive portal REDIRECT rules |
| `/etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf` | NM ignores wlan0 |
| `/etc/systemd/system/meshlink-network.service` | Boot persistence (rfkill, IP, iptables) |
| `/etc/systemd/system/meshlink-broker.service` | Broker auto-start |
| `/etc/sudoers.d/meshlink-network` | Broker can manage iptables/ipset |

## Services

| Service | Purpose |
|---------|---------|
| `meshlink-network` | Boot: rfkill unblock, wlan0 IP, iptables restore |
| `hostapd` | WiFi access point |
| `dnsmasq` | DHCP + DNS for clients |
| `meshlink-broker` | Node.js captive portal web app + API |

## Troubleshooting

### Captive portal not showing on device

**Forget and reconnect** to MeshLink WiFi — the device only checks for captive portals on fresh connections.

```bash
# Verify REDIRECT rule exists
sudo iptables -t nat -L PREROUTING -n -v

# Check broker is running and reachable
sudo systemctl status meshlink-broker
curl -s http://192.168.50.1:3000/api/health
```

### WiFi AP not starting

```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd -n 30
sudo rfkill list wlan
ip addr show wlan0
```

### Pi lost SSH / DNS broken

This can happen if dnsmasq's resolvconf helper overwrites `/etc/resolv.conf`. The installer prevents this with `IGNORE_RESOLVCONF=yes` in `/etc/default/dnsmasq` and `bind-interfaces` + `listen-address` in `/etc/dnsmasq.conf`. If it does happen:

1. Power cycle the Pi
2. Check `/etc/resolv.conf` points to your router (e.g. `nameserver 192.168.0.1`), not to `127.0.0.1`
3. Re-run the installer

### After reboot, captive portal doesn't work

```bash
sudo systemctl status meshlink-network
sudo journalctl -u meshlink-network -n 20
sudo systemctl restart meshlink-network hostapd dnsmasq meshlink-broker
```

## Re-running the Installer

The script is idempotent. It flushes iptables rules before re-adding them and backs up config files only once.

## Uninstall

```bash
sudo systemctl stop meshlink-broker hostapd dnsmasq meshlink-network
sudo systemctl disable meshlink-broker hostapd dnsmasq meshlink-network
sudo rm /etc/systemd/system/meshlink-network.service
sudo rm /etc/systemd/system/meshlink-broker.service
sudo rm /etc/NetworkManager/conf.d/99-meshlink-unmanaged.conf
sudo rm /etc/sysctl.d/99-meshlink.conf
sudo rm /etc/sudoers.d/meshlink-network
sudo rm /etc/default/dnsmasq
sudo cp /etc/dnsmasq.conf.orig /etc/dnsmasq.conf 2>/dev/null
sudo iptables -P FORWARD ACCEPT
sudo iptables -t nat -F
sudo iptables -F FORWARD
sudo systemctl restart NetworkManager
sudo systemctl daemon-reload
```
