🔒 AgentVault

A zero-trust, air-gapped Libvirt sandbox for autonomous AI coding agents.

AgentVault automatically provisions a mathematically sealed Debian VM designed specifically to run tools like Aider in total isolation.

It guarantees that your AI agent cannot "phone home," scrape the internet, or traverse your local network, while maintaining a perfectly comfortable development experience for you.
Why AgentVault?

    🚫 Zero Internet: The agent cannot curl malicious payloads, leak source code, or reach external APIs.

    🛡️ One-Way SSH Firewall: You can SSH into the vault. The vault cannot SSH back into your host.

    🧠 Ollama-Only: The vault is strictly firewalled to only communicate with your host's local Ollama instance on port 11434.

    📂 Secure 9p Shared Storage: Works on your local files with instant host-to-VM sync, anchored by Libvirt-native permission mapping.
