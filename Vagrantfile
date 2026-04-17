# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'etc'

# Two-stage workflow to avoid compiling uEmu on every worker VM:
#
#   Stage 1 (once): build a "builder" VM with all host CPUs, let it compile
#   everything, then package it into a reusable box. The helper script
#   `build-base-box.sh` automates this:
#
#       ./build-base-box.sh
#
#   Stage 2 (as often as you want): spawn many lightweight workers from the
#   pre-built box. Each worker boots already-compiled, so 1 CPU is fine:
#
#       UEMU_ROLE=worker UEMU_VM_COUNT=21 UEMU_VM_CPUS=1 vagrant up
#
# Override any of these on the host as needed:
#   UEMU_ROLE           builder | worker   (default: builder)
#   UEMU_VM_BOX         base box name      (default: ubuntu/focal64 for builder,
#                                                    uemu-prebuilt for worker)
#   UEMU_VM_COUNT       number of VMs      (default: 1 for builder, 4 for worker)
#   UEMU_VM_CPUS        vCPUs per VM       (default: all host CPUs for builder,
#                                                    1 for worker)
#   UEMU_VM_MEMORY      MB per VM          (default: 4096)

vm_role = ENV.fetch("UEMU_ROLE", "builder")
unless %w[builder worker].include?(vm_role)
  raise "UEMU_ROLE must be 'builder' or 'worker' (got: #{vm_role})"
end

default_box   = vm_role == "worker" ? "uemu-prebuilt" : "ubuntu/focal64"
default_count = vm_role == "worker" ? "4" : "1"
default_cpus  = vm_role == "worker" ? "1" : Etc.nprocessors.to_s
default_memory = vm_role == "worker" ? "4096" : "65536" 

vm_box    = ENV.fetch("UEMU_VM_BOX", default_box)
vm_count  = Integer(ENV.fetch("UEMU_VM_COUNT", default_count))
vm_cpus   = Integer(ENV.fetch("UEMU_VM_CPUS", default_cpus))
vm_memory = Integer(ENV.fetch("UEMU_VM_MEMORY", default_memory))

configure_worker = lambda do |machine, index|
  name = vm_count == 1 ? "uemu" : "uemu-t#{index}"

  machine.vm.hostname = name

  machine.vm.provider "virtualbox" do |vb|
    vb.name = name
    vb.memory = vm_memory.to_s
    vb.cpus = vm_cpus
  end
end

Vagrant.configure("2") do |config|
  config.vm.box = vm_box
  config.vm.synced_folder ".", "/vagrant"

  # Keep Vagrant's well-known insecure SSH key on the VM instead of rotating
  # it to a per-VM key. This is required for `vagrant package`: if Vagrant
  # rotated the key, the packaged box would carry the builder's private key
  # and fresh workers couldn't SSH in. On a local NAT-only cluster this is
  # the standard trade-off.
  config.ssh.insert_key = false

  # Only the builder runs the heavy bootstrap. Worker VMs come from the
  # pre-built box (uemu-prebuilt) and skip provisioning entirely.
  if vm_role == "builder"
    config.vm.provision :shell, path: "vagrant-bootstrap.sh", privileged: false
  end

  if vm_count <= 1
    configure_worker.call(config, 1)
  else
    (1..vm_count).each do |i|
      config.vm.define "t#{i}", primary: i == 1 do |vm|
        configure_worker.call(vm, i)
      end
    end
  end
end
