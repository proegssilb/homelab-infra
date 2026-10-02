# Proxmox provider credentials — never committed. Set these in your shell:
#
#   export PROXMOX_VE_ENDPOINT="https://proxmox.home.domain:8006/"
#   export PROXMOX_VE_API_TOKEN="user@pam!token-name=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#
# Garage (S3) backend credentials:
#
#   export AWS_ACCESS_KEY_ID="<garage-key-id>"
#   export AWS_SECRET_ACCESS_KEY="<garage-secret>"

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112.0"
    }
  }
  required_version = ">= 1.8"
}
