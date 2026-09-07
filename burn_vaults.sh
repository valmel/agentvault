#!/bin/bash
# burn-vaults.sh - Surgically vaporize AgentVaults without touching other VMs

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo ./burn-vaults.sh"
  exit 1
fi

# Strict regex matching the exact AgentVault naming combinations
VAULT_REGEX="^(aider|antigravity|claude|opencode|pi|deepseek)-(llama|ollama|vllm|openrouter|google|anthropic|openai)-(airgapped|restricted)$"

echo "======================================================="
echo " [!] SURGICALLY VAPORIZING AGENT VAULTS"
echo "======================================================="

# 1. Find matching VMs
TARGET_VMS=()
for dom in $(virsh list --all --name); do
    if [[ "$dom" =~ $VAULT_REGEX ]]; then
        TARGET_VMS+=("$dom")
    fi
done

if [ ${#TARGET_VMS[@]} -eq 0 ]; then
    echo "[+] No AgentVault VMs found matching the standard naming convention."
    echo "    (Other system VMs were ignored). Exiting."
    exit 0
fi

echo "[~] Found ${#TARGET_VMS[@]} vault(s) to destroy:"
for vm in "${TARGET_VMS[@]}"; do
    echo "    - $vm"
done
echo ""

# 2. Precision Teardown
for VM_NAME in "${TARGET_VMS[@]}"; do
    echo " -> Tearing down infrastructure for: $VM_NAME"
    NET_NAME="f-$(echo "$VM_NAME" | md5sum | cut -c1-10)"

    # A. Systemd relays
    for svc in /etc/systemd/system/*-relay-${VM_NAME}.service; do
        if [ -f "$svc" ]; then
            systemctl stop "$(basename "$svc")" 2>/dev/null || true
            systemctl disable "$(basename "$svc")" 2>/dev/null || true
            rm -f "$svc"
        fi
    done

    # B. Squid Proxies & Whitelists
    rm -f "/etc/agentvault/whitelists/${VM_NAME}.txt" 2>/dev/null || true
    rm -f "/etc/squid/conf.d/${VM_NAME}.conf" 2>/dev/null || true

    # C. Destroy the VM and its specific COW disk
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

    # D. Destroy the Network (This natively triggers the libvirt hook to clean iptables)
    if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
        virsh net-destroy "$NET_NAME" 2>/dev/null || true
        virsh net-undefine "$NET_NAME" 2>/dev/null || true
    fi

    # E. Remove the specific network hook
    rm -f "/etc/libvirt/hooks/network.d/$NET_NAME" 2>/dev/null || true

    # F. Fallback orphaned iptables cleanup (in case the hook failed)
    iptables -D FORWARD -i "$NET_NAME" -j "VFWD_$NET_NAME" 2>/dev/null || true
    iptables -D LIBVIRT_INP -i "$NET_NAME" -j "VINP_$NET_NAME" 2>/dev/null || true
    iptables -F "VFWD_$NET_NAME" 2>/dev/null || true
    iptables -X "VFWD_$NET_NAME" 2>/dev/null || true
    iptables -F "VINP_$NET_NAME" 2>/dev/null || true
    iptables -X "VINP_$NET_NAME" 2>/dev/null || true
done

# 3. Reload system daemons
systemctl daemon-reload
systemctl reload squid 2>/dev/null || true
systemctl restart libvirtd

# 4. Surgically clean up SSH config aliases
echo " -> Purging targeted SSH config blocks..."
for home in /home/*; do
    if [ -d "$home/.ssh" ]; then
        SSH_CONFIG="$home/.ssh/config"
        if [ -f "$SSH_CONFIG" ]; then
            # Dynamically build an awk regex out of the exact VM names we just deleted
            VM_PATTERN=$(IFS='|'; echo "${TARGET_VMS[*]}")

            awk -v pat="^($VM_PATTERN)$" '
            BEGIN { skip=0; block="" }
            /^([Hh][Oo][Ss][Tt][ \t]+)/ {
                if (!skip && block != "") { printf "%s", block }
                block = $0 "\n"
                if ($2 ~ pat) { skip = 1 } else { skip = 0 }
                next
            }
            { block = block $0 "\n" }
            END { if (!skip) { printf "%s", block } }
            ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"

            TARGET_UID=$(stat -c '%u' "$home")
            TARGET_GID=$(stat -c '%g' "$home")
            chown "$TARGET_UID:$TARGET_GID" "$SSH_CONFIG"
            chmod 600 "$SSH_CONFIG"
        fi
    fi
done

echo ""
echo "[+] PURGE COMPLETE. AgentVault infrastructure removed."
echo "    (Note: ~/harness_workspaces directories were left intact to prevent code loss)."