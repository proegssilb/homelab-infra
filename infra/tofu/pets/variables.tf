variable "proxmox_node" {
  description = "Proxmox node to place pets VMs on."
  type        = string
  default     = "pve01"
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone from."
  type        = number
}

variable "datastore" {
  description = "Proxmox storage ID for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "ansible_user" {
  description = "Username created via cloud-init for Ansible access."
  type        = string
  default     = "ansible"
}

variable "ansible_ssh_key" {
  description = "SSH public key injected via cloud-init for the ansible user."
  type        = string
}
