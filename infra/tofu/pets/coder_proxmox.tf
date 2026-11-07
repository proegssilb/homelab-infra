# Proxmox access for Coder (dev.<domain>) to create workspace VMs.
#
# Fence: coder@pve has VM rights only inside the "coder" pool, so it can never
# touch a lab VM. Workspace VMIDs are kept in 1000–1999 by the Coder template
# (ansible/roles/coder/files/coder-templates/proxmox-vm), not by Proxmox — PVE ACLs
# cannot express a VMID range.
#
# The password must match coder_proxmox_password in ansible host_vars/coder.yml
# (same pattern as oidc_client_secrets).

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
    template = { path = "/vms/${var.template_id}", role = proxmox_virtual_environment_role.coder_template.role_id }
    storage  = { path = "/storage/${var.datastore}", role = proxmox_virtual_environment_role.coder_resources.role_id }
    bridges  = { path = "/sdn/zones/localnetwork", role = proxmox_virtual_environment_role.coder_resources.role_id }
  }
}

resource "proxmox_acl" "coder" {
  for_each  = local.coder_acls
  user_id   = proxmox_virtual_environment_user.coder.user_id
  path      = each.value.path
  role_id   = each.value.role
  propagate = true
}
