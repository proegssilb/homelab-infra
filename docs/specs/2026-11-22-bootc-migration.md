# Migration to OpenTofu + bootc VMs

Status: draft spec, decisions agreed 2026-11-22. Nothing built yet.

## Goal

Replace "Debian VM + Ansible configures everything inside it" with **Fedora bootc VMs**:
one shared OS image, apps as Podman Quadlets, per-VM last-mile config through cloud-init,
secrets pushed from Bitwarden. Ansible shrinks to hypervisor tuning only.

Why: a `just bootstrap` that rebuilds the lab from an empty Proxmox cluster with no
hand-made state, OS updates as tested, rollback-able images instead of package drift, no
secrets in the repo (not even encrypted), and apps packaged as containers, which can later
move to Kubernetes on the Raspberry Pi tier where that makes sense. The Pis themselves don't
run bootc; the Pi tier is out of scope here.

## Decisions

### Images

- **One shared template image** (Fedora bootc) carries everything common: Podman, node_exporter,
  Alloy, the health-check framework, the nightly DB dump unit, the image-version metric.
- **cloud-init does per-VM last mile** as far as possible: hostname, static IP, SSH key, which
  Quadlets to enable, their non-secret config. A VM-specific image is a last resort, allowed
  when cloud-init genuinely can't do the job.
- **Build**: runner01 (Forgejo Actions) builds the image from a Containerfile in this repo on
  changes to `main`, plus the disk image via `bootc-image-builder`.
- **runner01 can run VMs (verified 2026-11-22)**: CPU type `host`, nested KVM enabled on its
  node, `/dev/kvm` present, and creating a VM + vCPU through it succeeded. Job containers are
  unprivileged but have the host Docker socket, so jobs start sibling containers: `--device
  /dev/kvm` for the QEMU test, `--privileged` for `bootc-image-builder`. No runner config change
  needed; the socket already gives jobs root on runner01.
- **Storage**: Forgejo's container registry. If Forgejo is down, VMs keep running their current
  image and just can't update. blade02 keeps a copy of the latest disk image for DR.
- **VM creation**: Tofu uploads the disk image to Proxmox and clones VMs from it. This replaces
  the hand-made templates 901/902 and their CephFS vendor snippets (and 901's inherited
  `cipassword`).

### Updates: fully automatic, three gates

1. **Tested before publishing.** CI pushes the image as a candidate, boots the disk image in
   QEMU with KVM on runner01 (no Proxmox credentials in CI), checks boot, cloud-init (hostname + IP),
   SSH, a container start and node_exporter, and checks an upgrade from the current `stable`
   image to the candidate. Pass → tag `canary`.
2. **Per-VM health checks with automatic rollback** (greenboot-style): after an update reboot,
   if the VM's app health checks fail, it reboots into the previous deployment on its own. Each
   app's check is part of its last-mile config.
3. **Canary promotion.** A few low-stakes canary VMs follow `canary`; everything else follows
   `stable`. A runner01 job moves `stable` only when Prometheus shows every canary booted the
   new image (a rolled-back canary blocks promotion), is up with passing health checks, and
   raised no alerts over the soak window (default 24h).
   - Other VMs update on staggered nights. **pg01 updates in the last wave.**
   - Grafana panel: image digest per VM. Alerts: a VM rolled back; promotion blocked for more
     than a few days.

### Alerts

Alertmanager delivers to **Discord** (native `discord_configs`), for the `fire` receiver and the
rollout warnings. Critical alerts already reach Discord (found during Phase 0; the webhook is
vaulted, and copied to Bitwarden). Routing the rollout warnings is Phase 1 work.

### Secrets

- Store: **Bitwarden Password Manager** on bitwarden.com (survives a lab outage).
- Scripts unlock the vault per recipe run with `bw unlock`. The session token stays inside that
  one process: never in a shell's environment, never in a file.
- **Unlock prompt**: a GUI password dialog when a display exists (so Claude can trigger it from its
  own shell), a terminal prompt otherwise (blade02 over SSH). The dialog shows the caller,
  worked out from the process tree (recipe, working directory, parent such as Claude Code).
  That is a heads-up against surprises, not a security boundary.
- Secrets are referenced by item name (e.g. `homelab/authentik/secret_key`). Names may appear
  in the repo; values never.
- Generated secrets are created by script and piped straight into `bw create item`, never printed
  to the terminal, logs, or Claude. Externally issued ones (API tokens) are pasted into Bitwarden
  by hand under the agreed name.
- `vault-to-bitwarden.py` copied all 54 ansible-vault values into Bitwarden (`<scope>/<var>`)
  without printing them. **The vault stays authoritative for Ansible until Phase 6**; each VM
  reads Bitwarden once it migrates. Rotations go into the vault first, then a re-run of the
  script (it reports drift by name).
- **Delivery: pushed after boot.** VMs boot with no secrets. A `just` step reads Bitwarden and
  copies each secret over SSH into the VM (Podman secrets / systemd credentials). Never via
  cloud-init or Tofu: both would leave values in Tofu state and on Proxmox storage. A rebuilt
  VM needs the operator to unlock and re-push.

### Networking and DNS

- **Static IPs: VMID = last octet** of the VM's subnet, computed by Tofu and set by cloud-init.
  Subnets stay in gitignored local settings (public repo). agentsvc VMs follow the same rule in
  their own subnet. VMIDs 100–254 stay reserved for lab VMs (already true).
- The Lab network's UniFi DHCP pool must stay below `.100` (codify, or document as a manual step).
- **DNS: one PowerDNS Authoritative VM with Proxmox HA**, serving `l.<domain>`. Records are
  written by Tofu's `hashicorp/dns` provider (RFC 2136 + TSIG; key in Bitwarden) next to each VM
  definition. No backup: all records come from Tofu. The DNS VM is created first in bootstrap
  and is reached by IP.
