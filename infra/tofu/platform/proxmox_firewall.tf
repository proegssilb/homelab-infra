# Proxmox firewall: datacenter switch on, but filtering nothing except guests
# that turn on their own VM-level firewall (today: Coder workspaces, see
# tofu/pets/coder_proxmox.tf and the Coder template).
#
# - Each node's host firewall is off: no INPUT/OUTPUT chains on the hypervisors,
#   so Ceph, corosync, SSH and the API are untouched.
# - All datacenter policies are ACCEPT, as a safety net for a node joining
#   before this is re-applied (its host firewall would default to on).
# - The iptables backend stays (nftables = false; the nftables one is a tech
#   preview and generates different rules).
#
# Not managed here (no provider attribute): each node's
# nf_conntrack_allow_invalid = 1, set once through the API
# (`pvesh set /nodes/<node>/firewall/options --nf_conntrack_allow_invalid 1`).
# Without it, bridged VM traffic in conntrack state INVALID is dropped; rare
# here (no asymmetric routing), so a rebuilt cluster works without it.

data "proxmox_virtual_environment_nodes" "all" {}

resource "proxmox_node_firewall" "node" {
  for_each = toset(data.proxmox_virtual_environment_nodes.all.names)

  node_name = each.value
  enabled   = false # host firewall off
  nftables  = false
}

resource "proxmox_virtual_environment_cluster_firewall" "this" {
  enabled        = true
  ebtables       = true # needed for the per-VM MAC/ARP filters
  input_policy   = "ACCEPT"
  output_policy  = "ACCEPT"
  forward_policy = "ACCEPT"

  # Node host firewalls must be off before the datacenter switch takes effect.
  depends_on = [proxmox_node_firewall.node]
}
