echo -n "    -> Bootstrapping Pi Coding Agent... "
sudo npm install -g --ignore-scripts @earendil-works/pi-coding-agent >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Injecting Pi gateway config... "
sudo -u "$GUEST_USER" mkdir -p /home/"$GUEST_USER"/.pi/agent

sudo -u "$GUEST_USER" cat <<EOF > /home/"$GUEST_USER"/.pi/agent/models.json
{
  "providers": {
    "litellm": {
      "baseUrl": "http://$BRIDGE_IP:4000/v1",
      "api": "openai-completions",
      "apiKey": "sk-agentvault-local",
      "compat": {
          "supportsDeveloperRole": false,
          "supportsReasoningEffort": false
      },
      "models": [
        {
          "id": "or-gemini-3.8-flash",
          "name": "Gemini 3.8 Flash",
          "contextWindow": 1048576,
          "maxTokens": 65536
        },
        {
          "id": "or-glm-5.3-flash",
          "name": "GLM 5.3 Flash",
          "contextWindow": 1310720,
          "maxTokens": 131072
        }
      ]
    }
  }
}
EOF
echo "OK"