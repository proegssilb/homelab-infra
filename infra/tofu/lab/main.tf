# bootc VMs (docs/specs/2026-11-22-bootc-migration.md). Every VM that moves to bootc
# lands in this state; platform/ and pets/ empty out over the migration.

locals {
  # The disk new VMs are installed from. Bumped deliberately: after install a VM
  # updates itself from its channel, so an older install disk costs one update.
  install_disk_version = "810f85717a51"

  registry = "code.${var.domain}"
  image    = "${local.registry}/minifig/bootc-base"
  zone     = var.zone

  network  = merge(var.network, { domain = var.domain })
  dns01_ip = cidrhost(var.network.subnet, 240)

  common = {
    node_name       = var.proxmox_node
    datastore       = var.datastore
    install_disk_id = proxmox_download_file.bootc_base.id
    image           = local.image
    network         = local.network
    admin_ssh_key   = var.admin_ssh_key
    loki_url        = var.loki_url
    # Pull-through registry cache (Zot on aptcache01). VMs fall back to the upstream
    # registries when it doesn't answer, so bootstrap order doesn't matter.
    registry_mirror = "aptcache01.${var.zone}:5000"
  }
}

# One copy on shared cephfs serves every node.
resource "proxmox_download_file" "bootc_base" {
  content_type = "import"
  datastore_id = "cephfs"
  node_name    = var.proxmox_node
  # Forgejo normally; in a rebuild from scratch (Forgejo not up yet) blade02's DR copy
  # (roles/bootc_disk_mirror): install_disk_url = "http://<blade02>:3902/bootc-base-<version>.qcow2".
  url       = coalesce(var.install_disk_url, "https://${local.registry}/api/packages/minifig/generic/bootc-base-disk/${local.install_disk_version}/bootc-base.qcow2")
  file_name = "bootc-base-${local.install_disk_version}.qcow2"

  lifecycle {
    # Where the file came from doesn't matter once it's on cephfs; switching to the
    # DR URL (or back) mustn't re-download it.
    ignore_changes = [url]
  }
}

# Proxmox HA for the lab VMs that need it. resource_id comes from the module output
# plus depends_on, never a literal VMID (CLAUDE.md: proxmox_haresource dependency trap).
# canary01 isn't here: it's the VM the rollback test breaks.
locals {
  ha_vms = {
    dns01      = module.dns01.vmid
    ittools    = module.ittools.vmid
    aptcache01 = module.aptcache01.vmid
  }
}

resource "proxmox_haresource" "vm" {
  for_each    = local.ha_vms
  resource_id = "vm:${each.value}"
  state       = "started"

  depends_on = [module.dns01, module.ittools, module.aptcache01]
}
