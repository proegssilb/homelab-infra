variable "vmid" {
  description = "Proxmox container ID — drives deterministic MAC address."
  type        = number
}

variable "name" {
  description = "Container hostname. Must match host_vars filename in Ansible inventory."
  type        = string
}

variable "node_name" {
  description = "Proxmox node to place this container on."
  type        = string
}

variable "template_file_id" {
  description = "Proxmox storage path to the LXC template, e.g. local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
  type        = string
}

variable "cores" {
  description = "Number of vCPU cores."
  type        = number
  default     = 1
}

variable "memory" {
  description = "RAM in MiB."
  type        = number
  default     = 256
}

variable "swap" {
  description = "Swap in MiB."
  type        = number
  default     = 0
}

variable "disk_size" {
  description = "Root disk size in GiB."
  type        = number
  default     = 4
}

variable "datastore" {
  description = "Proxmox storage ID for the container rootfs."
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Network bridge to attach the primary NIC to."
  type        = string
  default     = "vmbr0"
}

variable "privileged" {
  description = "Run as a privileged container. Required for keepalived (CAP_NET_ADMIN/NET_RAW)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "List of tags to apply in Proxmox."
  type        = list(string)
  default     = []
}

variable "ansible_ssh_key" {
  description = "SSH public key added to root's authorized_keys. LXCs don't use cloud-init user creation — Ansible connects as root."
  type        = string
}
