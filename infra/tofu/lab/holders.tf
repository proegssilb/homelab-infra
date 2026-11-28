# Temporary: the holder VMs that owned data disks before they became the VMs' own disks
# (modules/bootc_vm). Tofu forgets them and never destroys them: until
# scripts/dissolve-holder.py has moved a holder's disks onto its VM, the holder still owns
# that VM's data. The script deletes each empty holder through the API. Delete this file
# once all three are gone (no VM tagged bootc-data left in the cluster).

removed {
  from = module.canary01.proxmox_virtual_environment_vm.data
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.aptcache01.proxmox_virtual_environment_vm.data
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.garage_apps.proxmox_virtual_environment_vm.data
  lifecycle {
    destroy = false
  }
}
