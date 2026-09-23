echo -n "    -> Deploying Claude CLI Sandbox... "
sudo npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Configuring Claude Routing... "
echo "export ANTHROPIC_BASE_URL=\"http://$BRIDGE_IP:$VAULT_PORT/v1\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "export ANTHROPIC_API_KEY=\"sk-agentvault-local\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "OK"