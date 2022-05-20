
data "template_file" "user_data" {
  count    = 2
  template = file("${path.module}/files/pihole_userdata.yaml")
  vars     = {
    pubkey   = var.mach_pubkey
    hostname = format("dns%02d", count.index+1)
    fqdn     = format("dns%02d.%s", count.index+1, var.mach_domain_name)
  }
}

resource "local_file" "cloud_init_user_data_file" {
  count    = 2
  content  = data.template_file.user_data[count.index].rendered
  filename = "${path.module}/files/pihole_user_data_${count.index}.yaml"
}

resource "null_resource" "cloud_init_config_files" {
  depends_on = [
    local_file.cloud_init_user_data_file
  ]
  count = 2
  connection {
    type     = "ssh"
    user     = var.pve_ssh_user
    password = var.pve_password
    host     = var.pve_host
  }

  provisioner "file" {
    source      = "${path.module}/files/pihole_user_data_${count.index}.yaml"
    destination = "/mnt/pve/cephfs/snippets/pihole_userdata.${count.index+1}.yaml"
  }
}

resource "proxmox_vm_qemu" "piholes" {
  depends_on = [
    null_resource.cloud_init_config_files
  ]

  count = 2
  name = format("pihole%02d", count.index+1)
  vmid = 1100 + count.index
  desc = "Terraform-Managed Pihole Server. Do not touch."
  target_node = format("crit%02d", count.index + 1)
  pool = "net-crit"
  force_recreate_on_change_of = data.template_file.user_data[count.index].rendered

  onboot = true
  oncreate = true
  hastate = "started"
  hagroup = "main"

  cores = 1
  sockets = 1
  cpu = "host"
  memory = 2048
  balloon = 512
  scsihw = "virtio-scsi-pci"

  network {
    bridge = "vmbr0"
    model = "virtio"
  }

  disk {
    storage = "data"
    type = "scsi"
    size = "8G"
  }

  clone = "ubuntu-cloud-focal"
  full_clone = true
  os_type = "cloud-init"
  ipconfig0 = "ip=172.16.20.${count.index + 50}/24,gw=172.16.20.1"
  nameserver = "1.1.1.1"
  cicustom = "user=cephfs:snippets/pihole_userdata.${count.index+1}.yaml"
  cloudinit_cdrom_storage = "data:vm-${1100 + count.index}-cloudinit"
}
