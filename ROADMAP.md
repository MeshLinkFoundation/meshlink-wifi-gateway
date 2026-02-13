# MeshLink Roadmap

## Completed

- [x] WiFi access point setup (hostapd + dnsmasq on Raspberry Pi 5)
- [x] Captive portal detection (HTTP REDIRECT, works on iOS + Android)
- [x] Client access gating (FORWARD DROP + ipset-based authentication)
- [x] Free tier self-service (connect → captive portal → select free → internet granted)
- [x] Session expiry via in-memory timers (setTimeout per client)
- [x] Boot persistence (systemd services, iptables-restore, ipset creation)
- [x] Broker auto-start on boot (meshlink-broker.service)

## Up Next

### Session persistence across broker restarts
On startup, the broker should read active sessions from SQLite and re-populate the `meshlink_auth` ipset + schedule expiry timers. Currently a broker restart loses all timers and leaves stale IPs in the ipset with no cleanup.

### Bandwidth limiting (tc/traffic control)
Use Linux `tc` to enforce per-tier speed limits. Tier ipsets (`free_clients`, `lightweight_clients`, `premium_clients`) are already created — need tc qdisc/filter rules that match against them.
- Free: 1 Mbps down / 0.5 Mbps up
- Lightweight: 25 Mbps down / 5 Mbps up
- Premium: 200 Mbps down / 50 Mbps up

### Data usage tracking
Use iptables byte counters or per-IP accounting to track data consumption per session. Enforce `dataLimitMB` from tier config — revoke access when limit is reached.

### Stripe payment integration
Wire up paid tiers (Lightweight, Premium) to Stripe payment links. The captive portal UI already has Stripe redirect flow scaffolded — needs real keys and webhook handling to confirm payment before granting access.

## Future

### Admin dashboard improvements
- Real-time connected client list with usage stats
- Manual grant/revoke access controls
- Session history and revenue reporting

### Crypto payment support
Accept cryptocurrency payments for access tiers. Config structure exists (`enableCrypto`, `acceptCryptoPayments`) but no implementation yet.

### Multi-node mesh networking
Support multiple MeshLink APs sharing a session database so clients can roam between nodes without re-authenticating.

### Client isolation hardening
Add `ap_isolate=1` in hostapd and iptables rules to prevent direct client-to-client traffic on the WiFi network.

### HTTPS for admin interface
Add TLS for the admin dashboard (not for the captive portal itself, which must stay HTTP for redirect to work).

### Automatic updates
OTA update mechanism for pulling new broker builds and applying config changes without manual SSH.
