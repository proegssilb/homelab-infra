# A bootc VM (docs/specs/2026-11-22-bootc-migration.md).
#
# Proxmox's built-in cloud-init sets only identity and network: the `admin` user
# and key, the hostname, a static address (VMID = last octet) and DNS. Everything
# else (Alloy's endpoints, the update channel and window, app files, secrets) is
# pushed over SSH after first boot by scripts/push-vm.py, run from here. That avoids
# cloud-init snippets, which bpg can only upload by SSHing into the hypervisors.

locals {
  # Same deterministic MAC as modules/vm: same VMID, same MAC.
  mac_address = format("02:00:00:00:%02x:%02x", floor(var.vmid / 256), var.vmid % 256)

  ip     = cidrhost(var.network.subnet, var.vmid)
  prefix = split("/", var.network.subnet)[1]

  tracked_ref = "${var.image}:${var.channel}"
  window      = var.update_window != null ? var.update_window : (var.channel == "canary" ? "*-*-* 03:00" : null)

  base_files = concat(
    [{ path = "/etc/alloy/endpoints.env", content = "LOKI_URL=${var.loki_url}\n", mode = "0644" }],
    local.window == null ? [] : [{
      path    = "/etc/systemd/system/bootc-fetch-apply-updates.timer.d/window.conf"
      content = "[Timer]\nOnCalendar=\nOnCalendar=${local.window}\n"
      mode    = "0644"
    }],
  )

  # Track the channel tag instead of the exact build the install disk came from.
  # Staged now, applied by the next update reboot in the window.
  track_channel = join(" ", [
    "python3 -c 'import json, subprocess, sys; s = json.loads(subprocess.check_output([\"bootc\", \"status\", \"--json\"]));",
    "sys.exit(0 if ((s.get(\"spec\") or {}).get(\"image\") or {}).get(\"image\") == sys.argv[1] else 1)'",
    local.tracked_ref, "|| bootc switch --quiet", local.tracked_ref,
  ])

  base_run = [
    "systemctl daemon-reload",
    "systemctl restart alloy.service",
    local.track_channel,
    "systemctl restart bootc-fetch-apply-updates.timer",
    "systemctl start bootc-image-metric.service",
  ]

  push_spec = jsonencode({
    host         = local.ip
    vmid         = var.vmid
    user         = "admin"
    wait_seconds = 900
    files = [for f in concat(local.base_files, var.files) : {
      path        = f.path
      mode        = f.mode
      content_b64 = base64encode(f.content)
    }]
    run               = concat(local.base_run, var.run)
    secrets           = var.secrets
    run_after_secrets = var.run_after_secrets
  })
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vmid
  tags      = sort(distinct(concat(var.tags, ["bootc", "observe"])))

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  # OS disk from the bootc-base install image. scsi1, like modules/vm, so data
  # disks stay at scsi2+ and the /dev/disk/by-id conventions hold.
  disk {
    datastore_id = var.datastore
    interface    = "scsi1"
    import_from  = var.install_disk_id
    size         = var.disk_size
    file_format  = "raw"
    discard      = "on"
  }

  dynamic "disk" {
    for_each = { for i, d in var.data_disks : i => d }
    content {
      datastore_id = disk.value.datastore
      size         = disk.value.size
      interface    = "scsi${disk.key + 2}"
      file_format  = "raw"
      discard      = "on"
    }
  }

  boot_order = ["scsi1"]

  network_device {
    mac_address = local.mac_address
    bridge      = var.network.bridge
    model       = "virtio"
  }

  initialization {
    datastore_id = var.datastore
    # Proxmox's cloud-init defaults to "upgrade packages" (package_upgrade: true in
    # the user-data it generates), which fails on an immutable bootc root (dnf).
    # Updates come from the image channel instead.
    upgrade = false

    user_account {
      username = "admin"
      keys     = [var.admin_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "${local.ip}/${local.prefix}"
        gateway = var.network.gateway
      }
    }

    dns {
      domain  = var.network.domain
      servers = var.network.dns_servers
    }
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # The install disk only matters when a VM is created: afterwards it updates from
    # its channel. Bumping tofu/lab's install disk must not rebuild existing VMs.
    # (To rebuild one from the new disk: -replace=module.<vm>.proxmox_virtual_environment_vm.vm.)
    ignore_changes = [node_name, disk[0].import_from]

    precondition {
      condition     = var.vmid % 256 < var.network.dhcp_first || var.vmid % 256 > var.network.dhcp_last
      error_message = "VMID ${var.vmid} puts ${var.name} at ${local.ip}, inside the DHCP pool (.${var.network.dhcp_first}-.${var.network.dhcp_last})."
    }
  }
}

# Config and secrets after first boot. Re-runs when the VM is replaced or changed,
# or when the spec (files, commands, secret *names*) changes. Rotating a secret's
# value alone doesn't change the spec: `tofu apply -replace=module.<vm>.terraform_data.push`.
resource "terraform_data" "push" {
  triggers_replace = [sha256(local.push_spec)]

  provisioner "local-exec" {
    command     = "${path.module}/../../../scripts/push-vm.py"
    environment = { PUSH_SPEC = local.push_spec }
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.vm]
  }
}
