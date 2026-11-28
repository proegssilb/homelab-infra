# garage-apps: general-purpose S3 object storage (Garage, single node) for the pet apps,
# starting with anamnesis. Reached only through proxy01 (s3.<domain>). Distinct from
# blade02's bootstrap-only Garage, which holds Tofu state and stays a pet.
# Migrated from tofu/platform in Phase 3 (step 2): the old Debian VM's data disk was
# reassigned to it (a rename on the storage, not a copy).

locals {
  garage_image    = "docker.io/dxflrs/garage:v2.5.0"
  garage_data_dir = "/var/lib/garage"
  garage_uid      = 3900
}

module "garage_apps" {
  source = "../modules/bootc_vm"

  name      = "garage-apps"
  vmid      = 222
  cores     = 2
  memory    = 2048
  disk_size = 20
  channel   = "stable"
  tags      = ["garage_app"]
  pool_id   = proxmox_virtual_environment_pool.ha_prod.pool_id

  # meta/ (sqlite: layout, buckets, keys) and data/ (object blocks). On the old VM
  # they belonged to Debian's `garage` user; the run below hands them to the
  # container's pinned UID (a no-op once done).
  data_disks = [
    { size = 50, datastore = "ceph-hdd-pool", mount = local.garage_data_dir, owner = "${local.garage_uid}:${local.garage_uid}" },
  ]

  node_name       = local.common.node_name
  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url
  registry_mirror = local.common.registry_mirror

  files = [
    {
      path = "/etc/containers/systemd/garage.container"
      content = templatefile("${path.module}/files/garage/garage.container.tftpl", {
        image          = local.garage_image
        data_dir       = local.garage_data_dir
        default_bucket = "anamnesis"
      })
    },
    { path = "/etc/garage.toml", content = file("${path.module}/files/garage/garage.toml") },
    { path = "/etc/greenboot/check/required.d/50-garage.sh", content = file("${path.module}/files/garage/50-garage.sh"), mode = "0755" },
  ]

  run = [
    "install -d -o ${local.garage_uid} -g ${local.garage_uid} -m 0750 ${local.garage_data_dir}/meta ${local.garage_data_dir}/data",
    "find ${local.garage_data_dir}/meta ${local.garage_data_dir}/data \\( ! -user ${local.garage_uid} -o ! -group ${local.garage_uid} \\) -exec chown ${local.garage_uid}:${local.garage_uid} {} +",
  ]

  # Garage reads these from the environment (Podman secrets). The default bucket's key
  # is the one anamnesis is configured with (vault: group_vars/all/main.yml).
  secrets = [
    { item = "garage-apps/garage_rpc_secret", command = "tr -d '[:space:]' | podman secret create --replace garage-rpc-secret - >/dev/null" },
    { item = "all/anamnesis_s3_access_key_id", command = "tr -d '[:space:]' | podman secret create --replace garage-default-access-key - >/dev/null" },
    { item = "all/anamnesis_s3_secret_access_key", command = "tr -d '[:space:]' | podman secret create --replace garage-default-secret-key - >/dev/null" },
  ]

  run_after_secrets = ["systemctl restart garage.service"]
}
