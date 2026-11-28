#!/usr/bin/env python3
"""Give a VM a fresh bootc OS disk in place, keeping every other disk (its data) untouched.

    scripts/bw-run --env-map secrets.env.map -- scripts/reinstall-os.py VMID
        [--install-disk cephfs:import/bootc-base-<ver>.qcow2] [--size GIB]
        [--backup] [--backup-storage backups] [--yes]

Bootc VMs with data are never replaced by Tofu (modules/bootc_vm: prevent_destroy, Proxmox
protection), so "rebuild" means this: replace only the OS disk, scsi1, with a fresh import of
the install disk. Also how an old Debian VM becomes a bootc VM in place (same VMID, same data
disk; docs/migrating-a-vm-to-bootc.md). Without --yes it only prints what it would do.

Steps: [vzdump, mode=stop] -> clean shutdown -> lift protection -> detach scsi1 and delete
exactly that volume -> import the install disk as scsi1 (same drive options) -> resize ->
restore protection -> start -> wait for the guest agent -> check every other drive is unchanged.
Then push the VM's config again:
    tofu -chdir=tofu/lab apply -replace=module.<vm>.terraform_data.push
(cloud-init runs on the fresh disk; the push reads the new host key through the agent).

--install-disk defaults to tofu/lab's `install_disk_id` output; --size to scsi1's current size.
Prints VM IDs, drive and volume names only.
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pvelib  # noqa: E402
from pvelib import Refuse  # noqa: E402

LAB = Path(__file__).resolve().parent.parent / "tofu" / "lab"
OS_DRIVE = "scsi1"


def drives(cfg: dict) -> dict:
    """Disk drives and unused entries, without the OS drive."""
    return {k: v for k, v in cfg.items()
            if k != OS_DRIVE and k.startswith(("scsi", "sata", "virtio", "ide", "unused"))
            and k != "scsihw" and "media=cdrom" not in v and "cloudinit" not in v}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("vmid", type=int)
    ap.add_argument("--install-disk", help="volume id of the install image (default: tofu/lab output install_disk_id)")
    ap.add_argument("--size", type=int, help="OS disk size in GiB (default: the current scsi1 size)")
    ap.add_argument("--backup", action="store_true", help="vzdump first (mode=stop)")
    ap.add_argument("--backup-storage", default="backups")
    ap.add_argument("--migrate", action="store_true",
                    help="an old (Ansible-era) VM becoming a bootc VM: also drop its cloud-init snippet (cicustom) and "
                         "inherited cipassword, and leave it stopped, so `tofu apply` in tofu/lab sets its cloud-init "
                         "(static IP, admin user) before the fresh OS boots for the first time")
    ap.add_argument("--yes", action="store_true", help="act (default: dry run)")
    a = ap.parse_args()
    act = "" if a.yes else "[dry run] "

    # ── Preflight (read-only) ──────────────────────────────────────────────────
    info = pvelib.vm_info(a.vmid)
    if not info:
        raise Refuse(f"VM {a.vmid} not found")
    node = info["node"]
    cfg = pvelib.vm_config(node, a.vmid)
    if OS_DRIVE not in cfg:
        raise Refuse(f"VM {a.vmid} has no {OS_DRIVE} (the OS disk, by this repo's convention)")
    if any(k.startswith("unused") for k in cfg):
        raise Refuse(f"VM {a.vmid} has unused disks; sort those out first (this script only deletes its own)")
    store, volname, opts = pvelib.parse_drive(cfg[OS_DRIVE])
    old_volid = f"{store}:{volname}"
    size = f"{a.size}G" if a.size else opts.get("size")
    if not size:
        raise Refuse(f"can't tell {OS_DRIVE}'s size; pass --size")
    install = a.install_disk or subprocess.run(
        ["tofu", f"-chdir={LAB}", "output", "-raw", "install_disk_id"],
        capture_output=True, text=True, check=True).stdout.strip()
    if not install.endswith(".qcow2") and ":import/" not in install:
        raise Refuse(f"install disk {install!r} doesn't look like an import image")
    keep = drives(cfg)
    protected = cfg.get("protection") in (1, "1")
    # Proxmox drops a detached drive from the boot order, so it goes back with the import.
    boot = cfg.get("boot", "")
    if OS_DRIVE not in boot:
        raise Refuse(f"boot order {boot!r} doesn't include {OS_DRIVE}; refusing")
    new_opts = ",".join(f"{k}={v}" for k, v in opts.items() if k != "size")
    new_drive = f"{store}:0,import-from={install}" + (f",{new_opts}" if new_opts else "")

    print(f"VM {a.vmid} ({info.get('name')}) on {node}, {info.get('status')}, protection {'on' if protected else 'off'}")
    print(f"  OS disk {OS_DRIVE} = {old_volid} size={opts.get('size')} -> fresh import of {install}, {size}")
    for k, v in keep.items():
        print(f"  keeps {k} = {v.split(',')[0]}")
    if a.backup:
        print(f"{act}vzdump {a.vmid} to {a.backup_storage} (mode=stop)")
    drop = [k for k in ("cicustom", "cipassword") if a.migrate and k in cfg]
    if drop:
        print(f"{act}drop {', '.join(drop)} (Ansible-era cloud-init; the bootc module sets its own)")
    if a.migrate:
        print(f"{act}leave it stopped: next, import it into tofu/lab and apply (that starts it)")
    if not a.yes:
        print("dry run: nothing changed. Re-run with --yes to do it.")
        return 0

    # ── Act ────────────────────────────────────────────────────────────────────
    if a.backup:
        print("backup: running ...", flush=True)
        pvelib.vzdump(node, a.vmid, a.backup_storage)
        print("backup: done")
    pvelib.shutdown(node, a.vmid)
    print("stopped")
    if protected:
        pvelib.set_config(node, a.vmid, {"protection": 0}, "lift protection")
    try:
        pvelib.set_config(node, a.vmid, {"delete": OS_DRIVE}, f"detach {OS_DRIVE}")
        cfg = pvelib.vm_config(node, a.vmid)
        unused = [k for k, v in cfg.items() if k.startswith("unused") and v.split(",")[0] == old_volid]
        if len(unused) != 1:
            raise Refuse(f"after detaching {OS_DRIVE}, expected one unused entry for {old_volid}, found {unused}")
        pvelib.set_config(node, a.vmid, {"delete": unused[0]}, f"delete old OS volume {old_volid}")
        print(f"deleted old OS volume {old_volid}")
        change = {OS_DRIVE: new_drive, "boot": boot}
        if drop:
            change["delete"] = ",".join(drop)
        pvelib.set_config(node, a.vmid, change, "import install disk")
        pvelib.wait_task(node, pvelib.api("PUT", f"/nodes/{node}/qemu/{a.vmid}/resize",
                                          {"disk": OS_DRIVE, "size": size}), "resize")
        print(f"imported {install} as {OS_DRIVE}, {size}")
    finally:
        if protected:
            pvelib.set_config(node, a.vmid, {"protection": 1}, "restore protection")

    # ── Verify ─────────────────────────────────────────────────────────────────
    cfg = pvelib.vm_config(node, a.vmid)
    if drives(cfg) != keep:
        raise Refuse(f"other drives changed: before {keep}, after {drives(cfg)}; VM left stopped")
    if OS_DRIVE not in cfg.get("boot", ""):
        raise Refuse(f"boot order {cfg.get('boot')!r} doesn't include {OS_DRIVE}; VM left stopped")
    if a.migrate:
        print(f"done: VM {a.vmid} has a fresh OS disk and is stopped; other drives unchanged")
        print("next: import it in tofu/lab (import block), plan (in place only), apply")
        return 0
    pvelib.start(node, a.vmid)
    print("started; waiting for the guest agent ...", flush=True)
    pvelib.wait_agent(node, a.vmid)
    print(f"done: VM {a.vmid} runs a fresh OS disk; other drives unchanged")
    print(f"next: tofu -chdir=tofu/lab apply -replace=module.<vm>.terraform_data.push")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Refuse as e:
        sys.exit(f"reinstall-os: refused: {e}")
    except (KeyError, subprocess.CalledProcessError) as e:
        sys.exit(f"reinstall-os: {e} (run through scripts/bw-run --env-map secrets.env.map)")
