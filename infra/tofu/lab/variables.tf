variable "proxmox_node" {
  description = "Node for initial VM placement and for downloading the install disk (to shared cephfs)."
  type        = string
}

variable "datastore" {
  description = "Storage for OS disks and cloud-init drives (e.g. ceph-ssd-pool)."
  type        = string
}

variable "admin_ssh_key" {
  description = "SSH public key for the `admin` user on bootc VMs."
  type        = string
}

variable "domain" {
  description = "The lab's base domain (VMs' search domain; the registry is code.<domain>)."
  type        = string
}

variable "zone" {
  description = "The Tofu-managed DNS zone dns01 serves (e.g. l.example.com); UniFi forwards it to dns01."
  type        = string
}

variable "network" {
  description = "Lab network for bootc VMs: subnet CIDR (VMID = host part), gateway, DNS servers, and the DHCP pool's first/last host numbers."
  type = object({
    subnet      = string
    gateway     = string
    dns_servers = list(string)
    dhcp_first  = number
    dhcp_last   = number
  })
}

variable "dns_update_from" {
  description = "CIDRs dns01 accepts RFC 2136 updates from (TSIG is required on top): the networks the workstation and blade02 run Tofu from."
  type        = list(string)
}

variable "dns_update_key_secret" {
  description = "TSIG secret for record updates to dns01. Comes from Bitwarden (dns/tsig-tofu) as TF_VAR_dns_update_key_secret via secrets.env.map; never in tfvars."
  type        = string
  sensitive   = true
}

variable "loki_url" {
  description = "Loki base URL for Alloy on bootc VMs (e.g. http://obs02.<domain>:3100)."
  type        = string
}
