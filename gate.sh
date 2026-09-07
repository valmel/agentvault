#!/bin/bash
# gate.sh - Instant Egress Toggle for Vaults (Dead Man's Switch)

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo ./gate.sh <open|close> <vault-name>"
  exit 1
fi

ACTION="$1"
VAULT_NAME="$2"

if [[ "$ACTION" != "open" && "$ACTION" != "close" ]] || [ -z "$VAULT_NAME" ]; then
    echo "Usage: sudo ./gate.sh <open|close> <vault-name>"
    exit 1
fi

# Calculate the truncated network/bridge name used by forge.sh
NET_NAME="f-$(echo "$VAULT_NAME" | md5sum | cut -c1-10)"
HOOK_SCRIPT="/etc/libvirt/hooks/network.d/$NET_NAME"
FWD_CHAIN="VFWD_$NET_NAME"

if ! virsh net-info "$NET_NAME" &>/dev/null; then
    echo "[!] Error: Network '$NET_NAME' (for vault $VAULT_NAME) is not active."
    exit 1
fi

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "[!] Error: Topology hook not found for $VAULT_NAME ($NET_NAME)."
    exit 1
fi

close_gate() {
    echo ""
    echo "[x] Closing gate for $VAULT_NAME..."
    # Wipe the slate clean using the vault's own teardown logic
    "$HOOK_SCRIPT" "$NET_NAME" "stopped"

    # Restore the strict baseline topology
    "$HOOK_SCRIPT" "$NET_NAME" "started"
    echo "[x] GATE CLOSED. Baseline Airgap/Restricted Topology Restored."
}

if [ "$ACTION" == "close" ]; then
    close_gate
    exit 0
fi

if [ "$ACTION" == "open" ]; then
    # Clean the state first
    "$HOOK_SCRIPT" "$NET_NAME" "stopped"
    "$HOOK_SCRIPT" "$NET_NAME" "started"

    # Inject the internet override into the top of the vault's specific FORWARD chain
    iptables -I "$FWD_CHAIN" 1 -p tcp -m multiport --dports 80,443 -j ACCEPT

    echo "========================================================="
    echo " ⚠️  GATE OPENED FOR: $VAULT_NAME"
    echo "    Web (HTTP/HTTPS) allowed. LAN scanning still blocked."
    echo "========================================================="

    # Trap exit signals to ensure the gate closes no matter how the script dies
    trap close_gate EXIT

    echo "Press ENTER to manually close the gate."
    echo "Alternatively, it will auto-close in 15 minutes."

    # Wait for user input with a 900-second (15 min) timeout
    read -t 900

    # When read finishes (via Enter or timeout), the script exits, triggering the trap.
    exit 0
fi