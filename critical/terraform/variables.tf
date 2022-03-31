 # Providers
 variable "maas_apikey" {
    description = "(Required) - The API Key for the MAAS api."
    type = string
    sensitive = true
    nullable = false
 }

 variable "maas_url" {
    description = "(Required) - The url for the MAAS api. Looks something like `http://<MAAS_SERVER>[:MAAS_PORT]/MAAS`"
    type = string
    nullable = false
 }
 
 
 # Machine Config
 
 variable "mach_distro" {
   description = "(Required) - Which image to use when deploying machines. For example, \"focal\""
   type = string
   nullable = false
 }
 
 # RKE2 Config
 variable "rke2_token" {
   description = "(Required) - A shared secret used to authenticate nodes."
   type = string
   sensitive = true
   nullable = false
 }
 
 variable "rke2_virtual_ip" {
   description = "(Required) - An IPv4 address to use for the cluster's API. It will be used as an HA Virtual IP address, so make sure DHCP won't hand it out."
   type = string
   nullable = false
 }
