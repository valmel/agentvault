#!/bin/bash
# forge.sh - The Parametric Agentic Vault Builder

set -e

# --- 1. ARGUMENT PARSING & STATE ---
if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo ./forge.sh --agent=<aider|antigravity|claude|opencode|pi|deepseek> [ options ]"
  exit 1
fi

TARGET_USER="${SUDO_USER:-$1}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" == "root" ]; then
    echo "[!] Error: Could not determine the target non-root user."
    exit 1
fi

BASE_DIR="/home/$TARGET_USER"
CONFIG_DIR="$BASE_DIR/.config/agentvault"
CONFIG_FILE="$CONFIG_DIR/forge.conf"
PROXY_CONF_DIR="/etc/agentvault"

# --- 2. THE HYBRID CONFIGURATION SYSTEM ---

# A. Set absolute fallback defaults
IMAGE_DIR="/var/lib/libvirt/images"
VM_RAM="4096"
VM_VCPUS="2"
VM_DISK_SIZE="7"
GUEST_USER="agent"
GUEST_PASS="password123"
SUBNET_PREFIX="192.168"
VAULT_PORT="9931"
NODE_VERSION="22.x"
PYTHON_VERSION="3.12"
LOCAL_DUMMY_KEY="sk-local"

# B. Auto-generate config file if missing
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[-] Generating default configuration at $CONFIG_FILE..."
    mkdir -p "$CONFIG_DIR"
    cat <<EOF > "$CONFIG_FILE"
# =================================================================
# FORGE VAULT CONFIGURATION (~/.config/agentvault/forge.conf)
# Edit these variables to change the default behavior of forge.sh
# =================================================================

# Storage & Paths
IMAGE_DIR="$IMAGE_DIR"  # Standard libvirt path

# Default Hardware Specs (Can be overridden via CLI)
VM_RAM="$VM_RAM"          # Memory in MB
VM_VCPUS="$VM_VCPUS"      # Core count
VM_DISK_SIZE="$VM_DISK_SIZE" # Disk size in GB

# Guest User
GUEST_USER="$GUEST_USER"
GUEST_PASS="$GUEST_PASS"

# Networking
SUBNET_PREFIX="$SUBNET_PREFIX"
VAULT_PORT="$VAULT_PORT"

# Agent Toolchains
NODE_VERSION="$NODE_VERSION"
PYTHON_VERSION="$PYTHON_VERSION"
LOCAL_DUMMY_KEY="$LOCAL_DUMMY_KEY"
EOF
    chown -R "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"
    chmod 644 "$CONFIG_FILE"
fi

# C. Source the config file (Overrides fallbacks)
source "$CONFIG_FILE"

# D. Parse CLI Arguments (Overrides everything)
SSH_KEY="$BASE_DIR/.ssh/id_ed25519"
VM_NAME=""
AGENT_TYPE=""
VAULT_TYPE="airgapped"
PROVIDER="llama"
API_KEY=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --agent=*) AGENT_TYPE="${1#*=}" ;;
        --provider=*) PROVIDER="${1#*=}" ;;
        --type=*) VAULT_TYPE="${1#*=}" ;;
        --key=*) API_KEY="${1#*=}" ;;
        --ram=*) VM_RAM="${1#*=}" ;;
        --vcpus=*) VM_VCPUS="${1#*=}" ;;
        --disk=*) VM_DISK_SIZE="${1#*=}" ;;
        --name=*) VM_NAME="${1#*=}" ;;
        -h|--help)
            echo "Usage: sudo ./forge.sh [-h|--help] [Options]"
            echo "Options:"
            echo "  --agent=<agent>              aider|antigravity|claude|opencode|pi|deepseek (Required)"
            echo "  --provider=<service>         llama|ollama|vllm|openrouter|google|anthropic|openai (default: llama)"
            echo "  --type=<mode>                Network Posture: airgapped or restricted (default: airgapped)"
            echo "  --key=<api-key>              Required for cloud providers"
            echo "  --ram=<MB>                   Override default RAM (e.g., 8192)"
            echo "  --vcpus=<count>              Override default vCPUs (e.g., 4)"
            echo "  --disk=<GB>                  Override default disk size (e.g., 15)"
            echo "  --name=<name>                Override auto-generated vault name agent-provider-type"
            exit 0 ;;
    esac
    shift
