echo -n "    -> Bootstrapping DeepSeek Harness... "
sudo npm install -g --ignore-scripts @deepseek-ai/dsh >> "$LOG" 2>&1 || { echo "FAIL"; exit 1; }
echo "OK"

echo -n "    -> Injecting DeepSeek YAML config... "
# Define the correct DeepSeek configuration path
CONFIG_PATH="/home/$GUEST_USER/.dsh"
sudo -u "$GUEST_USER" mkdir -p "$CONFIG_PATH"

sudo -u "$GUEST_USER" cat <<EOF > "$CONFIG_PATH/settings.yaml"
ui-onboarding:
  welcomeNoticeVersion: 2026-08-13.1
llm-pi-ai:
  providers:
    openai:
      baseURL: http://$BRIDGE_IP:9931/v1
      api: openai-completions
      models:
        - id: qwen3.8:27b
          contextWindow: 210000
agent-default-model:
  provider: openai
  model: qwen3.8:27b
EOF
echo "OK"