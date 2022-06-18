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

# Kubernetes Vars

variable "rke2_token" {
  description = "(Required) - A shared secret used to authenticate nodes."
  type = string
  sensitive = true
  nullable = false
}

variable "rke2_virtual_ip" {
  description = "(Required) - An IPv4 address to use for the cluster's API. It will be used as an HA Virtual IP address, so make sure DHCP won't hand it out."
  type = string
  nullable = false
}
