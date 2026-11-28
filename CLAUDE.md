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

# Day-2 boot benchmark: Proxmox start -> service answering (persistent VM, N runs)
just cluster-up bench     # once; tofu/bench is NOT part of `just bootstrap`
just boot-bench [runs]    # VM start -> service answering (api / agent / service phases)
just docker-bench [runs]  # docker alone on the running VM (container start, daemon start)
just destroy bench        # when done
```

`tofu/bench/` needs its own gitignored `terraform.tfvars` (copy the template/datastore/ssh-key
values from `platform/`). The bench VM is built like any real VM on purpose, so the numbers
include whatever overhead the IaC produces.

### Environment setup

Before running any command, source the env file and set the vault password:

```bash
source .env                                         # from repo root
export ANSIBLE_VAULT_PASSWORD_FILE=infra/ansible/.vault-password
```

The `.env` file (gitignored) holds URLs and other non-secret settings (endpoints, `GARAGE_ENDPOINT`).
Credentials (Proxmox/Authentik tokens, Garage keys, sensitive `TF_VAR_*`) come from Bitwarden:
every Tofu and Ansible recipe in the justfile runs through `scripts/bw-run --env-map
secrets.env.map`, which shows a GUI unlock dialog naming the calling process chain (terminal
prompt when there's no display) and keeps the vault unlocked for 15 minutes after the last use
(kernel keyring, `BW_RUN_TIMEOUT`). `just bw-lock` locks it at once. `secrets.env.map` lists
env var → item name only (folder `homelab`).

**Agents must never read secret values**: don't `cat`/`grep`/`head` `.env`, `terraform.tfvars`,
vault plaintext or `bw get` output. The scripts that move secrets (`vault-to-bitwarden.py`,
`secrets-to-bitwarden.py`) print item names only; use their `--dry-run` / `--check` modes.

### Encrypting a new secret

```bash
ansible-vault encrypt_string '<value>' --name key_name
```

Paste the output into the relevant `host_vars/` or `group_vars/` file.

### Git remotes

Forgejo (`minifig/homelab-infra` on `code.<domain>`) is the primary remote and the only place to
push. GitHub is a publish-only push mirror (Forgejo pushes to it over SSH with a deploy key, on every
commit). Never push to GitHub directly and never pull the repo from GitHub as a workaround: a Forgejo
outage is an incident to fix, not to route around. CI runs on Forgejo Actions (runner01) from
`.forgejo/workflows/`; once that directory exists Forgejo ignores `.github/workflows/`, which keeps
running on GitHub off the mirror.

## Architecture

### Ergonomics affordances
- `just bootstrap` must always succeed in creating the entire lab from nothing an empty Proxmox cluser. Ordering issues that are hidden behind "existing state means you can shortcut" are a bomb that will explode in DR scenarios, the one time when you don't want issues.

### Responsibility split

**OpenTofu** = VM/LXC existence only. It provisions the VM in Proxmox (CPU, RAM, disks, cloud-init user+key) and stops there.  
**Ansible** = everything inside the VM. Software, config, services.

While these two tools are in use, do not mix up their purposes — Tofu does not install software; Ansible does not create VMs.

### State directories

`infra/tofu/` has three independent state directories, each with its own Garage S3 backend bucket key:

| Directory  | VMID range | Purpose |
|------------|------------|---------|
| `platform/` | 2xx | Infrastructure VMs: proxy pair, observability stack, auth |
| `pets/`     | 1xx | Named standalone VMs: Nextcloud, Forgejo (code) |
| `lab/`      | `.<VMID>`, outside the DHCP pool (`.20–.99`) | bootc VMs (`modules/bootc_vm`): ittools (112), upsmon01 (213), aptcache01 (230), dns01 (240), canary01 (241). Every VM lands here as it migrates; platform/ and pets/ empty out. Not configured by Ansible (tag `bootc`, excluded from the inventory). |
| (none)      | 1000–1999 | Coder workspace VMs, created by Coder (template in `ansible/roles/coder/files/coder-templates/`), fenced to the `coder` Proxmox pool, tagged `coder_workspace` and excluded from the Ansible inventory. Never allocate these IDs to lab VMs. |
| (lab)       | 2000–2999 | Holder VMs owning bootc VMs' data disks (`2000 + vmid`, `<name>-data`, tag `bootc-data`, never started). Created by `modules/bootc_vm` or `scripts/adopt-data-disk.py`. |

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

- `apt_cache` (aptcache01) → os_baseline, apt_cache — first play, ahead of `all`
- `all:!hypervisors` → os_baseline, node_exporter, alloy
- `hypervisors` (pxmx01–05, grunt; static in `inventory/hosts.yml`) → **not in site.yml**: `hypervisors.yml` via `just tune-hypervisors [limit]`, observability only (Debian `prometheus-node-exporter`, `rsyslog` forwarding the journal + `/var/log/pve-firewall.log` to Alloy's syslog listener on obs02, Ceph mgr Prometheus module). Debian packages only, no PVE config touched. Kept out of `just bootstrap` because each node's `ansible` user (key login, passwordless sudo; `sudo` isn't installed on PVE by default) is created by hand.
- `bootstrap` (blade02 only) → garage, tofu_state_backup (off until `tofu_state_backup_enabled`; needs the backup NAS export)
- `proxy` → keepalived, certbot, nginx_reverse_proxy
- `obs_prometheus` → prometheus, alertmanager, graphite_exporter, blackbox_exporter, snmp_exporter, unpoller (snmp_exporter polls the two UPS network cards on the Management VLAN over SNMPv3, job `ups`; targets, per-card MIB module and credentials are vaulted in `group_vars/obs_prometheus.yml`, the SNMPv3 user is set by hand on each card, and UniFi "Lab: obs01 -> UPS cards SNMP" allows only obs01 -> the two card addresses on UDP 161. Alert rules: `roles/prometheus/files/rules/`, checked by promtool before install. `fire.yml` = severity=critical, "needs a human, won't fix itself"; keep that bar. Alertmanager (config checked by amtool) routes critical to the `fire` receiver, which posts to Discord (webhook vaulted as `alertmanager_discord_webhook_url`), and everything else to `null`)
- upsmon01 (VM 213, pinned to pxmx01, no HA) is a **bootc VM** since Phase 3 (`tofu/lab/upsmon01.tf`; `roles/ups_usb` is unused): the UPS plugged into pxmx01 by USB, passed through by the cluster USB mapping in `tofu/platform/ups_usb.tf`; NUT (`images/apps/nut`, Debian's) reads it with `usbhid-ups` (Debian's NUT has no USB-capable build of this UPS's Modbus driver, and the UPS's firmware has no Modbus option anyway, so no load/voltage/temperature from it), as the unprivileged `nut` user thanks to a pushed udev rule; upsd on localhost only, no upsmon, so nothing shuts down on low battery; nut_exporter on :9199 is scraped by obs01 as job `ups_nut`, instance `ups-pxmx01`, and the UPS rules cover its `network_ups_tools_*` metrics
- `obs_loki` → loki
- `obs_grafana` → grafana
- `auth` → authentik
- `nextcloud_app` → nextcloud
- `forgejo_app` → forgejo (also registers the Actions runner's shared secret, `forgejo_runner_secret`)
- `forgejo_runner` (runner01) → forgejo_runner (Docker executor, host socket mounted into jobs, QEMU binfmt for arm64 builds; runs after the forgejo play)
- `coder_postgres` (coderdb, VM 120) → postgresql (Coder's own DB, same role as pg01; play runs before Coder's; dumps on its data disk, carried off by vzdump)
- `coder_app` (coder, VM 116) → coder (no DB, no Docker socket in the container; Ansible creates the `coder-admin` Owner and logs in per run to push templates, so no token is vaulted; Authentik login, limited to members of the hand-made Authentik group `coder-users` by a policy in `authentik_apps.tf`; metrics on :2112)
- `egress_proxy` (egress01) → egress_proxy (mitmproxy for Coder workspaces; refuses non-public destinations; destination allowlist `egress_proxy_allowlist`, in shadow mode: misses are logged as "egress would refuse", not blocked)
- `ntp_server` (egress01) → ntp_server (chrony; workspaces' NTP, so they need no internet NTP)
- `agentgateway_app` (mcpgw) → agentgateway (MCP gateway: Authentik login for MCP clients, per-tool CEL rules in `agentgateway_mcp_rules`, upstream servers in `agentgateway_mcp_targets`. Hybrid storage: the templated config file is the read-only baseline, servers/policies added in its UI live in SQLite on the VM, hence `backup = true`). Also serves the lab's local models to Coder workspaces at `mcp.<domain>/llm/v1` (`llm` section, models in `agentgateway_llm_models`; an entry's optional `defaults`/`overrides` set request-body fields, e.g. `qwen3.8-flash-next-fast` is Flash-Next with `reasoning_effort: none` for editors' utility calls; `qwen3-embedding` is a CPU-only Ollama model): callers present their workspace's Coder agent token, which the `coder-authz` sidecar (`files/coder_authz.py`) checks with Coder; upstreams are Ollama and PolyStrata on the hand-managed ollama VM (VM 100 on grunt, not in tofu except its Proxmox firewall, `tofu/pets/ollama_firewall.tf`: model ports from mcpgw only). The Coder template writes a Kilo Code config (`KILO_CONFIG`) with that token

### Agent support services

VMs that Coder workspaces use (egress proxy now; package caches, credential broker later) live in
`tofu/pets/agentsvc.tf` on the `agentsvc` SDN VNet (VLAN 31, UniFi "AgentSvc", DHCP, inside the
Agents zone). Each gets its own Proxmox VM firewall (inbound: service ports from the workspace
subnet, admin SSH, the node_exporter scrape). Never grant coder@pve anything on `agentsvc` or on
the `coder` SDN zone as a whole. Adding a VNet to an existing zone needs
`-replace=proxmox_sdn_applier.coder` on that apply (`replace_triggered_by` ignores creates).

proxy01 refuses the Agents and AgentSvc subnets (`coder_agents_cidr`, `agentsvc_cidr` in
`group_vars/all/local.yml`) on every vhost by default (`nginx_vhost_default_deny` in
`group_vars/proxy/main.yml`). Only `dev`, `code` and `mcp` opt out with `access_deny: []`; a new
vhost stays closed to workspaces unless it does the same.

The MCP gateway (mcpgw, VM 119) is on the Lab network, not `agentsvc`: like Forgejo, workspaces
reach it only through proxy01 (`mcp.<domain>`), never directly. Its UI vhost `mcp-admin` stays
default-denied to workspaces.

The Coder server (VM 116) has its own VM firewall with outbound DROP (`tofu/pets/coder_firewall.tf`);
a new thing Coder must reach needs a rule there. Its database is on coderdb (VM 120, `coderdb_firewall.tf`:
5432 from Coder only), not pg01, so the exposed Coder host has no path to the other apps' databases. The
two firewalls name each other by the guest-agent address (`module.vm[...].ipv4_address`), not DNS: both
VMs are in pets, so neither has a DNS record when a from-scratch bootstrap plans pets.

Workspaces send HTTP(S) through egress01's mitmproxy (proxy env vars in the Coder template; lab
names are NO_PROXY), apt through aptcache01, and NTP to egress01's chrony. They have no direct
internet: UniFi "Agents: workspaces -> internet only via egress proxy" blocks (and logs) VLAN 30 ->
External; AgentSvc (VLAN 31) isn't matched, so egress01 keeps its internet. Each egress01 service is
a `services` entry in `agentsvc.tf` (VM firewall) plus a UniFi "Agents: workspaces -> AgentSvc …"
allow from VLAN 30. Workspaces get git access only through a
per-workspace Forgejo deploy key, which the Coder template creates through proxy01's deploy-key
proxy (`code.<domain>:9443`, `roles/nginx_reverse_proxy/templates/forgejo_keys.conf.j2`): a
method+path allowlist in front of a Forgejo bot token that never leaves proxy01.

### APT proxy

Every Ansible-managed host (and every Coder workspace) fetches packages through `aptcache01` (apt-cacher-ng, port 3142), so a server that only needs the internet for packages can lose internet access. Since Phase 3 it's a bootc VM in `tofu/lab` (`aptcache01.<lab zone>`, `.230`; apt-cacher-ng from `images/apps/apt-cacher-ng`), and `roles/apt_cache` is unused. The proxy is an allowlist: plain-HTTP repos only via its Remap rules, HTTPS repos only by tunnel to the hosts in `acng_passthrough_hosts` (`tofu/lab/aptcache01.tf`). When a role adds a new HTTPS repo, add its host there, and give its `deb822_repository` task `environment: "{{ apt_proxy_env | default({}) }}"` so the signing-key download goes through the proxy too. The `bootstrap` group is exempt (`apt_proxy_host: ""`).

### Platform topology

```
LAN Clients → keepalived VIP (proxy01 HA LXC)
               └─ nginx → Proxmox nodes / internal services
