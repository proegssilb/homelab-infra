# bootc VMs (docs/specs/2026-11-22-bootc-migration.md). Every VM that moves to bootc
# lands in this state; platform/ and pets/ empty out over the migration.

locals {
  # The disk new VMs are installed from. Bumped deliberately: after install a VM
  # updates itself from its channel, so an older install disk costs one update.
  install_disk_version = "86bcc1f40307"

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
  }
}

# One copy on shared cephfs serves every node.
resource "proxmox_download_file" "bootc_base" {
  content_type = "import"
  datastore_id = "cephfs"
  node_name    = var.proxmox_node
  url          = "https://${local.registry}/api/packages/minifig/generic/bootc-base-disk/${local.install_disk_version}/bootc-base.qcow2"
  file_name    = "bootc-base-${local.install_disk_version}.qcow2"
}
