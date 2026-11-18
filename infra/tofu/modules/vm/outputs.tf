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

# The address the guest agent reports on the VM's own NIC (matched by MAC, so
# docker0 and friends are skipped). Known only after the VM is up, which makes
# it usable where DNS isn't yet: a firewall rule between two VMs of the same
# state, planned before either exists. null until the agent reports; callers
# that put it in a firewall rule must refuse null, which PVE reads as "any".
output "ipv4_address" {
  description = "IPv4 address of the VM's NIC as reported by the guest agent (null until reported)."
  value = try(flatten([
    for i, mac in proxmox_virtual_environment_vm.vm.mac_addresses :
    proxmox_virtual_environment_vm.vm.ipv4_addresses[i]
    if lower(mac) == lower(local.mac_address)
  ])[0], null)
}
