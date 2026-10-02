# Boot-benchmark state. One persistent VM, built exactly like the real ones
# (same template, same module, same Ansible roles) so `just boot-bench` measures
# what the lab's IaC actually produces. Not part of `just bootstrap`.
#
# Tag `bench` matches this directory name so `just cluster-up bench` /
# `just destroy bench` work unchanged; `ittools_app` gives it a stateless
# docker workload via the existing role.

locals {
  vms = {
    bench01 = {
      vmid   = 900
      cores  = 1
      memory = 1024
      node   = "pxmx01"
      tags   = ["bench", "ittools_app"]
    }
  }
}

module "vm" {
  for_each = local.vms
  source   = "../modules/vm"

  name          = each.key
  vmid          = each.value.vmid
  node_name     = each.value.node
  template_id   = var.template_id
  template_node = var.template_node
  datastore     = var.datastore

  cores  = each.value.cores
  memory = each.value.memory

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags = each.value.tags
}

# Consumed by scripts/boot-bench.py.
output "vms" {
  value = { for k, v in local.vms : k => { vmid = module.vm[k].vmid, node = v.node } }
}
