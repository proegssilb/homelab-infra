variable "proxmox_node" {
  description = "Proxmox node to place platform VMs on."
  type        = string
  default     = "pve01"
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone from."
  type        = number
}

variable "template_node" {
  description = "Proxmox node that hosts the template. Required when the template lives on a different node than var.proxmox_node."
  type        = string
  default     = ""
}

variable "datastore" {
  description = "Proxmox storage ID for VM and container disks."
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

variable "lxc_template_file_id" {
  description = "Proxmox storage path to the LXC template, e.g. local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
  type        = string
}
