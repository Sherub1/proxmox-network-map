#!/bin/bash
set -e

# ============================================================
# Proxmox Network Map - Standalone Installer
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Sherub1/proxmox-network-map/main/deploy.sh)"
#   Or: ./deploy.sh [VMID]
# ============================================================

# ── Configuration (override via env vars) ──
CT_NAME="network-map"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
MEMORY=256
DISK=2
BRIDGE="${BRIDGE:-vmbr0}"
APP_DIR="/opt/proxmox-network-map"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' B='\033[0;34m' C='\033[0;36m' NC='\033[0m'
info() { echo -e "${B}[INFO]${NC} $1"; }
ok() { echo -e "${G}[OK]${NC} $1"; }
warn() { echo -e "${Y}[WARN]${NC} $1"; }
die() { echo -e "${R}[ERROR]${NC} $1"; exit 1; }

clear
echo -e "${C}"
cat << 'BANNER'
  _   _      _                      _      __  __
 | \ | | ___| |___      _____  _ __| | __ |  \/  | __ _ _ __
 |  \| |/ _ \ __\ \ /\ / / _ \| '__| |/ / | |\/| |/ _` | '_ \
 | |\  |  __/ |_ \ V  V / (_) | |  |   <  | |  | | (_| | |_) |
 |_| \_|\___|\__| \_/\_/ \___/|_|  |_|\_\ |_|  |_|\__,_| .__/
                                                         |_|
  Proxmox Network Topology Dashboard
BANNER
echo -e "${NC}"

# ============================================================
# 1. Check prerequisites
# ============================================================
info "Checking prerequisites..."
command -v pct >/dev/null || die "pct not found — run this on a Proxmox VE host"
command -v pvesh >/dev/null || die "pvesh not found — run this on a Proxmox VE host"

# ── VMID selection ──
if [ -n "$1" ]; then
    VMID="$1"
else
    VMID=$(pvesh get /cluster/nextid)
    echo -e " Next available VMID: ${B}${VMID}${NC}"
    read -rp " Use VMID $VMID? (enter to confirm, or type another): " USER_VMID
    [ -n "$USER_VMID" ] && VMID="$USER_VMID"
fi

if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null 2>&1; then
    die "VMID $VMID already exists"
fi
ok "Will use VMID $VMID"

# ============================================================
# 2. Find template
# ============================================================
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard*.tar.* 2>/dev/null | sort -V | tail -1)
if [ -z "$TEMPLATE" ]; then
    info "Downloading Debian 12 template..."
    pveam update >/dev/null 2>&1
    TMPL_NAME=$(pveam available --section system | grep 'debian-12-standard' | awk '{print $2}' | sort -V | tail -1)
    [ -z "$TMPL_NAME" ] && die "No Debian 12 template found"
    pveam download "$TEMPLATE_STORAGE" "$TMPL_NAME"
    TEMPLATE="/var/lib/vz/template/cache/$TMPL_NAME"
fi
TEMPLATE_REL="${TEMPLATE_STORAGE}:vztmpl/$(basename "$TEMPLATE")"
ok "Template: $(basename "$TEMPLATE")"

# ============================================================
# 3. Create API token
# ============================================================
TOKEN_ID="root@pam!netmap"
TOKEN_FILE="/root/.proxmox-netmap-token"

if pvesh get /access/users/root@pam/token/netmap &>/dev/null 2>&1; then
    info "API token already exists"
    if [ -f "$TOKEN_FILE" ]; then
        TOKEN_SECRET=$(cat "$TOKEN_FILE")
    else
        warn "Token secret file missing. Recreating token..."
        pvesh delete /access/users/root@pam/token/netmap >/dev/null 2>&1
        TOKEN_OUTPUT=$(pvesh create /access/users/root@pam/token/netmap --privsep 0 --output-format json)
        TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
        echo "$TOKEN_SECRET" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        ok "Token recreated"
    fi
else
    info "Creating API token..."
    TOKEN_OUTPUT=$(pvesh create /access/users/root@pam/token/netmap --privsep 0 --output-format json)
    TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")
    echo "$TOKEN_SECRET" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "Token created"
fi

# ============================================================
# 4. Create LXC container
# ============================================================
info "Creating CT $VMID..."

pct create "$VMID" "$TEMPLATE_REL" \
    --hostname "$CT_NAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK}" \
    --memory "$MEMORY" \
    --swap 0 \
    --cores 1 \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 \
    2>&1 | grep -v "^  WARNING:"

ok "CT $VMID created"

# ============================================================
# 5. Start and install packages
# ============================================================
info "Starting CT..."
pct start "$VMID"
sleep 3

info "Waiting for network..."
for i in $(seq 1 30); do
    if pct exec "$VMID" -- ping -c1 -W1 deb.debian.org &>/dev/null; then break; fi
    [ "$i" -eq 30 ] && die "Network timeout"
    sleep 1
done

info "Installing dependencies..."
pct exec "$VMID" -- bash -c "
    apt-get update -qq &&
    apt-get install -y -qq python3 python3-pip python3-venv nginx > /dev/null 2>&1
"
ok "Dependencies installed"

# ============================================================
# 6. Write application files (self-contained)
# ============================================================
info "Deploying application..."

pct exec "$VMID" -- mkdir -p ${APP_DIR}/backend ${APP_DIR}/frontend

# ── requirements.txt ──
pct exec "$VMID" -- bash -c "cat > ${APP_DIR}/backend/requirements.txt << 'REQEOF'
fastapi==0.115.0
uvicorn[standard]==0.30.0
proxmoxer==2.1.0
requests>=2.32.3
urllib3>=2.2.3
REQEOF"

# ── config.py ──
pct exec "$VMID" -- bash -c "cat > ${APP_DIR}/backend/config.py << 'PYEOF'
import os

PROXMOX_HOST = os.environ.get(\"PROXMOX_HOST\", \"127.0.0.1\")
PROXMOX_PORT = int(os.environ.get(\"PROXMOX_PORT\", \"8006\"))
PROXMOX_TOKEN_ID = os.environ.get(\"PROXMOX_TOKEN_ID\", \"root@pam!netmap\")
PROXMOX_TOKEN_SECRET = os.environ.get(\"PROXMOX_TOKEN_SECRET\", \"\")
PROXMOX_VERIFY_SSL = os.environ.get(\"PROXMOX_VERIFY_SSL\", \"false\").lower() == \"true\"
REFRESH_INTERVAL = int(os.environ.get(\"REFRESH_INTERVAL\", \"30\"))
PYEOF"

# ── main.py ──
pct exec "$VMID" -- bash -c "cat > ${APP_DIR}/backend/main.py << 'PYEOF'
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from proxmox_client import get_client, discover_network
from config import REFRESH_INTERVAL
import time

app = FastAPI(title=\"Proxmox Network Map\")
_cache = {\"data\": None, \"ts\": 0}

@app.get(\"/api/topology\")
def topology():
    now = time.time()
    if _cache[\"data\"] is None or (now - _cache[\"ts\"]) > REFRESH_INTERVAL:
        client = get_client()
        _cache[\"data\"] = discover_network(client)
        _cache[\"ts\"] = now
    return _cache[\"data\"]

@app.post(\"/api/refresh\")
def refresh():
    _cache[\"data\"] = None
    _cache[\"ts\"] = 0
    return topology()

@app.get(\"/api/health\")
def health():
    return {\"status\": \"ok\"}

app.mount(\"/\", StaticFiles(directory=\"/opt/proxmox-network-map/frontend\", html=True), name=\"frontend\")
PYEOF"

# ── proxmox_client.py ──
# This file is larger, write via temp file on host then push
TMPFILE=$(mktemp)
cat > "$TMPFILE" << 'CLIENTEOF'
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

        containers = []
        try:
            for ct in client.nodes(node_name).lxc.get():
                vmid = ct["vmid"]
                ct_detail = {
                    "vmid": vmid, "name": ct.get("name", ""),
                    "status": ct.get("status", "unknown"), "type": "lxc",
                    "cpu": ct.get("cpus", 0), "maxmem": ct.get("maxmem", 0),
                    "maxdisk": ct.get("maxdisk", 0), "uptime": ct.get("uptime", 0),
                    "interfaces": [],
                }
                try:
                    config = client.nodes(node_name).lxc(vmid).config.get()
                    for key, val in config.items():
                        if key.startswith("net") and isinstance(val, str):
                            iface = _parse_lxc_net(val)
                            iface["config_key"] = key
                            ct_detail["interfaces"].append(iface)
                except Exception:
                    pass
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

        vms = []
        try:
            for vm in client.nodes(node_name).qemu.get():
                vmid = vm["vmid"]
                vm_detail = {
                    "vmid": vmid, "name": vm.get("name", ""),
                    "status": vm.get("status", "unknown"), "type": "qemu",
                    "cpu": vm.get("cpus", 0), "maxmem": vm.get("maxmem", 0),
                    "maxdisk": vm.get("maxdisk", 0), "uptime": vm.get("uptime", 0),
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

        arp_table = []
        try:
            with open("/proc/net/arp", "r") as f:
                for line in f.readlines()[1:]:
                    parts = line.split()
                    if len(parts) >= 6 and parts[3] != "00:00:00:00:00:00":
                        arp_table.append({"ip": parts[0], "mac": parts[3], "device": parts[5]})
        except Exception:
            pass

        nodes.append({
            "name": node_name, "status": node_status,
            "cpu": node_info.get("maxcpu", 0), "maxmem": node_info.get("maxmem", 0),
            "bridges": bridges, "containers": containers, "vms": vms, "arp": arp_table,
        })

    return {"nodes": nodes}


def _parse_lxc_net(raw: str) -> dict:
    parts = dict(p.split("=", 1) for p in raw.split(",") if "=" in p)
    return {
        "name": parts.get("name", ""), "mac": parts.get("hwaddr", ""),
        "bridge": parts.get("bridge", ""), "ip": parts.get("ip", ""),
        "gw": parts.get("gw", ""), "ip6": parts.get("ip6", ""),
        "firewall": parts.get("firewall", "0"), "tag": parts.get("tag", ""),
        "rate": parts.get("rate", ""), "runtime_ips": [],
    }


def _parse_qemu_net(raw: str, key: str) -> dict:
    parts = dict(p.split("=", 1) for p in raw.split(",") if "=" in p)
    model = raw.split(",")[0] if "=" not in raw.split(",")[0] else ""
    return {
        "name": key, "model": model or parts.get("model", ""),
        "mac": parts.get("macaddr", raw.split("=")[1].split(",")[0] if "=" in raw else ""),
        "bridge": parts.get("bridge", ""), "firewall": parts.get("firewall", "0"),
        "tag": parts.get("tag", ""), "runtime_ips": [],
    }


def _merge_runtime_ip(interfaces: list, ifname: str, cidr: str, family: str):
    for iface in interfaces:
        if iface.get("name") == ifname or (not iface.get("name") and len(interfaces) == 1):
            iface.setdefault("runtime_ips", []).append({"cidr": cidr, "family": family})
            return
    interfaces.append({"name": ifname, "runtime_ips": [{"cidr": cidr, "family": family}]})
CLIENTEOF
pct push "$VMID" "$TMPFILE" "${APP_DIR}/backend/proxmox_client.py"
rm -f "$TMPFILE"

# ── index.html (frontend) ──
TMPHTML=$(mktemp)
cat > "$TMPHTML" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Proxmox Network Map</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        :root{--bg:#0b0e14;--surface:#141820;--surface2:#1c2130;--surface3:#242a3a;--border:#2a3040;--border2:#353d52;--text:#e6e8f0;--text2:#a0a6b8;--text3:#6b7280;--accent:#6c8cff;--green:#22c55e;--red:#ef4444;--orange:#f59e0b;--cyan:#06b6d4;--purple:#a78bfa;--line:#2a3040}
        *{margin:0;padding:0;box-sizing:border-box}html{height:100%}body{font-family:'Inter',sans-serif;background:var(--bg);color:var(--text);min-height:100%}
        .header{display:flex;align-items:center;justify-content:space-between;padding:14px 28px;background:var(--surface);border-bottom:1px solid var(--border)}
        .header h1{font-size:17px;font-weight:600;letter-spacing:-0.3px;display:flex;align-items:center;gap:10px}
        .logo{width:28px;height:28px;border-radius:6px;background:linear-gradient(135deg,#6c8cff,#a78bfa);display:flex;align-items:center;justify-content:center;font-size:14px;color:#fff;font-weight:700}
        .header-right{display:flex;align-items:center;gap:12px}.update-badge{font-size:11px;color:var(--text3)}
        .dot{width:7px;height:7px;border-radius:50%;background:var(--green)}.dot.err{background:var(--red)}
        .btn{padding:5px 12px;border-radius:6px;border:1px solid var(--border);background:var(--surface2);color:var(--text2);cursor:pointer;font-size:12px;font-family:inherit;transition:all .15s}.btn:hover{border-color:var(--accent);color:var(--text)}
        .tabs{display:flex;gap:0;background:var(--surface);border-bottom:1px solid var(--border);padding:0 28px}
        .tab{padding:10px 18px;font-size:12px;font-weight:500;color:var(--text3);cursor:pointer;border-bottom:2px solid transparent;transition:all .15s}.tab:hover{color:var(--text2)}.tab.active{color:var(--accent);border-bottom-color:var(--accent)}
        .stats{display:flex;gap:20px;padding:12px 28px;border-bottom:1px solid var(--border);background:var(--surface)}
        .stat{font-size:12px;color:var(--text3);display:flex;align-items:center;gap:5px}.stat b{color:var(--text);font-size:15px;font-weight:600}
        .view{display:none}.view.active{display:block}
        .topo{padding:30px 28px 50px;overflow-x:auto}.topo-flow{display:flex;flex-direction:column;align-items:center;gap:0;min-width:fit-content}
        .connector{width:2px;height:28px;background:var(--line)}
        .tier-card{border-radius:10px;padding:14px 22px;text-align:center;border:1px solid var(--border)}
        .tier-card .label{font-size:11px;text-transform:uppercase;letter-spacing:1px;font-weight:600;margin-bottom:4px}
        .tier-card .title{font-size:18px;font-weight:700}.tier-card .sub{font-size:14px;font-family:'JetBrains Mono',monospace;color:var(--text2);margin-top:3px}
        .tier-wan{background:linear-gradient(135deg,#1a1040,#2d1b69);border-color:#7c3aed}.tier-wan .label{color:#a78bfa}
        .tier-gw{background:var(--surface2);border-color:#6d28d9}.tier-gw .label{color:#a78bfa}
        .tier-node{background:linear-gradient(135deg,#0c1929,#152a4a);border-color:#2563eb}.tier-node .label{color:#60a5fa}
        .bridges-row{display:flex;gap:16px;justify-content:center;flex-wrap:wrap}
        .bridge-col{display:flex;flex-direction:column;align-items:center;min-width:240px}
        .bridge-card{border-radius:10px;padding:12px 24px;text-align:center;background:var(--surface2);border:1px solid #b4530940;width:100%}
        .bridge-card .name{font-size:15px;font-weight:700;color:var(--orange)}.bridge-card .ip{font-size:13px;font-family:'JetBrains Mono',monospace;color:var(--text2);margin-top:2px}
        .bridge-card .no-ip{font-size:11px;color:var(--text3);font-style:italic;margin-top:2px}.bridge-card .empty{font-size:11px;color:var(--text3);margin-top:6px;font-style:italic}
        .guest-section{margin-top:12px;width:100%}
        .guest-section-title{font-size:11px;text-transform:uppercase;letter-spacing:0.8px;font-weight:600;padding:5px 10px;margin-bottom:6px;border-radius:4px;text-align:left}
        .guest-section-title.running{color:var(--green);background:rgba(34,197,94,0.08)}.guest-section-title.stopped{color:var(--text3);background:rgba(107,114,128,0.08)}
        .guest-grid{display:flex;flex-direction:column;gap:6px}
        .guest-card{display:grid;grid-template-columns:auto 1fr auto;align-items:center;gap:10px;padding:10px 14px;border-radius:8px;cursor:pointer;background:var(--surface);border:1px solid var(--border);transition:all .15s}
        .guest-card:hover{border-color:var(--accent);background:var(--surface2);transform:translateX(2px)}
        .guest-card.running{border-left:3px solid var(--green)}.guest-card.stopped{border-left:3px solid var(--border2);opacity:0.7}
        .guest-card .vmid{font-size:13px;font-family:'JetBrains Mono',monospace;color:var(--text3);min-width:32px;font-weight:500}
        .guest-card .info{display:flex;flex-direction:column;gap:2px;min-width:0}
        .guest-card .gname{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .guest-card .gip{font-size:12px;font-family:'JetBrains Mono',monospace;color:var(--text2)}
        .guest-card .badges{display:flex;gap:4px;align-items:center}
        .badge-sm{font-size:10px;font-weight:600;padding:3px 7px;border-radius:4px;text-transform:uppercase;letter-spacing:0.5px;white-space:nowrap}
        .badge-sm.lxc{background:rgba(167,139,250,0.15);color:var(--purple)}.badge-sm.qemu{background:rgba(6,182,212,0.15);color:var(--cyan)}
        .badge-sm.on{background:rgba(34,197,94,0.12);color:var(--green)}.badge-sm.off{background:rgba(107,114,128,0.12);color:var(--text3)}
        .multi-br{font-size:9px;color:var(--orange);margin-left:2px}
        .table-wrap{padding:16px 28px;overflow:auto;height:calc(100vh - 130px)}
        .search-row{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;align-items:center}
        .search-row input{padding:7px 12px;border-radius:6px;border:1px solid var(--border);background:var(--surface2);color:var(--text);font-size:12px;width:260px;font-family:inherit}
        .search-row input:focus{outline:none;border-color:var(--accent)}
        .pill{padding:4px 10px;border-radius:12px;border:1px solid var(--border);background:var(--surface2);color:var(--text3);cursor:pointer;font-size:11px;font-family:inherit}
        .pill.active{background:var(--accent);color:#fff;border-color:var(--accent)}
        table{width:100%;border-collapse:collapse;font-size:12px}
        thead th{text-align:left;padding:8px 10px;background:var(--surface);color:var(--text3);font-weight:500;font-size:11px;border-bottom:1px solid var(--border);position:sticky;top:0;cursor:pointer;user-select:none;white-space:nowrap;z-index:2}
        thead th:hover{color:var(--text2)}tbody tr{border-bottom:1px solid var(--border);transition:background .1s}tbody tr:hover{background:rgba(108,140,255,0.04)}
        td{padding:8px 10px;white-space:nowrap}.mono{font-family:'JetBrains Mono',monospace;font-size:11px}
        .badge{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:600}
        .badge.running{background:rgba(34,197,94,0.12);color:var(--green)}.badge.stopped{background:rgba(107,114,128,0.1);color:var(--text3)}
        .badge.lxc{background:rgba(167,139,250,0.12);color:var(--purple)}.badge.qemu{background:rgba(6,182,212,0.12);color:var(--cyan)}
        .overlay{position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:99;display:none;backdrop-filter:blur(2px)}.overlay.open{display:block}
        .panel{position:fixed;right:-440px;top:0;bottom:0;width:420px;max-width:100vw;background:var(--surface);border-left:1px solid var(--border);z-index:100;transition:right .25s ease;overflow-y:auto;padding:0}.panel.open{right:0}
        .panel-header{padding:16px 20px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;position:sticky;top:0;background:var(--surface);z-index:1}
        .panel-header h2{font-size:15px;font-weight:600}.panel-close{background:none;border:none;color:var(--text3);cursor:pointer;font-size:18px;padding:4px}.panel-close:hover{color:var(--text)}
        .panel-body{padding:16px 20px}.detail-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px}
        .detail-item{background:var(--surface2);border-radius:6px;padding:10px 12px}.detail-item .dl{font-size:10px;color:var(--text3);text-transform:uppercase;letter-spacing:0.5px;margin-bottom:3px}
        .detail-item .dv{font-size:13px;font-weight:500}.detail-item .dv.mono{font-family:'JetBrains Mono',monospace;font-size:12px}
        .detail-section{margin-top:16px}.detail-section h3{font-size:11px;color:var(--accent);text-transform:uppercase;letter-spacing:0.8px;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid var(--border)}
        .detail-row{display:flex;justify-content:space-between;padding:6px 0;font-size:12px}.detail-row .k{color:var(--text3)}.detail-row .v{font-family:'JetBrains Mono',monospace;font-size:11px;text-align:right}
        @media(max-width:768px){.header{padding:10px 16px}.topo{padding:16px}.bridges-row{flex-direction:column;align-items:center}.panel{width:100%;right:-100%}}
    </style>
</head>
<body>
    <div class="header"><h1><div class="logo">N</div> Network Map</h1><div class="header-right"><span class="update-badge" id="update-badge"></span><span class="dot" id="dot"></span><button class="btn" onclick="refresh()">Refresh</button></div></div>
    <div class="stats" id="stats"></div>
    <div class="tabs"><div class="tab active" data-v="topo" onclick="switchView('topo')">Topology</div><div class="tab" data-v="table" onclick="switchView('table')">Directory</div></div>
    <div class="view active" id="view-topo"><div class="topo" id="topo"></div></div>
    <div class="view" id="view-table"><div class="table-wrap"><div class="search-row"><input type="text" id="q" placeholder="Search name, IP, MAC, VMID..." oninput="renderTable()"><button class="pill active" data-f="all" onclick="setF('all')">All</button><button class="pill" data-f="lxc" onclick="setF('lxc')">LXC</button><button class="pill" data-f="qemu" onclick="setF('qemu')">QEMU</button><button class="pill" data-f="running" onclick="setF('running')">Running</button><button class="pill" data-f="stopped" onclick="setF('stopped')">Stopped</button></div><table><thead><tr><th onclick="doSort('vmid')">VMID</th><th onclick="doSort('name')">Name</th><th onclick="doSort('type')">Type</th><th onclick="doSort('status')">Status</th><th onclick="doSort('ip')">IP(s)</th><th onclick="doSort('mac')">MAC</th><th onclick="doSort('bridge')">Bridge</th><th onclick="doSort('node')">Node</th></tr></thead><tbody id="tbody"></tbody></table></div></div>
    <div class="overlay" id="ov" onclick="closePanel()"></div>
    <div class="panel" id="panel"><div class="panel-header"><h2 id="panel-title"></h2><button class="panel-close" onclick="closePanel()">&#10005;</button></div><div class="panel-body" id="panel-body"></div></div>
<script>
let data=null,flat=[],filter='all',sortCol='vmid',sortAsc=true;
async function load(force){try{const r=await fetch(force?'/api/refresh':'/api/topology',force?{method:'POST'}:{});data=await r.json();document.getElementById('dot').className='dot';document.getElementById('update-badge').textContent='Updated '+new Date().toLocaleTimeString();process();renderStats();renderTopo();renderTable()}catch(e){document.getElementById('dot').className='dot err';document.getElementById('update-badge').textContent='Error'}}
function refresh(){load(true)}
function process(){flat=[];if(!data||!data.nodes)return;for(const node of data.nodes){for(const g of[...(node.containers||[]),...(node.vms||[])]){const ips=[],macs=[],brs=[];for(const i of(g.interfaces||[])){if(i.mac)macs.push(i.mac);if(i.bridge)brs.push(i.bridge);if(i.ip&&i.ip!=='dhcp')ips.push(i.ip.replace(/\/\d+$/,''));if(i.runtime_ips)for(const r of i.runtime_ips)if(r.family==='inet'){const ip=r.cidr.replace(/\/\d+$/,'');if(!ip.startsWith('172.'))ips.push(ip)}}flat.push({vmid:g.vmid,name:g.name,type:g.type,status:g.status,ips:[...new Set(ips)],macs:[...new Set(macs)],bridges:[...new Set(brs)],node:node.name,guest:g})}}}
function renderStats(){const t=flat.length,r=flat.filter(i=>i.status==='running').length;const l=flat.filter(i=>i.type==='lxc').length,q=flat.filter(i=>i.type==='qemu').length;const n=data?data.nodes.length:0;document.getElementById('stats').innerHTML='<div class="stat"><b>'+n+'</b>Node'+(n>1?'s':'')+'</div><div class="stat"><b>'+t+'</b>Guests</div><div class="stat"><b>'+r+'</b>Running</div><div class="stat"><b>'+l+'</b>LXC</div><div class="stat"><b>'+q+'</b>QEMU</div>'}
function renderTopo(){if(!data||!data.nodes)return;let h='<div class="topo-flow">';h+='<div class="tier-card tier-wan"><div class="label">Network</div><div class="title">Internet / WAN</div></div>';h+='<div class="connector"></div>';for(const node of data.nodes){const mainBr=(node.bridges||[]).find(b=>b.gateway);const gwIp=mainBr?mainBr.gateway:'';const nodeIp=mainBr?mainBr.address:'';if(gwIp){h+='<div class="tier-card tier-gw"><div class="label">Gateway</div><div class="title">Router</div><div class="sub">'+gwIp+'</div></div>';h+='<div class="connector"></div>'}h+='<div class="tier-card tier-node"><div class="label">Proxmox VE Node</div><div class="title">'+node.name+'</div>';if(nodeIp)h+='<div class="sub">'+nodeIp+'</div>';h+='</div>';h+='<div class="connector"></div>';const bridgeInfo={};for(const br of(node.bridges||[]))if(br.type==='bridge')bridgeInfo[br.name]=br;const bridgeGuests={};const allGuests=[...(node.containers||[]),...(node.vms||[])];for(const brName of Object.keys(bridgeInfo))bridgeGuests[brName]=[];for(const g of allGuests){const br=(g.interfaces||[]).find(i=>i.bridge);const brName=br?br.bridge:'unknown';if(!bridgeGuests[brName])bridgeGuests[brName]=[];bridgeGuests[brName].push(g)}const bridgeNames=Object.keys(bridgeGuests).sort((a,b)=>{const ac=bridgeGuests[a].length,bc=bridgeGuests[b].length;if(ac&&!bc)return-1;if(!ac&&bc)return 1;return a.localeCompare(b)});h+='<div class="bridges-row">';for(const brName of bridgeNames){const br=bridgeInfo[brName]||{};const guests=bridgeGuests[brName];const running=guests.filter(g=>g.status==='running').sort((a,b)=>a.vmid-b.vmid);const stopped=guests.filter(g=>g.status!=='running').sort((a,b)=>a.vmid-b.vmid);h+='<div class="bridge-col">';h+='<div class="bridge-card"><div class="name">'+brName+'</div>';if(br.address)h+='<div class="ip">'+br.address+'</div>';else h+='<div class="no-ip">no IP (isolated)</div>';if(!guests.length)h+='<div class="empty">No guests</div>';h+='</div>';h+='<div class="guest-section">';if(running.length){h+='<div class="guest-section-title running">Running ('+running.length+')</div><div class="guest-grid">';for(const g of running)h+=guestCard(g);h+='</div>'}if(stopped.length){h+='<div class="guest-section-title stopped" style="margin-top:'+(running.length?8:0)+'px">Stopped ('+stopped.length+')</div><div class="guest-grid">';for(const g of stopped)h+=guestCard(g);h+='</div>'}h+='</div></div>'}h+='</div>'}h+='</div>';document.getElementById('topo').innerHTML=h}
function guestCard(g){const isLxc=g.type==='lxc',isRunning=g.status==='running';const ips=[],extraBr=[];let first=true;for(const i of(g.interfaces||[])){if(i.bridge&&!first)extraBr.push(i.bridge);if(i.bridge)first=false;if(i.ip&&i.ip!=='dhcp')ips.push(i.ip.replace(/\/\d+$/,''));if(i.runtime_ips)for(const r of i.runtime_ips)if(r.family==='inet'){const ip=r.cidr.replace(/\/\d+$/,'');if(!ip.startsWith('172.'))ips.push(ip)}}const uips=[...new Set(ips)];let card='<div class="guest-card '+(isRunning?'running':'stopped')+'" onclick="showDetail('+g.vmid+')">';card+='<span class="vmid">'+g.vmid+'</span>';card+='<div class="info"><span class="gname">'+g.name+'</span>';if(uips.length)card+='<span class="gip">'+uips.slice(0,2).join(' / ')+'</span>';card+='</div><div class="badges">';card+='<span class="badge-sm '+g.type+'">'+(isLxc?'LXC':'VM')+'</span>';card+='<span class="badge-sm '+(isRunning?'on':'off')+'">'+(isRunning?'ON':'OFF')+'</span>';if(extraBr.length)card+='<span class="multi-br">+'+extraBr.join(',')+'</span>';card+='</div></div>';return card}
function showDetail(vmid){const item=flat.find(i=>i.vmid===vmid);if(!item)return;const g=item.guest;const mem=g.maxmem?(g.maxmem/1024/1024/1024).toFixed(1)+' GB':'—';const disk=g.maxdisk?(g.maxdisk/1024/1024/1024).toFixed(1)+' GB':'—';const up=g.uptime?fmtUp(g.uptime):'—';document.getElementById('panel-title').textContent=item.name;let h='<div class="detail-grid">';h+=di('VMID',item.vmid,true)+di('Type',item.type.toUpperCase())+di('Status',item.status)+di('Node',item.node);h+=di('CPU(s)',g.cpu||'—')+di('Memory',mem)+di('Disk',disk)+di('Uptime',up);h+='</div>';for(const iface of(g.interfaces||[])){h+='<div class="detail-section"><h3>'+(iface.name||iface.config_key||'iface')+'</h3>';if(iface.mac)h+=dr('MAC',iface.mac);if(iface.bridge)h+=dr('Bridge',iface.bridge);if(iface.ip)h+=dr('Config IP',iface.ip);if(iface.gw)h+=dr('Gateway',iface.gw);if(iface.tag)h+=dr('VLAN',iface.tag);if(iface.firewall==='1')h+=dr('Firewall','Enabled');if(iface.runtime_ips)for(const r of iface.runtime_ips)h+=dr(r.family,r.cidr);h+='</div>'}document.getElementById('panel-body').innerHTML=h;document.getElementById('panel').classList.add('open');document.getElementById('ov').classList.add('open')}
function di(l,v,m){return'<div class="detail-item"><div class="dl">'+l+'</div><div class="dv'+(m?' mono':'')+'">'+v+'</div></div>'}
function dr(k,v){return'<div class="detail-row"><span class="k">'+k+'</span><span class="v">'+v+'</span></div>'}
function closePanel(){document.getElementById('panel').classList.remove('open');document.getElementById('ov').classList.remove('open')}
function fmtUp(s){const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?d+'d '+h+'h':h+'h '+m+'m'}
function switchView(v){document.querySelectorAll('.tab').forEach(t=>t.classList.toggle('active',t.dataset.v===v));document.querySelectorAll('.view').forEach(el=>el.classList.toggle('active',el.id==='view-'+v))}
function setF(f){filter=f;document.querySelectorAll('.pill').forEach(p=>p.classList.toggle('active',p.dataset.f===f));renderTable()}
function doSort(c){if(sortCol===c)sortAsc=!sortAsc;else{sortCol=c;sortAsc=true}renderTable()}
function renderTable(){const q=document.getElementById('q').value.toLowerCase();let items=flat.filter(i=>{if(filter==='lxc'&&i.type!=='lxc')return false;if(filter==='qemu'&&i.type!=='qemu')return false;if(filter==='running'&&i.status!=='running')return false;if(filter==='stopped'&&i.status!=='stopped')return false;if(q)return[i.vmid,i.name,i.type,i.status,...i.ips,...i.macs,...i.bridges,i.node].join(' ').toLowerCase().includes(q);return true});items.sort((a,b)=>{let va=a[sortCol],vb=b[sortCol];if(sortCol==='ip'){va=a.ips[0]||'';vb=b.ips[0]||''}if(sortCol==='mac'){va=a.macs[0]||'';vb=b.macs[0]||''}if(sortCol==='bridge'){va=a.bridges[0]||'';vb=b.bridges[0]||''}if(typeof va==='number')return sortAsc?va-vb:vb-va;return sortAsc?String(va||'').localeCompare(String(vb||'')):String(vb||'').localeCompare(String(va||''))});document.getElementById('tbody').innerHTML=items.map(i=>'<tr onclick="showDetail('+i.vmid+')" style="cursor:pointer"><td class="mono">'+i.vmid+'</td><td><strong>'+i.name+'</strong></td><td><span class="badge '+i.type+'">'+i.type.toUpperCase()+'</span></td><td><span class="badge '+i.status+'">'+i.status+'</span></td><td class="mono">'+(i.ips.join('<br>')||'<span style="color:var(--text3)">—</span>')+'</td><td class="mono">'+(i.macs.join('<br>')||'—')+'</td><td>'+(i.bridges.join(', ')||'—')+'</td><td>'+i.node+'</td></tr>').join('')}
load(false);setInterval(()=>load(false),30000);
</script>
</body>
</html>
HTMLEOF
pct push "$VMID" "$TMPHTML" "${APP_DIR}/frontend/index.html"
rm -f "$TMPHTML"

ok "Application deployed"

# ============================================================
# 7. Setup environment + services
# ============================================================
PVE_HOST=$(hostname -I | awk '{print $1}')

info "Installing Python packages..."
pct exec "$VMID" -- bash -c "
    python3 -m venv ${APP_DIR}/venv &&
    ${APP_DIR}/venv/bin/pip install -q -r ${APP_DIR}/backend/requirements.txt
"
ok "Python packages installed"

info "Configuring services..."

pct exec "$VMID" -- bash -c "cat > ${APP_DIR}/.env << ENVEOF
PROXMOX_HOST=${PVE_HOST}
PROXMOX_PORT=8006
PROXMOX_TOKEN_ID=${TOKEN_ID}
PROXMOX_TOKEN_SECRET=${TOKEN_SECRET}
PROXMOX_VERIFY_SSL=false
REFRESH_INTERVAL=30
ENVEOF
chmod 600 ${APP_DIR}/.env"

pct exec "$VMID" -- bash -c 'cat > /etc/systemd/system/netmap.service << EOF
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
systemctl enable -q netmap
systemctl start netmap'

pct exec "$VMID" -- bash -c 'cat > /etc/nginx/sites-available/netmap << EOF
server {
    listen 80 default_server;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/netmap /etc/nginx/sites-enabled/
nginx -t 2>/dev/null && systemctl reload nginx'
ok "Services configured"

# ============================================================
# 8. Summary
# ============================================================
sleep 2
CT_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${G}╔══════════════════════════════════════════╗${NC}"
echo -e "${G}║     Proxmox Network Map — Deployed!      ║${NC}"
echo -e "${G}╠══════════════════════════════════════════╣${NC}"
echo -e "${G}║${NC} VMID:    ${B}${VMID}${NC}"
echo -e "${G}║${NC} Name:    ${B}${CT_NAME}${NC}"
echo -e "${G}║${NC} URL:     ${B}http://${CT_IP}${NC}"
echo -e "${G}╠══════════════════════════════════════════╣${NC}"
echo -e "${G}║${NC} Manage:  ${C}pct enter ${VMID}${NC}"
echo -e "${G}║${NC} Logs:    ${C}pct exec ${VMID} -- journalctl -u netmap -f${NC}"
echo -e "${G}║${NC} Remove:  ${C}pct stop ${VMID} && pct destroy ${VMID}${NC}"
echo -e "${G}╚══════════════════════════════════════════╝${NC}"
echo ""
