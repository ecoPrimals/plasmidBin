# Gate Relay Manual Configuration

If the bootstrap script fails, configure these services manually.

## RustDesk (Channel 2b — remote desktop)

| Setting       | Value                                              |
|---------------|----------------------------------------------------|
| ID Server     | `157.230.3.183`                                    |
| Relay Server  | `157.230.3.183`                                    |
| Public Key    | `utlNOAWUDdV+Q+ifG3zHrQ5HU0FtQnOTHiAnu6prV7Q=`   |

Install RustDesk, open Settings > Network, set ID/Relay server to the values above,
paste the key into "Key". The relay is self-hosted on golgiBody (`remote.primals.eco`).

## WireGuard (Channel 1 — mesh)

| Setting         | Value                                            |
|-----------------|--------------------------------------------------|
| Hub Endpoint    | `157.230.3.183:51820`                            |
| Hub Public Key  | `A2fvz3czkqRUuu2mzkSS6IVr/TCQcpsJX9HbDBa1FBc=`  |
| Subnet          | `10.13.37.0/24`                                  |
| DNS             | `10.13.37.1`                                     |

Generate a keypair (`wg genkey | tee privatekey | wg pubkey > publickey`), then write
`/etc/wireguard/wg0.conf`:

```ini
[Interface]
PrivateKey = <generated private key>
Address = <assigned IP from manifest>/24
DNS = 10.13.37.1

[Peer]
PublicKey = A2fvz3czkqRUuu2mzkSS6IVr/TCQcpsJX9HbDBa1FBc=
Endpoint = 157.230.3.183:51820
AllowedIPs = 10.13.37.0/24
PersistentKeepalive = 25
```

Add the gate's public key on golgiBody: `wg set wg0 peer <GATE_PUBKEY> allowed-ips <GATE_IP>/32`

## Forgejo (inner membrane git)

| Setting | Value                           |
|---------|---------------------------------|
| Host    | `git.primals.eco` (`10.13.37.1` via mesh) |
| Port    | `2222`                          |
| User    | `git`                           |

SSH config (`~/.ssh/config`):
```
Host forgejo
    HostName 10.13.37.1
    Port 2222
    User git
    IdentityFile ~/.ssh/forgejo_deploy
```

## MitoBeacon (Channel 3 — identity/lineage)

| Setting            | Value                                     |
|--------------------|-------------------------------------------|
| Family ID          | `e8b62b6e`                                |
| Beacon seed source | `/etc/membrane/family/.beacon.seed` on hub |
| Per-gate lineage   | Generated on first boot or pulled from VPS |

## Coexistence Notes

RustDesk and MitoBeacon are **coexisting systems** on every gate:

- **RustDesk** provides immediate remote access (operator-in-the-loop)
- **MitoBeacon** provides autonomous identity and lineage tracking

Both run on every gate. Future: MitoBeacon evolves to negotiate trust
(e.g. bingoCube commitments during enrollment); RustDesk remains the
human-accessible fallback channel. Neither replaces the other — they
serve different trust models (autonomous vs. operator-mediated).
