# Coder template: one Proxmox VM per workspace, VMID 1000-1999.
#
# Pushed by the coder Ansible role. Proxmox credentials (coder@pve, fenced to
# the "coder" pool) come from PROXMOX_VE_* in the Coder server's environment.
#
# Agent bootstrap: cloud-init adds a Coder-owned SSH key for user "coder"; on
# every start, Coder SSHes in and (re)writes the agent's token + systemd unit.
# This avoids snippets, which would need root SSH to a Proxmox node.

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.19"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.120.0"
    }
  }
}

provider "coder" {}

provider "proxmox" {
  # endpoint, username, password from PROXMOX_VE_ENDPOINT/_USERNAME/_PASSWORD.
}

# ── Template variables (set by `coder templates push --variable`) ──────────────

variable "clone_template_vmid" {
  description = "VMID of the cloud-init template to clone."
  type        = number
}

variable "clone_template_node" {
  description = "Node holding the cloud-init template."
  type        = string
}

variable "nodes" {
  description = "Comma-separated Proxmox nodes workspaces may be placed on."
  type        = string
}

variable "datastore" {
  description = "Storage for workspace disks and the cloud-init drive."
  type        = string
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag for the workspace NIC (0 = untagged). Workspaces belong on the Agents VLAN, fenced off from the rest of the lab by the UniFi firewall; every node in var.nodes needs a VLAN-aware bridge."
  type        = number
  default     = 0
}

variable "pool" {
  description = "Proxmox pool the coder@pve user is fenced to."
  type        = string
  default     = "coder"
}

variable "vmid_min" {
  type    = number
  default = 1000
}

variable "vmid_max" {
  type    = number
  default = 1999
}

variable "ssh_public_key_path" {
  type    = string
  default = "/etc/coder-workspaces/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  type    = string
  default = "/etc/coder-workspaces/id_ed25519"
}

# ── Workspace parameters ───────────────────────────────────────────────────────

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "node" {
  name         = "node"
  display_name = "Proxmox node"
  description  = "Where the VM is first placed. Cannot change after creation."
  type         = "string"
  default      = split(",", var.nodes)[0]
  mutable      = false
  dynamic "option" {
    for_each = split(",", var.nodes)
    content {
      name  = option.value
      value = option.value
    }
  }
}

data "coder_parameter" "cores" {
  name         = "cores"
  display_name = "CPU cores"
  type         = "number"
  default      = 2
  mutable      = true
  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (MiB)"
  type         = "number"
  default      = 4096
  mutable      = true
  option {
    name  = "2 GiB"
    value = 2048
  }
  option {
    name  = "4 GiB"
    value = 4096
  }
  option {
    name  = "8 GiB"
    value = 8192
  }
  option {
    name  = "16 GiB"
    value = 16384
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk size (GiB)"
  type         = "number"
  default      = 30
  mutable      = true
  validation {
    min       = 20
    max       = 200
    monotonic = "increasing"
  }
}

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git repository (optional)"
  description  = <<-EOT
    Cloned into /home/coder on first start; later starts leave it alone.
    Public: https://github.com/owner/repo or https://code.<domain>/owner/repo.
    Private: use SSH (git@github.com:owner/repo.git, or
    ssh://git@code.<domain>:2222/owner/repo.git) after adding your Coder
    public key (Account → SSH Keys) to GitHub / Forgejo.
  EOT
  type         = "string"
  default      = ""
  mutable      = true
}

# ── VMID selection: lowest free ID in [vmid_min, vmid_max] ─────────────────────
#
# coder@pve only sees VMs in its pool plus the template, so an ID taken by a
# VM outside the pool is invisible here; Proxmox then rejects the clone and the
# build fails rather than touching that VM. The chosen ID is only used at
# creation (ignore_changes below), so later builds don't move the VM.

data "proxmox_virtual_environment_vms" "visible" {}

locals {
  used_vmids = toset([for v in data.proxmox_virtual_environment_vms.visible.vms : v.vm_id])
  free_vmids = [for id in range(var.vmid_min, var.vmid_max + 1) : id if !contains(local.used_vmids, id)]

  vm_name = lower("coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}")
  started = data.coder_workspace.me.start_count == 1
}

# ── Agent ──────────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Home disk"
    key          = "disk"
    script       = "coder stat disk --path /home/coder"
    interval     = 600
    timeout      = 30
  }
}

