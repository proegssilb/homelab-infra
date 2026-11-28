# upsmon01: reads the UPS plugged into pxmx01 by USB (passed through by the cluster
# USB mapping in tofu/platform/ups_usb.tf) with NUT, and serves its metrics to obs01
# (nut_exporter :9199, job ups_nut, instance ups-pxmx01). Pinned to pxmx01 with no
# HA: a passed-through USB device can't migrate. Nothing shuts down on low battery
# (no upsmon). Migrated from tofu/platform in Phase 3 (step 1c); no data disk.
# Fedora's kernel has USB, so the old Debian VM's generic-kernel swap is gone.

locals {
  # Built by .forgejo/workflows/app-images.yml from images/apps/nut (Debian's NUT, the
  # same usbhid-ups driver as before). Bumped deliberately.
  nut_image          = "${local.registry}/minifig/nut:fb4d2b7c3a6c"
  nut_exporter_image = "ghcr.io/druggeri/nut_exporter:3.3.0"

  # vendorid:productid, as in tofu/platform/ups_usb.tf.
  ups_vendorid  = "051d"
  ups_productid = "0003"
}

module "upsmon01" {
  source = "../modules/bootc_vm"

  name      = "upsmon01"
  vmid      = 213
  cores     = 1
  memory    = 1024
  disk_size = 20
  channel   = "stable"
  tags      = ["ups_usb"]

  usb_mappings = ["ups-pxmx01"]
  node_name    = "pxmx01"

  datastore       = local.common.datastore
  install_disk_id = local.common.install_disk_id
  image           = local.common.image
  network         = local.common.network
  admin_ssh_key   = local.common.admin_ssh_key
  loki_url        = local.common.loki_url
  registry_mirror = local.common.registry_mirror

  files = [
    {
      path    = "/etc/containers/systemd/nut.container"
      content = templatefile("${path.module}/files/upsmon/nut.container.tftpl", { image = local.nut_image })
    },
    {
      path    = "/etc/containers/systemd/nut-exporter.container"
      content = templatefile("${path.module}/files/upsmon/nut-exporter.container.tftpl", { image = local.nut_exporter_image })
    },
    {
      path    = "/etc/nut/ups.conf"
      content = <<-EOT
        # Written by Tofu (tofu/lab/upsmon01.tf).
        [ups]
          driver = usbhid-ups
          port = auto
          vendorid = ${local.ups_vendorid}
          productid = ${local.ups_productid}
          desc = "UPS on pxmx01 (USB, passed through)"
      EOT
    },
    { path = "/etc/nut/upsd.conf", content = "# Written by Tofu. Localhost only: nut_exporter is the only client.\nLISTEN 127.0.0.1 3493\n" },
    { path = "/etc/nut/nut.conf", content = "# Written by Tofu. Driver and upsd here; no upsmon.\nMODE=standalone\n" },
    { path = "/etc/nut/upsd.users", content = "# Written by Tofu. No users: reads need no login.\n" },
    {
      # The UPS's USB node gets the container's nut group (GID 101), so the driver
      # doesn't need to run as root. Debian's NUT package ships the same kind of rule.
      path    = "/etc/udev/rules.d/62-homelab-ups.rules"
      content = "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${local.ups_vendorid}\", ATTR{idProduct}==\"${local.ups_productid}\", MODE=\"0660\", GROUP=\"101\"\n"
    },
    { path = "/etc/greenboot/check/required.d/50-upsmon.sh", content = file("${path.module}/files/upsmon/50-upsmon.sh"), mode = "0755" },
  ]

  run = [
    "udevadm control --reload && udevadm trigger --subsystem-match=usb --attr-match=idVendor=${local.ups_vendorid}",
    "systemctl daemon-reload",
    "systemctl restart nut.service",
    "systemctl restart nut-exporter.service",
  ]
}
