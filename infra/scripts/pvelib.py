"""Small Proxmox API helpers for the bootc VM scripts (reinstall-os.py, dissolve-holder.py).

Needs PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN (run the scripts through scripts/bw-run
--env-map secrets.env.map). Nothing here prints a secret.
"""
import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request


class Refuse(Exception):
    pass


def api(method: str, path: str, data: dict | None = None):
    endpoint = os.environ["PROXMOX_VE_ENDPOINT"].rstrip("/")
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    req = urllib.request.Request(f"{endpoint}/api2/json{path}", data=body, method=method, headers={
        "Authorization": f"PVEAPIToken={os.environ['PROXMOX_VE_API_TOKEN']}"})
    ctx = ssl.create_default_context()
    if os.environ.get("PROXMOX_VE_INSECURE", "").lower() in ("1", "true", "yes"):
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
            return json.load(r)["data"]
    except urllib.error.HTTPError as e:
        raise Refuse(f"{method} {path}: HTTP {e.code} {e.read().decode(errors='replace')[:300]}") from None


def wait_task(node: str, upid: str | None, what: str, timeout: int = 7200) -> None:
    if not upid:  # synchronous config changes return no task
        return
    deadline = time.time() + timeout
    q = urllib.parse.quote(upid, safe="")
    while time.time() < deadline:
        st = api("GET", f"/nodes/{node}/tasks/{q}/status")
        if st.get("status") == "stopped":
            if st.get("exitstatus") != "OK":
                raise Refuse(f"{what} failed: {st.get('exitstatus')}")
            return
        time.sleep(3)
    raise Refuse(f"{what}: still running after {timeout}s")


def vm_info(vmid: int) -> dict | None:
    for v in api("GET", "/cluster/resources?type=vm"):
        if v.get("vmid") == vmid:
            return v
    return None


def vm_config(node: str, vmid: int) -> dict:
    return api("GET", f"/nodes/{node}/qemu/{vmid}/config")


def set_config(node: str, vmid: int, data: dict, what: str) -> None:
    wait_task(node, api("POST", f"/nodes/{node}/qemu/{vmid}/config", data), what)


def parse_drive(value: str) -> tuple[str, str, dict]:
    """'store:name,opt=v,...' -> (store, name, opts)."""
    vol, _, rest = value.partition(",")
    store, _, name = vol.partition(":")
    opts = dict(kv.split("=", 1) for kv in rest.split(",") if "=" in kv)
    return store, name, opts


def status(node: str, vmid: int) -> str:
    return api("GET", f"/nodes/{node}/qemu/{vmid}/status/current")["status"]


def shutdown(node: str, vmid: int, timeout: int = 360) -> None:
    """Clean guest shutdown (HA-aware: for an HA VM it sets the requested state to stopped)."""
    if status(node, vmid) == "stopped":
        return
    api("POST", f"/nodes/{node}/qemu/{vmid}/status/shutdown", {"timeout": 180})
    deadline = time.time() + timeout
    while time.time() < deadline:
        if status(node, vmid) == "stopped":
            return
        time.sleep(3)
    raise Refuse(f"VM {vmid} didn't stop within {timeout}s")


def start(node: str, vmid: int) -> None:
    """Start (for an HA VM this sets the requested state back to started)."""
    wait_task(node, api("POST", f"/nodes/{node}/qemu/{vmid}/status/start"), f"start {vmid}")


def vzdump(node: str, vmid: int, storage: str) -> None:
    """Back up a VM that is already shut down. Snapshot mode, because Proxmox refuses stop mode
    for HA-managed VMs; with the VM off, the disks don't change, so it is just as consistent."""
    if status(node, vmid) != "stopped":
        raise Refuse(f"VM {vmid} is running; shut it down before the backup")
    wait_task(node, api("POST", f"/nodes/{node}/vzdump", {
        "vmid": vmid, "storage": storage, "mode": "snapshot", "compress": "zstd"}), f"vzdump {vmid}")


def wait_agent(node: str, vmid: int, timeout: int = 900) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            api("POST", f"/nodes/{node}/qemu/{vmid}/agent/ping")
            return
        except Refuse:
            time.sleep(5)
    raise Refuse(f"VM {vmid}: no guest agent within {timeout}s")