done

# --- 3. LOGICAL INFERENCE & VALIDATION ---
if [ -z "$AGENT_TYPE" ]; then
    echo "[!] Error: --agent is required."
    exit 1
fi

case "$AGENT_TYPE" in
    aider|antigravity|claude|opencode|pi|deepseek) ;;
    *) echo "[!] Error: Invalid agent '$AGENT_TYPE'."; exit 1 ;;
esac

case "$PROVIDER" in
    llama|ollama|vllm|openrouter|google|anthropic|openai) ;;
    *) echo "[!] Error: Invalid provider '$PROVIDER'."; exit 1 ;;
esac

if [[ "$VAULT_TYPE" != "airgapped" && "$VAULT_TYPE" != "restricted" ]]; then
    echo "[!] Error: Invalid network posture type '$VAULT_TYPE'. Allowed values: airgapped, restricted."
    exit 1
fi

case "$PROVIDER" in
    openrouter|google|anthropic|openai) INFERENCE_LOC="cloud" ;;
    llama|ollama|vllm) INFERENCE_LOC="local" ;;
    *) INFERENCE_LOC="local" ;;
esac

if [[ "$INFERENCE_LOC" == "cloud" && "$VAULT_TYPE" == "airgapped" ]]; then
    echo "[!] Error: Cloud providers require internet access. You must use --type=restricted."
    exit 1
fi

if [[ "$AGENT_TYPE" == "antigravity" && "$PROVIDER" != "google" ]]; then
    echo "[~] Info: Antigravity requires Google provider. Forcing --provider=google."
    PROVIDER="google"
    INFERENCE_LOC="cloud"
    if [ "$VAULT_TYPE" == "airgapped" ]; then
        echo "[!] Error: Antigravity forced to Google, requiring --type=restricted."
        exit 1
    fi
fi

if [[ "$INFERENCE_LOC" == "cloud" && -z "$API_KEY" ]]; then
    echo "[!] Error: Cloud providers require an API key (--key=...)"
    exit 1
fi

# Auto-generate VM Name if omitted
if [ -z "$VM_NAME" ]; then
    VM_NAME="${AGENT_TYPE}-${PROVIDER}-${VAULT_TYPE}"
fi

# Define a safe network/bridge name under the 15-character Linux limit
NET_NAME="f-$(echo "$VM_NAME" | md5sum | cut -c1-10)"
ACL_ID="acl_$(echo "$VM_NAME" | md5sum | cut -c1-6)"

HARNESS_DIR="$BASE_DIR/harness_workspaces"
SHARE_DIR="$HARNESS_DIR/$VM_NAME"

if [ "$INFERENCE_LOC" == "local" ]; then
    case "$PROVIDER" in
        llama)    HOST_PORT=9931 ;;
        ollama)   HOST_PORT=11434 ;;
        vllm)     HOST_PORT=8000 ;;
        *)        HOST_PORT=9931 ;;
    esac
fi

SUBNET_OCTET=$(echo "$VM_NAME" | cksum | awk '{print ($1 % 240) + 10}')
BRIDGE_IP="${SUBNET_PREFIX}.${SUBNET_OCTET}.1"
STATIC_VM_IP="${SUBNET_PREFIX}.${SUBNET_OCTET}.100"

