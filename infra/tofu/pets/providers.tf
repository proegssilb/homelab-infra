provider "proxmox" {
  # endpoint and api_token read from PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN.
}

provider "authentik" {
  # url and token read from AUTHENTIK_URL / AUTHENTIK_TOKEN environment variables (set in .env).
}
