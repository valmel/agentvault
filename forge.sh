#!/bin/bash
# forge.sh - The Parametric Agentic Vault Builder

set -e

# --- 1. ARGUMENT PARSING & STATE ---
if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo ./forge.sh --name=<vault> --agent=<aider|ag|claude|opencode|pi-local|pi-cloud>"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$1}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" == "root" ]; then
    echo "[!] Error: Could not determine the target non-root user."
    exit 1
fi

BASE_DIR="/home/$TARGET_USER"
SSH_KEY="$BASE_DIR/.ssh/id_ed25519"
PASSWORD="password123"

# Defaults
VM_NAME=""
AGENT_TYPE=""
API_KEY=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --name=*) VM_NAME="${1#*=}" ;;
        --agent=*) AGENT_TYPE="${1#*=}" ;;
        --key=*) API_KEY="${1#*=}" ;;
        -h|--help)
            echo "Usage: sudo ./forge.sh --name=<vault> --agent=<aider|ag|claude|opencode|pi-local|pi-cloud> [--key=<api-key>]"
            exit 0 ;;
    esac
    shift
done

if [ -z "$VM_NAME" ] || [ -z "$AGENT_TYPE" ]; then
    echo "[!] Error: --name and --agent are required."
    exit 1
fi

# --- 2. DETERMINISTIC SUBNET GENERATION ---
# Hash the VM name into a unique integer between 10 and 250
SUBNET_OCTET=$(echo "$VM_NAME" | cksum | awk '{print ($1 % 240) + 10}')

BRIDGE_IP="192.168.${SUBNET_OCTET}.1"
STATIC_VM_IP="192.168.${SUBNET_OCTET}.100"

echo "======================================================="
echo " [~] INITIALIZING VAULT FORGE: $VM_NAME ($AGENT_TYPE)"
echo " [~] Allocated Subnet: 192.168.${SUBNET_OCTET}.0/24"
echo "======================================================="

case "$AGENT_TYPE" in
    aider|pi-local)
        NET_TYPE="airgap"
        SHARE_DIR="$BASE_DIR/$VM_NAME"
        ;;
    ag|claude|opencode|pi-cloud)
        NET_TYPE="blind-nat"
        SHARE_DIR="$BASE_DIR/${VM_NAME}_workspace"

        if [ -z "$API_KEY" ]; then
            echo "[!] Error: Agent '$AGENT_TYPE' requires an API key (--key=...)"
            exit 1
        fi
        ;;
    *)
        echo "[!] Error: Unknown agent type '$AGENT_TYPE'."
        exit 1
        ;;
esac

# --- 3. CORE FUNCTIONS ---

