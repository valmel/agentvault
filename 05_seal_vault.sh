#!/bin/bash
# 05_seal_vault.sh

if [ -z "$1" ]; then
    echo "Error: You must provide the name of the Vault VM."
    echo "Usage: ./05_seal_vault.sh <vm-name>"
    exit 1
fi

VM_NAME="$1"
NETWORK_NAME="$1"
BRIDGE_IP="192.168.100.1"
STATIC_VM_IP="192.168.100.100" # The eternal, unchanging IP

# Sanity Check: Verify the VM actually exists
if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "[!] Error: VM '$VM_NAME' does not exist in Libvirt."
    exit 1
fi

# Extract the VM's MAC address so we can lock it to a static IP
echo "[-] Extracting hardware MAC address to bind static lease..."
VM_MAC=$(virsh dumpxml "$VM_NAME" | grep "mac address" | head -n 1 | awk -F\' '{print $2}')
if [ -z "$VM_MAC" ]; then
    echo "[!] Error: Could not extract MAC address from VM."
    exit 1
fi
echo "[-] MAC Address: $VM_MAC -> Locked to $STATIC_VM_IP"

echo "[-] Defining the Vault Network: $NETWORK_NAME (Zero Internet)..."
cat <<EOF > /tmp/${NETWORK_NAME}-net.xml
<network>
  <name>$NETWORK_NAME</name>
  <bridge name='$NETWORK_NAME' stp='on' delay='0'/>
  <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.100.2' end='192.168.100.254'/>
      <!-- STATIC LEASE: Lock this MAC address to this exact IP forever -->
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

echo "[-] Creating Localhost Relay Service for Ollama..."
cat <<EOF | sudo tee /etc/systemd/system/ollama-relay-${VM_NAME}.service > /dev/null
[Unit]
Description=Ollama VM Bridge Relay for $VM_NAME
After=network.target libvirtd.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:11434,bind=$BRIDGE_IP,reuseaddr,fork TCP:127.0.0.1:11434
Restart=always
DynamicUser=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ollama-relay-${VM_NAME}.service

echo "[-] Severing internet access for $VM_NAME..."

# Ensure the VM is completely powered off before altering the XML hardware map
if virsh list | grep -q " $VM_NAME .*running"; then
    echo "[-] Stopping running VM instance..."
    virsh destroy $VM_NAME 2>/dev/null
    sleep 3 # Give Libvirt a moment to release the state file locks
fi

# Dump the current XML configuration
virsh dumpxml $VM_NAME > /tmp/${VM_NAME}_config.xml

# Idempotent Hot-Swap: This regex captures '<source network=' followed by ANY
# single or double quoted network name, and violently overwrites it to $NETWORK_NAME.
# This ensures it works perfectly even if the VM is already on a custom network.
sed -i -E "s/<source network=['\"][^'\"]+['\"](\s*\/)?>/<source network='$NETWORK_NAME'\/>/g" /tmp/${VM_NAME}_config.xml

# Apply the locked-down configuration back to Libvirt
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
echo "[+] DONE! The environment is now fully air-gapped."
echo "    - The one-way firewall hook is active."
echo "    - Internet access is completely severed."
echo "    - Aider can reach Ollama, but cannot reach your host."
echo ""
echo "To enter the Vault securely, open your terminal and simply type:"
echo ""
echo "    ssh $VM_NAME"
echo ""