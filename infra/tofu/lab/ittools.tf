# ittools: IT Tools (stateless), the Phase 2 pilot migrated from tofu/pets. Tracks
# :canary, so a real app proves each canary before it reaches :stable.
module "ittools" {
  source = "../modules/bootc_vm"

  name      = "ittools"
  vmid      = 112
  cores     = 1
  memory    = 1024
  disk_size = 20
  channel   = "canary"
  tags      = ["ittools"]

  node_name       = local.common.node_name
  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url

  files = [
    { path = "/etc/containers/systemd/ittools.container", content = file("${path.module}/files/ittools/ittools.container") },
    { path = "/etc/greenboot/check/required.d/50-ittools.sh", content = file("${path.module}/files/ittools/50-ittools.sh"), mode = "0755" },
  ]

  run = [
    "systemctl daemon-reload",
    "systemctl restart ittools.service",
  ]
}
