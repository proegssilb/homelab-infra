output "name" {
  value = proxmox_virtual_environment_vm.vm.name
}

output "vmid" {
  value = proxmox_virtual_environment_vm.vm.vm_id
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
