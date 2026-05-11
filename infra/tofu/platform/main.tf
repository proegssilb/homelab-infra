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
  vms = {
    # HA reverse-proxy pair — keepalived VIP + nginx → pxmx01-05
    proxy01 = { vmid = 200, cores = 2, memory = 2048, tags = ["platform", "proxy", "observe"], node = "pxmx01" }
    proxy02 = { vmid = 201, cores = 2, memory = 2048, tags = ["platform", "proxy", "observe"], node = "pxmx03" }

    # Observability stack — Prometheus + Alertmanager + Loki + Grafana
    obs01 = { vmid = 210, cores = 4, memory = 4096, tags = ["platform", "observability", "obs_prometheus", "observe"], node = "pxmx01", data_disks = [{ size = 60, datastore = "ceph-ssd-pool" }] }
    obs02 = { vmid = 211, cores = 4, memory = 4096, tags = ["platform", "observability", "obs_loki", "observe"],       node = "pxmx02", data_disks = [{ size = 80, datastore = "ceph-hdd-pool" }] }
    obs03 = { vmid = 212, cores = 2, memory = 2048, tags = ["platform", "observability", "obs_grafana", "observe"],    node = "pxmx03", data_disks = [{ size = 20, datastore = "ceph-ssd-pool" }] }
  }
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
