#!/bin/bash
# 02_build_vm.sh

if [ -z "$1" ]; then
    echo "Error: You must provide a name for the Vault."
    echo "Usage: sudo ./02_build_vm.sh <vm-name>"
    exit 1
fi

VM_NAME="$1"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
#DISK_PATH="/spool/vms/libvirt/${VM_NAME}.qcow2"

BASE_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
ISO_FILE=$(curl -s "$BASE_URL" | grep -Eo 'debian-[0-9\.]+-amd64-netinst\.iso' | head -n 1)
ISO_URL="${BASE_URL}${ISO_FILE}"
ISO_PATH="/tmp/${ISO_FILE}"

MAJOR_VERSION=$(echo "$ISO_FILE" | grep -oE 'debian-[0-9]+' | grep -oE '[0-9]+')
OS_VARIANT="debian${MAJOR_VERSION}"

echo "[-] Auto-detected Stable Release: Debian ${MAJOR_VERSION}"
echo "[-] Target Hypervisor Profile:   ${OS_VARIANT}"

USERNAME="agent"
PASSWORD="password123"

# 1. GENERATE DUMB PRESEED (OS & SSH Only)
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
d-i passwd/user-fullname string $USERNAME
d-i passwd/username string $USERNAME
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

# Core system essentials. We let 'uv' handle Python environment isolation later.
# And we install OpenSSH here so we can remotely configure it in Phase 2
d-i pkgsel/include string \
    python3-pip \
    python3-venv \
    git \
    curl \
    build-essential \
    python3-dev \
    openssh-server \
    qemu-guest-agent
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda

# Configure serial console and inject passwordless sudo
d-i preseed/late_command string in-target sh -c '\
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT.*/GRUB_CMDLINE_LINUX_DEFAULT=\"console=ttyS0,115200n8\"/" /etc/default/grub; \
    update-grub; \
    systemctl enable serial-getty@ttyS0.service; \
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USERNAME; \
    chmod 0440 /etc/sudoers.d/$USERNAME'
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/poweroff boolean true
EOF

# 2. START PROVISIONING
if [ ! -f "$ISO_PATH" ]; then
    echo "[-] Downloading ${ISO_FILE}..."
    curl -L -o "$ISO_PATH" "$ISO_URL"
fi

echo "[-] Building the Base OS (Will power off when done)..."
virt-install \
  --name "$VM_NAME" \
  --ram 4096 \
  --vcpus 2 \
  --memorybacking access.mode=shared \
  --disk path=$DISK_PATH,size=7 \
  --os-variant "$OS_VARIANT" \
  --network network=default \
  --location "$ISO_PATH" \
  --initrd-inject=/tmp/preseed.cfg \
  --extra-args "auto=true priority=critical console=ttyS0,115200n8" \
  --graphics none \
  --wait -1