echo "======================================================="
echo " [~] INITIALIZING VAULT FORGE: $VM_NAME"
echo " [~] Agent:        $AGENT_TYPE"
echo " [~] Provider:     $PROVIDER ($INFERENCE_LOC)"
echo " [~] Privacy type: $VAULT_TYPE"
echo " [~] Hardware:     ${VM_VCPUS} vCPUs | ${VM_RAM}MB RAM | ${VM_DISK_SIZE}GB Disk"
if [ "$INFERENCE_LOC" == "local" ]; then
echo " [~] Engine Route: Host Port $HOST_PORT -> Vault Port $VAULT_PORT"
fi
echo " [~] Subnet:       ${SUBNET_PREFIX}.${SUBNET_OCTET}.0/24"
echo " [~] Workspace:    ~/harness_workspaces/$VM_NAME"
echo "======================================================="

# --- 4. CORE FUNCTIONS ---

setup_host() {
    echo "[-] Phase 1: Configuring Host Infrastructure..."
    echo -n "    -> Installing host packages... "
    apt update -yqq > /dev/null 2>&1
    #apt install -yqq qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager virtiofsd iptables sshpass > /dev/null 2>&1
    apt install -yqq qemu-kvm libvirt-daemon-system libvirt-clients virtinst socat curl virt-manager iptables sshpass dpkg-dev squid > /dev/null 2>&1
    echo "OK"

    echo -n "    -> Configuring Layer 7 Modular Proxy (Squid)... "
    mkdir -p "$PROXY_CONF_DIR/whitelists"
    mkdir -p /etc/squid/conf.d

    # Ensure base Squid config supports modular includes
    if ! grep -q "include /etc/squid/conf.d" /etc/squid/squid.conf 2>/dev/null; then
        cp /etc/squid/squid.conf /etc/squid/squid.conf.bak || true
        cat << 'EOF' > /etc/squid/squid.conf
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# === FORGE MODULAR VAULT INCLUDES ===
include /etc/squid/conf.d/*.conf

# Default block all
http_access deny all
http_port 0.0.0.0:8888
EOF
    fi

    # Generate the Least Privilege Whitelist for THIS vault
    cat << 'EOF' > "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt"
# --- Core OS Packages ---
.debian.org

# --- Python Ecosystem ---
.pypi.org
.pythonhosted.org

# --- Node Ecosystem ---
.npmjs.org
#.yarnpkg.com

# --- Microsoft / Code Hosting ---
# .github.com
# .githubusercontent.com
EOF

    # Add tool-specific domains
    if [ "$AGENT_TYPE" == "aider" ]; then echo ".astral.sh" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt"; fi

    # Add provider-specific domains (Cloud only)
    case "$PROVIDER" in
        google)     echo ".googleapis.com" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt" ;;
        anthropic)  echo ".anthropic.com" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt" ;;
        openai)     echo ".openai.com" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt" ;;
        openrouter) echo ".openrouter.ai" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt" ;;
        deepseek)   echo ".deepseek.com" >> "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt" ;;
    esac

    # Bind the whitelist to the vault's specific subnet
    cat << EOF > /etc/squid/conf.d/${VM_NAME}.conf
acl src_${ACL_ID} src ${SUBNET_PREFIX}.${SUBNET_OCTET}.0/24
acl wl_${ACL_ID} dstdomain "$PROXY_CONF_DIR/whitelists/${VM_NAME}.txt"
http_access allow src_${ACL_ID} wl_${ACL_ID}
EOF

    systemctl enable --now squid > /dev/null 2>&1
    systemctl reload squid
    echo "OK"

    # Set up master harness workspace directory
    mkdir -p "$HARNESS_DIR"
    chown "$TARGET_USER:$TARGET_USER" "$HARNESS_DIR"
    chmod 755 "$HARNESS_DIR"

    # Set up specific VM workspace
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

    echo "    -> Writing strict firewall topology... OK"
    # Note: Hook applies to the truncated NET_NAME to avoid bridge name length limits
    cat << EOF | tee /etc/libvirt/hooks/network.d/$NET_NAME > /dev/null
#!/bin/bash
HOOK_NETWORK="\$1"
ACTION="\$2"
FWD_CHAIN="VFWD_\$HOOK_NETWORK"
INP_CHAIN="VINP_\$HOOK_NETWORK"

if [ "\$HOOK_NETWORK" == "$NET_NAME" ]; then
    if [ "\$ACTION" == "started" ]; then
        # 1. FORWARD CHAIN (Egress Isolation)
        iptables -N "\$FWD_CHAIN" 2>/dev/null || iptables -F "\$FWD_CHAIN"
        iptables -C FORWARD -i "\$HOOK_NETWORK" -j "\$FWD_CHAIN" 2>/dev/null || iptables -I FORWARD 1 -i "\$HOOK_NETWORK" -j "\$FWD_CHAIN"

        # ALL routing is dropped. VM has no direct internet access.
        iptables -A "\$FWD_CHAIN" -j DROP

        # 2. INPUT CHAIN (Host Protection)
        iptables -N "\$INP_CHAIN" 2>/dev/null || iptables -F "\$INP_CHAIN"
        iptables -C LIBVIRT_INP -i "\$HOOK_NETWORK" -j "\$INP_CHAIN" 2>/dev/null || iptables -I LIBVIRT_INP 1 -i "\$HOOK_NETWORK" -j "\$INP_CHAIN"

        iptables -A "\$INP_CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A "\$INP_CHAIN" -p udp --dport 67 -j ACCEPT
        iptables -A "\$INP_CHAIN" -p udp --dport 53 -j ACCEPT
        iptables -A "\$INP_CHAIN" -p tcp --dport 53 -j ACCEPT
        iptables -A "\$INP_CHAIN" -p tcp --dport $VAULT_PORT -j ACCEPT

        if [ "$VAULT_TYPE" == "restricted" ]; then
            # Allow access to the Layer 7 Squid Proxy ONLY
            iptables -A "\$INP_CHAIN" -p tcp --dport 8888 -j ACCEPT
        fi

        iptables -A "\$INP_CHAIN" -p tcp -m state --state NEW -j DROP

    elif [ "\$ACTION" == "stopped" ]; then
        # Destroy FORWARD Custom Chain
        iptables -D FORWARD -i "\$HOOK_NETWORK" -j "\$FWD_CHAIN" 2>/dev/null || true
        iptables -F "\$FWD_CHAIN" 2>/dev/null || true
        iptables -X "\$FWD_CHAIN" 2>/dev/null || true

        # Destroy INPUT Custom Chain
        iptables -D LIBVIRT_INP -i "\$HOOK_NETWORK" -j "\$INP_CHAIN" 2>/dev/null || true
        iptables -F "\$INP_CHAIN" 2>/dev/null || true
        iptables -X "\$INP_CHAIN" 2>/dev/null || true
    fi
fi
EOF

    chmod +x /etc/libvirt/hooks/network.d/$NET_NAME
    systemctl restart libvirtd
    usermod -aG libvirt,kvm "$TARGET_USER"
}

build_vm() {
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "[-] Phase 2: Auditing Base OS... VM already exists. Skipping."
        return
    fi

    DISK_PATH="$IMAGE_DIR/${VM_NAME}.qcow2"
    GOLDEN_IMAGE="$IMAGE_DIR/debian-golden.qcow2"
    mkdir -p "$IMAGE_DIR"

    # Auto-build Golden Master if it doesn't exist yet
    if [ ! -f "$GOLDEN_IMAGE" ]; then
        echo "[-] Golden Master image not found. Building base Debian Golden Image (One-time installation)..."
        ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
        ISO_FILE=$(curl -s "$ISO_BASE_URL" | grep -Eo 'debian-[0-9\.]+-amd64-netinst\.iso' | head -n 1)
        ISO_URL="${ISO_BASE_URL}${ISO_FILE}"
        ISO_PATH="/tmp/${ISO_FILE}"
        MAJOR_VERSION=$(echo "$ISO_FILE" | grep -oE 'debian-[0-9]+' | grep -oE '[0-9]+')
        LOG="/tmp/vault_golden_install.log"

        if [ ! -f "$ISO_PATH" ]; then curl -s -L -o "$ISO_PATH" "$ISO_URL"; fi

        cat <<EOF > /tmp/preseed.cfg
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian-golden
d-i netcfg/get_domain string localdomain
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i passwd/root-login boolean false
d-i passwd/user-fullname string $GUEST_USER
d-i passwd/username string $GUEST_USER
d-i passwd/user-password password $GUEST_PASS
d-i passwd/user-password-again password $GUEST_PASS
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
d-i preseed/late_command string in-target sh -c 'sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8\"/" /etc/default/grub; update-grub; systemctl enable serial-getty@ttyS0.service; echo "$GUEST_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$GUEST_USER; chmod 0440 /etc/sudoers.d/$GUEST_USER'
d-i preseed/late_command string in-target sh -c 'sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8\"/" /etc/default/grub; update-grub; systemctl enable serial-getty@ttyS0.service; echo "$GUEST_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$GUEST_USER; chmod 0440 /etc/sudoers.d/$GUEST_USER; rm -f /etc/machine-id /var/lib/dbus/machine-id; touch /etc/machine-id'
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF

        virt-install --name "debian-golden-builder" --ram "$VM_RAM" --vcpus "$VM_VCPUS" \
            --memorybacking access.mode=shared \
            --disk path="$GOLDEN_IMAGE",size="$VM_DISK_SIZE" \
            --os-variant "debian${MAJOR_VERSION}" \
            --network network=default \
            --location "$ISO_PATH" \
            --initrd-inject=/tmp/preseed.cfg \
            --extra-args "auto=true priority=critical console=ttyS0,115200n8" \
            --graphics none --wait -1 --noreboot --quiet > "$LOG" 2>&1 || { echo "FAIL! Check $LOG"; exit 1; }

        virsh undefine "debian-golden-builder" --nvram 2>/dev/null || virsh undefine "debian-golden-builder" 2>/dev/null || true
        echo "[-] Golden Master image successfully built."
    else
        ISO_BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
        ISO_FILE=$(curl -s "$ISO_BASE_URL" 2>/dev/null | grep -Eo 'debian-[0-9\.]+-amd64-netinst\.iso' | head -n 1 || echo "debian-12")
        MAJOR_VERSION=$(echo "$ISO_FILE" | grep -oE 'debian-[0-9]+' | grep -oE '[0-9]+' || echo "12")
    fi

    echo -n "[-] Phase 2: Spawning Instant Vault via Copy-On-Write (COW)... "
    # Create lightweight pointer overlay
    qemu-img create -f qcow2 -F qcow2 -b "$GOLDEN_IMAGE" "$DISK_PATH" "${VM_DISK_SIZE}G" > /dev/null 2>&1

    virt-install --name "$VM_NAME" --ram "$VM_RAM" --vcpus "$VM_VCPUS" \
        --memorybacking access.mode=shared \
        --disk path="$DISK_PATH",bus=virtio \
        --import \
        --os-variant "debian${MAJOR_VERSION}" \
        --network network=default \
        --graphics none --noautoconsole > /dev/null 2>&1

    echo "OK (Instant)"
}

hunt_for_ip() {
    echo -n "    -> Polling Libvirt for active SSH daemon... "
    VM_IP=""
    PREFIX_ESC="${SUBNET_PREFIX//./\.}"

    for i in {1..40}; do
        sleep 3
        TEMP_IP=$(virsh domifaddr "$VM_NAME" | grep -oE "${PREFIX_ESC}\.[0-9]+\.[0-9]+" | head -n 1)
        if [ ! -z "$TEMP_IP" ]; then
            if sudo -u "$TARGET_USER" sshpass -p "$GUEST_PASS" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q $GUEST_USER@$TEMP_IP exit 2>/dev/null; then
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
    sudo -u "$TARGET_USER" sshpass -p "$GUEST_PASS" ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $GUEST_USER@$VM_IP 2>/dev/null || true

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

echo -n "    -> Setting internal hostname... "
sudo sed -i 's/127.0.1.1.*/127.0.1.1\t'"$VM_NAME"'/g' /etc/hosts
sudo hostnamectl set-hostname "$VM_NAME"
echo "OK"

echo -n "    -> Generating idempotent environment profile... "
mkdir -p /home/$GUEST_USER/.config/agentvault

# 1. Hook .bashrc exactly once
if ! grep -q ".config/agentvault/env" /home/$GUEST_USER/.bashrc; then
    echo -e "\n# Forge Vault Environment Hook\nsource /home/$GUEST_USER/.config/agentvault/env" >> /home/$GUEST_USER/.bashrc
fi

# 2. Overwrite env entirely from scratch (Idempotent wipe)
cat << 'ENVEOF' > /home/$GUEST_USER/.config/agentvault/env
# ==========================================
# AUTO-GENERATED FORGE ENVIRONMENT
# Do not edit. Overwritten on provision.
# ==========================================
export PATH="\$HOME/.local/bin:/home/$GUEST_USER/bin:\$PATH"
export DO_NOT_TRACK=1
export AIDER_ANALYTICS=false
export skipWebFetchPreflight=true
ENVEOF

EOF

    if [ "$VAULT_TYPE" == "restricted" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo 'export HTTP_PROXY="http://$BRIDGE_IP:8888"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export HTTPS_PROXY="http://$BRIDGE_IP:8888"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export http_proxy="http://$BRIDGE_IP:8888"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export https_proxy="http://$BRIDGE_IP:8888"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
    fi

    cat <<EOF >> /tmp/remote_deploy.sh
chown -R $GUEST_USER:$GUEST_USER /home/$GUEST_USER/.config
echo "OK"
EOF

    # --- INJECT PREREQUISITES ---
    if [[ "$AGENT_TYPE" =~ ^(claude|pi|deepseek)$ ]]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Injecting Node.js $NODE_VERSION Environment... "
curl -fsSL https://deb.nodesource.com/setup_$NODE_VERSION | sudo -E bash - >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo apt-get install -y nodejs >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
    fi

    # --- INJECT AGENT TOOLS ---
    case "$AGENT_TYPE" in
        aider)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Installing Astral UV & Sandboxing Aider... "
sudo -i -u $GUEST_USER curl -LsSf https://astral.sh/uv/install.sh | sudo -i -u $GUEST_USER sh >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo -i -u $GUEST_USER /home/$GUEST_USER/.local/bin/uv tool install --python $PYTHON_VERSION aider-chat >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
        antigravity)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Installing Antigravity Engine... "
