output "name" {
  description = "VM hostname."
  value       = proxmox_virtual_environment_vm.vm.name
}

output "vmid" {
  description = "Proxmox VM ID."
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "mac_address" {
  description = "Deterministic MAC address derived from VMID."
  value       = local.mac_address
}
