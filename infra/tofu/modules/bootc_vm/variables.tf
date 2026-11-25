variable "name" {
  description = "VM name; also its hostname (Proxmox cloud-init)."
  type        = string
}

variable "vmid" {
  description = "Proxmox VM ID. Drives the MAC and the static address (last octet), so it must stay outside the subnet's DHCP pool."
  type        = number
}

variable "node_name" {
  description = "Proxmox node for initial placement (HA and migrations may move it later)."
  type        = string
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory" {
  description = "RAM in MiB."
  type        = number
  default     = 2048
}

variable "disk_size" {
  description = "OS disk size in GiB (the install image is grown to this; bootc-generic-growpart expands the filesystem)."
  type        = number
  default     = 20
}

variable "datastore" {
  description = "Storage for the OS disk and the cloud-init drive."
  type        = string
}

variable "data_disks" {
  description = "Data disks after the OS disk (scsi2, scsi3, ...): {size (GiB), datastore}."
  type = list(object({
    size      = number
    datastore = string
  }))
  default = []
}

variable "install_disk_id" {
  description = "Proxmox file ID of the bootc-base install disk (an `import` file, e.g. from proxmox_download_file)."
  type        = string
}

variable "image" {
  description = "Image repository the VM tracks, without tag (e.g. <registry>/<owner>/bootc-base)."
  type        = string
}

variable "channel" {
  description = "Image tag the VM tracks and updates from: canary or stable."
  type        = string
  default     = "stable"
  validation {
    condition     = contains(["canary", "stable"], var.channel)
    error_message = "channel must be canary or stable."
  }
}

variable "update_window" {
  description = "systemd OnCalendar for the update reboot. Null = channel default (canary 03:00, stable 04:00 from the image)."
  type        = string
  default     = null
}

variable "network" {
  description = "Static addressing: subnet CIDR (the VMID is the host part), gateway, DNS servers and search domain, the DHCP pool's first/last host numbers (the VM's address must be outside), and the Proxmox bridge."
  type = object({
    subnet      = string
    gateway     = string
    dns_servers = list(string)
    domain      = string
    dhcp_first  = number
    dhcp_last   = number
    bridge      = optional(string, "vmbr0")
  })
}

variable "admin_ssh_key" {
  description = "SSH public key for the `admin` user (also how the push reaches the VM)."
  type        = string
}

variable "loki_url" {
  description = "Loki base URL for Alloy (written to /etc/alloy/endpoints.env)."
  type        = string
}

variable "tags" {
  description = "Extra Proxmox tags. `bootc` is always added (the Ansible inventory skips it); `observe` is added for Prometheus discovery."
  type        = list(string)
  default     = []
}

variable "files" {
  description = "Extra files pushed to the VM after first boot: {path, content, mode}. Non-secret only (they sit in Tofu state)."
  type = list(object({
    path    = string
    content = string
    mode    = optional(string, "0644")
  }))
  default = []
}

variable "run" {
  description = "Commands run as root after the files are pushed (e.g. daemon-reload, start a Quadlet)."
  type        = list(string)
  default     = []
}

variable "secrets" {
  description = "Bitwarden items pushed after `run`: {item, command}; the value goes to the command's stdin and never into Tofu state."
  type = list(object({
    item    = string
    command = string
  }))
  default = []
}

variable "run_after_secrets" {
  description = "Commands run as root after the secrets."
  type        = list(string)
  default     = []
}
