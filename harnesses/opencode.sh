echo -n "    -> Compiling OpenCode Binary... "
sudo -i -u "$GUEST_USER" curl -fsSL https://opencode.ai/install | bash >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Configuring OpenCode Routing... "
echo "export OPENCODE_DEFAULT_PROVIDER=\"openai\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "export OPENAI_API_BASE=\"http://$BRIDGE_IP:$VAULT_PORT/v1\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "export OPENAI_API_KEY=\"sk-agentvault-local\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "OK"