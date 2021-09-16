#!/bin/bash

# Distribute and run script to patch kube-system manifests to master nodes
masters=$(kubectl get node --selector='node-role.kubernetes.io/master' -o name | sed -e 's,^node/,,' | paste -sd,)
export PDSH_SSH_ARGS_APPEND="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
export IFS=","
for master in $masters; do
  ssh-keyscan -H "$master" 2> /dev/null >> ~/.ssh/known_hosts
  scp ${ROOTDIR}/scripts/patch-manifests.sh $master:/tmp
  pdsh -w $master "/tmp/patch-manifests.sh"
  # Give K8S a chance to spin up pods for this node
  sleep 10
done
unset IFS

# Ensuring cloud-init is healthy
cloud-init query -a > /dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
  # Attempt to repair cached data
  cloud-init init > /dev/null 2>&1
fi

# Distribute and configure node-exporter to storage nodes
num_storage_nodes=$(craysys metadata get num-storage-nodes)
for node_num in $(seq $num_storage_nodes); do
  storage_node=$(printf "ncn-s%03d" "$node_num")
  ssh-keyscan -H "$storage_node" 2> /dev/null >> ~/.ssh/known_hosts
  status=$(pdsh -N -w $storage_node "systemctl is-active node_exporter")
  if [ "$status" == "active" ]; then
    pdsh -w $storage_node "systemctl stop node_exporter; zypper rm -y golang-github-prometheus-node_exporter"
  fi
  pdsh -w $storage_node "zypper --no-gpg-checks in -y https://packages.local/repository/csm-sle-15sp2/cray-node-exporter-1.2.2.1-1.x86_64.rpm"
done
