#!/bin/bash
# 03_setup_aider.sh

if [ -z "$1" ]; then
    echo "Error: You must provide the name of the Vault VM."
    echo "Usage: ./03_setup_aider.sh <vm-name>"
    exit 1
fi

VM_NAME="$1"
BRIDGE_IP="192.168.100.1"
USERNAME="agent"
PASSWORD="password123"

# Ensure the host has a modern ED25519 keypair
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "[-] Generating a secure ED25519 keypair..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q
fi

echo "[-] Waking up $VM_NAME for software provisioning..."
if ! virsh list | grep -q " $VM_NAME .*running"; then
    virsh start $VM_NAME
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
ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME@$VM_IP"


# 2. Create the Payload
echo "[-] Generating remote installation payload..."
cat <<EOF > /tmp/remote_deploy.sh
#!/bin/bash
set -e

echo "[-] Updating apt registries..."
apt-get update
echo "[-] Installing system build essentials..."
apt-get install -y curl git build-essential

# Use 'sudo -i -u' to ensure the user's absolute home environment is loaded
# before executing the Astral 'uv' installer script.
echo "[-] Installing 'uv' (Rust-based Python package manager)..."
sudo -i -u $USERNAME curl -LsSf https://astral.sh/uv/install.sh | sudo -i -u $USERNAME sh

echo "[-] Installing standalone Python 3.12 and sandboxing Aider..."
sudo -i -u $USERNAME /home/$USERNAME/.local/bin/uv tool install --python 3.12 aider-chat

echo "[-] Injecting clean configuration profiles into .bashrc..."
cat << 'PROFILE' >> /home/$USERNAME/.bashrc

# --- Aider Air-Gapped configuration ---
export OLLAMA_API_BASE="http://$BRIDGE_IP:11434"
export AIDER_ANALYTICS=false
export PATH="\$HOME/.local/bin:\$PATH"
PROFILE

echo "[-] Ensuring .bashrc ownership for $USERNAME..."
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc
EOF
chmod +x /tmp/remote_deploy.sh

# 3. Ship and Execute Payload
echo "[-] Shipping installation matrix to the VM..."
scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_deploy.sh $USERNAME@$VM_IP:/tmp/

echo "[-] Triggering installation pipeline inside VM..."
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USERNAME@$VM_IP "sudo bash /tmp/remote_deploy.sh"

if [ $? -eq 0 ]; then
    echo "---"
    echo "[+] Software provisioning completely successful!"
    echo "[-] Shutting down VM to prepare for Phase 04 (Shared Directory Configuration)..."
    ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USERNAME@$VM_IP "sudo poweroff"
    rm -f /tmp/remote_deploy.sh
    echo "[-] Ready. You may now run: ./04_share_dir.sh $VM_NAME /path/to/your/host/dir"
else
    echo "[!] Critical failure during installation loop."
    exit 1
fi