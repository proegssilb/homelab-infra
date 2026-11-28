#!/usr/bin/env python3
"""Hand an existing VM's data disk to a bootc VM's holder VM (modules/bootc_vm).

    adopt-data-disk.py --from 210 --drive scsi2 --holder 2210 --holder-name obs01-data
                       [--to-drive scsi0] [--backup] [--backup-storage backups]
                       [--max-backup-age-hours 6] [--yes]

Phase 3+ migrations keep each app's data disk (docs/migrating-a-vm-to-bootc.md):
the old VM's disk is *reassigned* to the holder VM (Proxmox disk reassign: a rename
on the storage, no copy, data untouched), then Tofu imports the holder and the new
bootc VM attaches the disk. Without --yes it only prints what it would do.

Refuses unless:
  - the old VM is stopped (no writes in flight),
  - the drive is on shared storage (the holder and the VM may sit on any node),
  - a vzdump of the old VM, newer than --max-backup-age-hours, is in --backup-storage
    (--backup takes one now, mode=stop, and waits for it): the rollback,
  - the holder VMID is free, or is a stopped holder (tag bootc-data) with --to-drive free.

Needs PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN (run it through scripts/bw-run
--env-map secrets.env.map). Prints VM IDs, drive and volume names only.
"""
import argparse
import json
import os
import ssl
import sys
import time
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


def wait_task(node: str, upid: str, what: str, timeout: int = 7200) -> None:
    deadline = time.time() + timeout
    q = urllib.parse.quote(upid, safe="")
    while time.time() < deadline:
        st = api("GET", f"/nodes/{node}/tasks/{q}/status")
        if st.get("status") == "stopped":
            if st.get("exitstatus") != "OK":
                raise Refuse(f"{what} failed: {st.get('exitstatus')}")
            return
        time.sleep(5)
    raise Refuse(f"{what}: still running after {timeout}s")


def vm_info(vmid: int) -> dict | None:
    for v in api("GET", "/cluster/resources?type=vm"):
        if v.get("vmid") == vmid:
            return v
    return None