- UniFi stays the resolver and forwards `l.<domain>` to PowerDNS (UniFi supports per-domain
  forwarding). Codify the forwarding rule, or document it as a manual step, like the DHCP pool.

### Data

- App data lives on **separate data disks** that image updates never touch. A rebuild replaces
  the OS disk only and reattaches the data disk.
- Backups: keep vzdump to the backup NAS, plus a nightly DB dump onto the data disk (shared unit in the
  template image).
- **Postgres**: Immich and Coder each get their own (Immich: Postgres container on its own VM
  using Immich's published image. Coder: coderdb, VM 120, as today). Mealie, FreshRSS,
  Anamnesis and Home Assistant stay on **shared pg01**: per-app Postgres costs too much storage.
- **pg01 HA = Proxmox HA on Ceph** (already configured). Replicated Postgres (Patroni etc.) was
  considered and rejected as not worth the complexity.

### What stays outside bootc

| Thing | Plan |
|---|---|
| proxy01 (LXC 200) | Converted to a bootc VM, same VMID, Proxmox HA |
| tsrouter01/02 (LXC 201/202) | Converted to bootc VMs, same VMIDs, HA anti-affinity kept |
| Hypervisors (pxmx01–05, grunt) | Keep **Ansible**, `hypervisors.yml` only |
| Coder workspaces | Stay Debian (they are mutable dev boxes); aptcache01 stays for them, itself as a bootc VM |
| ollama VM (100) | Stays hand-managed (GPU-specific); out of scope |
| blade02 and the Pi tier | **bootc is out of scope for the Pis.** blade02 stays a pet for now |

**Rule for hypervisors**: anything Proxmox can *create* through its API goes in Tofu (SDN,
pools, firewalls, storage definitions, users/tokens, HA groups, image uploads). Ansible is
only for *tuning the host OS* (packages, log forwarding, kernel settings).

### Disaster recovery

- `just bootstrap` runs from **either the workstation or blade02**.
- blade02: Garage (Tofu state), a timer that pulls the repo and pinned tools, a copy of the latest
  disk image, and a periodic check that bootstrap *could* start. No secrets at rest; the operator
  brings them through Bitwarden.
- **Nightly backup of the Tofu state bucket to the backup NAS.** Garage runs `replication_factor = 1` and
  nothing backed the state up before.
- Bootstrap order: state backend → DNS VM → image upload → platform → pets → secret push.

## Migration

**Approach per VM: in place.** Keep the VMID (so IP, MAC and name stay the same). Take a fresh
vzdump backup, replace the OS disk with the bootc image, keep the data disk, adapt the app's data
to its container layout. Rollback = restore the vzdump. Short planned outage per app.

### Phases

Each phase leaves the lab working.

**0. Foundations** (no VM changes)
- `scripts/bw-run`: unlock helper (GUI/terminal, caller chain shown, 15-min keyring timeout)
- Vault → Bitwarden copy (54 values); Tofu's `.env` and sensitive tfvars secrets → Bitwarden,
  fed to every `just` recipe through `secrets.env.map`
- Nightly Tofu state backup to the backup NAS (`roles/tofu_state_backup` on blade02, alert
  `TofuStateBackupStale`). **Manual step**: TrueNAS dataset + NFS export restricted to blade02,
  then `tofu_state_backup_enabled: true`. The backup runs as root, which NFS squashes, so the
  user is making a **new NAS user for this and the pg01/coderdb backup shares** (Maproot/Mapall
  to it). NFS mapping needs no password, so the account can have "Disable Password" set; if it
  gets one, it goes into Bitwarden as `nas/<user>`.
- ~~Alertmanager → Discord~~: already done (critical alerts post to Discord)
- PowerDNS moved to Phase 1 (first bootc VM)

**1. Image pipeline**
- PowerDNS VM as the first bootc VM, with Tofu records for the existing VMs (proves DNS
  before Phase 2 depends on it)
- Template Containerfile; runner01 build; QEMU boot + upgrade tests
- `canary`/`stable` tags, promotion job, image-digest metric, rollback/stall alerts
- `bootc-image-builder` disk image, Tofu upload, copy to blade02
- VM module: static IP from VMID, OS disk replaceable while keeping data disks

**2. Pilot**: ittools (112), stateless. Proves cloud-init last mile, static IP, DNS record,
secret push and automatic updates end to end.

**3. Platform**: aptcache01 (230), obs01–03 (210–212), proxy01 (200, LXC → VM),
tsrouter01/02 (201/202, LXC → VM), authentik (220), garage-apps (222).

**4. Apps with data**: searxng (111), homepage (115), actual (107), freshrss (109),
mealie (108), anamnesis (113), homeassistant (114), immich (110, own Postgres),
nextcloud (103), then pg01 (221). Nextcloud migrates: bulk storage stays in the lab as a data
disk on `ceph-hdd-pool`.

**5. High stakes**: forgejo (106; hosts the registry, so VMs can't update while it's down),
runner01 (118), coderdb (120), coder (116), egress01 (117), mcpgw (119).

**6. Cleanup**: delete retired Ansible roles and vault files, remove the LXC module and
templates 901/902, rewrite CLAUDE.md's architecture section.

## Open items

- **Verify automatic rollback empirically** in phases 1–2: deliberately publish an image whose
  health check fails to the canary/pilot and confirm the VM rolls back, reports the old digest,
  alerts, and blocks promotion. Exit criterion for phase 2.
- Canary set and wave assignment per VM.
- Per-app data layout mapping (Debian paths → container volumes) for each phase 3–5 VM.