setup_host() {
    echo "[-] Phase 1: Configuring Host Infrastructure..."

    echo -n "    -> Installing host packages... "
    apt update -yqq > /dev/null 2>&1
    #apt install -yqq qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager virtiofsd iptables sshpass > /dev/null 2>&1
    apt install -yqq qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager iptables sshpass > /dev/null 2>&1
    echo "OK"

    mkdir -p "$SHARE_DIR"
    chown "$TARGET_USER:libvirt-qemu" "$SHARE_DIR"
    chmod 2775 "$SHARE_DIR"
    chmod o+x "$BASE_DIR"

    # Git Trust
    sudo -u "$TARGET_USER" git config --global --unset-all safe.directory "^${SHARE_DIR}/\\*$" 2>/dev/null || true
    sudo -u "$TARGET_USER" git config --global --add safe.directory "$SHARE_DIR/*"

    # Master Hook Infrastructure
    mkdir -p /etc/libvirt/hooks/network.d
    cat << 'EOF' | tee /etc/libvirt/hooks/network > /dev/null
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
    chmod +x /etc/libvirt/hooks/network

    # Agent-Specific Network Hook
    echo "    -> Writing $NET_TYPE firewall topology... OK"
    if [ "$NET_TYPE" == "airgap" ]; then
        cat << EOF | tee /etc/libvirt/hooks/network.d/$VM_NAME > /dev/null
#!/bin/bash
HOOK_NETWORK="\$1"
ACTION="\$2"
if [ "\$HOOK_NETWORK" == "$VM_NAME" ]; then
    if [ "\$ACTION" == "started" ]; then
        iptables -I LIBVIRT_INP 1 -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 2 -i "\$HOOK_NETWORK" -p tcp --dport 11434 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 3 -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 4 -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 5 -i "\$HOOK_NETWORK" -p tcp -m state --state NEW -j DROP 2>/dev/null
        # Absolute egress drop for NAT-enabled airgaps
        iptables -I FORWARD 1 -i "\$HOOK_NETWORK" -j DROP 2>/dev/null
    elif [ "\$ACTION" == "stopped" ]; then
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p tcp --dport 11434 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -p tcp -m state --state NEW -j DROP 2>/dev/null || true
        iptables -D FORWARD -i "\$HOOK_NETWORK" -j DROP 2>/dev/null || true
    fi
fi
EOF
    else
        cat << EOF | tee /etc/libvirt/hooks/network.d/$VM_NAME > /dev/null
#!/bin/bash
HOOK_NETWORK="\$1"
ACTION="\$2"
if [ "\$HOOK_NETWORK" == "$VM_NAME" ]; then
    if [ "\$ACTION" == "started" ]; then
        iptables -I LIBVIRT_INP 1 -i "\$HOOK_NETWORK" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 2 -i "\$HOOK_NETWORK" -p udp --dport 67 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 3 -i "\$HOOK_NETWORK" -p udp --dport 53 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 4 -i "\$HOOK_NETWORK" -p tcp --dport 53 -j ACCEPT 2>/dev/null
        iptables -I LIBVIRT_INP 5 -i "\$HOOK_NETWORK" -j DROP 2>/dev/null

        # Isolation blocks
        iptables -I FORWARD 1 -i "\$HOOK_NETWORK" -d 192.168.0.0/16 -j DROP 2>/dev/null
        iptables -I FORWARD 2 -i "\$HOOK_NETWORK" -d 10.0.0.0/8 -j DROP 2>/dev/null
        iptables -I FORWARD 3 -i "\$HOOK_NETWORK" -d 172.16.0.0/12 -j DROP 2>/dev/null

        # WAN access for package servers and OpenRouter API
        iptables -I FORWARD 4 -i "\$HOOK_NETWORK" -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null
        iptables -I FORWARD 5 -i "\$HOOK_NETWORK" -j DROP 2>/dev/null
    elif [ "\$ACTION" == "stopped" ]; then
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
    fi

    chmod +x /etc/libvirt/hooks/network.d/$VM_NAME
    systemctl restart libvirtd
    usermod -aG libvirt,kvm "$TARGET_USER"
}

