variable "vmid" {
  description = "Proxmox VM ID — must be unique across the cluster. Drives deterministic MAC address."
  type        = number
}

variable "name" {
  description = "VM hostname (set via cloud-init). Must match the host_vars filename in Ansible inventory."
  type        = string
}

variable "node_name" {
  description = "Proxmox node to place this VM on (e.g. pve01)."
  type        = string
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone."
  type        = number
}

variable "template_node" {
  description = "Proxmox node that hosts the template. Defaults to node_name (same node). Set this when the template lives on a different node than the target VM."
  type        = string
  default     = ""
}

variable "cores" {
  description = "Number of vCPU cores."
  type        = number
  default     = 2
}

variable "memory" {
  description = "RAM in MiB."
  type        = number
  default     = 2048
}

variable "disk_size" {
  description = "Root disk size in GiB."
  type        = number
  default     = 20
}

variable "datastore" {
  description = "Proxmox storage ID for the VM disk (e.g. local-lvm)."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge to attach the primary NIC to."
  type        = string
  default     = "vmbr0"
}

variable "tags" {
  description = "List of tags to apply in Proxmox."
  type        = list(string)
  default     = []
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

variable "data_disks" {
  description = "Additional data disks beyond the root. Each entry: {size (GiB), datastore (storage pool ID)}."
  type = list(object({
    size      = number
    datastore = string
  }))
  default = []
}
