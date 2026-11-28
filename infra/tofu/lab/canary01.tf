# canary01: no app. It tracks :canary, so it's what canary promotion waits on, and the
# VM the deliberate broken-image rollback test breaks, without risking a real service.
module "canary01" {
  source = "../modules/bootc_vm"

  name      = "canary01"
  vmid      = 241
  cores     = 1
  memory    = 1024
  disk_size = 20
  channel   = "canary"
  tags      = ["canary"]

  # A small data disk, so the canary exercises what real VMs with data do across
  # image updates and OS reinstalls (protection, mount, homelab-prepare-disk).
  data_disks = [{ size = 1, datastore = "ceph-ssd-pool", mount = "/var/lib/scratch" }]

  node_name       = local.common.node_name
  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url
  registry_mirror = local.common.registry_mirror
}
