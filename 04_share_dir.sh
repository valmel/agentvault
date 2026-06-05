#!/bin/bash
# 04_share_dir.sh (VIRTIOFS UPGRADE)

if [ "$#" -ne 2 ]; then
    echo "Usage: ./04_share_dir.sh <vm-name> <absolute-path-to-host-dir>"
    echo "Example: ./04_share_dir.sh aider-vault /home/$USER/aider"
    exit 1
fi

VM_NAME="$1"
HOST_DIR=$(realpath "$2")
USERNAME="agent"
PASSWORD="password123"

if [ ! -d "$HOST_DIR" ]; then
    echo "[!] Error: Host directory '$HOST_DIR' does not exist."
    exit 1
fi

echo "[-] Waking up $VM_NAME to configure the shared directory..."
if ! virsh list | grep -q " $VM_NAME .*running"; then
    virsh start $VM_NAME
    echo "[-] Waiting 30 seconds for the VM to boot..."
    sleep 30
fi

VM_IP=""
MAX_RETRIES=30
echo "[-] Hunting for temporary VM IP via Libvirt API..."
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

echo "[-] Injecting virtiofs Shared Memory Filesystem into Libvirt XML map..."
cat <<EOF > /tmp/fs_${VM_NAME}.xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$HOST_DIR'/>
  <target dir='vault_share'/>
</filesystem>
EOF

# Attach persistently to the VM config
virsh attach-device "$VM_NAME" /tmp/fs_${VM_NAME}.xml --config
# Attach to the running instance
virsh attach-device "$VM_NAME" /tmp/fs_${VM_NAME}.xml --live 2>/dev/null
rm /tmp/fs_${VM_NAME}.xml

echo "[-] Executing remote mount configuration inside VM via SSH..."
cat <<EOF > /tmp/remote_mount.sh
#!/bin/bash
set -e

echo "[-] Creating guest mount point..."
mkdir -p /home/$USERNAME/aider

echo "[-] Adding share entry to /etc/fstab with systemd safeguards..."
# Clean existing vault_share entries out to avoid duplication loops
sed -i '/vault_share/d' /etc/fstab
echo 'vault_share /home/$USERNAME/aider virtiofs x-systemd.automount,rw,nofail 0 0' >> /etc/fstab

echo "[-] Refreshing storage targets inside the guest kernel..."
systemctl daemon-reload
systemctl restart local-fs.target || true
EOF
chmod +x /tmp/remote_mount.sh

# Push and execute the mount script as root
scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_mount.sh $USERNAME@$VM_IP:/tmp/
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USERNAME@$VM_IP "sudo bash /tmp/remote_mount.sh"

rm -f /tmp/remote_mount.sh

echo "[+] SUCCESS! High-speed virtiofs link established."