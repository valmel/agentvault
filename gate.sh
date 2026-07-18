#!/bin/bash
# gate.sh - Instant Egress Toggle for Vaults

if [ "$EUID" -ne 0 ]; then
  echo "[!] Please run as root: sudo ./gate.sh <open|close> <vault-name>"
  exit 1
fi

ACTION="$1"
VAULT_NAME="$2"
HOOK_SCRIPT="/etc/libvirt/hooks/network.d/$VAULT_NAME"

if [[ "$ACTION" != "open" && "$ACTION" != "close" ]] || [ -z "$VAULT_NAME" ]; then
    echo "Usage: sudo ./gate.sh <open|close> <vault-name>"
    exit 1
fi

if ! virsh net-info "$VAULT_NAME" &>/dev/null; then
    echo "[!] Error: Network '$VAULT_NAME' is not running."
    exit 1
fi

if [ ! -f "$HOOK_SCRIPT" ]; then
    echo "[!] Error: Topology hook not found for $VAULT_NAME."
    echo "    Was this vault built with forge.sh?"
    exit 1
fi

# Step 1: Wipe the slate clean using the vault's own teardown logic
# This prevents rule duplication no matter how many times you run this script.
iptables -D FORWARD -i "$VAULT_NAME" -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
"$HOOK_SCRIPT" "$VAULT_NAME" "stopped"

# Step 2: Restore the exact baseline topology for this specific vault
"$HOOK_SCRIPT" "$VAULT_NAME" "started"

if [ "$ACTION" == "open" ]; then
    # Step 3 (Open Only): Inject the internet override at the very top of the FORWARD chain.
    # Because forge.sh always puts LAN drops at rules 1, 2, and 3, inserting this at rule 1
    # pushes the LAN drops down, granting web access while keeping LAN scanning strictly blocked.
    iptables -I FORWARD 1 -i "$VAULT_NAME" -p tcp -m multiport --dports 80,443 -j ACCEPT

    echo "[+] GATE OPENED for $VAULT_NAME (Web allowed, LAN blocked)"

elif [ "$ACTION" == "close" ]; then
    # The baseline was already restored in Step 2.
    # If this is an airgap vault, it is now safely airgapped again.
    # If this is a blind-nat vault, it is back to its standard configuration.
    echo "[x] GATE CLOSED for $VAULT_NAME (Baseline Topology Restored)"
fi