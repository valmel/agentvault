#!/bin/bash
# 03_setup_antigravity.sh

# No sudo for host execution. Paths use literal $HOME.
SSH_KEY="$HOME/.ssh/id_ed25519"
VM_NAME="$1"
GEMINI_API_KEY="$2"
REMOTE_USER="agent"
PASSWORD="password123"

if [ -z "$VM_NAME" ] || [ -z "$GEMINI_API_KEY" ]; then
    echo "Usage: ./03_setup_antigravity.sh <vm-name> <YOUR_GEMINI_API_KEY>"
    exit 1
fi

# Ensure the host has a modern ED25519 keypair
if [ ! -f "$SSH_KEY" ]; then
    echo "[-] Generating a secure ED25519 keypair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
fi

echo "[-] Waking up $VM_NAME for software provisioning..."
if ! virsh list | grep -q " $VM_NAME .*running"; then
    virsh start "$VM_NAME"
    echo "[-] Waiting 30 seconds for the VM to boot and acquire an IP..."
    sleep 30
fi

# Native hypervisor IP lookup instead of flaky ARP tables
VM_IP=""
MAX_RETRIES=30
echo "[-] Hunting for VM IP via Libvirt API..."
for ((i=1; i<=MAX_RETRIES; i++)); do
    sleep 3
    VM_IP=$(virsh domifaddr "$VM_NAME" | grep -oE "192\.168\.[0-9]+\.[0-9]+")
    if [ ! -z "$VM_IP" ]; then
        break
    fi
done

if [ -z "$VM_IP" ]; then
    echo "[!] Error: Could not find the VM's temporary IP address."
    exit 1
fi

echo "[-] Found VM at IP: $VM_IP"

# 1. Establish Key-Based Trust
echo "[-] Establishing passwordless SSH trust..."
echo "[*] PLEASE TYPE '$PASSWORD' WHEN PROMPTED (This is the final time):"
ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER@$VM_IP"

echo "[-] Generating Antigravity deployment payload..."
cat <<EOF > /tmp/remote_deploy.sh
#!/bin/bash
set -e

echo "[-] Installing System Dependencies..."
# Only system-level changes use sudo
sudo apt-get update
sudo apt-get install -y curl git build-essential

echo "[-] Installing Google Antigravity CLI..."
# Runs in pure user-space. Will natively install to ~/.local/bin
curl -fsSL https://antigravity.google/cli/install.sh | bash

echo "[-] Securing Gemini API Key and Workflows..."
cat << 'PROFILE' >> /home/$REMOTE_USER/.bashrc

# --- Antigravity CLI Config ---
export GEMINI_API_KEY="$GEMINI_API_KEY"
export PATH="\$HOME/.local/bin:\$PATH"
PROFILE
EOF
chmod +x /tmp/remote_deploy.sh

echo "[-] Shipping and executing payload..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_deploy.sh "$REMOTE_USER@$VM_IP:/tmp/"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER@$VM_IP" "bash /tmp/remote_deploy.sh"

if [ $? -eq 0 ]; then
    echo "---"
    echo "[+] Software provisioning completely successful!"
    echo "[-] Shutting down VM to prepare for Phase 04 (Shared Directory Configuration)..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$REMOTE_USER@$VM_IP" "sudo poweroff"
    rm -f /tmp/remote_deploy.sh
    echo "[-] Ready. You may now run the Phase 04 virtiofs script."
else
    echo "[!] Critical failure during installation loop."
    exit 1
fi