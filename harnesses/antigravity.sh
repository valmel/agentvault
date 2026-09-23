echo -n "    -> Installing Antigravity Engine... "
sudo -i -u "$GUEST_USER" curl -fsSL https://antigravity.google/cli/install.sh | bash >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"