# Azure Personal WireGuard VPN (Azure CLI + Ansible)

Deploy a small Ubuntu 22.04 Azure VM and configure it as a WireGuard IPv4 full-tunnel egress VPN. The control node is Ubuntu under WSL2. Azure CLI provisions resources; Ansible configures the host. No Terraform and no permanently running control VM are required.

## What this deploys

- Azure resource group, VNet/subnet, Standard static public IPv4, NSG, NIC and Ubuntu VM.
- SSH limited to `SSH_ALLOWED_CIDR`; WireGuard UDP/51820 reachable from client networks.
- Ubuntu security updates, UFW, WireGuard, IPv4 forwarding and NAT.
- Separate client keys/configurations for Windows desktop, MacBook and phone.
- Client profiles stored locally under `secrets/clients/` with restrictive permissions; this directory is git-ignored.
- A test playbook for service, interface, forwarding, firewall and file permissions.

**IPv6 behavior:** client profiles route `::/0` into the tunnel as well, but this initial server config only provides IPv4 egress. This is intended to prevent IPv6 from bypassing the VPN; IPv6 connectivity will not work through the VPN until IPv6 routing is deliberately implemented. Do not remove `::/0` unless you have independently addressed IPv6 leak risk.

## 0. Prerequisites

- An Azure subscription with permission to create resource groups, VMs, networking and public IPs, and sufficient regional VM quota.
- WSL2 Ubuntu (Ubuntu 24.04 recommended) on Windows.
- Your current trusted public IPv4 address for SSH access. If your ISP changes it, update the NSG rule and UFW rule before reconnecting from the new address.
- Check your Azure subscription's current VM, public IPv4 and outbound data-transfer pricing before deployment. A static public IP and VM may incur charges while provisioned, including when the VM is stopped but not deallocated.

## 1. Install tools inside WSL2

Open the Ubuntu WSL terminal, not PowerShell:

```bash
sudo apt update
sudo apt install -y git curl openssh-client wireguard-tools qrencode python3 python3-pip python3-venv pipx
pipx ensurepath
```

Install Azure CLI using Microsoft's current Linux instructions: https://learn.microsoft.com/cli/azure/install-azure-cli-linux

Install Ansible using the supported package for your WSL Ubuntu release or pipx. For example, if pipx is configured and your Python version meets its requirements:

```bash
pipx install --include-deps ansible
```

Close/reopen the WSL terminal if `ansible` is not found after `pipx ensurepath`. Verify:

```bash
az version
ansible --version
wg --version
qrencode --version
```

## 2. Clone and configure

```bash
git clone <your-repository-url> azure-wireguard-vpn
cd azure-wireguard-vpn
az login
az account show
```

If you have multiple subscriptions, explicitly select the intended one:

```bash
az account set --subscription "<subscription-id-or-name>"
```

Set the source CIDR allowed to SSH to the VM. Find your current public IPv4 using a trusted method; if you use the command below, confirm the returned address before relying on it:

```bash
curl -4 https://ifconfig.me
export SSH_ALLOWED_CIDR="YOUR.PUBLIC.IP.ADDRESS/32"
```

Do **not** use `0.0.0.0/0` for SSH. WireGuard UDP/51820 is public so that your phone can connect from mobile networks and your laptop can connect from changing networks. SSH is separately restricted.

Optional environment variables:

```bash
export AZURE_LOCATION=southeastasia
export AZURE_RESOURCE_GROUP=rg-personal-wireguard
export AZURE_VM_NAME=vm-personal-wireguard
export AZURE_ADMIN_USER=azureuser
export AZURE_VM_SIZE=Standard_B1s
export SSH_KEY_PATH="$HOME/.ssh/azure-vpn"
```

Check VM sizes available in the chosen region if the default size is unavailable or quota-limited:

```bash
az vm list-sizes --location "$AZURE_LOCATION" -o table
```

The `Standard_B1s` size is a low-cost starting point, not a guarantee of availability or adequate performance for every workload. Choose a supported size and inspect the price for your subscription/region.

## 3. Deploy the Azure infrastructure

```bash
./scripts/infra-up.sh
```

The script creates the resource group, virtual network, subnet, NSG, static public IP, NIC and VM. It writes `ansible/inventory.ini` with the IP and SSH key path. It also adds the VM's SSH host key to `known_hosts` on first use. **First-use host-key scanning is trust-on-first-use**; for stronger protection, verify the VM host-key fingerprint through a trusted Azure console channel before administering a sensitive server.

If provisioning fails because a VM size is unavailable or quota is insufficient, set `AZURE_VM_SIZE` to a supported size and rerun. Inspect partially created resources in the named resource group before retrying.

## 4. Configure the VPN with Ansible

