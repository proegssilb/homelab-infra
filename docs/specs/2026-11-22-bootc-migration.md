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

Phase 1 progress and decisions (2026-11-24):
- **Forgejo is now the primary remote**; GitHub is a publish-only push mirror (SSH deploy key,
  no token anywhere). GitHub is never a fallback for Forgejo.
- Base image `quay.io/fedora/fedora-bootc:45`; VMs pull it **anonymously** (package public on
  Forgejo, nothing secret or site-specific in it).
- Step 1 done: `images/bootc-base/` builds clean under `bootc container lint --fatal-warnings`,
  and a local disk boots and passes all 14 checks of `images/bootc-base/test/boot-test.sh`
  (cloud-init hostname + static IP, guest agent, node_exporter + image metric, Alloy, Podman,
  sshd, no failed units, bootc status).
- Steps 2–3 done (2026-11-24, CI runs 1–8 on runner01): build + push, disk image, KVM boot
  test, upgrade test (`bootc switch` + reboot from the previous disk), then publish. Verified:
  a deliberately broken image (node_exporter off, run 7) fails the boot test; anonymous pulls
  of image and disk work. Learned on the way: the automatic Actions token can't push packages
  (owner token `PACKAGE_TOKEN`, package scope only, copy in Bitwarden); a separate `docker push`
  of bootc's big layers dies on proxy01's idle keep-alive, so build and push are one
  `buildx --push`; bootc-image-builder under Docker needs `--cgroupns=host`; the disk is
  published only after both tests, so a broken disk never becomes an upgrade base or install
  source. Branch runs (no canary) upgrade-test from the newest earlier disk.
- **For step 4**: CI's disk is built from the image *by digest*, so a VM installed from it would
  track that digest and never update. Step 4 must point VMs at the `canary`/`stable` tag (at
  install time or with a first-boot `bootc switch`).
- greenboot is installed but its bootc rollback behaviour is still unverified (empirical test in
  phases 1–2, as planned).

Phase 1 steps 4–6 (2026-11-24/25), done:
- `tofu/lab` (one state for every bootc VM; platform/pets empty out) + `modules/bootc_vm`. dns01
  (PowerDNS 5.0, zone `l.<apex>`, records written by Tofu with TSIG) and canary01 run on it.
- Per-VM config arrives by Tofu-run SSH push (cloud-init snippets would need SSH into the
  hypervisors); cloud-init only sets user, hostname and network. The push verifies host keys through
  the Proxmox API (guest agent) instead of trust-on-first-use.
- Channels and promotion work; the workflow's `RELEASE_BRANCH` is this branch until the merge.
- **greenboot rollback verified** on canary01: a failing required check after an upgrade made the
  bootloader fall back to the previous image, `bootc_update_available` stayed 1, and
  `BootcUpdateStuck` went pending. No custom fallback needed.
- Still to observe over time: canary01 taking the new canary in its window, promotion after 24 h
  (before the merge it runs at the start of a release-branch build), dns01 updating at 04:00.

