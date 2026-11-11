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
    forgejo = {
      source  = "svalabs/forgejo"
      version = "~> 1.7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "coder" {}

provider "proxmox" {
  # endpoint, username, password from PROXMOX_VE_ENDPOINT/_USERNAME/_PASSWORD.
}

provider "forgejo" {
  # host, api_token from FORGEJO_HOST/FORGEJO_API_TOKEN: the deploy-key proxy
  # on proxy01 and Coder's token for it — not a Forgejo token. The proxy holds
  # the real one and passes only the deploy-key calls (see forgejo_keys in
  # group_vars/proxy).
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

variable "agents_cidr" {
  description = "Subnet of the workspace network (e.g. 10.0.30.0/24). No DHCP there: each workspace gets the static address cidrhost(agents_cidr, 10 + vmid - vmid_min), the gateway is the first host, and the VM firewall pins the NIC to that one address."
  type        = string
}

variable "ssh_sources" {
  description = "Comma-separated addresses the workspace VM firewall accepts SSH from. Must include the Coder server, which installs the agent over SSH."
  type        = string
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

variable "forgejo_ssh_url_prefix" {
  description = "Forgejo SSH clone URL up to owner/repo, e.g. ssh://git@code.example.com:2222/. Repos under it (or under forgejo_web_url_prefix) get a per-workspace deploy key."
  type        = string
}

variable "forgejo_web_url_prefix" {
  description = "Forgejo web URL up to owner/repo, e.g. https://code.example.com/. Such repo URLs are cloned over SSH with the deploy key instead."
  type        = string
}

# ── Egress: what workspaces use instead of the open internet ───────────────────

variable "egress_proxy_url" {
  description = "HTTP(S) proxy for workspace sessions (mitmproxy on egress01), e.g. http://egress01.example.com:8080."
  type        = string
}

variable "no_proxy" {
  description = "Comma-separated NO_PROXY for workspace sessions: lab names reached directly (Coder, Forgejo), never through the egress proxy (which refuses private addresses anyway)."
  type        = string
}

variable "apt_proxy_url" {
  description = "apt proxy for workspaces (the lab apt cache), e.g. http://aptcache01.example.com:3142."
  type        = string
}

variable "ntp_server" {
  description = "NTP server for workspaces (chrony on egress01), so they need no internet NTP."
  type        = string
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
    Forgejo (https://code.<domain>/owner/repo or
    ssh://git@code.<domain>:2222/owner/repo.git): the workspace gets its own
    deploy key with push access to that one repo, deleted with the workspace.
    Protect main on the repo: deploy keys must not be allowed to push there.
    Other hosts: public HTTPS clones only; there is no key for them.
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

# The VMID picked at creation, frozen: the MAC and the static IP derive from it,
# so later builds (where free_vmids no longer contains it) must not re-pick.
resource "terraform_data" "vmid" {
  input = try(local.free_vmids[0], null)

  lifecycle {
    ignore_changes = [input]
    precondition {
      condition     = length(local.free_vmids) > 0
      error_message = "No free VMID left in ${var.vmid_min}-${var.vmid_max}."
    }
  }
}

locals {
  vmid = terraform_data.vmid.output
  # Same scheme as the lab VMs (tofu/modules/vm): 02:00:00:00:<vmid/256>:<vmid%256>.
  mac        = format("02:00:00:00:%02x:%02x", floor(local.vmid / 256), local.vmid % 256)
  ip         = cidrhost(var.agents_cidr, 10 + local.vmid - var.vmid_min)
  gateway_ip = cidrhost(var.agents_cidr, 1)
  prefix_len = split("/", var.agents_cidr)[1]
}

# ── Git credentials: one Forgejo deploy key per workspace ─────────────────────
#
# The workspace gets an SSH key that can push to the one repo it was created
# for, and nothing else. Not tied to start_count, so it survives stop/start
# and is deleted (key and Forgejo deploy key) with the workspace. The private
# key sits in this workspace's Terraform state in Coder's database.
#
# Coder's own per-user key (`coder gitssh`) stays reachable from inside any
# workspace through the agent API, so it must not be registered on Forgejo or
# GitHub; GIT_SSH_COMMAND below stops git from offering it.

locals {
  repo_url = trimspace(data.coder_parameter.repo_url.value)

  # owner/repo when repo_url points at this Forgejo, "" otherwise.
  forgejo_rest = (
    startswith(local.repo_url, var.forgejo_ssh_url_prefix) ? trimprefix(local.repo_url, var.forgejo_ssh_url_prefix) :
    startswith(local.repo_url, var.forgejo_web_url_prefix) ? trimprefix(local.repo_url, var.forgejo_web_url_prefix) :
    ""
  )
  forgejo_parts = split("/", trimsuffix(trimsuffix(local.forgejo_rest, "/"), ".git"))
  is_forgejo    = length(local.forgejo_parts) == 2 && alltrue([for p in local.forgejo_parts : length(p) > 0])
  forgejo_owner = local.is_forgejo ? local.forgejo_parts[0] : ""
  forgejo_repo  = local.is_forgejo ? local.forgejo_parts[1] : ""

  # Forgejo repos are always cloned over SSH, so the deploy key can push.
  clone_url = local.is_forgejo ? "${var.forgejo_ssh_url_prefix}${local.forgejo_owner}/${local.forgejo_repo}.git" : local.repo_url

  deploy_key_path = "/home/coder/.ssh/deploy_key"

  # Coder owner and workspace names are lowercase letters, digits and dashes.
  agent_git_name  = "Coder agent (${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name})"
  agent_git_email = "${data.coder_workspace.me.name}.${data.coder_workspace_owner.me.name}@coder-agent.invalid"

  apt_proxy_conf = <<-EOT
    // Managed by the Coder template: packages through the lab apt cache.
    Acquire::http::Proxy "${var.apt_proxy_url}";
    Acquire::https::Proxy "${var.apt_proxy_url}";
  EOT

  # Empty FallbackNTP: no silent fallback to internet pools.
  timesyncd_conf = <<-EOT
    # Managed by the Coder template: time from egress01, not the internet.
    [Time]
    NTP=${var.ntp_server}
    FallbackNTP=
  EOT
}

data "forgejo_repository" "repo" {
  count = local.is_forgejo ? 1 : 0
  owner = local.forgejo_owner
  name  = local.forgejo_repo
}

resource "tls_private_key" "deploy" {
  count     = local.is_forgejo ? 1 : 0
  algorithm = "ED25519"
}

resource "forgejo_deploy_key" "workspace" {
  count         = local.is_forgejo ? 1 : 0
  repository_id = data.forgejo_repository.repo[0].id
  key           = trimspace(tls_private_key.deploy[0].public_key_openssh)
  title         = "coder ${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"
  read_only     = false
}

# ── Agent ──────────────────────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  # GIT_SSH_COMMAND overrides the agent's default `coder gitssh` (manifest
  # variables win): git uses the workspace's deploy key only, never the
  # owner's Coder key.
  #
  # Commits made here carry an obviously-agent identity, never the owner's:
  # anything in a workspace is agent-tier. A .invalid address matches no
  # Forgejo account, so these commits are never attributed to a person. This
  # is labelling, not enforcement (an agent can set any author); what keeps
  # agents from posing as the owner is that only the owner's desktop holds
  # their signing key, and main requires signed commits.
  #
  # Proxy variables send sessions' HTTP(S) through the egress proxy, where
  # every destination is logged (phase 1 of gap 3). Both spellings, since
  # tools disagree on which they read. The agent service itself is not
  # proxied: it talks to Coder directly.
  env = {
    HTTP_PROXY          = var.egress_proxy_url
    HTTPS_PROXY         = var.egress_proxy_url
    NO_PROXY            = var.no_proxy
    http_proxy          = var.egress_proxy_url
    https_proxy         = var.egress_proxy_url
    no_proxy            = var.no_proxy
    GIT_SSH_COMMAND     = "ssh -i ${local.deploy_key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    GIT_AUTHOR_NAME     = local.agent_git_name
    GIT_AUTHOR_EMAIL    = local.agent_git_email
    GIT_COMMITTER_NAME  = local.agent_git_name
    GIT_COMMITTER_EMAIL = local.agent_git_email
  }

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

# Empty URL → the module skips the clone. Forgejo repos clone over SSH with the
# workspace's deploy key (GIT_SSH_COMMAND above).
module "git-clone" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 2.0"
  agent_id = coder_agent.main.id
  url      = local.clone_url
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
  vm_id     = local.vmid
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
    bridge      = var.bridge
    model       = "virtio"
    vlan_id     = var.vlan_id > 0 ? var.vlan_id : null
    mac_address = local.mac
    firewall    = true # filtered by the VM firewall below
  }

  initialization {
    datastore_id = var.datastore
    user_account {
      username = "coder"
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
    ip_config {
      ipv4 {
        address = "${local.ip}/${local.prefix_len}"
        gateway = local.gateway_ip
      }
    }
    dns {
      servers = [local.gateway_ip]
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
      condition     = 10 + var.vmid_max - var.vmid_min < pow(2, 32 - tonumber(local.prefix_len)) - 1
      error_message = "VMIDs ${var.vmid_min}-${var.vmid_max} don't all fit in ${var.agents_cidr} at offset 10; narrow the range or widen the subnet."
    }
  }
}

# ── VM firewall ────────────────────────────────────────────────────────────────
# Proxmox firewall on the workspace NIC (needs the datacenter firewall enabled).
# The UniFi Agents zone fences workspaces off from the rest of the network, but
# workspaces on the same VLAN reach each other at L2 without passing the
# gateway. Dropping all inbound except Coder's SSH closes that: no workspace
# accepts connections from another. Outbound stays open (UniFi filters it),
# minus DHCP/DHCPv6 server replies. macfilter pins the NIC to its MAC, the
# ipfilter-net0 set pins it to its static IP (so it can't pose as another
# workspace, the gateway or the Coder server), and radv (off) stops rogue IPv6
# RAs. The network has no DHCP, so the dhcp option is off too.
#
# The VM boots a few seconds before these apply; the NIC is unfiltered until
# then. The agent is installed only after (depends_on below).

resource "proxmox_virtual_environment_firewall_options" "workspace" {
  node_name = proxmox_virtual_environment_vm.workspace.node_name
  vm_id     = proxmox_virtual_environment_vm.workspace.vm_id

  enabled       = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  dhcp          = false
  macfilter     = true
  ipfilter      = true
  ndp           = false
  radv          = false
}

resource "proxmox_virtual_environment_firewall_ipset" "ipfilter" {
  node_name = proxmox_virtual_environment_vm.workspace.node_name
  vm_id     = proxmox_virtual_environment_vm.workspace.vm_id
  name      = "ipfilter-net0"
  comment   = "Only source address net0 may use"

  cidr {
    name = local.ip
  }
}

resource "proxmox_virtual_environment_firewall_rules" "workspace" {
  node_name = proxmox_virtual_environment_vm.workspace.node_name
  vm_id     = proxmox_virtual_environment_vm.workspace.vm_id

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    source  = var.ssh_sources
    comment = "Coder server installs the agent over SSH"
  }

  rule {
    type    = "out"
    action  = "DROP"
    proto   = "udp"
    sport   = "67"
    comment = "No rogue DHCP server"
  }

  rule {
    type    = "out"
    action  = "DROP"
    proto   = "udp"
    sport   = "547"
    comment = "No rogue DHCPv6 server"
  }

  depends_on = [
    proxmox_virtual_environment_firewall_options.workspace,
    proxmox_virtual_environment_firewall_ipset.ipfilter,
  ]
}

# Re-runs on every start: the agent token can change per build.
resource "terraform_data" "agent_install" {
  count = data.coder_workspace.me.start_count
  triggers_replace = [
    coder_agent.main.token,
    proxmox_virtual_environment_vm.workspace.vm_id,
    tls_private_key.deploy[*].public_key_fingerprint_sha256,
  ]

  # SSH in only once the firewall (and its SSH allow rule) is in place.
  depends_on = [proxmox_virtual_environment_firewall_rules.workspace]

  connection {
    type        = "ssh"
    host        = local.ip
    user        = "coder"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = concat([
      "cloud-init status --wait >/dev/null || true",
      # Packages through the lab apt cache and time from egress01, before
      # anything is installed: neither needs the open internet.
      "echo '${base64encode(local.apt_proxy_conf)}' | base64 -d | sudo tee /etc/apt/apt.conf.d/01proxy >/dev/null",
      "sudo install -d -m 0755 /etc/systemd/timesyncd.conf.d",
      "echo '${base64encode(local.timesyncd_conf)}' | base64 -d | sudo tee /etc/systemd/timesyncd.conf.d/agents.conf >/dev/null",
      "sudo systemctl try-restart systemd-timesyncd || true",
      # Deploy key (runs as user coder); removed if the repo isn't on Forgejo.
      "install -d -m 0700 /home/coder/.ssh",
      ], local.is_forgejo ? [
      "echo '${base64encode(tls_private_key.deploy[0].private_key_openssh)}' | base64 -d | install -m 0600 /dev/stdin ${local.deploy_key_path}",
      ] : [
      "rm -f ${local.deploy_key_path}",
      ], [
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
    ])
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
    value = local.ip
  }
}