build_vm() {
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "[-] Phase 2: Auditing Base OS... VM already exists. Skipping."
        return
    fi

    echo -n "[-] Phase 2: Building Base OS (This takes a few minutes)... "
    DISK_PATH="/spool/vms/libvirt/${VM_NAME}.qcow2"
    mkdir -p /spool/vms/libvirt
    BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
    ISO_FILE=$(curl -s "$BASE_URL" | grep -Eo 'debian-[0-9\.]+-amd64-netinst\.iso' | head -n 1)
    ISO_URL="${BASE_URL}${ISO_FILE}"
    ISO_PATH="/tmp/${ISO_FILE}"
    MAJOR_VERSION=$(echo "$ISO_FILE" | grep -oE 'debian-[0-9]+' | grep -oE '[0-9]+')
    LOG="/tmp/vault_os_install.log"

    if [ ! -f "$ISO_PATH" ]; then curl -s -L -o "$ISO_PATH" "$ISO_URL"; fi

    cat <<EOF > /tmp/preseed.cfg
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $VM_NAME
d-i netcfg/get_domain string localdomain
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i passwd/root-login boolean false
d-i passwd/user-fullname string agent
d-i passwd/username string agent
d-i passwd/user-password password $PASSWORD
d-i passwd/user-password-again password $PASSWORD
d-i clock-setup/utc boolean true
d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard
d-i pkgsel/include string python3-pip python3-venv git curl build-essential python3-dev openssh-server qemu-guest-agent unzip ripgrep fd-find
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda
d-i preseed/late_command string in-target sh -c 'sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8\"/" /etc/default/grub; update-grub; systemctl enable serial-getty@ttyS0.service; echo "agent ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent; chmod 0440 /etc/sudoers.d/agent'
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF

    virt-install --name "$VM_NAME" --ram 4096 --vcpus 2 \
        --memorybacking access.mode=shared \
        --disk path=$DISK_PATH,size=7 \
        --os-variant "debian${MAJOR_VERSION}" \
        --network network=default \
        --location "$ISO_PATH" \
        --initrd-inject=/tmp/preseed.cfg \
        --extra-args "auto=true priority=critical console=ttyS0,115200n8" \
        --graphics none --wait -1 --noreboot --quiet > "$LOG" 2>&1 || { echo "FAIL! Check $LOG"; exit 1; }

    echo "OK"
}

hunt_for_ip() {
    echo -n "    -> Polling Libvirt for active SSH daemon... "
    VM_IP=""
    for i in {1..40}; do
        sleep 3
        # Grab IP from Libvirt
        TEMP_IP=$(virsh domifaddr "$VM_NAME" | grep -oE "192\.168\.[0-9]+\.[0-9]+" | head -n 1)
        if [ ! -z "$TEMP_IP" ]; then
            # We MUST use sshpass here because the SSH keys haven't been copied yet!
            if sudo -u "$TARGET_USER" sshpass -p "$PASSWORD" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q agent@$TEMP_IP exit 2>/dev/null; then
                VM_IP="$TEMP_IP"
                echo "Connected ($VM_IP)"
                break
            fi
        fi
    done

    if [ -z "$VM_IP" ]; then
        echo "FAILED"
        echo "[!] Error: Could not establish SSH connection to the VM."
        exit 1
    fi
}

