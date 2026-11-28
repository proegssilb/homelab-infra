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
  description = <<-EOT
    Data disks after the OS disk (scsi2, scsi3, ...). They belong to a separate, never-started
    holder VM (VMID data_holder_vmid) and are attached here, so replacing or destroying this VM
    leaves them alone (docs/specs/2026-11-22-bootc-migration.md, Data). Each:
      size, datastore  as for any Proxmox disk;
      mount            optional mount point (letters, digits, _ and /; no dashes, so the systemd
                       unit name is just the path with / -> -). Mounted with the container SELinux
                       context, so Quadlets bind-mount it without :Z relabelling;
      owner            optional "uid:gid" for the mount point itself (not recursive).
    A blank disk gets ext4 on first mount (homelab-prepare-disk refuses anything not blank).
    Adding a disk to an existing VM takes two applies: the first adds it to the holder and stops
    with "Provider produced inconsistent final plan" (the new disk's path isn't known at plan
    time); the second attaches it. Nothing is lost in between. A provider limitation, not fixed as
    of bpg 0.124.0 (changelog checked 2026-11-28). Creating a VM with its disks is one apply.
  EOT
  type = list(object({
    size      = number
    datastore = string
    mount     = optional(string)
    owner     = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for d in var.data_disks : d.mount == null || can(regex("^/var/[a-z0-9_]+(/[a-z0-9_]+)*$", d.mount))])
    error_message = "data_disks[*].mount must be under /var and use only [a-z0-9_] path components (no dashes)."
  }
  validation {
    condition     = alltrue([for d in var.data_disks : d.owner == null || can(regex("^[0-9]+:[0-9]+$", d.owner))])
    error_message = "data_disks[*].owner must be numeric uid:gid."
  }
}

variable "data_holder_vmid" {
  description = "VMID of the holder VM that owns the data disks. Default 2000 + vmid (2000-2999 is reserved for holders; Coder uses 1000-1999)."
  type        = number
  default     = null
}

variable "registry_mirror" {
  description = <<-EOT
    host:port of the lab's pull-through registry cache (Zot on aptcache01), or null. Podman then
    pulls each upstream in registry_mirror_upstreams through <mirror>/<upstream> first and falls
    back to the upstream itself when the cache doesn't answer, so nothing depends on it being up.
  EOT
  type        = string
  default     = null
}

variable "registry_mirror_upstreams" {
  description = "Upstream registries pulled through registry_mirror (each must be a sync source in Zot's config)."
  type        = list(string)
  default     = ["docker.io", "ghcr.io", "quay.io"]
}

variable "usb_mappings" {
  description = "Proxmox cluster USB mapping names to pass through (the VM then can't migrate: pin it, no HA)."
  type        = list(string)
  default     = []
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
  description = <<-EOT
    Extra files pushed to the VM after first boot: {path, mode, and either content or source}.
    source = a local file read by the push at apply time (big static files such as dashboards and
    rule files; only its hash goes into the push spec). Non-secret only.
  EOT
  type = list(object({
    path    = string
    content = optional(string)
    source  = optional(string)
    mode    = optional(string, "0644")
  }))
  default = []

  validation {
    condition     = alltrue([for f in var.files : (f.content == null) != (f.source == null)])
    error_message = "Each file needs exactly one of content or source."
  }
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
