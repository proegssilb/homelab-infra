output "name" {
  value = proxmox_virtual_environment_vm.vm.name
}

output "vmid" {
  value = proxmox_virtual_environment_vm.vm.vm_id
}

output "data_holder_vmid" {
  description = "VMID of the holder VM owning the data disks (null without data disks)."
  value       = length(var.data_disks) > 0 ? proxmox_virtual_environment_vm.data[0].vm_id : null
}

output "ip" {
  description = "Static IPv4 address (VMID = last octet). Known at plan time."
  value       = local.ip
}

# Something to depend on when a resource needs the VM's config and secrets in place
# (e.g. DNS records that need dns01's TSIG key).
output "pushed" {
  value = terraform_data.push.id
}
