# Proxmox provider credentials — never committed. Set these in your shell:
#
#   export PROXMOX_VE_ENDPOINT="https://proxmox.home.domain:8006/"
#   export PROXMOX_VE_API_TOKEN="user@pam!token-name=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#
# Garage (S3) backend credentials:
#
#   export AWS_ACCESS_KEY_ID="<garage-key-id>"
#   export AWS_SECRET_ACCESS_KEY="<garage-secret>"
#
# Authentik provider credentials (token created once in Authentik admin UI):
#
#   export AUTHENTIK_URL="https://auth.<domain>"
#   export AUTHENTIK_TOKEN="<api-token>"
#
# OIDC client secrets (one per app, must match Ansible host_vars):
#
#   export TF_VAR_domain="<base-domain>"
#   export TF_VAR_oidc_client_secrets='{"mealie":"...","freshrss":"...","immich":"...","budget":"..."}'

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.101.0"
    }
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
    }
  }
  required_version = ">= 1.8"
}
