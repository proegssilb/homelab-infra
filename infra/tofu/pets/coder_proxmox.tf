# Proxmox access for Coder (dev.<domain>) to create workspace VMs.
#
# Fence: coder@pve has VM rights only inside the "coder" pool, so it can never
# touch a lab VM. Workspace VMIDs are kept in 1000–1999 by the Coder template
# (ansible/roles/coder/files/coder-templates/proxmox-vm), not by Proxmox — PVE ACLs
# cannot express a VMID range.
#
# The password must match coder_proxmox_password in ansible host_vars/coder.yml
# (same pattern as oidc_client_secrets).

# ── Agents VNet ────────────────────────────────────────────────────────────────
# VLAN 30 (the UniFi "Agents" network) as an SDN VNet on every node's vmbr0, so
# coder@pve's SDN.Use can be granted on this VNet alone: Coder then cannot put
# a workspace on any other VLAN, or untagged, even with its own credentials.
# isolate_ports: guests on the same node's VNet bridge can't talk to each other
# at L2 (they only reach the uplink). Workspaces on different nodes still meet
# on the switch; the per-VM firewall in the Coder template covers that.
#
# Applying SDN regenerates the SDN part of each node's network config and runs
# ifreload there.

resource "proxmox_sdn_zone_vlan" "coder" {
  id     = "coder"
  bridge = "vmbr0"
}

resource "proxmox_sdn_vnet" "agents" {
  id            = "agents"
  zone          = proxmox_sdn_zone_vlan.coder.id
  alias         = "Coder workspaces (UniFi Agents VLAN)"
  tag           = 30
  isolate_ports = true
}

# VLAN 31 (UniFi "AgentSvc", in the Agents zone, DHCP on): support services
# for the workspaces (egress proxy, package caches, credential broker). Its own
# VLAN so workspaces reach these VMs only through explicit UniFi allows, and
# inside the Agents zone so a compromised support VM is no better a foothold
# into Lab than a workspace is (see agentsvc.tf).
#
# Reserved for IaC: coder@pve gets NO grant here (see coder_acls below, and
# keep it that way), so a compromised Coder server cannot plant a VM next to
# the support services. Only tofu, with the admin token, attaches NICs to it.
resource "proxmox_sdn_vnet" "agentsvc" {
  id            = "agentsvc"
  zone          = proxmox_sdn_zone_vlan.coder.id
  alias         = "Agent support services (UniFi AgentSvc VLAN)"
  tag           = 31
  isolate_ports = true
}

resource "proxmox_sdn_applier" "coder" {
  depends_on = [proxmox_sdn_zone_vlan.coder, proxmox_sdn_vnet.agents, proxmox_sdn_vnet.agentsvc]

  lifecycle {
    replace_triggered_by = [proxmox_sdn_zone_vlan.coder, proxmox_sdn_vnet.agents, proxmox_sdn_vnet.agentsvc]
  }
}

# ── Workspace clone source ─────────────────────────────────────────────────────
# Coder clones workspaces from this, not from the lab template: cloning checks
# SDN.Use on the source's NIC bridge, and the lab template's NIC is on vmbr0,
# which coder@pve must not be able to use. This copy's NIC is already on the
# agents VNet, so cloning needs nothing beyond the VNet grant below.
# Stopped template: the Ansible inventory only lists running VMs.

locals {
  coder_template_vmid = 903
  coder_template_node = var.template_node != "" ? var.template_node : var.proxmox_node
}

resource "proxmox_virtual_environment_vm" "coder_template" {
  name        = "coder-template"
  description = "Clone source for Coder workspaces (NIC on the agents VNet). Managed by tofu/pets/coder_proxmox.tf."
  node_name   = local.coder_template_node
  vm_id       = local.coder_template_vmid
  template    = true
  started     = false
  on_boot     = false

  clone {
    vm_id        = var.template_id
    node_name    = local.coder_template_node
    full         = true
    datastore_id = var.datastore
  }

  network_device {
    bridge   = proxmox_sdn_vnet.agents.id
    model    = "virtio"
    firewall = true
  }

  depends_on = [proxmox_sdn_applier.coder]
}

resource "proxmox_virtual_environment_pool" "coder" {
  pool_id = "coder"
  comment = "Coder workspace VMs (VMID 1000-1999). Managed by Coder, not tofu."
}

# Everything a workspace VM's lifecycle needs, applied only on /pool/coder.
# Pool.Allocate: the provider sets pool membership through the pool-edit API.
# Safe to grant here — adding a VM to a pool also needs VM.Allocate on that VM,
# which coder@pve only has for VMs already in this pool.
# Pool.Audit: the provider reads a VM's pool back by listing pools; without it
# the VM looks pool-less and every update re-adds it ("already a pool member").
resource "proxmox_virtual_environment_role" "coder_workspaces" {
  role_id = "CoderWorkspaces"
  privileges = [
    "Pool.Allocate",
    "Pool.Audit",
    "VM.Allocate",
    "VM.Audit",
    "VM.Clone",
    "VM.Config.CDROM",
    "VM.Config.CPU",
    "VM.Config.Cloudinit",
    "VM.Config.Disk",
    "VM.Config.HWType",
    "VM.Config.Memory",
    "VM.Config.Network",
    "VM.Config.Options",
    "VM.Console",
    "VM.GuestAgent.Audit",
    "VM.Migrate",
    "VM.PowerMgmt",
  ]
}

# Read + clone the cloud-init template; nothing else on it.
resource "proxmox_virtual_environment_role" "coder_template" {
  role_id    = "CoderTemplate"
  privileges = ["VM.Audit", "VM.Clone"]
}

# Shared resources a new VM consumes: disk space, the bridge, node listing.
resource "proxmox_virtual_environment_role" "coder_resources" {
  role_id    = "CoderResources"
  privileges = ["Datastore.AllocateSpace", "Datastore.Audit", "SDN.Use", "Sys.Audit"]
}

resource "proxmox_virtual_environment_user" "coder" {
  user_id  = "coder@pve"
  comment  = "Coder workspace provisioner (pool-fenced to /pool/coder)"
  password = var.coder_proxmox_password
}

locals {
  coder_acls = {
    pool     = { path = "/pool/${proxmox_virtual_environment_pool.coder.pool_id}", role = proxmox_virtual_environment_role.coder_workspaces.role_id }
    template = { path = "/vms/${proxmox_virtual_environment_vm.coder_template.vm_id}", role = proxmox_virtual_environment_role.coder_template.role_id }
    storage  = { path = "/storage/${var.datastore}", role = proxmox_virtual_environment_role.coder_resources.role_id }
    # The only network coder@pve may attach a NIC to (no vmbr0, no other VLAN,
    # and in particular not agentsvc). Never grant on /sdn/zones/coder itself:
    # with propagate it would cover agentsvc too.
    agents_vnet = { path = "/sdn/zones/${proxmox_sdn_zone_vlan.coder.id}/${proxmox_sdn_vnet.agents.id}", role = proxmox_virtual_environment_role.coder_resources.role_id }
  }
}

resource "proxmox_acl" "coder" {
  for_each  = local.coder_acls
  user_id   = proxmox_virtual_environment_user.coder.user_id
  path      = each.value.path
  role_id   = each.value.role
  propagate = true
}
