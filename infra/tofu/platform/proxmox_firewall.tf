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
# Everything else is stock PVE, deliberately: in particular
# nf_conntrack_allow_invalid stays at its default (off), so bridged VM packets
# in conntrack state INVALID are dropped. Measured on the busiest node: about
# one such packet every few minutes (stray RSTs after a connection closed);
# nothing depends on them.

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
