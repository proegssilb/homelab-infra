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

    # File-sync and collaboration — Nextcloud (storage via TrueNAS NFS, to be wired later)
    nextcloud = { vmid = 103, cores = 2, memory = 8192, node = "pxmx05", tags = ["observe", "pets", "nextcloud_app"] }

    # Git forge — Forgejo (mirrors to Codeberg; backed up via Proxmox VM snapshots)
    forgejo = { vmid = 106, cores = 4, memory = 8192, disk_size = 50, node = "pxmx04", tags = ["observe", "pets", "forgejo_app"], data_disks = [{ size = 100, datastore = "ceph-hdd-pool" }] }
  }
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

  tags = lookup(each.value, "tags", ["pet"])
}
