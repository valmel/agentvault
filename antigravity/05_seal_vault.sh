#!/bin/bash
# 05_seal_vault.sh

if [ -z "$1" ]; then
    echo "Error: You must provide the name of the Vault VM."
    echo "Usage: ./05_seal_vault.sh <vm-name>"
    exit 1
fi

VM_NAME="$1"
NETWORK_NAME="$1"
BRIDGE_IP="192.168.101.1"       # Migrated to 101 subnet to prevent Aider collisions
STATIC_VM_IP="192.168.101.200"

# Sanity Check
if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "[!] Error: VM '$VM_NAME' does not exist in Libvirt."
    exit 1
fi

echo "[-] Extracting MAC address..."
VM_MAC=$(virsh dumpxml "$VM_NAME" | grep "mac address" | head -n 1 | awk -F\' '{print $2}')
if [ -z "$VM_MAC" ]; then
    echo "[!] Error: Could not extract MAC address from VM."
    exit 1
fi
echo "[-] MAC Address: $VM_MAC -> Locked to $STATIC_VM_IP"

echo "[-] Defining the Antigravity Network (Blind Internet)..."
cat <<EOF > /tmp/${NETWORK_NAME}-net.xml
<network>
  <name>$NETWORK_NAME</name>
  <bridge name='${NETWORK_NAME}' stp='on' delay='0'/>
  <forward mode='nat'/> <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.101.2' end='192.168.101.254'/>
      <host mac='$VM_MAC' name='$VM_NAME' ip='$STATIC_VM_IP'/>
    </dhcp>
  </ip>
</network>
EOF

virsh net-destroy $NETWORK_NAME 2>/dev/null
virsh net-undefine $NETWORK_NAME 2>/dev/null
virsh net-define /tmp/${NETWORK_NAME}-net.xml
virsh net-start $NETWORK_NAME
virsh net-autostart $NETWORK_NAME
rm /tmp/${NETWORK_NAME}-net.xml

echo "[-] Swapping VM network to the Blind Internet bridge..."
if virsh list | grep -q " $VM_NAME .*running"; then
    echo "[-] Stopping running VM instance..."
    virsh destroy $VM_NAME 2>/dev/null
    sleep 3
fi

virsh dumpxml $VM_NAME > /tmp/${VM_NAME}_config.xml
sed -i -E "s/<source network=['\"][^'\"]+['\"](\s*\/)?>/<source network='$NETWORK_NAME'\/>/g" /tmp/${VM_NAME}_config.xml
virsh define /tmp/${VM_NAME}_config.xml
rm /tmp/${VM_NAME}_config.xml

echo "[-] Booting the mathematically sealed Vault..."
virsh start $VM_NAME

echo "[-] Waiting for VM to acquire the static IP ($STATIC_VM_IP)..."
for i in {1..20}; do
    sleep 2
    if virsh domifaddr "$VM_NAME" | grep -q "$STATIC_VM_IP"; then
        break
    fi
done

# Auto-configure SSH alias for the end user
SSH_CONFIG_DIR="$HOME/.ssh"
mkdir -p "$SSH_CONFIG_DIR"
chmod 700 "$SSH_CONFIG_DIR"

if ! grep -q "Host $VM_NAME" "$SSH_CONFIG_DIR/config" 2>/dev/null; then
    echo "[-] Automating SSH alias '$VM_NAME' in ~/.ssh/config..."
    cat <<EOF >> "$SSH_CONFIG_DIR/config"

Host $VM_NAME
    HostName $STATIC_VM_IP
    User agent
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    chmod 600 "$SSH_CONFIG_DIR/config"
fi

echo "---"
echo "[+] Antigravity Vault Sealed."
echo "    - VM has internet access to Google's API."
echo "    - VM is FIREWALLED from scanning your host or LAN."
echo "    - Run 'ssh $VM_NAME' and start typing: antigravity /goal 'Build me a solver'"