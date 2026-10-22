# -*- mode: ruby -*-
# vi: set ft=ruby :
# Defines the pgvms VMs from cluster.conf. Provisioning is driven by ./pglab deploy.

conf = {}
File.readlines(File.join(__dir__, "cluster.conf")).each do |line|
  next unless line =~ /^\s*([A-Z_][A-Z0-9_]*)=(.*)$/
  conf[$1] = $2.strip.sub(/\A"(.*)"\z/, '\1')
end

nodes = conf["PG_NODES"].split.map { |n| n.split(":") + ["pg"] } +
        conf["HAPROXY_NODES"].split.map { |n| n.split(":") + ["lb"] }

Vagrant.configure("2") do |config|
  config.vm.box = conf["BOX"]
  config.vm.box_check_update = false
  # Scripts are pushed over ssh by pglab, so no guest-additions dependency.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  nodes.each do |name, ip, role|
    config.vm.define name do |node|
      node.vm.hostname = name
      node.vm.network "private_network", ip: ip

      node.vm.provider "virtualbox" do |vb|
        vb.name = "#{conf['CLUSTER_NAME']}-#{name}"
        vb.cpus = (role == "pg" ? conf["PG_CPUS"] : conf["LB_CPUS"]).to_i
        vb.memory = (role == "pg" ? conf["PG_MEMORY"] : conf["LB_MEMORY"]).to_i
        vb.linked_clone = true
      end
    end
  end
end
