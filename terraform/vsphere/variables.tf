variable "vsphere_server"   { type = string }
variable "vsphere_user"     { type = string, sensitive = true }
variable "vsphere_password" { type = string, sensitive = true }

variable "datacenter"       { type = string }
variable "cluster"          { type = string }
variable "datastore"        { type = string } # app data; etcd uses separate fast ds
variable "datastore_etcd"   { type = string }
variable "network_ocp"      { type = string } # VLAN 30 portgroup name
variable "resource_pool"    { type = string }
variable "folder_path"      { type = string } # VM folder

variable "rhcos_template"   { type = string } # uploaded OVA name
variable "rhel_template"    { type = string } # hardened RHEL 9 template

variable "cluster_name"     { type = string, default = "ocp" }
variable "base_domain"      { type = string, default = "corp.local" }

variable "masters" {
  type = list(object({
    name = string
    ip   = string
    mac  = string
  }))
  default = [
    { name = "master-0", ip = "10.10.30.11", mac = "" },
    { name = "master-1", ip = "10.10.30.12", mac = "" },
    { name = "master-2", ip = "10.10.30.13", mac = "" },
  ]
}

variable "workers" {
  type = list(object({
    name = string
    ip   = string
    mac  = string
  }))
  default = [
    { name = "worker-0", ip = "10.10.30.21", mac = "" },
    { name = "worker-1", ip = "10.10.30.22", mac = "" },
    { name = "worker-2", ip = "10.10.30.23", mac = "" },
  ]
}

variable "bootstrap" {
  type = object({
    name = string
    ip   = string
    mac  = string
  })
  default = { name = "bootstrap", ip = "10.10.30.10", mac = "" }
}

# Ignition files are published over HTTPS on the bastion; referenced via extra config
variable "ignition_base_url" {
  type        = string
  description = "Base URL (HTTPS) where bootstrap/master/worker.ign are served"
}

# Sizing (see docs/03-sizing-and-bom.md)
variable "master_cpu"          { type = number, default = 8 }
variable "master_memory_mb"    { type = number, default = 32768 }
variable "master_disk_gb"      { type = number, default = 120 }
variable "master_etcd_disk_gb" { type = number, default = 100 }

variable "worker_cpu"       { type = number, default = 16 }
variable "worker_memory_mb" { type = number, default = 65536 }
variable "worker_disk_gb"   { type = number, default = 120 }
variable "worker_data_gb"   { type = number, default = 200 }
