# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All `just` commands run from `infra/`. Environment variables must be loaded first (see below).

```bash
# Plan a tofu state directory
just plan <platform|pets>

# Apply a tofu state directory (creates/updates VMs)
just cluster-up <platform|pets>

# Rebuild a single VM (destroy + re-provision + re-configure)
just node-rebuild <vm-name> <platform|pets>

# Run Ansible on a single host
just tune <hostname>

# Run Ansible on a group
just tune-all <group-name>

# Full day-1 bootstrap (Garage → platform → pets)
just bootstrap

# Tear down a state directory
just destroy <platform|pets>
```

### Environment setup

Before running any command, source the env file and set the vault password:

```bash
source .env                                         # from repo root
export ANSIBLE_VAULT_PASSWORD_FILE=infra/ansible/.vault-password
```

The `.env` file (gitignored) holds URLs and credentials needed to interact with proxmox
and tofu's shared state.

### Encrypting a new secret

```bash
ansible-vault encrypt_string '<value>' --name key_name
```

Paste the output into the relevant `host_vars/` or `group_vars/` file.

## Architecture

### Ergonomics affordances
- `just bootstrap` must always succeed in creating the entire lab from nothing an empty Proxmox cluser. Ordering issues that are hidden behind "existing state means you can shortcut" are a bomb that will explode in DR scenarios, the one time when you don't want issues.

### Responsibility split

**OpenTofu** = VM/LXC existence only. It provisions the VM in Proxmox (CPU, RAM, disks, cloud-init user+key) and stops there.  
**Ansible** = everything inside the VM. Software, config, services.

Never blur this line — Tofu does not install software; Ansible does not create VMs.

### State directories

`infra/tofu/` has three independent state directories, each with its own Garage S3 backend bucket key:

| Directory  | VMID range | Purpose |
|------------|------------|---------|
| `platform/` | 2xx | Infrastructure VMs: proxy pair, observability stack, auth |
| `pets/`     | 1xx | Named standalone VMs: Nextcloud, Forgejo (code) |

There is no `cluster-dev/` directory yet (referenced in justfile, not yet created).

The shared VM module lives at `tofu/modules/vm/`. An `lxc/` module also exists for containers.

### VM networking (critical)

VMs use DHCP. MAC addresses are **deterministic from VMID**: `02:00:00:00:<vmid/256 hex>:<vmid%256 hex>`. This means UniFi can assign stable DHCP leases and DNS entries by MAC. **Do not change VMIDs on existing VMs** — it will change the MAC and break the lease.

### Ansible inventory

Two inventory sources merge at runtime:
- **Static** (`inventory/hosts.yml`): blade02 only, in the `bootstrap` group. blade02 is a permanent management node that is NOT in any Tofu state.
- **Dynamic** (`inventory/proxmox.yml`): queries Proxmox API, creates groups from VM tags. A VM tagged `obs_prometheus` in Proxmox lands in the `obs_prometheus` Ansible group.

So Proxmox tags in `tofu/*/main.tf` directly control which Ansible roles run on a VM. When adding a VM, set tags that match the Ansible group_vars and site.yml role assignments.

### `site.yml` role mapping

Roles apply to groups, not individual hosts. Key assignments:

- `all` → os_baseline, node_exporter, alloy
- `bootstrap` (blade02 only) → garage
- `proxy` → keepalived, certbot, nginx_reverse_proxy
- `obs_prometheus` → prometheus, alertmanager, graphite_exporter, unpoller
- `obs_loki` → loki
- `obs_grafana` → grafana
- `auth` → authentik
- `nextcloud_app` → nextcloud

### Platform topology

```
LAN Clients → keepalived VIP (proxy01 HA LXC)
               └─ nginx → Proxmox nodes / internal services
blade02     → Garage S3 (stores all Tofu remote state) — NOT automated, manual pet
```

Proxmox nodes: pxmx01–pxmx05. Storage pools in use: `ceph-ssd-pool` (fast), `ceph-hdd-pool` (bulk), `local-lvm` (default root).

Raspberry Pi nodes: blade01-blade04. Each is a Raspberry Pi 4 with a consumer-grade NVMe drive. Only used when the user specifically asks for it, each pi serving a very specific, special-case purpose. blade01 is currently running MaaS (unused), blade02 has already been allocated as the "bootstrap" node for DR scenarios.

### Adding a new VM

1. Add entry to `locals.vms` in `tofu/<state>/main.tf` with VMID, node, resources, tags.
2. Run `just plan <state>` then `just cluster-up <state>` to provision.
3. Ansible picks it up automatically via dynamic inventory on next run — no inventory file edits needed, as long as tags match existing groups.
4. If a new role is needed, add it to `site.yml` and create the role under `ansible/roles/`.

### proxmox_haresource dependency trap

`proxmox_haresource` references a VM by its integer ID (`"vm:107"`). When that value comes from a local constant rather than a resource attribute, Tofu sees **no implicit dependency** on the VM actually existing and will create the HA resource in parallel — which fails or races.

**Always** wire the resource ID through the module output and add an explicit `depends_on`:

```hcl
resource "proxmox_haresource" "vm" {
  for_each    = { for k, v in local.vms : k => v if try(v.ha, false) }
  resource_id = "vm:${module.vm[each.key].vmid}"   # not each.value.vmid
  state       = "started"

  depends_on = [module.vm]
}
```

This pattern has burned the codebase twice. Do not revert to `each.value.vmid`.

### Disk device references

Always use `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsiN` instead of `/dev/sdX` when referencing disks in Ansible roles or scripts. The `sdX` name depends on PCI probe order at boot and is not stable — this project has directly observed the same `scsi2` data disk mapping to `sda` on some VMs and `sdb` on others depending on which PCI SCSI controller the kernel enumerated first.

In the VM module, the OS disk is `scsi1` and data disks start at `scsi2`, so the first (and usually only) data disk is always `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2`.

### Secrets

All secrets use ansible-vault AES256 encryption. Vault-encrypted values live inline in `host_vars/` and `group_vars/` files. The vault password file (`.vault-password`) is gitignored. The repo is public — nothing sensitive is committed in plaintext.
