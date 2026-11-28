terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.124.0"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.6"
    }
  }
  required_version = ">= 1.8"
}
