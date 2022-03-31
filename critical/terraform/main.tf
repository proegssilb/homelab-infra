terraform {
  required_providers {
    maas = {
      source = "suchpuppet/maas"
      version = "3.1.3"
    }
  }
}

provider "maas" {
  api_version = "2.0"
  api_key = var.maas_apikey
  api_url = var.maas_url
}

locals {
  cloudinit_kube_vip_config = yamlencode(base64gzip(data.template_file.kube_vip.rendered))
  cloudinit_rke_node1_config = yamlencode(base64gzip(data.template_file.rke_node1.rendered))
  cloudinit_rke_node2_config = yamlencode(base64gzip(data.template_file.rke_node2.rendered))
}

data "template_file" "kube_vip" {
  template = file("./files/kube_vip.yaml")
  
  vars = {
    virtual_ip = var.rke2_virtual_ip
  }
}

data "template_file" "rke_node1" {
  template = file("./files/rke_node1.yaml")
  
  vars = {
    virtual_ip = var.rke2_virtual_ip
    token = var.rke2_token
  }
}

data "template_file" "rke_node2" {
  template = file("./files/rke_node2.yaml")
  
  vars = {
    virtual_ip = var.rke2_virtual_ip
    token = var.rke2_token
  }
}

data "template_file" "node1_cloudinit" {
  template = file("./files/cloudconfig.yaml")
  
  vars = {
    vipconfig = local.cloudinit_kube_vip_config
    rkeconfig = local.cloudinit_rke_node1_config
  }
}

resource "maas_instance" "first_node" {
  count = 1
  tags = ["k8s-critical", "slot1"]
  user_data = data.template_file.node1_cloudinit.rendered
  distro_series = var.mach_distro
  release_erase_secure = true
  release_erase_quick = true
}
