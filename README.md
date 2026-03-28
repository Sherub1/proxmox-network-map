# Proxmox Network Map

Auto-discovery network topology dashboard for Proxmox VE. Deploys as a lightweight LXC container and maps all your nodes, VMs, containers, bridges, IPs and MACs in a clean web UI.

Works on any Proxmox — standalone or cluster, zero configuration.

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sherub1/proxmox-network-map/main/deploy.sh)"
```

That's it. The script creates a container, sets up everything, and gives you the URL.

## What you get

- **Topology view** — hierarchical map: Internet → Gateway → Node → Bridges → Guests
- **Directory view** — searchable/sortable table of all VMs and containers
- **Auto-discovery** — new machines appear automatically, nothing to configure
- **Detail panel** — click any guest for IPs, MACs, CPU, RAM, uptime, interfaces
- **Live refresh** — updates every 30 seconds

## Requirements

- Proxmox VE 7.x or 8.x
- Root access on the Proxmox host
- ~256MB RAM, 2GB disk

## Documentation

See [install.md](install.md) for manual install, configuration, cluster setup, Tailscale HTTPS, troubleshooting and uninstall instructions.

## License

MIT
