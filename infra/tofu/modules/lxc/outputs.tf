output "name" {
  description = "Container hostname."
  value       = proxmox_virtual_environment_container.lxc.initialization[0].hostname
}

output "vmid" {
  description = "Proxmox container ID."
  value       = proxmox_virtual_environment_container.lxc.vm_id
}

output "mac_address" {
  description = "Deterministic MAC address derived from VMID."
  value       = local.mac_address
}