# Empty URL → the module skips the clone. SSH URLs authenticate with the
# owner's Coder-managed key (the agent sets GIT_SSH_COMMAND to `coder gitssh`).
module "git-clone" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 2.0"
  agent_id = coder_agent.main.id
  url      = trimspace(data.coder_parameter.repo_url.value)
  base_dir = "/home/coder"
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.3"
  agent_id = coder_agent.main.id
  folder   = module.git-clone[0].repo_dir
}

# ── VM ─────────────────────────────────────────────────────────────────────────

resource "proxmox_virtual_environment_vm" "workspace" {
  name      = local.vm_name
  node_name = data.coder_parameter.node.value
  vm_id     = local.free_vmids[0]
  pool_id   = var.pool
  # Keeps these VMs out of the Ansible dynamic inventory (see proxmox.yml).
  tags        = ["coder_workspace"]
  description = "Coder workspace ${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}. Managed by Coder; delete the workspace, not the VM."

  started         = local.started
  on_boot         = false
  stop_on_destroy = true

  clone {
    vm_id        = var.clone_template_vmid
    node_name    = var.clone_template_node
    full         = true
    datastore_id = var.datastore
  }

  cpu {
    cores = data.coder_parameter.cores.value
    type  = "host"
  }

  memory {
    dedicated = data.coder_parameter.memory.value
  }

  # The template's OS disk is scsi1 (see tofu/modules/vm).
  disk {
    datastore_id = var.datastore
    size         = data.coder_parameter.disk_size.value
    interface    = "scsi1"
    file_format  = "raw"
    discard      = "on"
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id > 0 ? var.vlan_id : null
  }

  initialization {
    datastore_id = var.datastore
    user_account {
      username = "coder"
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  agent {
    enabled = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    # vm_id/clone: creation-time only. node_name: HA may migrate it. pool_id:
    # set at clone; the provider re-adds membership on every update when it
    # can't read the pool back, which Proxmox rejects ("already a pool member").
    ignore_changes = [vm_id, node_name, clone, pool_id]
    precondition {
      condition     = length(local.free_vmids) > 0
      error_message = "No free VMID left in ${var.vmid_min}-${var.vmid_max}."
    }
  }
}

locals {
  vm_ip = try([for a in flatten(proxmox_virtual_environment_vm.workspace.ipv4_addresses) : a if a != "127.0.0.1"][0], null)
}

# Re-runs on every start: the agent token can change per build.
resource "terraform_data" "agent_install" {
  count            = data.coder_workspace.me.start_count
  triggers_replace = [coder_agent.main.token, proxmox_virtual_environment_vm.workspace.vm_id]

  connection {
    type        = "ssh"
    host        = local.vm_ip
    user        = "coder"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait >/dev/null || true",
      # git-clone module needs git; the cloud image doesn't ship it.
      "command -v git >/dev/null || { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git >/dev/null; }",
      "sudo install -d -m 0755 /opt/coder-agent",
      "echo '${base64encode(coder_agent.main.init_script)}' | base64 -d | sudo tee /opt/coder-agent/init >/dev/null",
      "sudo chmod 0755 /opt/coder-agent/init",
      "echo 'CODER_AGENT_TOKEN=${coder_agent.main.token}' | sudo install -m 0600 /dev/stdin /opt/coder-agent/env",
      "printf '%s\\n' '[Unit]' 'Description=Coder agent' 'After=network-online.target' 'Wants=network-online.target' '[Service]' 'User=coder' 'EnvironmentFile=/opt/coder-agent/env' 'ExecStart=/opt/coder-agent/init' 'Restart=always' 'RestartSec=10' '[Install]' 'WantedBy=multi-user.target' | sudo tee /etc/systemd/system/coder-agent.service >/dev/null",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable coder-agent >/dev/null 2>&1",
      "sudo systemctl restart coder-agent",
    ]
  }
}

resource "coder_metadata" "vm" {
  count       = data.coder_workspace.me.start_count
  resource_id = proxmox_virtual_environment_vm.workspace.id
  item {
    key   = "VMID"
    value = tostring(proxmox_virtual_environment_vm.workspace.vm_id)
  }
  item {
    key   = "IP"
    value = coalesce(local.vm_ip, "pending")
  }
}
