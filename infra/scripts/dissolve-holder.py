#!/usr/bin/env python3
"""Move a bootc VM's data disks off its holder VM onto the VM itself, then delete the empty holder.

    scripts/bw-run --env-map secrets.env.map -- scripts/dissolve-holder.py VMID
        [--holder 2000+VMID] [--backup] [--backup-storage backups] [--yes]

One-off for the holder-VM layout modules/bootc_vm used before data disks became plain disks of
their own VM (holder disk scsiN was attached to the VM as scsi<N+2>). Without --yes it only
prints what it would do. Downtime: the VM is stopped while its disks move.

Per disk: drop the VM's reference to the holder's volume (the volume stays: it isn't the VM's),
reassign the volume to the VM (a rename on the storage, no copy) at the same drive name, put the
VM's drive options back. Then the holder must be empty, and is deleted; the VM starts.
Refuses unless the holder is a stopped VM tagged bootc-data whose every disk is attached to the VM.
Prints VM IDs, drive and volume names only.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pvelib  # noqa: E402
from pvelib import Refuse  # noqa: E402


def disks(cfg: dict) -> dict:
    return {k: v for k, v in cfg.items() if k.startswith("scsi") and k != "scsihw"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("vmid", type=int)
    ap.add_argument("--holder", type=int)
    ap.add_argument("--backup", action="store_true", help="vzdump the VM once it is shut down")
    ap.add_argument("--backup-storage", default="backups")
    ap.add_argument("--yes", action="store_true", help="act (default: dry run)")
    a = ap.parse_args()
    holder = a.holder or 2000 + a.vmid
    act = "" if a.yes else "[dry run] "

    # ── Preflight (read-only) ──────────────────────────────────────────────────
    vm, h = pvelib.vm_info(a.vmid), pvelib.vm_info(holder)
    if not vm:
        raise Refuse(f"VM {a.vmid} not found")
    if not h:
        raise Refuse(f"holder {holder} not found")
    node, hnode = vm["node"], h["node"]
    cfg, hcfg = pvelib.vm_config(node, a.vmid), pvelib.vm_config(hnode, holder)
    if h.get("status") != "stopped" or "bootc-data" not in hcfg.get("tags", "").split(";"):
        raise Refuse(f"VMID {holder} isn't a stopped holder (tag bootc-data)")
    if any(k.startswith("unused") for k in list(cfg) + list(hcfg)):
        raise Refuse("unused disks on the VM or the holder; sort those out first")
    vm_by_vol = {v.split(",")[0]: k for k, v in disks(cfg).items()}
    moves = []  # (holder drive, vm drive, volid, vm drive options)
    for hd, hv in sorted(disks(hcfg).items()):
        volid = hv.split(",")[0]
        vd = vm_by_vol.get(volid)
        if vd is None:
            raise Refuse(f"holder {hd} = {volid} isn't attached to VM {a.vmid}; refusing")
        if vd != f"scsi{int(hd[4:]) + 2}":
            raise Refuse(f"holder {hd} is attached as {vd}, not scsi{int(hd[4:]) + 2}; refusing")
        _, _, vopts = pvelib.parse_drive(cfg[vd])
        moves.append((hd, vd, volid, vopts))
    if not moves:
        raise Refuse(f"holder {holder} has no disks")
    protected = cfg.get("protection") in (1, "1")

    print(f"VM {a.vmid} ({vm.get('name')}) on {node}, {vm.get('status')}; holder {holder} ({h.get('name')}) on {hnode}")
    if a.backup:
        print(f"{act}vzdump {a.vmid} to {a.backup_storage} (after the shutdown; includes the attached disks)")
    if hnode != node:
        print(f"{act}migrate the stopped holder {holder} {hnode} -> {node} (reassign needs both on one node; shared storage, no copy)")
    for hd, vd, volid, _ in moves:
        print(f"{act}{volid}: holder {hd} -> VM {a.vmid} {vd} (rename only, no copy)")
    print(f"{act}delete the empty holder {holder}; start VM {a.vmid}")
    if not a.yes:
        print("dry run: nothing changed. Re-run with --yes to do it.")
        return 0

    # ── Act ────────────────────────────────────────────────────────────────────
    pvelib.shutdown(node, a.vmid)
    print("VM stopped")
    if a.backup:
        print("backup: running ...", flush=True)
        pvelib.vzdump(node, a.vmid, a.backup_storage)
        print("backup: done")
    node = pvelib.vm_info(a.vmid)["node"]
    if hnode != node:
        pvelib.wait_task(hnode, pvelib.api("POST", f"/nodes/{hnode}/qemu/{holder}/migrate", {"target": node}),
                         f"migrate holder to {node}")
        hnode = pvelib.vm_info(holder)["node"]
        if hnode != node:
            raise Refuse(f"holder {holder} is on {hnode} after migrating, not {node}")
        print(f"holder {holder} migrated to {node}")
    if protected:
        pvelib.set_config(node, a.vmid, {"protection": 0}, "lift protection")
    try:
        for hd, vd, volid, vopts in moves:
            pvelib.set_config(node, a.vmid, {"delete": vd}, f"drop reference {vd}")
            cfg = pvelib.vm_config(node, a.vmid)
            if any(k.startswith("unused") for k in cfg) or pvelib.vm_config(hnode, holder).get(hd, "").split(",")[0] != volid:
                raise Refuse(f"after dropping {vd}: unexpected unused entry, or the holder lost {hd}; stopping here")
            pvelib.wait_task(hnode, pvelib.api("POST", f"/nodes/{hnode}/qemu/{holder}/move_disk", {
                "disk": hd, "target-vmid": a.vmid, "target-disk": vd}), f"reassign {hd}")
            store, newname, nopts = pvelib.parse_drive(pvelib.vm_config(node, a.vmid)[vd])
            if not newname.startswith(f"vm-{a.vmid}-"):
                raise Refuse(f"after reassign, {vd} = {store}:{newname}, not owned by {a.vmid}")
            if nopts.get("size") != vopts.get("size"):
                raise Refuse(f"{vd} size {nopts.get('size')} != {vopts.get('size')}")
            # Same options the VM had on that drive (discard etc.).
            opts = ",".join(f"{k}={v}" for k, v in vopts.items())
            pvelib.set_config(node, a.vmid, {vd: f"{store}:{newname}" + (f",{opts}" if opts else "")}, f"options {vd}")
            print(f"{vd} = {store}:{newname} (was {volid})")
    finally:
        if protected:
            pvelib.set_config(node, a.vmid, {"protection": 1}, "restore protection")

    # ── Holder: must be empty now ──────────────────────────────────────────────
    hcfg = pvelib.vm_config(hnode, holder)
    if disks(hcfg) or any(k.startswith("unused") for k in hcfg):
        raise Refuse(f"holder {holder} still has disks; not deleting it (VM {a.vmid} left stopped)")
    pvelib.wait_task(hnode, pvelib.api("DELETE", f"/nodes/{hnode}/qemu/{holder}?purge=1&destroy-unreferenced-disks=0"),
                     f"delete holder {holder}")
    print(f"holder {holder} deleted")
    pvelib.start(node, a.vmid)
    print(f"VM {a.vmid} started")
    print(f"next (tofu/lab): `removed` block for module.<vm>.proxmox_virtual_environment_vm.data, plan, apply")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refuse as e:
        sys.exit(f"dissolve-holder: refused: {e}")
    except KeyError as e:
        sys.exit(f"dissolve-holder: missing {e} (run through scripts/bw-run --env-map secrets.env.map)")