sudo -i -u $GUEST_USER curl -fsSL https://antigravity.google/cli/install.sh | bash >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
        claude)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Deploying Claude CLI Sandbox... "
sudo npm install -g @anthropic-ai/claude-code >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
        opencode)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Compiling OpenCode Binary... "
sudo -i -u $GUEST_USER curl -fsSL https://opencode.ai/install | bash >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
        pi)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Bootstrapping Pi Coding Agent... "
sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
        deepseek)
            cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Bootstrapping DeepSeek Harness... "
sudo npm install -g --ignore-scripts @deepseek-ai/dsh >> \$LOG 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"
EOF
            ;;
    esac

    # --- LOCK PROXIES ---
    if [ "$VAULT_TYPE" == "restricted" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo -n "    -> Locking Package Managers (APT, NPM, PIP) to Squid... "
EOF

        # Lock NPM (if applicable)
        if [[ "$AGENT_TYPE" =~ ^(claude|pi|deepseek)$ ]]; then
            cat <<EOF >> /tmp/remote_deploy.sh
sudo npm config set proxy http://$BRIDGE_IP:8888 >> \$LOG 2>&1
sudo npm config set https-proxy http://$BRIDGE_IP:8888 >> \$LOG 2>&1
EOF
        fi

        # Lock APT & PIP
        cat <<EOF >> /tmp/remote_deploy.sh
echo 'Acquire::http::Proxy "http://$BRIDGE_IP:8888";' | sudo tee /etc/apt/apt.conf.d/00proxy > /dev/null
echo 'Acquire::https::Proxy "http://$BRIDGE_IP:8888";' | sudo tee -a /etc/apt/apt.conf.d/00proxy > /dev/null

sudo mkdir -p /etc
echo "[global]" | sudo tee /etc/pip.conf > /dev/null
echo "proxy = http://$BRIDGE_IP:8888" | sudo tee -a /etc/pip.conf > /dev/null
echo "OK"
EOF
    fi

    # --- INJECT ENVIRONMENT ROUTING INTO .config/agentvault/env ---
    echo -n "    -> Configuring AI Routing... "
    if [ "$INFERENCE_LOC" == "local" ]; then
        cat <<EOF >> /tmp/remote_deploy.sh
echo 'export OPENAI_API_BASE="http://$BRIDGE_IP:$VAULT_PORT/v1"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export OPENAI_API_KEY="$LOCAL_DUMMY_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export ANTHROPIC_BASE_URL="http://$BRIDGE_IP:$VAULT_PORT/v1"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export ANTHROPIC_API_KEY="$LOCAL_DUMMY_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export DEEPSEEK_BASE_URL="http://$BRIDGE_IP:$VAULT_PORT/v1"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export DEEPSEEK_API_KEY="$LOCAL_DUMMY_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
    else
        case "$PROVIDER" in
            google)
                cat <<EOF >> /tmp/remote_deploy.sh
