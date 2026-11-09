# Agent support services — VMs that Coder workspaces (AI agents) use instead of
# reaching the lab or the internet directly: the egress proxy now; package
# caches and a credential broker later.
#
# Network: the agentsvc VNet (VLAN 31, UniFi "AgentSvc", DHCP on), declared in
# coder_proxmox.tf. That network sits in the UniFi Agents zone, so these VMs
# get exactly what a workspace gets toward Lab (proxy01 443/2222, aptcache01,
# gateway DNS) plus two AgentSvc-only allows for observability (obs01 scrapes
# :9100, Alloy pushes to Loki). Workspaces reach them only through per-service
# UniFi allows. coder@pve cannot attach anything to this VNet.
#
# Each VM also gets its own Proxmox VM firewall: inbound dropped except its
# service ports from the workspace subnet, admin SSH and the node_exporter
# scrape. The UniFi rules are zone-wide in places (e.g. the Coder server's SSH
# into Agents), so this is what keeps a workspace or the Coder server off the
# support VMs' SSH and other daemons. The rules live in the cluster-wide
# /etc/pve/firewall/<vmid>.fw, so they follow the VM through HA migrations.

locals {
  agentsvc_vms = {
    # Egress proxy — mitmproxy, logging only for now (no TLS interception);
    # workspaces opt in via HTTP(S)_PROXY. Sees every request workspaces make
    # through it, so treat it as sensitive.
    egress01 = {
      vmid     = 117
      node     = "pxmx03"
      cores    = 2
      memory   = 2048
      tags     = ["observe", "pets", "agentsvc", "egress_proxy"]
      ha       = true
      services = [{ port = "8080", comment = "mitmproxy (HTTP/HTTPS proxy)" }]
    }
  }
}

module "agentsvc" {
  for_each = local.agentsvc_vms
  source   = "../modules/vm"

  name          = each.key
  vmid          = each.value.vmid
  node_name     = each.value.node
  template_id   = var.template_id
  template_node = var.template_node
  datastore     = var.datastore

  cores     = each.value.cores
  memory    = each.value.memory
  disk_size = try(each.value.disk_size, 20)

  data_disks = try(each.value.data_disks, [])

  bridge   = proxmox_sdn_vnet.agentsvc.id
  firewall = true

  ansible_user    = var.ansible_user
  ansible_ssh_key = var.ansible_ssh_key

  tags = each.value.tags

  depends_on = [proxmox_sdn_applier.coder]
}

resource "proxmox_haresource" "agentsvc" {
  for_each    = { for k, v in local.agentsvc_vms : k => v if try(v.ha, false) }
  resource_id = "vm:${module.agentsvc[each.key].vmid}"
  state       = "started"

  depends_on = [module.agentsvc]
}

# DHCP network, so no ipfilter (the address isn't known here); macfilter pins
# the NIC to its VMID-derived MAC, radv/ndp off as on workspaces.
resource "proxmox_virtual_environment_firewall_options" "agentsvc" {
  for_each  = local.agentsvc_vms
  node_name = each.value.node
  vm_id     = module.agentsvc[each.key].vmid

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  dhcp          = true
  macfilter     = true
  ipfilter      = false
  ndp           = false
  radv          = false
}

resource "proxmox_virtual_environment_firewall_rules" "agentsvc" {
  for_each  = local.agentsvc_vms
  node_name = each.value.node
  vm_id     = module.agentsvc[each.key].vmid

  dynamic "rule" {
    for_each = each.value.services
    content {
      type    = "in"
      action  = "ACCEPT"
      proto   = "tcp"
      dport   = rule.value.port
      source  = var.agents_cidr
      comment = "Workspaces: ${rule.value.comment}"
    }
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

  # Only the UniFi gateway hands out leases on this network.
  rule {
    type    = "out"
    action  = "DROP"
    proto   = "udp"
    sport   = "67"
    comment = "No rogue DHCP server replies"
  }
}
