# dns01: PowerDNS Authoritative for var.zone (l.<apex>). Every record in it comes from this
# state, so it needs no backup. UniFi forwards the zone here (manual UniFi setting).
#
# One apply goes VM -> push (files, pdns started, zone created, TSIG key imported)
# -> records: the records depend on the whole module, push included.
module "dns01" {
  source = "../modules/bootc_vm"

  name      = "dns01"
  vmid      = 240
  cores     = 1
  memory    = 1024
  disk_size = 20
  channel   = "stable"
  tags      = ["dns"]

  node_name       = local.common.node_name
  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url
  registry_mirror = local.common.registry_mirror

  files = [
    { path = "/etc/containers/systemd/pdns.container", content = file("${path.module}/files/pdns/pdns.container") },
    {
      path = "/etc/powerdns/homelab.conf"
      content = templatefile("${path.module}/files/pdns/homelab.conf.tftpl", {
        listen      = local.dns01_ip
        update_from = join(", ", var.dns_update_from)
      })
    },
    {
      path    = "/etc/systemd/system/pdns-zone-init.service"
      content = templatefile("${path.module}/files/pdns/pdns-zone-init.service.tftpl", { zone = local.zone })
    },
    {
      path    = "/etc/greenboot/check/required.d/50-pdns.sh"
      content = templatefile("${path.module}/files/pdns/50-pdns.sh.tftpl", { zone = local.zone })
      mode    = "0755"
    },
  ]

  run = [
    "systemctl daemon-reload",
    "systemctl restart pdns.service",
    # restart, not enable --now: it's a RemainAfterExit oneshot that must re-run when
    # its unit (the zone) changes.
    "systemctl enable pdns-zone-init.service",
    "systemctl restart pdns-zone-init.service",
  ]

  # pdnsutil takes the key as an argument, so on dns01 it's briefly visible in the
  # process list; acceptable on a single-purpose VM. It never touches disk unencrypted
  # outside pdns's own database, nor Tofu state.
  secrets = [{
    item    = "dns/tsig-tofu"
    command = "podman exec -i pdns sh -c 'read -r k; pdnsutil tsigkey delete tofu >/dev/null 2>&1; pdnsutil tsigkey import tofu hmac-sha256 \"$k\" >/dev/null'"
  }]
}

# One record per lab VM (add each new VM here).
resource "dns_a_record_set" "bootc" {
  for_each = {
    dns01       = module.dns01.ip
    ns1         = module.dns01.ip
    canary01    = module.canary01.ip
    ittools     = module.ittools.ip
    aptcache01  = module.aptcache01.ip
    upsmon01    = module.upsmon01.ip
    garage-apps = module.garage_apps.ip
  }

  zone      = "${local.zone}."
  name      = each.key
  addresses = [each.value]
  ttl       = 300

  depends_on = [module.dns01]
}
