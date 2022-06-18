
data "template_file" "kube_vip" {
  template = file("${path.module}/files/kube_vip.yaml")

  vars = {
    virtual_ip = var.rke2_virtual_ip
  }
}

data "template_file" "rke_node_config" {
  count = 2
  template = file("${path.module}/files/rke_node${count.index+1}.yaml")

  vars = {
    virtual_ip = var.rke2_virtual_ip
    token = var.rke2_token
  }
}

data "template_file" "rke_cloudinit_data" {
  count = 3

  template = file("${path.module}/files/rke2_config.yaml")

  vars = {
    kubemanifest = count.index == 0 ? yamlencode(base64gzip(data.template_file.kube_vip.rendered)) : ""
    rkeconfig = yamlencode(base64gzip( data.template_file.rke_node_config[count.index == 0 ? 0 : 1].rendered ))
    hostname = format("rke%02d", count.index+1)
  }
}

resource "local_file" "rke_cloud_init_local_file" {
  count    = 3
  content  = data.template_file.rke_cloudinit_data[count.index].rendered
  filename = "${path.module}/files/rke_cloudinit_user_${count.index}.rendered.yaml"
}

resource "null_resource" "rke_cloud_init_remote_file" {
  depends_on = [
    local_file.rke_cloud_init_local_file
  ]

  triggers = {
    source_content = data.template_file.rke_cloudinit_data[count.index].rendered
  }

  count = 3
  connection {
    type     = "ssh"
    user     = var.pve_ssh_user
    password = var.pve_password
    host     = var.pve_host
  }

  provisioner "file" {
    source      = "${path.module}/files/rke_cloudinit_user_${count.index}.rendered.yaml"
    destination = "/mnt/pve/cephfs/snippets/rke_cloudinit_user.${count.index}.yaml"
  }
}

resource "proxmox_vm_qemu" "rke_nodes" {
  depends_on = [
    null_resource.rke_cloud_init_remote_file
  ]

  count = 3
  name = format("rke%02d", count.index+1)
  vmid = 1110 + count.index
  desc = "Terraform-Managed RKE2 Node. Do not touch."
  target_node = format("crit%02d", count.index + 1)
  pool = "main"
  force_recreate_on_change_of = data.template_file.rke_cloudinit_data[count.index].rendered

  onboot = true
  oncreate = true
  hastate = "started"
  hagroup = "main"

  cores = 8
  sockets = 1
  cpu = "host"
  memory = 16384
  scsihw = "virtio-scsi-pci"

  network {
    bridge = "vmbr0"
    model = "virtio"
  }

  disk {
    storage = "data"
    type = "scsi"
    size = "20G"
  }

  clone = "ubuntu-cloud-focal"
  full_clone = true
  # Until I get agent installation in the template sorted out, this won't work
  agent = 0
  os_type = "cloud-init"
  ipconfig0 = "ip=172.16.20.${count.index + 61}/24,gw=172.16.20.1"
  nameserver = "1.1.1.1"
  cicustom = "user=cephfs:snippets/rke_cloudinit_user.${count.index}.yaml"
  cloudinit_cdrom_storage = "data:vm-${1100 + count.index}-cloudinit"
}

# data "template_file" "user_data" {
#   count    = 2
#   template = file("${path.module}/files/pihole_userdata.yaml")
#   vars     = {
#     pubkey   = var.mach_pubkey
#     hostname = format("dns%02d", count.index+1)
#     fqdn     = format("dns%02d.%s", count.index+1, var.mach_domain_name)
#     syncip   = format("172.16.20.%s", 51-count.index)
#   }
# }
#
# resource "local_file" "cloud_init_user_data_file" {
#   count    = 2
#   content  = data.template_file.user_data[count.index].rendered
#   filename = "${path.module}/files/pihole_user_data_${count.index}.yaml"
# }
#
# resource "null_resource" "cloud_init_config_files" {
#   depends_on = [
#     local_file.cloud_init_user_data_file
#   ]
#
#   triggers = {
#     source_content = data.template_file.user_data[count.index].rendered
#   }
#
#   count = 2
#   connection {
#     type     = "ssh"
#     user     = var.pve_ssh_user
#     password = var.pve_password
#     host     = var.pve_host
#   }
#
#   provisioner "file" {
#     source      = "${path.module}/files/pihole_user_data_${count.index}.yaml"
#     destination = "/mnt/pve/cephfs/snippets/pihole_userdata.${count.index+1}.yaml"
#   }
# }
#
# resource "proxmox_vm_qemu" "piholes" {
#   depends_on = [
#     null_resource.cloud_init_config_files
#   ]
#
#   count = 2
#   name = format("dns%02d", count.index+1)
#   vmid = 1100 + count.index
#   desc = "Terraform-Managed Pihole Server. Do not touch."
#   target_node = format("crit%02d", count.index + 1)
#   pool = "net-crit"
#   force_recreate_on_change_of = data.template_file.user_data[count.index].rendered
#
#   onboot = true
#   oncreate = true
#   hastate = "started"
#   hagroup = "main"
#
#   cores = 1
#   sockets = 1
#   cpu = "host"
#   memory = 2048
#   balloon = 512
#   scsihw = "virtio-scsi-pci"
#
#   network {
#     bridge = "vmbr0"
#     model = "virtio"
#   }
#
#   disk {
#     storage = "data"
#     type = "scsi"
#     size = "8G"
#   }
#
#   clone = "ubuntu-cloud-focal"
#   full_clone = true
#   # Until I get agent installation in the template sorted out, this won't work
#   agent = 0
#   os_type = "cloud-init"
#   ipconfig0 = "ip=172.16.20.${count.index + 50}/24,gw=172.16.20.1"
#   nameserver = "1.1.1.1"
#   cicustom = "user=cephfs:snippets/pihole_userdata.${count.index+1}.yaml"
#   cloudinit_cdrom_storage = "data:vm-${1100 + count.index}-cloudinit"
# }
