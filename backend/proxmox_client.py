from proxmoxer import ProxmoxAPI
from config import PROXMOX_HOST, PROXMOX_PORT, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, PROXMOX_VERIFY_SSL


def get_client() -> ProxmoxAPI:
    return ProxmoxAPI(
        PROXMOX_HOST,
        port=PROXMOX_PORT,
        user=PROXMOX_TOKEN_ID.split("!")[0],
        token_name=PROXMOX_TOKEN_ID.split("!")[1],
        token_value=PROXMOX_TOKEN_SECRET,
        verify_ssl=PROXMOX_VERIFY_SSL,
        timeout=15,
    )


def discover_network(client: ProxmoxAPI) -> dict:
    nodes = []
    for node_info in client.nodes.get():
        node_name = node_info["node"]
        node_status = node_info.get("status", "unknown")

        # Node network interfaces (bridges, bonds, etc.)
        bridges = []
        try:
            for iface in client.nodes(node_name).network.get():
                if iface.get("type") in ("bridge", "bond", "eth", "vlan"):
                    bridges.append({
                        "name": iface.get("iface", ""),
                        "type": iface.get("type", ""),
                        "address": iface.get("address", ""),
                        "cidr": iface.get("cidr", ""),
                        "gateway": iface.get("gateway", ""),
                        "bridge_ports": iface.get("bridge_ports", ""),
                        "active": bool(iface.get("active", 0)),
                    })
        except Exception:
            pass

        # LXC Containers
        containers = []
        try:
            for ct in client.nodes(node_name).lxc.get():
                vmid = ct["vmid"]
                ct_detail = {
                    "vmid": vmid,
                    "name": ct.get("name", ""),
                    "status": ct.get("status", "unknown"),
                    "type": "lxc",
                    "cpu": ct.get("cpus", 0),
                    "maxmem": ct.get("maxmem", 0),
                    "maxdisk": ct.get("maxdisk", 0),
                    "uptime": ct.get("uptime", 0),
                    "interfaces": [],
                }
                # Get config for network interfaces
                try:
                    config = client.nodes(node_name).lxc(vmid).config.get()
                    for key, val in config.items():
                        if key.startswith("net") and isinstance(val, str):
                            iface = _parse_lxc_net(val)
                            iface["config_key"] = key
                            ct_detail["interfaces"].append(iface)
                except Exception:
                    pass
                # Get runtime IPs if running
                if ct.get("status") == "running":
                    try:
                        for ri in client.nodes(node_name).lxc(vmid).interfaces.get():
                            name = ri.get("name", "")
                            if name == "lo":
                                continue
                            for addr in ri.get("inet", "").split():
                                _merge_runtime_ip(ct_detail["interfaces"], name, addr, "inet")
                            for addr in ri.get("inet6", "").split():
                                _merge_runtime_ip(ct_detail["interfaces"], name, addr, "inet6")
                    except Exception:
                        pass
                containers.append(ct_detail)
        except Exception:
            pass

        # QEMU VMs
        vms = []
        try:
            for vm in client.nodes(node_name).qemu.get():
                vmid = vm["vmid"]
                vm_detail = {
                    "vmid": vmid,
                    "name": vm.get("name", ""),
                    "status": vm.get("status", "unknown"),
                    "type": "qemu",
                    "cpu": vm.get("cpus", 0),
                    "maxmem": vm.get("maxmem", 0),
                    "maxdisk": vm.get("maxdisk", 0),
                    "uptime": vm.get("uptime", 0),
                    "interfaces": [],
                }
                try:
                    config = client.nodes(node_name).qemu(vmid).config.get()
                    for key, val in config.items():
                        if key.startswith("net") and isinstance(val, str):
                            iface = _parse_qemu_net(val, key)
                            vm_detail["interfaces"].append(iface)
                except Exception:
                    pass
                # Try QEMU guest agent for runtime IPs
                if vm.get("status") == "running":
                    try:
                        agent_net = client.nodes(node_name).qemu(vmid).agent("network-get-interfaces").get()
                        for ri in agent_net.get("result", []):
                            name = ri.get("name", "")
                            if name == "lo":
                                continue
                            for addr_info in ri.get("ip-addresses", []):
                                ip = addr_info.get("ip-address", "")
                                prefix = addr_info.get("prefix", "")
                                family = "inet" if addr_info.get("ip-address-type") == "ipv4" else "inet6"
                                cidr = f"{ip}/{prefix}" if prefix else ip
                                _merge_runtime_ip(vm_detail["interfaces"], name, cidr, family)
                    except Exception:
                        pass
                vms.append(vm_detail)
        except Exception:
            pass

        # ARP table — only available when running directly on the Proxmox host
        arp_table = []
        try:
            with open("/proc/net/arp", "r") as f:
                for line in f.readlines()[1:]:
                    parts = line.split()
                    if len(parts) >= 6 and parts[3] != "00:00:00:00:00:00":
                        arp_table.append({
                            "ip": parts[0],
                            "mac": parts[3],
                            "device": parts[5],
                        })
        except Exception:
            pass

        nodes.append({
            "name": node_name,
            "status": node_status,
            "cpu": node_info.get("maxcpu", 0),
            "maxmem": node_info.get("maxmem", 0),
            "bridges": bridges,
            "containers": containers,
            "vms": vms,
            "arp": arp_table,
        })

    return {"nodes": nodes}


def _parse_lxc_net(raw: str) -> dict:
    parts = dict(p.split("=", 1) for p in raw.split(",") if "=" in p)
    return {
        "name": parts.get("name", ""),
        "mac": parts.get("hwaddr", ""),
        "bridge": parts.get("bridge", ""),
        "ip": parts.get("ip", ""),
        "gw": parts.get("gw", ""),
        "ip6": parts.get("ip6", ""),
        "firewall": parts.get("firewall", "0"),
        "tag": parts.get("tag", ""),
        "rate": parts.get("rate", ""),
        "runtime_ips": [],
    }


def _parse_qemu_net(raw: str, key: str) -> dict:
    parts = dict(p.split("=", 1) for p in raw.split(",") if "=" in p)
    model = raw.split(",")[0] if "=" not in raw.split(",")[0] else ""
    return {
        "name": key,
        "model": model or parts.get("model", ""),
        "mac": parts.get("macaddr", raw.split("=")[1].split(",")[0] if "=" in raw else ""),
        "bridge": parts.get("bridge", ""),
        "firewall": parts.get("firewall", "0"),
        "tag": parts.get("tag", ""),
        "runtime_ips": [],
    }


def _merge_runtime_ip(interfaces: list, ifname: str, cidr: str, family: str):
    for iface in interfaces:
        if iface.get("name") == ifname or (not iface.get("name") and len(interfaces) == 1):
            iface.setdefault("runtime_ips", []).append({"cidr": cidr, "family": family})
            return
    interfaces.append({
        "name": ifname,
        "runtime_ips": [{"cidr": cidr, "family": family}],
    })
