#!/bin/bash
# 01_setup_host.sh

# Auto-detect the real non-root user who ran sudo
TARGET_USER="${SUDO_USER:-$1}"

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" == "root" ]; then
    echo "Error: Could not auto-detect your non-root username."
    echo "Usage: sudo ./01_setup_host.sh [optional-vault-network-name]"
    exit 1
fi

# Fallback to 'aider-vault' if no network name is passed as an argument
VAULT_NET="${2:-aider-vault}"

echo "[-] Target User identified as: $TARGET_USER"
echo "[-] Target Vault Network set to: $VAULT_NET"

echo "[-] Installing Host Dependencies..."
sudo apt update && sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager virtiofsd iptables

echo "[-] Provisioning Secure Shared Storage Directory..."
SHARE_DIR="/home/$TARGET_USER/aider"

# Create the directory if it doesn't exist
sudo mkdir -p "$SHARE_DIR"

# Change ownership: Target user is owner, libvirt-qemu is the group
sudo chown "$TARGET_USER:libvirt-qemu" "$SHARE_DIR"

# 2775 permissions:
# - User and Group get full Read/Write/Execute
# - The '2' sets the setgid bit, meaning any NEW files created in this folder
#   automatically inherit the 'libvirt-qemu' group, preserving the bridge.
sudo chmod 2775 "$SHARE_DIR"

# Critical Path Traversal Insurance: Ensure the hypervisor can actually step
# into /home/user to reach the share directory.
sudo chmod o+x "/home/$TARGET_USER"

echo "[-] Configuring Git Trust for the Libvirt bridge..."
# Surgically remove ONLY our specific entry (and any duplicates of it).
# The regex "^${SHARE_DIR}/\\*$" ensures we don't touch the user's other safe directories.
sudo -u "$TARGET_USER" git config --global --unset-all safe.directory "^${SHARE_DIR}/\\*$" 2>/dev/null || true

# Inject the fresh trust exception (guaranteed to only be a single line now)
sudo -u "$TARGET_USER" git config --global --add safe.directory "$SHARE_DIR/*"

echo "[+] Shared directory ready at $SHARE_DIR (Permissions tuned for Libvirt)."

echo "[-] Creating Modular Libvirt Hook Infrastructure..."
sudo mkdir -p /etc/libvirt/hooks/network.d

# 1. Create the Master Multiplexer (This runs once and never has to change)
cat << 'EOF' | sudo tee /etc/libvirt/hooks/network > /dev/null
#!/bin/bash
# /etc/libvirt/hooks/network
# Master Multiplexer: Dynamically executes all scripts in network.d/

HOOK_DIR="/etc/libvirt/hooks/network.d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        if [ -x "$hook" ]; then
            "$hook" "$@"
        fi
    done
fi
EOF
sudo chmod +x /etc/libvirt/hooks/network

# 2. Create your isolated network-dependent script inside network.d/
cat << EOF | sudo tee /etc/libvirt/hooks/network.d/vault_$VAULT_NET > /dev/null
#!/bin/bash
# /etc/libvirt/hooks/network.d/vault_$VAULT_NET

HOOK_NETWORK="\$1"
ACTION="\$2"

if [ "\$HOOK_NETWORK" == "$VAULT_NET" ]; then
    if [ "\$ACTION" == "started" ]; then
        # 1. Allow established return traffic (Allows Host->VM SSH)
        iptables -I LIBVIRT_INP 1 -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

        # 2. Allow Ollama API (11434)
        iptables -I LIBVIRT_INP 2 -i "\$HOOK_NETWORK" -p tcp --dport 11434 -j ACCEPT 2>/dev/null

        # 3. Allow DHCP and DNS
        iptables -I LIBVIRT_INP 3 -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 4 -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null

        # 4. DROP all other new TCP requests from VM to Host
        iptables -I LIBVIRT_INP 5 -i "\$HOOK_NETWORK" -p tcp -m state --state NEW -j DROP 2>/dev/null

    elif [ "\$ACTION" == "stopped" ]; then
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p tcp --dport 11434 -j ACCEPT 2>/dev/null
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p tcp -m state --state NEW -j DROP 2>/dev/null
    fi
fi
EOF
sudo chmod +x /etc/libvirt/hooks/network.d/vault_$VAULT_NET

echo "[-] Restarting Libvirt to register the master multiplexer hook..."
sudo systemctl restart libvirtd

echo "[-] Granting hypervisor permissions to $TARGET_USER..."
sudo usermod -aG libvirt,kvm "$TARGET_USER"

echo "[-] Host Infrastructure Ready. Target network '$VAULT_NET' is protected."