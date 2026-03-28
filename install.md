# Proxmox Network Map

A lightweight, self-hosted network topology dashboard for **Proxmox VE**. Automatically discovers all nodes, VMs, containers, bridges, IPs, and MACs via the Proxmox API. Deploys in under 2 minutes.

Works on **any Proxmox VE setup** — standalone or cluster, no configuration needed.

![License](https://img.shields.io/badge/license-MIT-blue)

## Features

- **Auto-discovery** — new VMs/CTs appear automatically, no manual config
- **Topology view** — hierarchical layout: Internet → Gateway → Node → Bridges → Guests
- **Directory view** — searchable, sortable, filterable table of all guests
- **Detail panel** — click any guest for full info (IPs, MACs, CPU, RAM, uptime, interfaces)
- **Live refresh** — auto-updates every 30s, manual refresh button
- **Cluster-ready** — point to any node, all cluster members are discovered
- **Lightweight** — 256MB RAM, 2GB disk, single unprivileged LXC container

## Quick Install

Run on your **Proxmox host** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sherub1/proxmox-network-map/main/deploy.sh)"
```

Or clone and run:

```bash
git clone https://github.com/Sherub1/proxmox-network-map.git
cd proxmox-network-map
bash deploy.sh
```

The script will:
1. Prompt for a VMID (auto-suggests next available)
2. Download a Debian 12 template if needed
3. Create a read-only API token (`root@pam!netmap`)
4. Create and start an unprivileged LXC container
5. Install and configure everything (Python, FastAPI, nginx)
6. Print the access URL

### Options

```bash
# Force a specific VMID
bash deploy.sh 200

# Use a different storage backend
STORAGE=local-zfs bash deploy.sh

# Use a different bridge
BRIDGE=vmbr1 bash deploy.sh

# Combine options
STORAGE=local-zfs BRIDGE=vmbr1 bash deploy.sh 200
```

## Architecture

```
┌─────────────────────────────────────────┐
│  LXC Container (Debian 12, unprivileged)│
│                                         │
│  nginx :80 ──► uvicorn :8080 (FastAPI)  │
│                    │                    │
│                    ├── GET  /api/topology│
│                    ├── POST /api/refresh │
│                    └── Static frontend   │
│                                         │
│  Proxmox API (token auth, read-only)    │
└─────────────────────────────────────────┘
```

The backend queries the Proxmox API every 30 seconds:
- `/nodes` — discover all cluster nodes
- `/nodes/{node}/network` — bridges and interfaces
- `/nodes/{node}/lxc` + `/qemu` — list all guests
- `/nodes/{node}/lxc/{vmid}/config` — static IPs, MACs, bridges
- `/nodes/{node}/lxc/{vmid}/interfaces` — runtime IPs (running guests)
- QEMU guest agent for VM runtime IPs

## Manual Install

For deploying on an existing server or outside of Proxmox:

### Prerequisites

- Python 3.9+
- Access to a Proxmox API endpoint

### Steps

```bash
# 1. Clone the project
git clone https://github.com/Sherub1/proxmox-network-map.git
cd proxmox-network-map

# 2. Create a Proxmox API token (on the Proxmox host)
pvesh create /access/users/root@pam/token/netmap --privsep 0
# Note the token value from the output

# 3. Create environment file
cat > .env << EOF
PROXMOX_HOST=<your-proxmox-ip>
PROXMOX_PORT=8006
PROXMOX_TOKEN_ID=root@pam!netmap
PROXMOX_TOKEN_SECRET=<your-token-secret>
PROXMOX_VERIFY_SSL=false
REFRESH_INTERVAL=30
EOF

# 4. Setup Python environment
python3 -m venv venv
venv/bin/pip install -r backend/requirements.txt

# 5. Run
venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8080
```

Open `http://localhost:8080` in your browser.

### Systemd service (optional)

```bash
cat > /etc/systemd/system/netmap.service << EOF
[Unit]
Description=Proxmox Network Map
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/proxmox-network-map/backend
EnvironmentFile=/opt/proxmox-network-map/.env
ExecStart=/opt/proxmox-network-map/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now netmap
```

## Configuration

All configuration is via environment variables (`.env` file):

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXMOX_HOST` | `127.0.0.1` | Proxmox API host (IP or FQDN) |
| `PROXMOX_PORT` | `8006` | Proxmox API port |
| `PROXMOX_TOKEN_ID` | `root@pam!netmap` | API token ID (`user@realm!tokenname`) |
| `PROXMOX_TOKEN_SECRET` | *(required)* | API token secret (UUID) |
| `PROXMOX_VERIFY_SSL` | `false` | Verify SSL certificate |
| `REFRESH_INTERVAL` | `30` | Data cache TTL in seconds |

### API Token Permissions

With `--privsep 0`, the token inherits the user's full permissions.

For a **restricted setup**, create a dedicated user with the `PVEAuditor` role instead:

```bash
pvesh create /access/users/netmap@pve --password <password>
pvesh set /access/acl --path / --users netmap@pve --roles PVEAuditor
pvesh create /access/users/netmap@pve/token/dashboard --privsep 1
```

## Cluster Support

For Proxmox clusters, point `PROXMOX_HOST` to **any node** in the cluster. The API automatically returns data for all nodes. Each node's guests appear grouped under their respective node in the topology view.

## HTTPS with Tailscale Serve

To expose the dashboard via HTTPS (inside the CT):

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up

# Expose via HTTPS
tailscale serve --bg --https=443 http://localhost:80
```

> **Note:** The CT needs TUN device access for Tailscale. Add to the CT config on the host (`/etc/pve/lxc/<vmid>.conf`):
> ```
> lxc.cgroup2.devices.allow: c 10:200 rwm
> lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
> ```
> Then restart the CT: `pct restart <vmid>`

## Troubleshooting

**Dashboard shows no data / API error:**
```bash
# Check the service (inside CT)
pct enter <vmid>
systemctl status netmap
journalctl -u netmap -f

# Test Proxmox API connectivity (inside CT)
source /opt/proxmox-network-map/.env
curl -sk "https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/version" \
  -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
```

**nginx not responding:**
```bash
nginx -t
systemctl status nginx
```

**Debug mode:**
```bash
cd /opt/proxmox-network-map/backend
source ../venv/bin/activate
source ../.env
uvicorn main:app --host 0.0.0.0 --port 8080 --log-level debug
```

## Uninstall

```bash
# Get the VMID of the network-map CT
pct list | grep network-map

# Remove the CT
pct stop <vmid> && pct destroy <vmid>

# Remove the API token
pvesh delete /access/users/root@pam/token/netmap

# Remove the saved token secret
rm -f /root/.proxmox-netmap-token
```

## Project Structure

```
proxmox-network-map/
├── deploy.sh               # One-liner installer script
├── install.md              # Documentation
├── backend/
│   ├── main.py             # FastAPI app (API + static files)
│   ├── config.py           # Environment-based configuration
│   ├── proxmox_client.py   # Proxmox API client & auto-discovery
│   └── requirements.txt    # Python dependencies
└── frontend/
    └── index.html          # Single-page dashboard (HTML/CSS/JS)
```

## Contributing

Pull requests welcome. For major changes, please open an issue first.

## License

[MIT](LICENSE)
