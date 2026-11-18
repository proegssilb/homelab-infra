# Proxmox VM firewall on the ollama VM (VM 100 on grunt, Lab VLAN).
#
# The VM itself is hand-managed and isn't in any tofu state; only this fence
# is. Ollama (11434) and PolyStrata (18081) listen on the VM's address so the
# MCP gateway can serve them to Coder workspaces (agentgateway's `llm`
# section, roles/agentgateway). Ollama has no authentication of its own, so
# both model ports admit mcpgw and nobody else; everything else on the VM
# (SSH, Open WebUI) keeps the default ACCEPT it had before this file.
#
# A firewall outside the guest on purpose: Docker's published ports bypass
# the guest's INPUT chain, so an in-guest rule wouldn't cover PolyStrata.

data "dns_a_record_set" "ollama_peer" {
  for_each = toset(["mcpgw"])
  host     = "${each.key}.${var.domain}"
}

locals {
  ollama_fw_vmid     = 100
  ollama_fw_node     = "grunt"
  ollama_model_ports = "11434,18081"
}

resource "proxmox_virtual_environment_firewall_options" "ollama" {
  node_name = local.ollama_fw_node
  vm_id     = local.ollama_fw_vmid

  enabled       = true
  input_policy  = "ACCEPT"
  output_policy = "ACCEPT"
  dhcp          = true
  macfilter     = true
  ipfilter      = false
  ndp           = true
  radv          = false
}

resource "proxmox_virtual_environment_firewall_rules" "ollama" {
  node_name = local.ollama_fw_node
  vm_id     = local.ollama_fw_vmid

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = local.ollama_model_ports
    source  = join(",", data.dns_a_record_set.ollama_peer["mcpgw"].addrs)
    comment = "Ollama and PolyStrata from the MCP gateway"
  }
  rule {
    type    = "in"
    action  = "DROP"
    proto   = "tcp"
    dport   = local.ollama_model_ports
    comment = "Ollama and PolyStrata: nobody else"
  }

  depends_on = [
    proxmox_virtual_environment_firewall_options.ollama,
  ]
}
