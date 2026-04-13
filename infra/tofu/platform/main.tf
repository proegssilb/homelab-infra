# platform — 2xx VMID range
#
# Platform / infrastructure VMs. Add entries to locals.vms as needed.
# Optional per-VM keys:
#   cores   — vCPU count (default 2)
#   memory  — MiB RAM (default 4096)
#   tags    — Proxmox tags list (default ["platform"])
#   node    — Proxmox node name (default: var.proxmox_node)

locals {
  vms = {
    # HA reverse-proxy pair — keepalived VIP + nginx → pxmx01-05
    proxy01 = { vmid = 200, cores = 2, memory = 2048, tags = ["platform", "proxy"], node = "pxmx01" }
    proxy02 = { vmid = 201, cores = 2, memory = 2048, tags = ["platform", "proxy"], node = "pxmx03" }
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

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags = lookup(each.value, "tags", ["platform"])
}
