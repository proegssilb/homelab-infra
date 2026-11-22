# USB-connected UPS on pxmx01, passed through to upsmon01 (main.tf).
#
# A cluster mapping rather than a raw host device: Proxmox lets only root@pam
# attach raw USB devices, while a mapping needs Mapping.Use (VM side) and
# Mapping.Modify (to create it here) on /mapping/usb.
#
# Matched by vendor:product ID, so the UPS can move to another USB port on
# pxmx01. The Proxmox API lists the node's devices at
# /nodes/pxmx01/hardware/usb.
resource "proxmox_hardware_mapping_usb" "ups_pxmx01" {
  name    = "ups-pxmx01"
  comment = "UPS on pxmx01, for upsmon01"
  map = [
    {
      node = "pxmx01"
      id   = "051d:0003"
    },
  ]
}
