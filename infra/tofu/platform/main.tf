# platform — 2xx VMID range
#
# Platform / infrastructure VMs. Add entries to locals.vms as needed.
# Optional per-VM keys:
#   cores      — vCPU count (default 2)
#   memory     — MiB RAM (default 4096)
#   tags       — Proxmox tags list (default ["platform"])
#   node       — Proxmox node name (default: var.proxmox_node)
#   data_disks — list of {size (GiB), datastore} for extra disks beyond the root (default [])

locals {
  lxcs = {
    # Reverse proxy — single nginx LXC, Proxmox HA for auto-restart
    proxy01 = { vmid = 200, cores = 1, memory = 512, tags = ["platform", "proxy", "observe"], node = "pxmx01", privileged = false }
  }

  vms = {
    # Observability stack — Prometheus + Alertmanager + Loki + Grafana
    obs01 = { vmid = 210, cores = 4, memory = 4096, tags = ["platform", "observability", "obs_prometheus", "observe"], node = "pxmx01", data_disks = [{ size = 60, datastore = "ceph-ssd-pool" }] }
    obs02 = { vmid = 211, cores = 4, memory = 4096, tags = ["platform", "observability", "obs_loki", "observe"],       node = "pxmx02", data_disks = [{ size = 80, datastore = "ceph-hdd-pool" }] }
    obs03 = { vmid = 212, cores = 2, memory = 2048, tags = ["platform", "observability", "obs_grafana", "observe"],    node = "pxmx03", data_disks = [{ size = 20, datastore = "ceph-ssd-pool" }] }

    # Identity provider — Authentik
    auth = { vmid = 220, cores = 2, memory = 4096, tags = ["platform", "auth_app", "observe"], node = "pxmx02", data_disks = [{ size = 20, datastore = "ceph-ssd-pool" }] }
  }
}

module "lxc" {
  for_each = local.lxcs
  source   = "../modules/lxc"

  name             = each.key
  vmid             = each.value.vmid
  node_name        = each.value.node
  template_file_id = var.lxc_template_file_id
  datastore        = var.datastore
  cores            = each.value.cores
  memory           = each.value.memory
  privileged       = each.value.privileged
  tags             = each.value.tags
  ansible_ssh_key  = var.ansible_ssh_key
}

resource "proxmox_haresource" "proxy01" {
  resource_id = "ct:200"
  state       = "started"
}

module "vm" {
  for_each = local.vms
  source   = "../modules/vm"

  name        = each.key
  vmid        = each.value.vmid
  node_name   = lookup(each.value, "node", var.proxmox_node)
  template_id   = var.template_id
  template_node = var.template_node
  datastore   = var.datastore

  cores  = lookup(each.value, "cores", 2)
  memory = lookup(each.value, "memory", 4096)

  data_disks = try(each.value.data_disks, [])

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags = lookup(each.value, "tags", ["platform"])
}