provision_software() {
    echo "[-] Phase 3: Provisioning Agent Software..."

    if ! virsh list | grep -q " $VM_NAME .*running"; then
        virsh start "$VM_NAME" > /dev/null 2>&1
    fi

    if [ ! -f "$SSH_KEY" ]; then
        sudo -u "$TARGET_USER" ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    fi

    hunt_for_ip

    sudo -u "$TARGET_USER" sshpass -p "$PASSWORD" ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null agent@$VM_IP 2>/dev/null || true

    cat <<EOF > /tmp/remote_deploy.sh
#!/bin/bash
set -e
# Force non-interactive mode to prevent agent installers from hanging the SSH pipe
export DEBIAN_FRONTEND=noninteractive
export CI=true
LOG="/tmp/vault_install.log"

echo "    -> Logging execution inside VM to \$LOG"

echo -n "    -> Updating APT & system packages... "
sudo apt-get update -yqq > \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo apt-get install -yqq curl git build-essential unzip ripgrep fd-find >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Generating secure .bashrc profile... "
touch /home/agent/.bashrc
sed -i '/--- VAULT ENV ---/d' /home/agent/.bashrc
echo "# --- VAULT ENV ---" >> /home/agent/.bashrc
echo 'export PATH="\$HOME/.local/bin:/home/agent/bin:\$PATH"' >> /home/agent/.bashrc
echo "OK"
EOF

    if [[ "$AGENT_TYPE" == "claude" || "$AGENT_TYPE" == "pi-cloud" || "$AGENT_TYPE" == "pi-local" ]]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Injecting Node.js v22 Environment... "
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo apt-get install -y nodejs >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
    fi

    if [ "$AGENT_TYPE" == "aider" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Installing Astral UV & Sandboxing Aider... "
sudo -i -u agent curl -LsSf https://astral.sh/uv/install.sh | sudo -i -u agent sh >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo -i -u agent /home/agent/.local/bin/uv tool install --python 3.12 aider-chat >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export OLLAMA_API_BASE="http://$BRIDGE_IP:11434"' >> /home/agent/.bashrc
echo 'export AIDER_ANALYTICS=false' >> /home/agent/.bashrc
echo "OK"
EOF
    elif [ "$AGENT_TYPE" == "ag" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Installing Antigravity Engine... "
sudo -i -u agent curl -fsSL https://antigravity.google/cli/install.sh | bash >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export GEMINI_API_KEY="$API_KEY"' >> /home/agent/.bashrc
echo "OK"
EOF
    elif [ "$AGENT_TYPE" == "claude" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Deploying Claude CLI Sandbox... "
sudo npm install -g @anthropic-ai/claude-code >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export OPENROUTER_API_KEY="$API_KEY"' >> /home/agent/.bashrc
echo 'export ANTHROPIC_BASE_URL="https://openrouter.ai/api"' >> /home/agent/.bashrc
echo 'export ANTHROPIC_AUTH_TOKEN="\$OPENROUTER_API_KEY"' >> /home/agent/.bashrc
echo 'export ANTHROPIC_API_KEY=""' >> /home/agent/.bashrc
# Kill Claude's interactive pre-flight checks
echo 'export skipWebFetchPreflight=true' >> /home/agent/.bashrc
echo 'export DO_NOT_TRACK=1' >> /home/agent/.bashrc
echo "OK"
EOF
    elif [ "$AGENT_TYPE" == "opencode" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Compiling OpenCode Binary... "
sudo -i -u agent curl -fsSL https://opencode.ai/install | bash >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export OPENROUTER_API_KEY="$API_KEY"' >> /home/agent/.bashrc
echo 'export OPENCODE_DEFAULT_PROVIDER="openrouter"' >> /home/agent/.bashrc
echo "OK"
EOF
    elif [ "$AGENT_TYPE" == "pi-cloud" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Bootstrapping Pi Cloud Engine... "
sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export OPENROUTER_API_KEY="$API_KEY"' >> /home/agent/.bashrc
echo "OK"
EOF
    elif [ "$AGENT_TYPE" == "pi-local" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Bootstrapping Pi Local Engine... "
sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo 'export OLLAMA_API_BASE="http://$BRIDGE_IP:11434"' >> /home/agent/.bashrc
echo "OK"
EOF
    fi

    sudo -u "$TARGET_USER" scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_deploy.sh agent@$VM_IP:/tmp/
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null agent@$VM_IP "bash /tmp/remote_deploy.sh"

    echo "    -> Gracefully shutting down VM to map hardware..."
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null agent@$VM_IP "sudo poweroff" || true

    # Block script execution until the VM is fully offline
    while virsh list | grep -q " $VM_NAME .*running"; do
        sleep 2
    done
}

mount_workspace() {
    echo "[-] Phase 4: Establishing virtiofs Link..."

    cat <<EOF > /tmp/fs_${VM_NAME}.xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='$SHARE_DIR'/>
  <target dir='vault_share'/>
</filesystem>
EOF
    virsh attach-device "$VM_NAME" "/tmp/fs_${VM_NAME}.xml" --config > /dev/null 2>&1 || true

    virsh start "$VM_NAME" > /dev/null 2>&1
    hunt_for_ip

    cat <<EOF > /tmp/remote_mount.sh
#!/bin/bash
set -e
LOG="/tmp/vault_mount.log"
echo -n "    -> Injecting mount point into fstab... "
GUEST_FOLDER="\$(basename $SHARE_DIR)"
mkdir -p /home/agent/\$GUEST_FOLDER
sudo sed -i '/vault_share/d' /etc/fstab
echo "vault_share /home/agent/\$GUEST_FOLDER virtiofs x-systemd.automount,rw,nofail 0 0" | sudo tee -a /etc/fstab > /dev/null
echo "OK"

echo -n "    -> Triggering systemd daemon reload... "
sudo systemctl daemon-reload > \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo systemctl restart local-fs.target > \$LOG 2>&1 || true
sudo chown agent:agent /home/agent/\$GUEST_FOLDER
echo "OK"
EOF

    sudo -u "$TARGET_USER" scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_mount.sh agent@$VM_IP:/tmp/
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null agent@$VM_IP "bash /tmp/remote_mount.sh"

    echo "    -> Gracefully shutting down VM for final sealing..."
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null agent@$VM_IP "sudo poweroff" || true

    while virsh list | grep -q " $VM_NAME .*running"; do
        sleep 2
    done
}

seal_vault() {
    echo -n "[-] Phase 5: Mathematically Sealing Network... "

    VM_MAC=$(virsh dumpxml "$VM_NAME" | grep "mac address" | head -n 1 | awk -F\' '{print $2}')

    cat <<EOF > /tmp/${VM_NAME}-net.xml
<network>
  <name>$VM_NAME</name>
  <bridge name='$VM_NAME' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BRIDGE_IP%.*}.2' end='${BRIDGE_IP%.*}.254'/>
      <host mac='$VM_MAC' name='$VM_NAME' ip='$STATIC_VM_IP'/>
    </dhcp>
  </ip>
</network>
EOF

    virsh net-destroy "$VM_NAME" > /dev/null 2>&1 || true
    virsh net-undefine "$VM_NAME" > /dev/null 2>&1 || true
    virsh net-define /tmp/${VM_NAME}-net.xml > /dev/null 2>&1
    virsh net-start "$VM_NAME" > /dev/null 2>&1
    virsh net-autostart "$VM_NAME" > /dev/null 2>&1

    if [[ "$AGENT_TYPE" == "aider" || "$AGENT_TYPE" == "pi-local" ]]; then
        cat <<EOF > /etc/systemd/system/ollama-relay-${VM_NAME}.service
[Unit]
Description=Ollama Relay for $VM_NAME
After=network.target libvirtd.service
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:11434,bind=$BRIDGE_IP,reuseaddr,fork TCP:127.0.0.1:11434
Restart=always
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ollama-relay-${VM_NAME}.service > /dev/null 2>&1
    fi

    # Swap the VM to the permanent vault network
    virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}_config.xml
    sed -i -E "s/<source network=['\"][^'\"]+['\"](\s*\/)?>/<source network='$VM_NAME'\/>/g" /tmp/${VM_NAME}_config.xml
    virsh define /tmp/${VM_NAME}_config.xml > /dev/null 2>&1

    virsh start "$VM_NAME" > /dev/null 2>&1
    echo "OK"

    SSH_CONFIG_DIR="$BASE_DIR/.ssh"
    if ! grep -q "Host $VM_NAME" "$SSH_CONFIG_DIR/config" 2>/dev/null; then
        cat <<EOF >> "$SSH_CONFIG_DIR/config"
Host $VM_NAME
    HostName $STATIC_VM_IP
    User agent
    IdentityFile $SSH_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        chown "$TARGET_USER:$TARGET_USER" "$SSH_CONFIG_DIR/config"
        chmod 600 "$SSH_CONFIG_DIR/config"
    fi
}

# --- EXECUTION ---
setup_host
build_vm
provision_software
mount_workspace
seal_vault

echo ""
echo "[+] DEPLOYMENT COMPLETE. Vault is running."
echo "    Agent deployed: $AGENT_TYPE"
echo "    Subnet:         192.168.${SUBNET_OCTET}.0/24"
echo "    Access it via:  ssh $VM_NAME"