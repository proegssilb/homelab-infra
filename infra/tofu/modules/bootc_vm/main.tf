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

  # Data disks are the VM's own disks scsi2, scsi3, ... (the VM is never replaced:
  # see the lifecycle block below).
  mounts = [for i, d in var.data_disks : {
    drive = "scsi${i + 2}"
    mount = d.mount
    owner = d.owner
    unit  = "${trimprefix(replace(d.mount, "/", "-"), "-")}.mount"
  } if d.mount != null]

  mount_files = [for m in local.mounts : {
    path    = "/etc/systemd/system/${m.unit}"
    mode    = "0644"
    content = <<-EOT
      # Data disk ${m.drive} (modules/bootc_vm).
      [Unit]
      Description=Data disk ${m.drive} at ${m.mount}
      # Formats it only if it's blank; refuses unknown data.
      Requires=homelab-prepare-disk@${m.drive}.service
      After=homelab-prepare-disk@${m.drive}.service

      [Mount]
      What=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-${m.drive}
      Where=${m.mount}
      Type=ext4
      # Data disks hold container data: the whole filesystem gets the container
      # SELinux label at mount time, so Quadlets bind-mount it without :Z (no
      # recursive relabel of a big disk, and no :Z on these mounts).
      Options=defaults,noatime,context=system_u:object_r:container_file_t:s0

      [Install]
      WantedBy=local-fs.target
    EOT
  }]

  # The disk-prep script and unit the mounts require. Per-VM config like the mounts
  # themselves, so pushed, never baked into the image (a VM on a channel whose image
  # lacked them would boot without its data). The image's CI boot test pushes the
  # same files. /usr is read-only (including /usr/local), so the script lives in /etc
  # and the image's bash runs it.
  prepare_disk_files = length(local.mounts) == 0 ? [] : [
    { path = "/etc/homelab/prepare-disk", source = "${path.module}/files/prepare-disk", mode = "0644" },
    {
      path    = "/etc/systemd/system/homelab-prepare-disk@.service"
      content = file("${path.module}/files/homelab-prepare-disk@.service")
      mode    = "0644"
    },
  ]

  mount_run = flatten([for m in local.mounts : concat(
    ["systemctl enable --now ${m.unit}"],
    m.owner == null ? [] : ["chown ${m.owner} ${m.mount}"],
  )])

  base_files = concat(
    [
      { path = "/etc/alloy/endpoints.env", content = "LOKI_URL=${var.loki_url}\n", mode = "0644" },
      # Read by homelab-track-channel.service (image), which retries while the registry
      # is unreachable, so the push doesn't depend on Forgejo being up.
      { path = "/etc/homelab/channel", content = "${local.tracked_ref}\n", mode = "0644" },
    ],
    var.registry_mirror == null ? [] : [{
      # Pull-through cache first, upstream as fallback (podman tries mirrors in
      # order, then the location). Plain HTTP inside the lab; podman still checks
      # every blob against the digest the manifest names.
      path = "/etc/containers/registries.conf.d/50-homelab-mirror.conf"
      mode = "0644"
      content = join("\n", concat(
        ["# Written by Tofu (modules/bootc_vm): the lab's pull-through registry cache."],
        [for u in var.registry_mirror_upstreams : join("\n", [
          "",
          "[[registry]]",
          "prefix = \"${u}\"",
          "location = \"${u}\"",
          "[[registry.mirror]]",
          "location = \"${var.registry_mirror}/${u}\"",
          "insecure = true",
        ])],
        [""],
      ))
    }],
    local.window == null ? [] : [{
      path    = "/etc/systemd/system/bootc-fetch-apply-updates.timer.d/window.conf"
      content = "[Timer]\nOnCalendar=\nOnCalendar=${local.window}\n"
      mode    = "0644"
    }],
  )

  # Track the channel tag instead of the exact build the install disk came from.
  # Staged now, applied by the next update reboot in the window. Images without the
  # retrying unit (installed from an older disk, not updated yet) switch inline.
  track_channel_inline = join(" ", [
    "python3 -c 'import json, subprocess, sys; s = json.loads(subprocess.check_output([\"bootc\", \"status\", \"--json\"]));",
    "sys.exit(0 if ((s.get(\"spec\") or {}).get(\"image\") or {}).get(\"image\") == sys.argv[1] else 1)'",
    local.tracked_ref, "|| bootc switch --quiet", local.tracked_ref,
  ])
  track_channel = join(" ", [
    "if systemctl cat homelab-track-channel.service >/dev/null 2>&1; then",
    "systemctl enable homelab-track-channel.service && systemctl restart --no-block homelab-track-channel.service;",
    "else ${local.track_channel_inline}; fi",
  ])

  base_run = concat(
    ["systemctl daemon-reload"],
    local.mount_run,
    [
      "systemctl restart alloy.service",
      local.track_channel,
      "systemctl restart bootc-fetch-apply-updates.timer",
      "systemctl start bootc-image-metric.service",
    ],
  )

  push_spec = jsonencode({
    host         = local.ip
    vmid         = var.vmid
    user         = "admin"
    wait_seconds = 900
    # Inline files carry their content; source files carry a path and its hash (so
    # a changed file still changes the spec and re-runs the push).
    files = [for f in concat(local.base_files, local.prepare_disk_files, local.mount_files, var.files) : {
      path        = f.path
      mode        = f.mode
      content_b64 = try(f.source, null) == null ? base64encode(f.content) : null
      source      = try(f.source, null)
      sha256      = try(f.source, null) == null ? null : filesha256(f.source)
    }]
    run               = concat(local.base_run, var.run)
    secrets           = var.secrets
    run_after_secrets = var.run_after_secrets
  })
}

# The VM is the long-lived object: its data disks are its own, so it is never
# replaced (several apps are single-instance; there's no other copy). Rebuilding the
# OS is scripts/reinstall-os.py, which swaps only the OS disk in place.
resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vmid
  tags      = sort(distinct(concat(var.tags, ["bootc", "observe"])))
  # Backup pool (vzdump jobs target pools); a vzdump of the VM includes its data disks.
  pool_id = var.pool_id
  # Proxmox refuses to remove a protected VM or any of its drives (API and UI alike;
  # a volume deleted straight through the storage API is not covered). Tofu's
  # prevent_destroy below stops a replace at plan time, before bpg would shut the VM
  # down for a delete that protection then refuses.
  protection = length(var.data_disks) > 0

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

  # Data disks: scsi2, scsi3, ... (mounted by the units in local.mount_files).
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

  dynamic "usb" {
    for_each = var.usb_mappings
    content {
      mapping = usb.value
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
    # Never replaced or destroyed by Tofu, data or not (a literal: one way to rebuild
    # every bootc VM). A change bpg can't make in place (in practice: vm_id) or a
    # -replace fails the plan; a fresh OS is scripts/reinstall-os.py. Retiring a VM is
    # deliberate: lift protection in Proxmox, then remove it from the config and apply.
    prevent_destroy = true

    # The install disk only matters when a VM is created: afterwards it updates from
    # its channel. Bumping tofu/lab's install disk must not rebuild existing VMs.
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
    command = "${path.module}/../../../scripts/push-vm.py"
    # Compressed: an environment variable holds at most 128 KiB.
    environment = { PUSH_SPEC_GZ = base64gzip(local.push_spec) }
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.vm]
  }
}
