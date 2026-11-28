# Migrating a VM to bootc

The recipe proved on ittools (Phase 2 pilot, 2026-11-25) for moving a VM from `tofu/pets` or
`tofu/platform` (Debian + Ansible) to `tofu/lab` (bootc, `modules/bootc_vm`). The steps below are
the **stateless** version; "With a data disk" adds the disk handover (Phase 3).
Background: `docs/specs/2026-11-22-bootc-migration.md`, CLAUDE.md "bootc VMs".

## Before

- The VM keeps its VMID, so its MAC stays the same and its address becomes `.<VMID>`, outside the
  Lab DHCP pool (`.20–.99`). If the VM still has a temporary UniFi reservation (Phase 2 list in
  the spec), it goes away at the end.
- Check what refers to the VM by its DHCP name (`<name>.<domain>`), which disappears once it's
  static: proxy01 vhost upstreams (`group_vars/proxy/vhosts_*.yml`), Prometheus targets, firewall
  rules by IP. bootc VMs are named in the lab zone (`<name>.<lab_dns_zone>`).
- The app as a Quadlet: same pinned image, same port. Add a greenboot required check that the app
  answers (an update that breaks it then rolls back).
- `tofu/lab`'s install disk (`install_disk_version` in `main.tf`) must be a release disk with
  everything the push relies on (currently: the SSH host-key publisher). Bumping it never rebuilds
  existing VMs (`ignore_changes` on `import_from`).

## Steps

1. **Write the lab VM**: `tofu/lab/<name>.tf` (copy `ittools.tf`), files in `tofu/lab/files/<name>/`,
   an entry in `dns_a_record_set.bootc` (`dns01.tf`), and in `local.ha_vms` (`main.tf`) if it was HA.
   `tofu get && tofu validate` in `tofu/lab`. Channel: `canary` for apps that can take a bad night,
   `stable` otherwise.
2. **Backup**: vzdump the VM to the backups storage (`pvesh create /nodes/<node>/vzdump --vmid N
   --storage backups --mode snapshot --compress zstd`).
3. **Remove it from the old state**: delete its entry in `tofu/<pets|platform>/main.tf`, `tofu plan`
   (expect only the VM and its HA resource), apply that plan. Downtime starts.
4. **Create it**: `just cluster-up lab`. Tofu creates the VM, pushes its config (and secrets),
   writes its record, adds HA.
5. **Switch consumers** to `<name>.<lab_dns_zone>` (e.g. the vhost upstream) and apply
   (`just tune-all proxy`). Downtime ends.
6. **Remove the temporary UniFi reservation** for its MAC (`02:00:00:00:<vmid/256>:<vmid%256>`),
   if it had one, and read it back.

Rollback: re-add the old state's entry and `just cluster-up <state>` (Ansible reinstalls it), or
restore the vzdump.

## Verify

- `https://<vhost>.<domain>/` answers through proxy01.
- On the VM (`ssh admin@<ip>`): static `.<VMID>`, `ipv4.method manual`, `bootc status` tracks
  `bootc-base:<channel>`, greenboot `success`, the app's unit active, 0 failed units, window as
  expected, `/var/log/qemu-ga/ssh-host-key.pub` matches the host key.
- `<name>.<lab_dns_zone>` resolves through the UniFi gateway; Prometheus target up; HA resource present;
  not in `ansible-inventory --list`.
- `tofu plan` in both `lab` and the old state: no changes.

## With a data disk

Data disks must survive every rebuild: the apps are single-instance, so there's no second copy
while one is offline. In `modules/bootc_vm` a VM's `data_disks` belong to a **holder VM**
(VMID `2000 + vmid`, tag `bootc-data`, never started, `prevent_destroy`) and the VM only attaches
them (`path_in_datastore`), so replacing or destroying the VM leaves them alone. Proved on canary01
(2026-11-28): a rebuild, a live migration and a vzdump (which includes the attached disk) all keep
the data, and Tofu refuses to destroy the holder.

Each disk can have a `mount` (and an `owner` for the mount point). The module writes a mount unit
that requires `homelab-prepare-disk@scsiN` (image): it formats a disk only if its first and last MiB
are zeros, leaves any filesystem alone, and refuses unknown data. The whole filesystem gets the
container SELinux context at mount, so Quadlets bind-mount it **without `:Z`**.

An existing VM's disk is **adopted**, not copied (a rename on the storage):

1. Write the lab VM with `data_disks` (same size, same datastore, `mount`), and a temporary
   `import { to = module.<vm>.proxmox_virtual_environment_vm.data[0], id = "${var.proxmox_node}/<2000+vmid>" }`
   file (delete it after the apply). Map the old paths to the container layout: ownership may need
   changing to the container's UID (e.g. `chown -R` once, as a `run` command or by hand, noted in
   the VM's `.tf`).
2. Stop the old VM (its app stops; downtime starts). Then
   `scripts/bw-run --env-map secrets.env.map -- scripts/adopt-data-disk.py --from <vmid> --drive scsi2
   --holder <2000+vmid> --holder-name <name>-data --backup`: a dry run that shows what it will do.
   Re-run with `--yes`: it takes a vzdump of the stopped VM (mode=stop, the rollback), creates the
   holder and reassigns the disk to it. It refuses if the VM isn't stopped, the storage isn't
   shared, or (without `--backup`) there's no vzdump newer than 6 h.
3. Remove the old VM from its state (its data disk is no longer in its config, so destroying it
   deletes only the OS disk). `tofu plan` there first: only the VM and its HA resource.
4. `tofu plan` in `tofu/lab`: the holder is **imported** and updated in place (never replaced: the
   plan would fail on `prevent_destroy`), the VM and its push are created. Apply that plan.
5. Verify the app's data, then continue with steps 5–6 above.

Rollback: restore the vzdump (it has the OS disk and the data disk as they were at the stop).

Retiring a VM's data for good is deliberate and manual: remove `prevent_destroy`'s protection by
deleting the holder in Proxmox after a final backup, then `tofu state rm` it.
