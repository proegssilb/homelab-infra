provider "proxmox" {
  # endpoint and api_token read from PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN.
}

# Record updates to dns01 (RFC 2136), signed with the TSIG key `tofu`. dns01 gets the
# same key from module.dns01's push, before any record is written. Provider settings
# aren't stored in state, so the key stays out of it.
provider "dns" {
  update {
    server        = local.dns01_ip
    key_name      = "tofu."
    key_algorithm = "hmac-sha256"
    key_secret    = var.dns_update_key_secret
  }
}
