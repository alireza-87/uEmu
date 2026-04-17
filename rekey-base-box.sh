#!/usr/bin/env bash
# One-shot recovery: restore Vagrant's insecure public key on the builder VM
# and re-package it as `uemu-prebuilt`.
#
# Why this exists: `vagrant package` captures the VM's current authorized_keys.
# If Vagrant rotated the key to a per-VM key on first boot, the packaged box
# can't be SSH'd into by fresh workers. This script re-keys the builder back
# to the insecure key so the re-packaged box works for all workers.
#
# Requires the existing builder VM (VirtualBox name: `uemu`) to still exist.

set -euo pipefail

BOX_NAME="${UEMU_BASE_BOX_NAME:-uemu-prebuilt}"
BOX_FILE="${UEMU_BASE_BOX_FILE:-uemu-prebuilt.box}"
VM_NAME="uemu"
VAGRANT_PUBKEY_URL="https://raw.githubusercontent.com/hashicorp/vagrant/main/keys/vagrant.pub"

export UEMU_ROLE=builder
export UEMU_VM_COUNT=1

echo "[rekey] Stage 1/5: starting builder VM (no re-provision)..."
vagrant up --provider=virtualbox --no-provision

echo "[rekey] Stage 2/5: restoring Vagrant's insecure public key on the VM..."
vagrant ssh -c "
    set -e
    curl -sfL '$VAGRANT_PUBKEY_URL' \
        | sudo tee /home/vagrant/.ssh/authorized_keys > /dev/null
    sudo chmod 0600 /home/vagrant/.ssh/authorized_keys
    sudo chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
    echo '[rekey] authorized_keys restored.'
"

echo "[rekey] Stage 3/5: halting builder..."
vagrant halt

if [[ -f "$BOX_FILE" ]]; then
    echo "[rekey] Removing stale $BOX_FILE"
    rm -f "$BOX_FILE"
fi

echo "[rekey] Stage 4/5: re-packaging $VM_NAME -> $BOX_FILE ..."
vagrant package --base "$VM_NAME" --output "$BOX_FILE"

if vagrant box list 2>/dev/null | awk '{print $1}' | grep -qx "$BOX_NAME"; then
    echo "[rekey] Removing previously registered box '$BOX_NAME'"
    vagrant box remove -f "$BOX_NAME"
fi

echo "[rekey] Stage 5/5: registering $BOX_FILE as '$BOX_NAME' ..."
vagrant box add "$BOX_NAME" "$BOX_FILE"

cat <<EOF

[rekey] Done. Retry the workers:

    UEMU_ROLE=worker UEMU_VM_COUNT=21 vagrant destroy -f   # clear any stale t1
    ./up-workers.sh 21 2 8192
EOF
