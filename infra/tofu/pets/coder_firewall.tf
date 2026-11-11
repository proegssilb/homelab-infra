# Proxmox VM firewall around the Coder server (VM 116, Lab VLAN).
#
# The Coder server holds the coder@pve password and the SSH key into every
# workspace, and runs the Terraform that builds them. If an agent ever gets
# code running here (e.g. through an Owner session opened inside a
# workspace), this fence keeps that foothold from reaching the rest of Lab:
# both directions default to DROP, and only what Coder needs is let through.
#
# In:  the reverse proxy -> Coder's HTTP port, admin SSH, node_exporter scrape.
# Out: the reverse proxy (Proxmox API at proxmox.<domain>, Forgejo at
#      code.<domain>, Coder's own dev.<domain>, and the Forgejo deploy-key
#      proxy on 9443 that mints workspace keys), SSH into workspaces (agent
#      install), the apt cache, Loki (Alloy), gateway DNS, and the internet
#      (container images, Terraform providers, registry.coder.com modules) —
#      "internet" meaning everything outside the private ranges.
#
# Replies to allowed connections pass both ways (the firewall is stateful).
# Rules live in the cluster-wide /etc/pve/firewall/116.fw, so they follow the
# VM through HA migrations.

# Peers by DNS name, resolved at plan time: firewall rules only take addresses,
# and DNS (UniFi, leases keyed on the VMID-derived MAC) is where they live.
# All are platform VMs, up before pets in `just bootstrap`. If one ever moves,
# re-apply pets. Names are the ones Coder and the lab actually use.
data "dns_a_record_set" "coder_peer" {
  for_each = toset([
    "proxy01",    # source of dev.<domain> traffic into Coder
    "proxmox",    # Proxmox API (coder_proxmox_endpoint), via proxy01
    "code",       # Forgejo and the deploy-key proxy, via proxy01
    "dev",        # Coder's own access URL, via proxy01
    "aptcache01", # apt_proxy_host
    "obs02",      # loki_url
  ])
  host = "${each.key}.${var.domain}"
}

locals {
  coder_fw_vmid = module.vm["coder"].vmid
  coder_fw_node = local.vms.coder.node

  coder_peer = { for k, v in data.dns_a_record_set.coder_peer : k => join(",", v.addrs) }
  coder_via_proxy = join(",", distinct(flatten([
    for k in ["proxmox", "code", "dev"] : data.dns_a_record_set.coder_peer[k].addrs
  ])))
}

resource "proxmox_virtual_environment_firewall_options" "coder" {
  node_name = local.coder_fw_node
  vm_id     = local.coder_fw_vmid

  enabled       = true
  input_policy  = "DROP"
  output_policy = "DROP"
  dhcp          = true # Lab hands out its address by DHCP
  macfilter     = true
  ipfilter      = false # DHCP address, not known here
  ndp           = true
  radv          = false
}

# Everything that isn't a private (RFC 1918) address.
resource "proxmox_virtual_environment_firewall_ipset" "coder_internet" {
  node_name = local.coder_fw_node
  vm_id     = local.coder_fw_vmid
  name      = "internet"
  comment   = "Public IPv4: everything but the private ranges"

  # PVE refuses a zero prefix in an ipset, so 0.0.0.0/0 is two halves.
  cidr {
    name = "0.0.0.0/1"
  }
  cidr {
    name = "128.0.0.0/1"
  }
  cidr {
    name    = "10.0.0.0/8"
    nomatch = true
  }
  cidr {
    name    = "172.16.0.0/12"
    nomatch = true
  }
  cidr {
    name    = "192.168.0.0/16"
    nomatch = true
  }
}

resource "proxmox_virtual_environment_firewall_rules" "coder" {
  node_name = local.coder_fw_node
  vm_id     = local.coder_fw_vmid

  # ── In ──
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "7080"
    source  = local.coder_peer["proxy01"]
    comment = "Coder HTTP from the reverse proxy (dev.<domain>)"
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

  # ── Out ──
  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "443,9443"
    dest    = local.coder_via_proxy
    comment = "Reverse proxy: Proxmox API, Forgejo, Coder; 9443 deploy-key proxy"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    dest    = var.agents_cidr
    comment = "SSH into workspaces (agent install)"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "3142"
    dest    = local.coder_peer["aptcache01"]
    comment = "apt-cacher-ng"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "3100"
    dest    = local.coder_peer["obs02"]
    comment = "Alloy -> Loki"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    macro   = "DNS"
    dest    = join(",", var.lab_dns_servers)
    comment = "DNS (gateway)"
  }

  rule {
    type    = "out"
    action  = "ACCEPT"
    dest    = "+guest/${proxmox_virtual_environment_firewall_ipset.coder_internet.name}"
    comment = "Internet: images, providers, modules, NTP"
  }

  depends_on = [
    proxmox_virtual_environment_firewall_options.coder,
  ]
}