echo 'export GEMINI_API_KEY="$API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export AIDER_MODEL="gemini/gemini-2.5-pro"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export OPENCODE_DEFAULT_PROVIDER="google"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export PI_DEFAULT_PROVIDER="google"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
                ;;
            anthropic)
                cat <<EOF >> /tmp/remote_deploy.sh
echo 'export ANTHROPIC_API_KEY="$API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export AIDER_MODEL="anthropic/claude-3-5-sonnet-20241022"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export OPENCODE_DEFAULT_PROVIDER="anthropic"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export PI_DEFAULT_PROVIDER="anthropic"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
                ;;
            openai)
                cat <<EOF >> /tmp/remote_deploy.sh
echo 'export OPENAI_API_KEY="$API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export AIDER_MODEL="openai/gpt-4o"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export OPENCODE_DEFAULT_PROVIDER="openai"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export PI_DEFAULT_PROVIDER="openai"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
                ;;
            *)
                cat <<EOF >> /tmp/remote_deploy.sh
echo 'export OPENROUTER_API_KEY="$API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export ANTHROPIC_BASE_URL="https://openrouter.ai/api"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export ANTHROPIC_AUTH_TOKEN="\$OPENROUTER_API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export ANTHROPIC_API_KEY=""' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export AIDER_MODEL="openrouter/anthropic/claude-3.5-sonnet"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export OPENCODE_DEFAULT_PROVIDER="openrouter"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export PI_DEFAULT_PROVIDER="openrouter"' >> /home/$GUEST_USER/.config/agentvault/env
echo 'export DEEPSEEK_API_KEY="$API_KEY"' >> /home/$GUEST_USER/.config/agentvault/env
EOF
                ;;
        esac
    fi
    cat <<EOF >> /tmp/remote_deploy.sh
