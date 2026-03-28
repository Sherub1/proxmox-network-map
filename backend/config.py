import os

PROXMOX_HOST = os.environ.get("PROXMOX_HOST", "127.0.0.1")
PROXMOX_PORT = int(os.environ.get("PROXMOX_PORT", "8006"))
PROXMOX_TOKEN_ID = os.environ.get("PROXMOX_TOKEN_ID", "root@pam!netmap")
PROXMOX_TOKEN_SECRET = os.environ.get("PROXMOX_TOKEN_SECRET", "")
PROXMOX_VERIFY_SSL = os.environ.get("PROXMOX_VERIFY_SSL", "false").lower() == "true"
REFRESH_INTERVAL = int(os.environ.get("REFRESH_INTERVAL", "30"))
