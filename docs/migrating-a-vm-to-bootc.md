# Migrating a VM to bootc

The recipe proved on ittools (Phase 2 pilot, 2026-11-25) for moving a VM from `tofu/pets` or
`tofu/platform` (Debian + Ansible) to `tofu/lab` (bootc, `modules/bootc_vm`). This is the
**stateless** version; VMs with data disks or secrets add steps (Phase 3/4 extend this file).
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
