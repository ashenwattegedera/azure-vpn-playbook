#!/usr/bin/env bash
set -Eeuo pipefail
RG="${AZURE_RESOURCE_GROUP:-rg-personal-wireguard}"
VM="${AZURE_VM_NAME:-vm-personal-wireguard}"
printf 'This permanently deletes Azure resource group %s, including VM %s and its resources.\n' "$RG" "$VM"
read -r -p "Type DELETE $RG to continue: " CONFIRM
[[ "$CONFIRM" == "DELETE $RG" ]] || { echo 'Cancelled.'; exit 1; }
az group delete --name "$RG" --yes
printf 'Deleted resource group %s. Local client private keys/profiles were not deleted. Remove secrets/clients securely if you no longer need them.\n' "$RG"