echo "OK"
EOF

    sudo -u "$TARGET_USER" scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_deploy.sh $GUEST_USER@$VM_IP:/tmp/
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $GUEST_USER@$VM_IP "bash /tmp/remote_deploy.sh"

    echo "    -> Gracefully shutting down VM to map hardware..."
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $GUEST_USER@$VM_IP "sudo poweroff" || true
    while virsh list | grep -q " $VM_NAME .*running"; do sleep 2; done
}

mount_workspace() {
    echo "[-] Phase 4: Establishing virtiofs Link..."

    # 1. Attach the Workspace
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

echo -n "    -> Injecting mount points into fstab... "
GUEST_FOLDER="\$(basename $SHARE_DIR)"
mkdir -p /home/$GUEST_USER/\$GUEST_FOLDER
sudo sed -i '/vault_share/d' /etc/fstab

# Mount Workspace (Read/Write)
echo "vault_share /home/$GUEST_USER/\$GUEST_FOLDER virtiofs x-systemd.automount,rw,nofail 0 0" | sudo tee -a /etc/fstab > /dev/null
echo "OK"

echo -n "    -> Triggering systemd daemon reload... "
sudo systemctl daemon-reload > \$LOG 2>&1 || { echo "FAIL"; exit 1; }
sudo systemctl restart local-fs.target > \$LOG 2>&1 || true
sudo chown $GUEST_USER:$GUEST_USER /home/$GUEST_USER/\$GUEST_FOLDER
echo "OK"
EOF

    sudo -u "$TARGET_USER" scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null /tmp/remote_mount.sh $GUEST_USER@$VM_IP:/tmp/
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $GUEST_USER@$VM_IP "bash /tmp/remote_mount.sh"

    echo "    -> Gracefully shutting down VM for final sealing..."
    sudo -u "$TARGET_USER" ssh -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $GUEST_USER@$VM_IP "sudo poweroff" || true
    while virsh list | grep -q " $VM_NAME .*running"; do sleep 2; done
}

