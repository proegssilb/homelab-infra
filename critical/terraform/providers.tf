locals {
  pve_url = "https://${var.pve_host}:8006/api2/json"
}

terraform {
  required_providers {
    proxmox = {
      source = "Telmate/proxmox"
      version = "2.9.10"
    }
  }
}

provider "proxmox" {
  pm_api_url = local.pve_url
  pm_user = var.pve_user
  pm_password = var.pve_password
}