def parse_drive(value: str) -> tuple[str, str, dict]:
    vol, _, rest = value.partition(",")
    store, _, name = vol.partition(":")
    opts = dict(kv.split("=", 1) for kv in rest.split(",") if "=" in kv)
    return store, name, opts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--from", dest="src", type=int, required=True, help="VMID of the old VM")
    ap.add_argument("--drive", required=True, help="its data drive, e.g. scsi2")
    ap.add_argument("--holder", type=int, required=True, help="holder VMID (modules/bootc_vm: 2000 + vmid)")
    ap.add_argument("--holder-name", required=True)
    ap.add_argument("--to-drive", default="scsi0", help="drive on the holder (data_disks index i -> scsi<i>)")
    ap.add_argument("--backup", action="store_true", help="take the vzdump now (mode=stop) instead of requiring one")
    ap.add_argument("--backup-storage", default="backups")
    ap.add_argument("--max-backup-age-hours", type=float, default=6)
    ap.add_argument("--yes", action="store_true", help="act (default: dry run)")
    a = ap.parse_args()
    act = "" if a.yes else "[dry run] "

    # ── Preflight (read-only) ──────────────────────────────────────────────────
    src = vm_info(a.src)
    if not src:
        raise Refuse(f"VM {a.src} not found")
    node = src["node"]
    if src.get("status") != "stopped":
        raise Refuse(f"VM {a.src} is {src.get('status')}; stop it first (no writes during the handover)")
    cfg = api("GET", f"/nodes/{node}/qemu/{a.src}/config")
    if a.drive not in cfg:
        raise Refuse(f"VM {a.src} has no {a.drive}")
    store, volname, opts = parse_drive(cfg[a.drive])
    storage = api("GET", f"/storage/{store}")
    if not (storage.get("shared") or storage.get("type") in ("rbd", "cephfs", "nfs")):
        raise Refuse(f"{store} isn't shared storage; refusing (the holder could end up on another node)")
    print(f"old VM {a.src} on {node}: {a.drive} = {store}:{volname} size={opts.get('size', '?')}")

    holder = vm_info(a.holder)
    if holder:
        hcfg = api("GET", f"/nodes/{holder['node']}/qemu/{a.holder}/config")
        if holder.get("status") != "stopped" or "bootc-data" not in hcfg.get("tags", "").split(";"):
            raise Refuse(f"VMID {a.holder} exists and isn't a stopped holder (tag bootc-data)")
        if a.to_drive in hcfg:
            raise Refuse(f"holder {a.holder} already has {a.to_drive}")
        print(f"holder {a.holder} exists on {holder['node']}; {a.to_drive} is free")
    else:
        print(f"holder {a.holder} ({a.holder_name}) will be created on {node}")

    backups = [b for b in api("GET", f"/nodes/{node}/storage/{a.backup_storage}/content?content=backup")
               if b.get("vmid") == a.src]
    newest = max((b.get("ctime", 0) for b in backups), default=0)
    age_h = (time.time() - newest) / 3600 if newest else None
    fresh = age_h is not None and age_h <= a.max_backup_age_hours
    if fresh:
        print(f"backup: newest vzdump of {a.src} in {a.backup_storage} is {age_h:.1f} h old")
    elif a.backup:
        print(f"{act}backup: vzdump {a.src} to {a.backup_storage} (mode=stop, zstd)")
    else:
        raise Refuse(f"no vzdump of {a.src} newer than {a.max_backup_age_hours:g} h in {a.backup_storage}; "
                     "take one (--backup) first")

    print(f"{act}reassign {a.src}:{a.drive} -> {a.holder}:{a.to_drive} (rename only, no copy)")
    if not a.yes:
        print("dry run: nothing changed. Re-run with --yes to do it.")
        return 0

    # ── Act ────────────────────────────────────────────────────────────────────
    if not fresh:
        upid = api("POST", f"/nodes/{node}/vzdump", {
            "vmid": a.src, "storage": a.backup_storage, "mode": "stop", "compress": "zstd"})
        print("backup: running ...", flush=True)
        wait_task(node, upid, "vzdump")
        print("backup: done")
    if not holder:
        upid = api("POST", f"/nodes/{node}/qemu", {
            "vmid": a.holder, "name": a.holder_name, "tags": "bootc;bootc-data", "onboot": 0,
            "description": f"Data disks of VM {a.src}'s bootc successor, attached there. Never started. "
                           "Destroying this VM destroys the data."})
        wait_task(node, upid, "create holder")
        print(f"holder {a.holder} created")
    upid = api("POST", f"/nodes/{node}/qemu/{a.src}/move_disk", {
        "disk": a.drive, "target-vmid": a.holder, "target-disk": a.to_drive})
    wait_task(node, upid, "disk reassign")

    # ── Verify ─────────────────────────────────────────────────────────────────
    h = vm_info(a.holder)
    hcfg = api("GET", f"/nodes/{h['node']}/qemu/{a.holder}/config")
    if a.to_drive not in hcfg:
        raise Refuse(f"after reassign, holder {a.holder} has no {a.to_drive}; check the Proxmox task log")
    hstore, hvol, hopts = parse_drive(hcfg[a.to_drive])
    if hstore != store or hopts.get("size") != opts.get("size"):
        raise Refuse(f"holder {a.to_drive} = {hstore}:{hvol} size={hopts.get('size')} doesn't match the source")
    if a.drive in api("GET", f"/nodes/{node}/qemu/{a.src}/config"):
        raise Refuse(f"VM {a.src} still lists {a.drive}")
    print(f"done: holder {a.holder} {a.to_drive} = {hstore}:{hvol} size={hopts.get('size')}")
    print(f"next: import it in tofu/lab (import {{ to = module.<vm>.proxmox_virtual_environment_vm.data[0], "
          f"id = \"{h['node']}/{a.holder}\" }}), plan, and check the plan doesn't replace it")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refuse as e:
        sys.exit(f"adopt-data-disk: refused: {e}")
    except KeyError as e:
        sys.exit(f"adopt-data-disk: missing {e} (run through scripts/bw-run --env-map secrets.env.map)")
