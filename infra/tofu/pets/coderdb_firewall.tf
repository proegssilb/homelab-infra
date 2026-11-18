# Proxmox VM firewall around coderdb (VM 120), Coder's PostgreSQL.
#
# In:  PostgreSQL from the Coder server only, admin SSH, node_exporter scrape.
# Out: open, as on the agentsvc VMs. The point of this fence is that the Coder
#      server (see coder_firewall.tf for why it is treated as exposed) reaches
#      nothing here but 5432.
#
# Coder's address comes from the guest agent (module output), not DNS: both VMs
# live in this state, so in a from-scratch `just bootstrap` neither has a DNS
# record when pets is planned. The rules are created once both VMs are up.
# Rules live in the cluster-wide /etc/pve/firewall/120.fw, so they follow the
# VM through HA migrations.

locals {
  coderdb_fw_vmid = module.vm["coderdb"].vmid
  coderdb_fw_node = local.vms.coderdb.node
  coder_ip        = module.vm["coder"].ipv4_address
  coderdb_ip      = module.vm["coderdb"].ipv4_address
}

resource "proxmox_virtual_environment_firewall_options" "coderdb" {
  node_name = local.coderdb_fw_node
  vm_id     = local.coderdb_fw_vmid

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  dhcp          = true # Lab hands out its address by DHCP
  macfilter     = true
  ipfilter      = false # DHCP address, not known here
  ndp           = true
  radv          = false
}

resource "proxmox_virtual_environment_firewall_rules" "coderdb" {
  node_name = local.coderdb_fw_node
  vm_id     = local.coderdb_fw_vmid

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "5432"
    source  = local.coder_ip
    comment = "PostgreSQL from the Coder server"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    source  = join(",", var.agentsvc_admin_sources)
    comment = "Admin / Ansible SSH"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "9100"
    source  = join(",", var.agentsvc_scrape_sources)
    comment = "Prometheus node_exporter scrape"
  }

  lifecycle {
    # An empty source means "any" to PVE: never write the 5432 rule without
    # Coder's address.
    precondition {
      condition     = local.coder_ip != null
      error_message = "No guest-agent address for the coder VM yet; is it running with qemu-guest-agent? Re-run the apply once it reports."
    }
  }

  depends_on = [
    proxmox_virtual_environment_firewall_options.coderdb,
  ]
}
