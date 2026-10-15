#!/usr/bin/env bash
set -Eeuo pipefail

: "${SSH_ALLOWED_CIDR:?Set SSH_ALLOWED_CIDR to your trusted public IPv4 CIDR, e.g. 203.0.113.10/32}"

LOCATION="${AZURE_LOCATION:-southeastasia}"
RG="${AZURE_RESOURCE_GROUP:-rg-personal-wireguard}"
VM="${AZURE_VM_NAME:-vm-personal-wireguard}"
ADMIN="${AZURE_ADMIN_USER:-azureuser}"
SIZE="${AZURE_VM_SIZE:-Standard_B1s}"
VNET="${AZURE_VNET_NAME:-vnet-wireguard}"
SUBNET="${AZURE_SUBNET_NAME:-snet-wireguard}"
NSG="${AZURE_NSG_NAME:-nsg-wireguard}"
PIP="${AZURE_PUBLIC_IP_NAME:-pip-wireguard}"
NIC="${AZURE_NIC_NAME:-nic-wireguard}"
KEY="${SSH_KEY_PATH:-$HOME/.ssh/azure-vpn}"

command -v az >/dev/null || { echo 'Azure CLI (az) is required.' >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo 'OpenSSH client is required.' >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo 'Run az login first.' >&2; exit 1; }

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -f "$KEY" -N '' -C 'azure-wireguard-vpn'
fi
[[ -f "$KEY.pub" ]] || ssh-keygen -y -f "$KEY" > "$KEY.pub"
chmod 600 "$KEY"

az group create --name "$RG" --location "$LOCATION" --output none
if ! az network vnet show -g "$RG" -n "$VNET" >/dev/null 2>&1; then
  az network vnet create -g "$RG" -n "$VNET" --address-prefixes 10.20.0.0/16 --subnet-name "$SUBNET" --subnet-prefixes 10.20.1.0/24 --output none
fi
if ! az network nsg show -g "$RG" -n "$NSG" >/dev/null 2>&1; then
  az network nsg create -g "$RG" -n "$NSG" --output none
fi
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n Allow-SSH-From-Trusted-IP --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "$SSH_ALLOWED_CIDR" --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --output none
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n Allow-WireGuard-UDP --priority 110 --direction Inbound --access Allow --protocol Udp --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 51820 --output none
if ! az network public-ip show -g "$RG" -n "$PIP" >/dev/null 2>&1; then
  az network public-ip create -g "$RG" -n "$PIP" --location "$LOCATION" --sku Standard --allocation-method Static --version IPv4 --output none
fi
if ! az network nic show -g "$RG" -n "$NIC" >/dev/null 2>&1; then
  az network nic create -g "$RG" -n "$NIC" --location "$LOCATION" --vnet-name "$VNET" --subnet "$SUBNET" --network-security-group "$NSG" --public-ip-address "$PIP" --output none
fi

if ! az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
  az vm create -g "$RG" -n "$VM" --location "$LOCATION" --nics "$NIC" --image Ubuntu2204 --size "$SIZE" --admin-username "$ADMIN" --authentication-type ssh --ssh-key-values "$KEY.pub" --os-disk-size-gb 30 --output none
else
  echo "VM $VM already exists; leaving it in place."
fi

IP="$(az network public-ip show -g "$RG" -n "$PIP" --query ipAddress -o tsv)"
if [[ -z "$IP" || "$IP" == "None" ]]; then
  echo 'Azure public IP has not been assigned yet.' >&2
  exit 1
fi

mkdir -p ansible
printf '[vpn]\nazure-vpn ansible_host=%s ansible_user=%s ansible_ssh_private_key_file=%s\n' "$IP" "$ADMIN" "$KEY" > ansible/inventory.ini
chmod 600 ansible/inventory.ini

# Trust on first use. For higher assurance, verify the host-key fingerprint through Azure's trusted console channel.
ssh-keygen -R "$IP" >/dev/null 2>&1 || true
ssh-keyscan -H "$IP" >> "$HOME/.ssh/known_hosts" 2>/dev/null
chmod 600 "$HOME/.ssh/known_hosts"

printf '\nAzure VM is ready.\nResource group: %s\nVM: %s\nPublic IP: %s\nSSH user: %s\n' "$RG" "$VM" "$IP" "$ADMIN"
printf 'Inventory written to ansible/inventory.ini\n'
