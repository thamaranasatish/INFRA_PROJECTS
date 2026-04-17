output "master_ips"    { value = [for m in vsphere_virtual_machine.master : m.default_ip_address] }
output "worker_ips"    { value = [for w in vsphere_virtual_machine.worker : w.default_ip_address] }
output "bootstrap_ip"  { value = try(vsphere_virtual_machine.bootstrap[0].default_ip_address, null) }
