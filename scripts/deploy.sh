#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
: "${SSH_ALLOWED_CIDR:?Set SSH_ALLOWED_CIDR to your trusted public IPv4 CIDR, e.g. 203.0.113.10/32}"
./scripts/infra-up.sh
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory.ini ansible/site.yml
ansible-playbook -i ansible/inventory.ini ansible/tests.yml
printf '\nClient profiles are in secrets/clients/. Import the matching .conf file into the WireGuard app.\n'
printf 'Install qrencode in WSL to generate phone.png QR output.\n'
