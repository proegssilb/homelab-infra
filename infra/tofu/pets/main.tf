# pets — 1xx VMID range
#
# Experiments, misc lone VMs, and named infrastructure that lives
# outside a cluster.
#
# IMPORTANT: blade02 is the permanent management/bootstrap node.
# It hosts the Garage S3 backend that stores all OpenTofu state.
# It must not be destroyed via automation. It is provisioned manually
# and is NOT in this state directory — destroying pets does not touch it.

locals {
  vms = {
    # Optional per-VM keys:
    #   cores      — vCPU count (default 2)
    #   memory     — MiB RAM (default 2048)
    #   node       — Proxmox node name (default: var.proxmox_node)
    #   data_disks — list of {size (GiB), datastore} for extra disks beyond the root (default [])
    #   backup     — assign to the ha-prod/la-prod pool for backups (default false); pool picked by the "ha" key

    # File-sync and collaboration — Nextcloud (storage via TrueNAS NFS, to be wired later)
    nextcloud = { vmid = 103, cores = 2, memory = 8192, node = "pxmx05", tags = ["observe", "pets", "nextcloud_app"], ha = true, backup = true }

    # Git forge — Forgejo (mirrors to Codeberg; backed up via Proxmox VM snapshots)
    forgejo = { vmid = 106, cores = 4, memory = 8192, disk_size = 50, node = "pxmx04", tags = ["observe", "pets", "forgejo_app"], data_disks = [{ size = 100, datastore = "ceph-hdd-pool" }], ha = true, backup = true }

    # Personal finance tracker — Actual Budget (file-based storage, OIDC via Authentik)
    # VM hostname is "actual" (not "budget") so it doesn't collide with the
    # public vhost alias budget.{{ homelab_domain }} — see nginx vhosts_apps.yml.
    actual = { vmid = 107, cores = 1, memory = 1024, node = "pxmx01", tags = ["observe", "pets", "budget_app"], data_disks = [{ size = 10, datastore = "ceph-ssd-pool" }], ha = true, backup = true }

    # Recipe manager — Mealie (PostgreSQL on pg01, OIDC via Authentik)
    mealie = { vmid = 108, cores = 2, memory = 2048, disk_size = 40, node = "pxmx02", tags = ["observe", "pets", "mealie_app"], data_disks = [{ size = 10, datastore = "ceph-ssd-pool" }], ha = true, backup = true }

    # RSS aggregator — FreshRSS (PostgreSQL on pg01, OIDC via Authentik)
    freshrss = { vmid = 109, cores = 1, memory = 1024, node = "pxmx04", tags = ["observe", "pets", "freshrss_app"], data_disks = [{ size = 10, datastore = "ceph-ssd-pool" }], ha = true, backup = true }

    # Photo management — Immich (PostgreSQL + pgvector on pg01)
    immich = { vmid = 110, cores = 4, memory = 8192, node = "pxmx05", tags = ["observe", "pets", "immich_app"], data_disks = [{ size = 700, datastore = "ceph-hdd-pool" }], ha = true, backup = true }

    # Privacy-preserving metasearch — SearXNG (Docker + Redis, no external accounts)
    searxng = { vmid = 111, cores = 2, memory = 2048, node = "pxmx03", tags = ["observe", "pets", "searxng_app"], data_disks = [{ size = 5, datastore = "ceph-ssd-pool" }], ha = true }

    # Developer tools collection — IT Tools (stateless Docker, no persistence)
    ittools = { vmid = 112, cores = 1, memory = 1024, node = "pxmx01", tags = ["observe", "pets", "ittools_app"], ha = true }
  }
}

resource "proxmox_haresource" "vm" {
  for_each    = { for k, v in local.vms : k => v if try(v.ha, false) }
  resource_id = "vm:${module.vm[each.key].vmid}"
  state       = "started"

  depends_on = [module.vm]
}

module "vm" {
  for_each = local.vms
  source   = "../modules/vm"

  name          = each.key
  vmid          = each.value.vmid
  node_name     = lookup(each.value, "node", var.proxmox_node)
  template_id   = var.template_id
  template_node = var.template_node
  datastore     = var.datastore

  cores     = lookup(each.value, "cores", 2)
  memory    = lookup(each.value, "memory", 2048)
  disk_size = lookup(each.value, "disk_size", 20)

  data_disks = try(each.value.data_disks, [])

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags    = lookup(each.value, "tags", ["pet"])
  pool_id = try(each.value.backup, false) ? (try(each.value.ha, false) ? "ha-prod" : "la-prod") : null
}
