from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from proxmox_client import get_client, discover_network
from config import REFRESH_INTERVAL
import time

app = FastAPI(title="Proxmox Network Map")

_cache = {"data": None, "ts": 0}


@app.get("/api/topology")
def topology():
    now = time.time()
    if _cache["data"] is None or (now - _cache["ts"]) > REFRESH_INTERVAL:
        client = get_client()
        _cache["data"] = discover_network(client)
        _cache["ts"] = now
    return _cache["data"]


@app.post("/api/refresh")
def refresh():
    _cache["data"] = None
    _cache["ts"] = 0
    return topology()


@app.get("/api/health")
def health():
    return {"status": "ok"}


app.mount("/", StaticFiles(directory="/opt/proxmox-network-map/frontend", html=True), name="frontend")