Ensure `SSH_ALLOWED_CIDR` is still exported in the same WSL shell, then run:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.ini ansible/site.yml
```

Or run the wrapper to provision, configure and test in one go:

```bash
./scripts/deploy.sh
```

The first run generates three client private keys locally. It creates server keys on the VM, configures NAT and forwarding, and renders client profiles. Client private keys are never intentionally copied to the server. Do not paste client profiles, QR codes, or private keys into chats, issue trackers or source control.

Generated files:

```text
secrets/clients/windows-desktop.conf
secrets/clients/macbook.conf
secrets/clients/phone.conf
secrets/clients/phone.png
```

The PNG is generated for the phone if `qrencode` is installed in WSL. If no PNG appears, run:

```bash
qrencode -o secrets/clients/phone.png < secrets/clients/phone.conf
chmod 600 secrets/clients/*
```

## 5. Connect your devices

1. Install the official WireGuard client on Windows, macOS and your phone: https://www.wireguard.com/install/
2. On Windows, import `windows-desktop.conf` from a secure local path.
3. On macOS, import `macbook.conf`.
4. On your phone, use WireGuard's QR import to scan `phone.png`. Display it only where others cannot photograph it.
5. Activate one profile and visit `https://ifconfig.me` or another IP-check service. The observed IPv4 should be the Azure public IP, not your home/mobile ISP IP.
6. Check DNS resolution and verify that IPv6 does not escape the tunnel. This profile routes IPv6 into the tunnel, but the current server does not provide IPv6 egress, so IPv6-only destinations may be unavailable.

Do not use the same client profile on multiple devices. Separate peers allow individual revocation and better troubleshooting.

## 6. Tests and day-to-day commands

```bash
# Run automated server checks
ansible-playbook -i ansible/inventory.ini ansible/tests.yml

# Show Azure VM state and WireGuard peer status
./scripts/status.sh

# Check configuration syntax without applying changes
ansible-playbook -i ansible/inventory.ini ansible/site.yml --syntax-check

# Check what Ansible would change (not all tasks support check mode)
ansible-playbook -i ansible/inventory.ini ansible/site.yml --check --diff
```

The playbook is designed to be re-run. Re-running it should preserve existing client/server keys and converge the configuration. Review any unexpected changes before applying them.

## 7. Add or revoke a client

Edit `ansible/group_vars/vpn/main.yml` and assign a unique address to each client, for example `10.66.66.5/32` for a new tablet. Add a unique, filesystem-safe name. Then rerun:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml
```

To revoke a device, remove its entry from `vpn_clients` and rerun the playbook. The server's WireGuard config will no longer contain that peer. Delete the old local `.conf`, `.key`, and QR image securely if no longer needed. Revocation does not erase a copy already imported into a device, but the removed public key will no longer be accepted by the server.

For a more mature version, add an explicit peer-revocation command, backup/restore for the server private key and configuration, and a separate encrypted backup location.

## 8. SSH source IP changes

If your ISP changes your public IP, update the NSG SSH rule and UFW rule before reconnecting. Use Azure CLI to update the rule's `--source-address-prefixes` to your new `/32`, and rerun the Ansible hardening role after exporting the new `SSH_ALLOWED_CIDR`. Do not temporarily open SSH to all IPs.

## 9. Cleanup (important)

Azure resources can continue to cost money while provisioned. To delete the entire resource group and all resources in it:

```bash
./scripts/infra-down.sh
```

The script requires you to type the exact resource-group confirmation. Confirm the resource group name first; deleting a resource group removes **all** resources inside it. Local client keys and profiles are not deleted automatically. If you no longer need them, remove `secrets/clients/` securely.

Stopping a VM is not the same as deallocating it. To stop and deallocate without deleting resources:

```bash
az vm deallocate -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_VM_NAME"
```

To start it again:

```bash
az vm start -g "$AZURE_RESOURCE_GROUP" -n "$AZURE_VM_NAME"
```

The public IP resource is configured as static, but always confirm the endpoint from Azure after resource changes.

## Security notes and limitations

- This is a personal-use starting point, not a hardened multi-user VPN service.
- Azure billing depends on region, VM SKU, public IP SKU and outbound traffic; check current prices before deployment.
- SSH is restricted by source CIDR; UDP/51820 must be reachable from arbitrary client networks.
- Client and server private keys are secrets. The repo ignores `secrets/**`; check `git status --ignored` and never force-add secret files.
- Do not enable verbose Ansible logging (`-vvv`) when handling key material. Sensitive tasks use `no_log` where appropriate.
- The initial setup is IPv4 egress with IPv6 routed into the tunnel but not routed onward. Implement proper Azure IPv6 networking and WireGuard IPv6 forwarding before enabling IPv6 internet access through the VPN.
- WireGuard only protects traffic while its client tunnel is active. Configure the client app's always-on/on-demand options if you want it to reconnect automatically.
- The server's IP is an Azure data-center IP; some streaming services and websites may block cloud-hosted VPN endpoints.
