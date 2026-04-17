# -*- mode: ruby -*-
# vi: set ft=ruby :

require 'etc'
require 'fileutils'

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

workspace_root = File.expand_path(__dir__)
active_state_file = File.join(workspace_root, ".vagrant", "uemu-active-env")

load_active_state = lambda do |path|
  next {} unless File.file?(path)

  File.readlines(path, chomp: true).each_with_object({}) do |line, state|
    next if line.empty? || line.start_with?("#")

    key, value = line.split("=", 2)
    next if key.nil? || value.nil? || key.empty? || value.empty?

    state[key] = value
  end
end

detect_existing_worker_count = lambda do |root|
  machines_root = File.join(root, ".vagrant", "machines")
  next nil unless Dir.exist?(machines_root)

  worker_indexes = Dir.children(machines_root).filter_map do |entry|
    match = /\At(\d+)\z/.match(entry)
    next unless match

    cwd_file = File.join(machines_root, entry, "virtualbox", "vagrant_cwd")
    next unless File.file?(cwd_file)
    next unless File.read(cwd_file).strip == root

    Integer(match[1])
  end

  next nil if worker_indexes.empty?

  worker_indexes.max
end

persist_active_state = lambda do |path, state|
  FileUtils.mkdir_p(File.dirname(path))

  lines = state.filter_map do |key, value|
    next if value.nil? || value.to_s.empty?

    "#{key}=#{value}"
  end

  File.write(path, lines.join("\n") + "\n")
end

persisted_state = load_active_state.call(active_state_file)
detected_worker_count = detect_existing_worker_count.call(workspace_root)
inferred_role = persisted_state["UEMU_ROLE"] || (detected_worker_count ? "worker" : "builder")

vm_role = ENV.fetch("UEMU_ROLE", inferred_role)
unless %w[builder worker].include?(vm_role)
  raise "UEMU_ROLE must be 'builder' or 'worker' (got: #{vm_role})"
end

default_box   = vm_role == "worker" ? "uemu-prebuilt" : "ubuntu/focal64"
default_count = if vm_role == "worker"
                  (persisted_state["UEMU_VM_COUNT"] || detected_worker_count || "4").to_s
                else
                  "1"
                end
default_cpus = vm_role == "worker" ? (persisted_state["UEMU_VM_CPUS"] || "1") : Etc.nprocessors.to_s
default_memory = vm_role == "worker" ? (persisted_state["UEMU_VM_MEMORY"] || "4096") : "65536"

vm_box    = ENV.fetch("UEMU_VM_BOX", persisted_state["UEMU_VM_BOX"] || default_box)
vm_count  = Integer(ENV.fetch("UEMU_VM_COUNT", default_count))
vm_cpus   = Integer(ENV.fetch("UEMU_VM_CPUS", default_cpus))
vm_memory = Integer(ENV.fetch("UEMU_VM_MEMORY", default_memory))

if ENV.key?("UEMU_ROLE") || ENV.key?("UEMU_VM_BOX") || ENV.key?("UEMU_VM_COUNT") ||
   ENV.key?("UEMU_VM_CPUS") || ENV.key?("UEMU_VM_MEMORY")
  persist_active_state.call(active_state_file, {
    "UEMU_ROLE" => vm_role,
    "UEMU_VM_BOX" => vm_box,
    "UEMU_VM_COUNT" => vm_count,
    "UEMU_VM_CPUS" => vm_cpus,
    "UEMU_VM_MEMORY" => vm_memory
  })
end

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
