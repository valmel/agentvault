# 🔒 AgentVault
**A parametric, zero-trust Libvirt sandbox builder for autonomous AI coding agents.**

AgentVault (`forge.sh`) automatically provisions mathematically sealed or strictly
filtered Debian VMs specifically designed to run tools like [Aider](https://aider.chat/),
Claude Code, Pi, and DeepSeek in total isolation. It handles host setup, Golden-Image
Copy-on-Write (COW) cloning, `virtiofs` workspace mounting, dynamic Layer 7 proxy
enforcement, and universal AI gateway routing in a single parametric command.

### 🛑 Prerequisites
- A Debian/Ubuntu-based host machine.
- Hardware virtualization (VT-x/AMD-V) enabled in BIOS.
- Root privileges (`sudo`) to manage Libvirt networks, KVM domains, and host firewalls.
- **Python 3 / pip** on the host for the LiteLLM universal gateway.
- *Note: The guest VM hardcodes the user as `agent` with password `password123`.
This is intentional for unattended automation and completely safe, as the VM is
physically firewalled from the network and strictly enforces ED25519 key-pair SSH access.*

---

## 🏛️ The Architecture: Universal AI Gateway & Zero Secrets

Past iterations of AgentVault attempted to manage API keys and cloud dependencies
directly inside the VM. This proved to be a configuration nightmare, leading to leaked
secrets, fragmented billing, and endless dependency conflicts.

AgentVault now enforces a **Facade Architecture**:
1. **The Host is the Brain:** You manually configure `litellm` (and local runners like `llama.cpp`, `ollama`, or `vllm`) directly on your host machine. Your API keys (OpenRouter, Google, Anthropic) live securely on the host.
2. **The Vault is Dumb:** The VM holds **zero secrets**. It thinks it is talking to standard local OpenAI endpoints.
3. **The Bridge is Universal:** AgentVault automatically opens local `socat` relays across the isolated KVM network bridge. Whether the vault is `airgapped` (local AI only), `local` (whitelisted egress + local AI), or `cloud` (whitelisted egress + cloud/local AI), the AI intelligence can be hot-swapped dynamically from inside the VM without rebuilding the infrastructure.

---

## ⚙️ The Parametric Engine (`forge.sh`)

AgentVault is driven by a unified utility. Configuration options can be defined via
CLI flags or permanently customized inside `~/.config/agentvault/forge.conf`.

### Basic Syntax
```bash
   sudo ./forge.sh --agent=<agent> [options]
```

### Supported Flags & Parameters
| Flag | Description | Choices / Default                                                                                                                                             |
| :--- | :--- |:--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--agent` | The coding agent toolchain to install | `aider`, `antigravity`, `claude`, `opencode`, `pi`, `deepseek` (**Required**)                                                                                 |
| `--type` | Network security posture | `cloud` (whitelisted egress + local/cloud AI), `local` (whitelisted egress + local AI only), or `airgapped` (no egress, local AI only) (default: `airgapped`) |
| `--ram` | Override default guest RAM in MB | Default: `4096`                                                                                                                                               |
| `--vcpus` | Override guest vCPU count | Default: `2`                                                                                                                                                  |
| `--disk` | Override guest disk size in GB | Default: `7`                                                                                                                                                  |
| `--name` | Custom override for the VM/workspace name | Auto-generated as `<agent>-<type>`                                                                                                                            |

### Deployment Examples
1. **An airgapped vault for local DeepSeek Harness (No internet access):**
   ```bash
   sudo ./forge.sh --agent=deepseek --type=airgapped
   ```
2. **A cloud vault for Pi (Allows NPM installs and LiteLLM cloud access):**
   ```bash
   sudo ./forge.sh --agent=pi --type=cloud
   ```

---

## 🧩 Modular Harness Plugins

Because every AI coding agent requires unique configuration files (JSON, YAML, ENV) and installation paths, AgentVault uses a **Modular Subscript System**.

Users are expected to define their specific tool setups in the `./harnesses/` directory. When `forge.sh` runs, it dynamically injects variables (`$BRIDGE_IP`, `$GUEST_USER`) into these scripts to seamlessly configure the VM.

*(More official harness examples will be added in the future).*

### Example 1: Local Setup (DeepSeek on Llama.cpp)
**File: `harnesses/deepseek.sh`**

### Example 2: Cloud Setup (Pi on LiteLLM)
**File: `harnesses/pi.sh`**

---

## 🚀 Daily Zero-Trust Workflow

Protect your main production repository by isolating code execution. AgentVault mounts projects centrally under `~/harness_workspaces`.

### 1. Locate your workspace
When a vault is created, a shared folder is automatically provisioned at `~/harness_workspaces/<vm-name>`. Clone your sandbox project inside it.
```bash
   cd ~/harness_workspaces/aider-cloud
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
   ssh aider-cloud
   cd ~/aider-cloud/secure-sandbox
   aider
```

### 5. Audit and merge
Inspect changes locally on your host. If sound, pull them back into production.
```bash
   cd /path/to/your/production/repo
   git pull ~/harness_workspaces/aider-cloud/secure-sandbox
```

---

## 🏗️ Under the Hood: The Architecture
AgentVault abandons leaky Docker containers in favor of hardware-backed KVM virtualization, utilizing advanced L3/L7 network enforcement.

* **Layer 3 Blackout:** `iptables` Libvirt hooks explicitly `DROP` all `FORWARD` traffic originating from the VM. The guest OS lacks direct IP routing to the internet or local subnets.
* **Layer 7 Surgical Proxy (`--type=cloud` or `--type=local`):** Rather than allowing blind TCP egress, forge.sh configures a host-side **Squid proxy**. Access is strictly limited to OS and language package managers (APT, PyPI, NPM). 
It dynamically generates a specific whitelist file (`/etc/agentvault/whitelists/<vm-name>.txt`) bound strictly to the VM's unique `/24` subnet.
* **The VirtioFS Bridge:** Allows the guest OS to read host workspace files directly from RAM without network overhead.
* **Universal Multi-Port Relay:** Dynamically provisions `socat` systemd services to safely bridge host inference engines (`8000`, `9931`, `11434`, and conditionally `4000` for cloud) into the guests without exposing the host OS.

---

## 🛠️ Companion Utilities

### 1. The Dead Man's Switch (`gate.sh`)
Provides instant, temporary internet access to a sealed vault for package installation, automatically slamming shut after 15 minutes.

**Usage:** `sudo ./gate.sh open <vault-name>`

### 2. The Nuclear Option (`burn-vaults.sh`)
> **⚠️ WARNING: DESTRUCTIVE ACTION**
> Irreparably vaporizes all running vaults `<agent>-<type>`, purges COW storage, flushes `iptables` chains, stops `socat` relays, and sanitizes SSH configs.
**Usage:** `sudo ./burn-vaults.sh`