seal_vault() {
    echo -n "[-] Phase 5: Mathematically Sealing Network... "
    VM_MAC=$(virsh dumpxml "$VM_NAME" | grep "mac address" | head -n 1 | awk -F\' '{print $2}')

    cat <<EOF > /tmp/${NET_NAME}-net.xml
<network>
  <name>$NET_NAME</name>
  <bridge name='$NET_NAME' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='$BRIDGE_IP' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BRIDGE_IP%.*}.2' end='${BRIDGE_IP%.*}.254'/>
      <host mac='$VM_MAC' name='$VM_NAME' ip='$STATIC_VM_IP'/>
    </dhcp>
  </ip>
</network>
EOF

    virsh net-destroy "$NET_NAME" > /dev/null 2>&1 || true
    virsh net-undefine "$NET_NAME" > /dev/null 2>&1 || true
    virsh net-define /tmp/${NET_NAME}-net.xml > /dev/null 2>&1
    virsh net-start "$NET_NAME" > /dev/null 2>&1
    virsh net-autostart "$NET_NAME" > /dev/null 2>&1

    if [ "$INFERENCE_LOC" == "local" ]; then
        SERVICE_NAME="${PROVIDER}-relay-${VM_NAME}.service"
        cat <<EOF > /etc/systemd/system/${SERVICE_NAME}
[Unit]
Description=Inference Engine Relay for $VM_NAME ($PROVIDER)
After=network.target libvirtd.service
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:$VAULT_PORT,bind=$BRIDGE_IP,reuseaddr,fork TCP:127.0.0.1:$HOST_PORT
Restart=always
DynamicUser=yes
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now ${SERVICE_NAME} > /dev/null 2>&1
    fi

    # Swap the VM to the permanent vault network
    virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}_config.xml
    sed -i -E "s/<source network=['\"][^'\"]+['\"](\s*\/)?>/<source network='$NET_NAME'\/>/g" /tmp/${VM_NAME}_config.xml
    virsh define /tmp/${VM_NAME}_config.xml > /dev/null 2>&1

    virsh start "$VM_NAME" > /dev/null 2>&1
    echo "OK"

    SSH_CONFIG_DIR="$BASE_DIR/.ssh"
    if ! grep -q "Host $VM_NAME" "$SSH_CONFIG_DIR/config" 2>/dev/null; then
        cat <<EOF >> "$SSH_CONFIG_DIR/config"
Host $VM_NAME
    HostName $STATIC_VM_IP
    User $GUEST_USER
    IdentityFile $SSH_KEY
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
        chown "$TARGET_USER:$TARGET_USER" "$SSH_CONFIG_DIR/config"
        chmod 600 "$SSH_CONFIG_DIR/config"
    fi
}

setup_host
build_vm
provision_software
mount_workspace
seal_vault

echo ""
echo "[+] DEPLOYMENT COMPLETE. Vault is running."
echo "    Access it via:  ssh $VM_NAME"