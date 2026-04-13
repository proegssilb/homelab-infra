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
    # Add pet VMs here as needed. Example:
    # mylab-vm = { vmid = 101, cores = 2, memory = 2048 }
  }
}

module "vm" {
  for_each = local.vms
  source   = "../modules/vm"

  name        = each.key
  vmid        = each.value.vmid
  node_name   = var.proxmox_node
  template_id = var.template_id
  datastore   = var.datastore

  cores  = lookup(each.value, "cores", 2)
  memory = lookup(each.value, "memory", 2048)

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags = ["pet"]
}
