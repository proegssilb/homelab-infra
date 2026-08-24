# LXC module — lightweight containers for single-purpose platform services.
#
# MAC address is derived deterministically from VMID using the same formula
# as the VM module — same VMID always yields the same DHCP lease and DNS entry.

locals {
  mac_address = format("02:00:00:00:%02x:%02x",
    floor(var.vmid / 256),
    var.vmid % 256
  )
}

resource "proxmox_virtual_environment_container" "lxc" {
  node_name = var.node_name
  vm_id     = var.vmid
  tags      = var.tags
  pool_id   = var.pool_id

  # privileged = true is required for keepalived (CAP_NET_ADMIN, CAP_NET_RAW).
  # Set explicitly per container rather than defaulting to true.
  unprivileged = !var.privileged

  # nesting required for systemd 257+ to function correctly inside LXC.
  features {
    nesting = true
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "debian"
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.datastore
    size         = var.disk_size
  }

  network_interface {
    name        = "eth0"
    mac_address = local.mac_address
    bridge      = var.bridge
  }

  initialization {
    hostname = var.name

    user_account {
      keys = [var.ansible_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  # Start on boot so the VIP comes back automatically after a node reboot.
  started      = true
  start_on_boot = true

  # Proxmox's container API doesn't expose the source template or the
  # injected root SSH key after creation, so `tofu import` can never
  # populate these two fields — every plan after an import shows them as
  # forces-replacement drift against a real, unchanged container.
  lifecycle {
    ignore_changes = [
      operating_system,
      initialization[0].user_account,
    ]
  }
}
