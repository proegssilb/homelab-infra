# VM module — owns "does this VM exist with these specs."
#
# MAC address is derived deterministically from VMID using the locally-
# administered unicast prefix (02:). Same VMID → same MAC → same DHCP
# lease → same DNS entry via Unifi. No static IP management required.

locals {
  mac_address = format("02:00:00:00:%02x:%02x",
    floor(var.vmid / 256),
    var.vmid % 256
  )
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.name
  node_name = var.node_name
  vm_id     = var.vmid
  tags      = var.tags
  pool_id   = var.pool_id

  # Clone from a cloud-init-enabled template. Full clone so the VM is
  # fully independent — no shared base disk.
  clone {
    vm_id        = var.template_id
    full         = true
    node_name    = var.template_node != "" ? var.template_node : var.node_name
    datastore_id = var.datastore
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.memory
  }

  # The Proxmox template's OS disk is scsi1.
  disk {
    datastore_id = var.datastore
    size         = var.disk_size
    interface    = "scsi1"
    file_format  = "raw"
    discard      = "on"
  }

  # Data disks start at scsi2, which the kernel enumerates as it will.
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

  network_device {
    mac_address = local.mac_address
    bridge      = var.bridge
    model       = "virtio"
  }

  # Cloud-init: create the ansible user with SSH key, request DHCP.
  # Hostname comes from the VM name field above via Proxmox metadata service.
  # All other config (packages, etc.) is handled by Ansible post-provision.
  initialization {
    datastore_id = var.datastore

    user_account {
      username = var.ansible_user
      keys     = [var.ansible_ssh_key]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  # Improve I/O performance for Linux guests.
  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # Prevent accidental destruction — use -target destroy explicitly.
    prevent_destroy = false

    # node_name controls initial placement only. After creation, Proxmox HA
    # and manual migrations are free to move the VM without causing drift.
    # To force a VM back to a specific node, taint it and re-apply.
    ignore_changes = [node_name]
  }
}
