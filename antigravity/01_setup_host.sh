#!/bin/bash
# 01_setup_host.sh

# Smart argument parsing based on execution context
if [ -n "$SUDO_USER" ]; then
    # Ran with 'sudo' -> Target user is known. $1 is the vault name.
    TARGET_USER="$SUDO_USER"
    VAULT_NET="${1:-ag-vault}"
else
    # Ran directly as root -> We need the username explicitly as $1.
    TARGET_USER="$1"
    VAULT_NET="${2:-ag-vault}"
fi

# Sanity check
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" == "root" ]; then
    echo "Error: Could not determine the target non-root user."
    echo "Usage (if using sudo):   sudo ./01_setup_host.sh [optional-vault-network]"
    echo "Usage (if already root): ./01_setup_host.sh <your-linux-username> [optional-vault-network]"
    exit 1
fi

echo "[-] Target User identified as: $TARGET_USER"
echo "[-] Target Vault Network set to: $VAULT_NET"

echo "[-] Installing Host Dependencies..."
sudo apt update && sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager virtiofsd iptables

echo "[-] Provisioning Secure Shared Storage Directory..."
SHARE_DIR="/home/$TARGET_USER/antigravity_workspace"
sudo mkdir -p "$SHARE_DIR"
sudo chown "$TARGET_USER:libvirt-qemu" "$SHARE_DIR"
sudo chmod 2775 "$SHARE_DIR"
sudo chmod o+x "/home/$TARGET_USER"

echo "[-] Configuring Git Trust for the Libvirt bridge..."
sudo -u "$TARGET_USER" git config --global --unset-all safe.directory "^${SHARE_DIR}/\\*$" 2>/dev/null || true
sudo -u "$TARGET_USER" git config --global --add safe.directory "$SHARE_DIR/*"

echo "[-] Creating Libvirt Hook Infrastructure..."
sudo mkdir -p /etc/libvirt/hooks/network.d

# Master Multiplexer
cat << 'EOF' | sudo tee /etc/libvirt/hooks/network > /dev/null
#!/bin/bash
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

# The Antigravity Egress-Only Firewall Hook
cat << EOF | sudo tee /etc/libvirt/hooks/network.d/$VAULT_NET > /dev/null
#!/bin/bash
HOOK_NETWORK="\$1"
ACTION="\$2"

if [ "\$HOOK_NETWORK" == "$VAULT_NET" ]; then
    if [ "\$ACTION" == "started" ]; then
        # --- PROTECT THE HOST (INPUT CHAIN) ---
        # 1. Allow Host to SSH into VM (Return traffic)
        iptables -I LIBVIRT_INP 1 -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        # 2. Allow VM to ask Host's Libvirt DHCP for its IP
        iptables -I LIBVIRT_INP 2 -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null
        # 3. Allow VM to ask Host's Libvirt DNS for web addresses
        iptables -I LIBVIRT_INP 3 -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 4 -i "\$HOOK_NETWORK" -p tcp --dport 53 -j ACCEPT 2>/dev/null
        # 4. DROP absolutely all other traffic trying to reach the Host directly
        iptables -I LIBVIRT_INP 5 -i "\$HOOK_NETWORK" -j DROP 2>/dev/null

        # --- PROTECT THE LAN (FORWARD CHAIN) ---
        # 5. Drop any traffic headed to private local networks (Your 192.168.1.x, etc.)
        iptables -I FORWARD 1 -i "\$HOOK_NETWORK" -d 192.168.0.0/16 -j DROP 2>/dev/null
        iptables -I FORWARD 2 -i "\$HOOK_NETWORK" -d 10.0.0.0/8 -j DROP 2>/dev/null
        iptables -I FORWARD 3 -i "\$HOOK_NETWORK" -d 172.16.0.0/12 -j DROP 2>/dev/null

        # 6. Allow only specific web ports to the rest of the world (The actual Internet)
        iptables -I FORWARD 4 -i "\$HOOK_NETWORK" -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null

        # 7. DROP any other random outbound traffic (e.g., SSH, FTP, Telnet to the outside world)
        iptables -I FORWARD 5 -i "\$HOOK_NETWORK" -j DROP 2>/dev/null

    elif [ "\$ACTION" == "stopped" ]; then
        # Clean teardown of rules
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -j DROP 2>/dev/null || true

        iptables -D FORWARD -i "\$HOOK_NETWORK" -d 192.168.0.0/16 -j DROP 2>/dev/null || true
        iptables -D FORWARD -i "\$HOOK_NETWORK" -d 10.0.0.0/8 -j DROP 2>/dev/null || true
        iptables -D FORWARD -i "\$HOOK_NETWORK" -d 172.16.0.0/12 -j DROP 2>/dev/null || true
        iptables -D FORWARD -i "\$HOOK_NETWORK" -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "\$HOOK_NETWORK" -j DROP 2>/dev/null || true
    fi
fi
EOF
sudo chmod +x /etc/libvirt/hooks/network.d/$VAULT_NET

echo "[-] Restarting Libvirt to register hooks..."
sudo systemctl restart libvirtd

echo "[-] Granting hypervisor permissions to $TARGET_USER..."
sudo usermod -aG libvirt,kvm "$TARGET_USER"

echo ""
echo "====================================================================="
echo " [SUCCESS] HOST INFRASTRUCTURE READY"
echo "====================================================================="
echo " Shared Directory: $SHARE_DIR"
echo " Network Profile:  $VAULT_NET"
echo "====================================================================="
echo ""
echo " [!] CRITICAL ACTION REQUIRED BEFORE PROCEEDING [!]"
echo " Your user account ($TARGET_USER) was just added to the required"
echo " hypervisor security groups (libvirt, kvm)."
echo ""
echo " Your active terminal DOES NOT have these permissions yet."
echo " If you proceed immediately, the next script will crash or prompt"
echo " for unexpected passwords."
echo ""
echo " TO FIX THIS, DO ONE OF THE FOLLOWING NOW:"
echo "   Option A: Close this terminal completely and open a new one."
echo "   Option B: Run these two commands manually:"
echo "             newgrp libvirt"
echo "             newgrp kvm"
echo "====================================================================="
echo ""