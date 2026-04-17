# Skeleton — not production-complete. Review with Virtualisation + Security before apply.
data "vsphere_datacenter" "dc"       { name = var.datacenter }
data "vsphere_compute_cluster" "cl"  { name = var.cluster, datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_resource_pool" "rp"    { name = var.resource_pool, datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_datastore" "ds"        { name = var.datastore, datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_datastore" "ds_etcd"   { name = var.datastore_etcd, datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_network" "ocp"         { name = var.network_ocp, datacenter_id = data.vsphere_datacenter.dc.id }
data "vsphere_virtual_machine" "rhcos" {
  name          = var.rhcos_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

locals {
  common_extra_config = {
    "guestinfo.hostname"           = "" # overridden per VM
    "guestinfo.afterburn.initrd.network-kargs" = "ip=dhcp" # replace with static via ignition
  }
}

# ---------- Masters ----------
resource "vsphere_virtual_machine" "master" {
  for_each         = { for m in var.masters : m.name => m }
  name             = "${var.cluster_name}-${each.value.name}"
  folder           = var.folder_path
  resource_pool_id = data.vsphere_resource_pool.rp.id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = var.master_cpu
  memory           = var.master_memory_mb
  guest_id         = data.vsphere_virtual_machine.rhcos.guest_id
  firmware         = "efi"
  enable_disk_uuid = true

  network_interface {
    network_id   = data.vsphere_network.ocp.id
    adapter_type = "vmxnet3"
    use_static_mac = each.value.mac != ""
    mac_address    = each.value.mac != "" ? each.value.mac : null
  }

  disk {
    label            = "disk0"
    size             = var.master_disk_gb
    eagerly_scrub    = false
    thin_provisioned = true
  }

  disk {
    label            = "etcd"
    size             = var.master_etcd_disk_gb
    datastore_id     = data.vsphere_datastore.ds_etcd.id
    eagerly_scrub    = false
    thin_provisioned = false # etcd: thick for performance
    unit_number      = 1
  }

  clone { template_uuid = data.vsphere_virtual_machine.rhcos.id }

  extra_config = {
    "guestinfo.ignition.config.data.encoding" = "base64"
    "guestinfo.ignition.config.data"          = filebase64("${path.module}/ignition/master.ign")
    "guestinfo.hostname"                      = "${each.value.name}.${var.cluster_name}.${var.base_domain}"
  }

  lifecycle { ignore_changes = [clone] }
}

# ---------- Workers ----------
resource "vsphere_virtual_machine" "worker" {
  for_each         = { for w in var.workers : w.name => w }
  name             = "${var.cluster_name}-${each.value.name}"
  folder           = var.folder_path
  resource_pool_id = data.vsphere_resource_pool.rp.id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = var.worker_cpu
  memory           = var.worker_memory_mb
  guest_id         = data.vsphere_virtual_machine.rhcos.guest_id
  firmware         = "efi"
  enable_disk_uuid = true

  network_interface {
    network_id   = data.vsphere_network.ocp.id
    adapter_type = "vmxnet3"
    use_static_mac = each.value.mac != ""
    mac_address    = each.value.mac != "" ? each.value.mac : null
  }

  disk { label = "disk0" size = var.worker_disk_gb thin_provisioned = true }
  disk { label = "data"  size = var.worker_data_gb thin_provisioned = true unit_number = 1 }

  clone { template_uuid = data.vsphere_virtual_machine.rhcos.id }

  extra_config = {
    "guestinfo.ignition.config.data.encoding" = "base64"
    "guestinfo.ignition.config.data"          = filebase64("${path.module}/ignition/worker.ign")
    "guestinfo.hostname"                      = "${each.value.name}.${var.cluster_name}.${var.base_domain}"
  }
}

# ---------- Bootstrap (destroy after install) ----------
resource "vsphere_virtual_machine" "bootstrap" {
  count            = var.bootstrap.name == "" ? 0 : 1
  name             = "${var.cluster_name}-${var.bootstrap.name}"
  folder           = var.folder_path
  resource_pool_id = data.vsphere_resource_pool.rp.id
  datastore_id     = data.vsphere_datastore.ds.id
  num_cpus         = 4
  memory           = 16384
  guest_id         = data.vsphere_virtual_machine.rhcos.guest_id
  firmware         = "efi"
  enable_disk_uuid = true

  network_interface {
    network_id   = data.vsphere_network.ocp.id
    adapter_type = "vmxnet3"
  }

  disk { label = "disk0" size = 120 thin_provisioned = true }

  clone { template_uuid = data.vsphere_virtual_machine.rhcos.id }

  extra_config = {
    "guestinfo.ignition.config.data.encoding" = "base64"
    "guestinfo.ignition.config.data"          = filebase64("${path.module}/ignition/bootstrap.ign")
    "guestinfo.hostname"                      = "${var.bootstrap.name}.${var.cluster_name}.${var.base_domain}"
  }
}

# DRS anti-affinity: masters must be on different hosts
resource "vsphere_compute_cluster_vm_anti_affinity_rule" "masters" {
  name                = "${var.cluster_name}-masters-anti-affinity"
  compute_cluster_id  = data.vsphere_compute_cluster.cl.id
  virtual_machine_ids = [for m in vsphere_virtual_machine.master : m.id]
  mandatory           = true
}

# Workers should be on different hosts when possible
resource "vsphere_compute_cluster_vm_anti_affinity_rule" "workers" {
  name                = "${var.cluster_name}-workers-anti-affinity"
  compute_cluster_id  = data.vsphere_compute_cluster.cl.id
  virtual_machine_ids = [for w in vsphere_virtual_machine.worker : w.id]
  mandatory           = false
}
