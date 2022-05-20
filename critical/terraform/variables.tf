 # Providers
variable "pve_user" {
  description = "(Required) - The username for proxmox web api."
  type = string
  sensitive = true
  nullable = false
}

variable "pve_ssh_user" {
  description = "(Required) - The username for proxmox ssh."
  type = string
  sensitive = true
  nullable = false
}

variable "pve_password" {
  description = "(Required) - The password for proxmox."
  type = string
  sensitive = true
  nullable = false
}

variable "pve_host" {
  description = "(Required) - The host for the Proxmox api. Used for the API and ssh."
  type = string
  nullable = false
}


# Machine settings
variable "mach_pubkey" {
  description = "(Required) - the SSH public key used to ssh into the VMs."
  type = string
  nullable = false
}

variable "mach_domain_name" {
  description = "(Required) - the VMs' Domain Name."
  type = string
  nullable = false
}