blade02     → Garage S3 (stores all Tofu remote state) — NOT automated, manual pet
               └─ tofu_state_backup: nightly rclone copy of the bucket → backup NAS over NFS (30 days)
```

`/etc/garage.toml` on blade02 matches the garage role's template, so `just garage` only rewrites it
when blade02's address changes (it derives `rpc_public_addr` from facts; a stale one makes the bare
`garage` CLI hang). The role leaves blade02's Garage binary alone (`garage_version` in its host_vars
is unused there). Prometheus scrapes blade02 through the static `bootstrap` job (proxmox SD only
finds guests).

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

### bootc image pipeline (migration in progress)

`images/bootc-base/` is the template image for bootc VMs (Fedora bootc, pinned major; see
`docs/specs/2026-11-22-bootc-migration.md`). It holds only what every VM shares and nothing
site-specific: hostname, network, keys, the domain and log endpoints come from cloud-init (Alloy reads
`/etc/alloy/endpoints.env` and doesn't start without it). Rules that `bootc container lint
--fatal-warnings` enforces at build time: service users are pinned in `usr/lib/sysusers.d/homelab.conf`
and created before the RPMs install (a random UID would orphan their `/var` files on update), and
every directory a package leaves in `/var` gets a tmpfiles.d entry.

- Local loop: `podman build -t localhost/bootc-base:dev images/bootc-base`, then
  `sudo images/bootc-base/build-disk.sh` (bootc-image-builder needs root; output in the gitignored
  `out/`), then the boot test: `podman build -t localhost/bootc-test:dev -f images/bootc-test/Containerfile
  images/bootc-base && podman run --rm --device /dev/kvm -v "$PWD/images/bootc-base/out:/work:ro,z"
  localhost/bootc-test:dev /work/qcow2/disk.qcow2`.
- CI (`.forgejo/workflows/bootc-base.yml`, any branch push touching the image): build + push,
  qcow2 via bootc-image-builder, KVM boot test, upgrade test (from `:canary`; on branches from the
  newest earlier disk), and only then publishes the qcow2 as generic package `bootc-base-disk`
  and (release branch only) tags `:canary`. Branches get `branch-<sha>` only. The release branch is
  `RELEASE_BRANCH` in the workflows: the migration branch until it merges, then `main`. A broken disk must never be
  published: if one is, delete that `bootc-base-disk` version, or the next branch run upgrades
  from it and fails.
- CI gotchas (each cost a run): pushes use `secrets.PACKAGE_TOKEN` (owner token, package scope;
  the automatic token gets 401 on push); build and push are one `buildx --push` (a separate
  `docker push` of the big layers hits proxy01's idle keep-alive); bootc-image-builder under
  Docker needs `--cgroupns=host`; job logs aren't public, so read the run in the Forgejo UI.

### bootc VMs (`tofu/lab`, `modules/bootc_vm`)

- Installed from the `bootc-base-disk` package (version pinned in `tofu/lab/main.tf`), static address
  = VMID as last octet (the module refuses one inside the DHCP pool), names in the Tofu-managed zone
  `var.zone` on dns01 (PowerDNS; UniFi forwards that zone to it; `lab_dns_zone` for Ansible).
- Proxmox cloud-init sets only the `admin` user + key, hostname and network, with `upgrade = false`
  (Proxmox's default "upgrade packages" runs dnf and breaks cloud-init on bootc). No snippets.
- Everything else is **pushed over SSH by Tofu** (`scripts/push-vm.py`, local-exec): files, commands,
  then Bitwarden secrets on stdin. Values never in state or cloud-init. The push verifies the VM's
  SSH host key by reading it through the Proxmox API (guest agent) from `/var/log/qemu-ga/`, where the
  image republishes it (the confined agent can't read `/etc/ssh`); host keys change with every new
  cloud-init instance, so nothing is cached. A rotated secret alone doesn't trigger a push:
  `tofu apply -replace=module.<vm>.terraform_data.push`.
- Updates: each VM tracks `bootc-base:canary` or `:stable` (switched on first push) and reboots into
  updates in a nightly window (canary 03:00, stable 04:00). `:stable` moves only when every canary VM
  has run the canary 24 h healthy (`.forgejo/scripts/bootc_promote.py`, before each release build and
  daily once merged). greenboot rolls an update back if a required check fails (verified on canary01);
  alerts `BootcUpdateStuck` (48 h) and `BootcPromotionStalled` (4 days).
- **Data disks survive rebuilds**: `data_disks` belong to a never-started holder VM (VMID 2000 + vmid,
  tag `bootc-data`, `prevent_destroy`); the VM attaches them by `path_in_datastore`, so `-replace` or
  destroying the VM keeps the data (several apps are single-instance). Mounts use
  `homelab-prepare-disk@` (formats only an all-zero disk) and the container SELinux context, so Quadlets
  mount them without `:Z`. Existing disks are adopted with `scripts/adopt-data-disk.py` (dry run by
  default). Never remove `prevent_destroy` or delete a holder casually.
- The image waits up to 10 min for the network (`homelab-wait-network`, before
  `network-online.target`); Quadlets use `RestartSec=10s` + `StartLimitIntervalSec=0`, and pushed
  greenboot checks wait up to 10 min and stay self-contained (no helper an older deployment lacks).
  The channel switch retries in `homelab-track-channel.service`, so pushes don't need Forgejo up.
- DR: blade02 mirrors the newest release install disks (`roles/bootc_disk_mirror`, Garage web on
  :3902); set `install_disk_url` in `tofu/lab` to it when Forgejo isn't up yet.
- Migrating a VM: `docs/migrating-a-vm-to-bootc.md`. Lab DHCP is `.20–.99`; not-yet-migrated DHCP
  VMs above that keep temporary UniFi reservations (list in the spec), removed as each migrates.
- Never run `pdnsutil tsigkey list` (it prints the secret). Rotate with
  `scripts/bw-run -- scripts/bw-generate.py dns/tsig-tofu --rotate`, then targeted-apply dns01's push
  before a full apply (a full plan refreshes records with the new key first and fails NOTAUTH).

### Secrets

All secrets use ansible-vault AES256 encryption. Vault-encrypted values live inline in `host_vars/` and `group_vars/` files. The vault password file (`.vault-password`) is gitignored. The repo is public — nothing sensitive is committed in plaintext.

**Bitwarden copy (bootc migration, until Phase 6)**: every vaulted value is also an item in
Bitwarden folder `homelab`, named `<scope>/<var>` (`obs_prometheus/alertmanager_discord_webhook_url`,
`blade02/garage_rpc_secret`; list entries add `/<index>/<key>`). The vault stays authoritative
for Ansible; bootc VMs read Bitwarden once they migrate. After adding or rotating a vaulted
secret, run `just vault-to-bitwarden` (it reports `exists-DIFFERENT` by name; add
`--update <name>` to overwrite). Tofu's secrets live only in Bitwarden (`env/<NAME>`,
`<state>/<var>`).
