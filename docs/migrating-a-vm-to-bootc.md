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
while one is offline. In `modules/bootc_vm` a VM's `data_disks` are **its own disks** (`scsi2`,
`scsi3`, ...), and the VM is the long-lived object:

- Tofu never replaces or destroys a bootc VM (`prevent_destroy`): a change bpg can't make in place
  (in practice only `vm_id`) or a `-replace` fails the plan.
- Proxmox `protection` is on for every VM with data: removing the VM or any of its drives is refused,
  in the API and the UI. (A volume deleted straight through the storage API is not covered.)
- A fresh OS is `scripts/reinstall-os.py <vmid>`: it swaps only the OS disk (`scsi1`) for a new import
  of the install disk, in place, and leaves every other drive alone; then re-push with
  `tofu -chdir=tofu/lab apply -replace=module.<vm>.terraform_data.push`.
- vzdump of the VM includes its data disks, as for any Proxmox VM; the VM joins a backup pool
  (`pool_id`, `ha-prod` with HA, `la-prod` without), since the nightly jobs target pools.

Each disk can have a `mount` (and an `owner` for the mount point). The module writes a mount unit
that requires `homelab-prepare-disk@scsiN` (image): it formats a disk only if its first and last MiB
are zeros, leaves any filesystem alone, and refuses unknown data. The whole filesystem gets the
container SELinux context at mount, so Quadlets bind-mount it **without `:Z`**. Adding a disk is one
apply.

### Migrating a VM that has data: in place

Same VMID, same data disk where it is; only the OS disk changes. Rehearsed 2026-11-28 on a scratch VM
shaped like the old Debian platform VMs (OS `scsi1`, data `scsi2`, cloud-init snippet, DHCP).

1. **Write the lab VM** as in step 1 above, with `data_disks` at the sizes and datastores the VM has
   now (same order: `scsi2` first), `mount`s mapped to the container layout, and `pool_id`. Ownership
   may need handing to the container's UID: an idempotent `find <dir> ! -user <uid> -exec chown …`
   in `run` (see `garage-apps.tf`).
2. **Stop and reinstall**: `scripts/bw-run --env-map secrets.env.map -- scripts/reinstall-os.py <vmid>
   --migrate --backup --size <GiB>` is a dry run; re-run with `--yes`. It shuts the VM down, takes a vzdump (the
   rollback; snapshot mode, as HA VMs refuse stop mode), puts a fresh bootc OS disk in place, drops the old cloud-init snippet (`cicustom`)
   and inherited `cipassword`, and leaves the VM **stopped**. Downtime starts.
3. **Forget it in the old state**: `tofu -chdir=tofu/<pets|platform> state rm 'module.vm["<name>"]'`
   (a `removed` block can't name one instance of a `for_each` module), then delete its entry in that
   state's `main.tf`. `tofu plan` there must show only its `proxmox_haresource` being destroyed (the VM
   is stopped; `tofu/lab` recreates the HA resource, and would fail creating one that still exists);
   apply it.
4. **Import it into the lab**: a temporary
   `import { to = module.<vm>.proxmox_virtual_environment_vm.vm, id = "<node>/<vmid>" }`; `tofu plan`
   must show the VM **updated in place** (static IP, `admin` user, protection, tags, ...) and nothing
   replaced (prevent_destroy would fail the plan). Apply: it configures and starts the VM, pushes
   config and secrets, writes DNS, adds HA. Delete the import block.
5. **Verify the app's data**, then continue with steps 5–6 above.

Rollback: restore the vzdump (it has the OS disk and the data disks as they were at the stop).

### Retiring data

Deliberate, never a side effect: lift protection in Proxmox **first**, then remove the disk (or the
whole VM) from the config and apply. With protection still on the apply fails: for a removed disk Tofu
then forgets it while it stays attached; for a removed VM bpg has already shut it down when the delete
is refused (an outage, no data loss). A disk removed from the config becomes `unusedN` on the VM, not
deleted: deleting it for good is a separate step in Proxmox, after a final backup.