**2. Pilot** — done 2026-11-25. ittools (112) runs as a bootc VM in `tofu/lab` on the canary
channel (HA, `.112`, behind proxy01 via `ittools.<lab zone>`). The recipe is
`docs/migrating-a-vm-to-bootc.md`. Lab DHCP pool is now `.20–.99`; **temporary UniFi fixed-IP
reservations** keep the not-yet-migrated DHCP VMs at their old addresses, each removed when its VM
migrates (MAC `02:00:00:00:00:xx`): nextcloud .148, forgejo .151, actual .158, mealie .153,
freshrss .154, immich .155, searxng .156, anamnesis .159, homeassistant .160, homepage .161,
coder .162, runner01 .163, mcpgw .164, coderdb .165 (ittools' .157 already removed). Found on the
way: an install disk older than the host-key publisher can't be pushed to, so the install disk is
bumped deliberately and `ignore_changes` keeps that from rebuilding existing VMs.

Pilot plan (original):: ittools (112), stateless. Proves cloud-init last mile, static IP, DNS record,
secret push and automatic updates end to end.

**3. Platform**: aptcache01 (230), upsmon01 (213), garage-apps (222), obs03, obs02, obs01
(212–210), authentik (220), tsrouter02 then tsrouter01 (202/201, LXC → VM), proxy01 (200, LXC →
VM), in that order, one VM at a time with the user's go-ahead before each cutover.

Phase 3 decisions (2026-11-25/27):
- **Data disks must survive every rebuild** (several apps are single-instance): a never-started
  holder VM (VMID 2000 + vmid, `prevent_destroy`) owns them, the VM attaches them. Existing disks
  are adopted (reassigned, no copy) with `scripts/adopt-data-disk.py` after a vzdump of the stopped
  VM. Platform VMs renumber to `.<VMID>`; UniFi policies that pin them by IP get the new address next
  to the old one before each cutover and lose the old one after; consumers move to lab-zone names.
- DR: blade02 mirrors the newest release install disks (`roles/bootc_disk_mirror`); the channel
  switch retries until Forgejo is back, so a rebuild from scratch doesn't need Forgejo first.
- Network patience: VMs wait up to 10 min for the network at boot (switch/gateway/DNS back late
  after a power cut); Quadlets retry without a start limit; app greenboot checks wait 10 min.
- Staggered nightly windows for stable platform VMs (HA pairs and the observability stack never
  reboot together).

Step 0 (foundations), done 2026-11-28: image units (network wait, channel switch retries, timid
disk prep), module (holder disks, mounts, USB, source files), DR mirror. Verified in CI (NIC link
down 3 min at boot; a blank disk gets ext4, a disk of random data is refused and unchanged: that
check caught a pipefail bug that *did* format it) and on canary01: an adopted disk keeps its data and
ownership through a rebuild, a live migration and a vzdump (which includes it); Tofu refuses to
destroy the holder; plan is a no-op afterwards. canary01 keeps a 1 GiB data disk to exercise this
on every update.

Step 1 (aptcache01), cut over 2026-11-28 02:34–02:36 UTC: bootc VM `.230` on `:stable`, apt-cacher-ng
from `images/apps/apt-cacher-ng` (built by `app-images.yml`), fresh 100 GiB cache disk on a holder.
Same allowlist (Debian 200, unmanaged URL 403, CONNECT only to the listed hosts). All 26 reachable
Debian hosts point at `aptcache01.<lab zone>` (os_baseline only); the Coder template was re-pushed;
UniFi "Agents: -> aptcache01" now names `.230` only. Left: the Coder VM's own firewall peer
(`tofu/pets`, needs `lab_zone` in its tfvars and the workstation resolving the lab zone; until then
the Coder VM itself fetches packages directly). Done 2026-11-28 once `zone` was in pets' tfvars and
the workstation's Tailscale split DNS answered for the lab zone.

Step 1b (registry cache), 2026-11-28: Zot v2.1.23 on aptcache01 (:5000, own 100 GiB data disk,
unprivileged UID 5000, no capabilities) syncs docker.io, ghcr.io and quay.io on demand under
`/<upstream>/`. Every bootc VM gets a registries.conf drop-in (module `registry_mirror`) listing it
as a mirror with the upstream as fallback: verified a pull from canary01 lands in the cache, and
(locally) that a pull still succeeds from the upstream when the cache is down. Plain HTTP inside
the lab; podman checks every blob against the manifest's digests.

Step 1c (upsmon01), cut over 2026-11-28 03:34–03:37 UTC: bootc VM `.213`, pinned, no HA, the cluster
USB mapping attached by name. NUT from `images/apps/nut` (Debian's, same `usbhid-ups`) as the nut
user (pushed udev rule gives the UPS node GID 101), nut_exporter from its upstream image as UID 9199
with no capabilities. The generic-kernel swap is gone (Fedora's kernel has USB). obs01 scrapes
`upsmon01.<lab zone>:9199`; `up{job="ups_nut"}` 1, battery metrics back. Also: bpg/proxmox 0.124
in every state (no plan changes).

Step 2 (garage-apps), cut over 2026-11-28 05:13–05:19 UTC: the first adopted data disk. Bootc VM `.222`,
HA, `:stable`, Garage from its upstream image (`dxflrs/garage:v2.5.0`, same version) as UID 3900 with
no capabilities, RPC and admin API on loopback only. The old VM's 50 GiB disk was reassigned to holder
2222 after a stop-mode vzdump; the existing node, layout, `anamnesis` bucket and key (from 2026-09-05)
came back unchanged, ownership handed to UID 3900 by an idempotent `find … -exec chown`. RPC secret
and default key are Podman secrets from Bitwarden. proxy01's `s3` vhost points at the lab-zone name.
Found on the way: lab VMs weren't in a backup pool, so the nightly pool-based vzdump would have dropped
them. `ha-prod`/`la-prod` moved from `tofu/platform` to `tofu/lab` (lab is applied first by bootstrap;
`removed` without destroy there, imported here) and `modules/bootc_vm` takes `pool_id`.

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
