#!/usr/bin/env bash
set -Eeuo pipefail
RG="${AZURE_RESOURCE_GROUP:-rg-personal-wireguard}"
VM="${AZURE_VM_NAME:-vm-personal-wireguard}"
az vm show -g "$RG" -n "$VM" --show-details --query '{name:name,powerState:powerState,publicIps:publicIps,privateIps:privateIps}' -o table
if [[ -f ansible/inventory.ini ]]; then
  ansible -i ansible/inventory.ini vpn -b -m command -a 'wg show wg0'
else
  echo 'No Ansible inventory yet. Run scripts/infra-up.sh first.'
fi
