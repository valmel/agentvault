# 🔒 AgentVault
**A parametric, zero-trust Libvirt sandbox builder for autonomous AI coding agents.**

AgentVault (`forge.sh`) automatically provisions mathematically sealed or strictly
filtered Debian VMs specifically designed to run tools like [Aider](https://aider.chat/),
Claude Code, and OpenCode in total isolation. It handles host setup, Golden-Image
Copy-on-Write (COW) cloning, `virtiofs` workspace mounting, dynamic Layer 7 proxy
enforcement, and local-inference relay routing in a single parametric command.

### 🛑 Prerequisites
- A Debian/Ubuntu-based host machine.
- Hardware virtualization (VT-x/AMD-V) enabled in BIOS.
- Root privileges (`sudo`) to manage Libvirt networks, KVM domains, and host firewalls.
- *Note: The guest VM hardcodes the user as `agent` with password `password123`.
This is intentional for unattended automation and completely safe, as the VM is
physically firewalled from the network and strictly enforces ED25519 key-pair SSH access.*

---

## ⚙️ The Parametric Engine (`forge.sh`)

AgentVault is driven by a unified utility. Configuration options can be defined via
CLI flags or permanently customized inside `~/.config/agentvault/forge.conf`.

### Basic Syntax
```bash
   sudo ./forge.sh --agent=<agent> [options]
```

### Supported Flags & Parameters
| Flag | Description | Choices / Default |
| :--- | :--- | :--- |
| `--agent` | The coding agent toolchain to install | `aider`, `antigravity`, `claude`, `opencode`, `pi`, `deepseek` (**Required**) |
| `--provider` | The AI inference backend or service | `llama`, `ollama`, `vllm`, `openrouter`, `google`, `anthropic`, `openai` (default: `llama`) |
| `--type` | Network security posture | `restricted` (whitelisted egress) or `airgapped` (default: `airgapped`) |
| `--key` | API key for cloud providers | Required if using cloud-backed providers |
| `--ram` | Override default guest RAM in MB | Default: `4096` |
| `--vcpus` | Override guest vCPU count | Default: `2` |
| `--disk` | Override guest disk size in GB | Default: `7` |
| `--name` | Custom override for the VM/workspace name | Auto-generated as `<agent>-<provider>-<type>` |

### Deployment Examples
1. **Air-gapped local Ollama vault with Aider:**
   ```bash
   sudo ./forge.sh --agent=aider --provider=ollama --type=airgapped
   ```
2. **Surgically restricted cloud vault with Claude Code and Anthropic API:**
   ```bash
   sudo ./forge.sh --agent=claude --provider=anthropic --type=restricted --key="sk-ant-..."
   ```

---

## 🚀 Daily Zero-Trust Workflow

Protect your main production repository by isolating code execution. AgentVault mounts projects centrally under `~/harness_workspaces`.

### 1. Locate your workspace
When a vault is created, a shared folder is automatically provisioned at `~/harness_workspaces/<vm-name>`. Clone your sandbox project inside it.
```bash
   cd ~/harness_workspaces/aider-ollama-airgapped
   git clone /path/to/your/production/repo secure-sandbox
   cd secure-sandbox
```

### 2. Strip upstream remotes
Remove upstream remotes to prevent accidental pushes or TCP timeout hangs if an agent attempts a `git push`.
```bash
   git remote remove origin
```

### 3. Sanitize secrets
Ensure no active `.env` files, API tokens, or private keys bleed into the sandbox.
```bash
   rm -f .env .env.local *.pem *.key
```

### 4. Execute the agent
Enter the vault via the automatically generated SSH alias and launch your agent.
```bash
   ssh aider-ollama-airgapped

   # Inside the guest VM:
   cd ~/aider-ollama-airgapped/...
   aider
```

### 5. Audit and merge
Inspect the agent's changes locally on your host. If the logic is sound, pull the sandboxed commits back into your production repository.
```bash
   cd /path/to/your/production/repo
   git pull ~/harness_workspaces/aider-ollama-airgapped/secure-sandbox
```

---

## 🏗️ Under the Hood: The Architecture
AgentVault abandons leaky Docker containers in favor of hardware-backed KVM virtualization, utilizing advanced L3/L7 network enforcement.

* **Layer 3 Blackout:** `iptables` Libvirt hooks explicitly `DROP` all `FORWARD` traffic originating from the VM. The guest OS lacks direct IP routing to the internet or local subnets.
* **Layer 7 Surgical Least-Privilege Proxy (`--type=restricted`):** Rather than allowing blind TCP egress, forge.sh installs **Squid proxy** on the host.
It dynamically generates a specific whitelist file (`/etc/agentvault/whitelists/<vm-name>.txt`) bound strictly
to the VM's unique `/24` subnet. An Anthropic agent is mathematically incapable of reaching OpenAI's API.
* **Sudo-Proof Configuration:** Proxies for APT, PIP, and NPM are locked at the global system configuration level 
(`/etc/apt/apt.conf.d/00proxy`, `/etc/pip.conf`). They survive `sudo` environment stripping, ensuring autonomous agents 
seamlessly fetch dependencies without hanging.
* **The VirtioFS Bridge:** AgentVault utilizes `virtiofs`, allowing the guest OS to read host workspace files directly from RAM without network overhead of SMB/NFS mounts.
* **Local Inference Relay:** Automatically provisions dynamic `socat` systemd services to safely bridge host inference engines (Ollama, vLLM, Llama.cpp) into air-gapped guests without exposing the host OS to the guest.

---

## 🛠️ Companion Utilities

Because true airgaps prevent routine dependency installation (`pip`, `apt`), AgentVault abandons bulky offline package caches in favor of a "Dead Man's Switch" workflow, accompanied by a nuclear teardown script.

### 1. The Dead Man's Switch (`gate.sh`)
Provides instant, temporary internet access to a sealed vault for package installation, automatically slamming shut after 15 minutes. 

**Usage:** `sudo ./gate.sh open <vault-name>`

### 2. The Nuclear Option (`burn-vaults.sh`)
> **⚠️ WARNING: DESTRUCTIVE ACTION**  
> This script irreparably vaporizes all running libvirt vaults `<agent>-<provider>-<type>`, purges their COW storage, flushes all `VFWD_` iptables chains, stops `socat` systemd relays, and sanitizes user SSH configs. Use this to instantly return the host to a clean baseline.

**Usage:** `sudo ./burn-vaults.sh`