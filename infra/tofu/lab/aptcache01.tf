# aptcache01: the APT caching proxy (apt-cacher-ng) every Debian host and the Coder
# workspaces fetch packages through, so servers that only need the internet for
# packages can do without it. Migrated from tofu/platform in Phase 3 (step 1).
# The cache is disposable: a fresh data disk, not adopted.

locals {
  # Image built by .forgejo/workflows/app-images.yml from images/apps/apt-cacher-ng.
  # Bumped deliberately (the weekly rebuild picks up Debian security updates).
  acng_image = "${local.registry}/minifig/apt-cacher-ng:072ce9fe4300"

  acng_cache_dir = "/var/lib/aptcache"

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

  data_disks = [{ size = 100, datastore = "ceph-hdd-pool", mount = local.acng_cache_dir, owner = "3142:3142" }]

  node_name       = local.common.node_name
  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url

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
  ]

  run = [
    "systemctl daemon-reload",
    "systemctl restart apt-cacher-ng.service",
  ]
}
