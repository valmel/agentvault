echo -n "    -> Installing Astral UV & Sandboxing Aider... "
sudo -i -u "$GUEST_USER" curl -LsSf https://astral.sh/uv/install.sh | sudo -i -u "$GUEST_USER" sh >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
sudo -i -u "$GUEST_USER" /home/"$GUEST_USER"/.local/bin/uv tool install --python 3.12 aider-chat >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Configuring Aider Routing... "
echo "export AIDER_MODEL=\"openai/default\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "export OPENAI_API_BASE=\"http://$BRIDGE_IP:$VAULT_PORT/v1\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "export OPENAI_API_KEY=\"sk-agentvault-local\"" >> /home/"$GUEST_USER"/.config/agentvault/env
echo "OK"