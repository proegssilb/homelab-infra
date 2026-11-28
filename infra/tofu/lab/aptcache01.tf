# aptcache01: the lab's package caches.
#   - apt-cacher-ng (:3142): every Debian host and the Coder workspaces fetch packages
#     through it, so servers that only need the internet for packages can do without it.
#   - Zot (:5000): pull-through cache for container images from docker.io, ghcr.io and
#     quay.io; every bootc VM tries it first and falls back to the upstream
#     (modules/bootc_vm registry_mirror). Fewer pulls against Docker Hub's per-IP limits
#     (the lab shares one address), faster rebuilds.
# Migrated from tofu/platform in Phase 3 (steps 1 and 1b). Both caches are disposable:
# fresh data disks, not adopted.

locals {
  # Image built by .forgejo/workflows/app-images.yml from images/apps/apt-cacher-ng.
  # Bumped deliberately (the weekly rebuild picks up Debian security updates).
  acng_image = "${local.registry}/minifig/apt-cacher-ng:072ce9fe4300"
  zot_image  = "ghcr.io/project-zot/zot-linux-amd64:v2.1.23"

  acng_cache_dir = "/var/lib/aptcache"
  zot_data_dir   = "/var/lib/zot"

  # HTTPS repositories can't be cached; the proxy only tunnels (CONNECT) to these
  # hosts on 443. Each one is a repo (or the source of its signing key) that a
  # Debian host or workspace uses. Add a host here when something starts using a
  # new HTTPS repo, or hosts without internet access can't install from it.
  acng_passthrough_hosts = [
    "apt.grafana.com",
    "download.docker.com",
    "pkgs.tailscale.com",
    "deb.debian.org",
    "security.debian.org",
  ]

  # Plain-HTTP repositories beyond the stock Debian/Ubuntu/Debian-security mirror
  # lists apt-cacher-ng already knows. Anything else is refused (ForceManaged).
  acng_remaps = [
    { name = "rpi", match = "archive.raspberrypi.com/debian archive.raspberrypi.org/debian", backend = "http://archive.raspberrypi.com/debian" },
  ]
}

module "aptcache01" {
  source = "../modules/bootc_vm"

  name      = "aptcache01"
  vmid      = 230
  cores     = 1
  memory    = 1536
  disk_size = 20
  channel   = "stable"
  tags      = ["apt_cache"]

  data_disks = [
    { size = 100, datastore = "ceph-hdd-pool", mount = local.acng_cache_dir, owner = "3142:3142" },
    { size = 100, datastore = "ceph-hdd-pool", mount = local.zot_data_dir, owner = "5000:5000" },
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
      path    = "/etc/containers/systemd/apt-cacher-ng.container"
      content = templatefile("${path.module}/files/aptcache/apt-cacher-ng.container.tftpl", { image = local.acng_image, cache_dir = local.acng_cache_dir })
    },
    {
      path    = "/etc/apt-cacher-ng/homelab.conf"
      content = templatefile("${path.module}/files/aptcache/homelab.conf.tftpl", { remaps = local.acng_remaps, passthrough = local.acng_passthrough_hosts })
    },
    { path = "/etc/greenboot/check/required.d/50-aptcache.sh", content = file("${path.module}/files/aptcache/50-aptcache.sh"), mode = "0755" },
    {
      path    = "/etc/containers/systemd/zot.container"
      content = templatefile("${path.module}/files/aptcache/zot.container.tftpl", { image = local.zot_image, data_dir = local.zot_data_dir })
    },
    { path = "/etc/zot/config.json", content = file("${path.module}/files/aptcache/zot-config.json") },
    { path = "/etc/greenboot/check/required.d/51-zot.sh", content = file("${path.module}/files/aptcache/51-zot.sh"), mode = "0755" },
  ]

  run = [
    "systemctl daemon-reload",
    "systemctl restart apt-cacher-ng.service",
    "systemctl restart zot.service",
  ]
}
