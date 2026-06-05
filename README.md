# 🔒 AgentVault
**A zero-trust, air-gapped Libvirt sandbox for autonomous AI coding agents.**

AgentVault automatically provisions a mathematically sealed Debian VM designed specifically to run tools like [Aider](https://aider.chat/) in total isolation. It guarantees that your AI agent cannot "phone home," scrape the internet, or traverse your local network, while maintaining a high-speed `virtiofs` bridge to your local files and a dedicated `socat` relay to your host's Ollama instance.

### 🛑 Prerequisites
- A Debian/Ubuntu-based host machine.
- Hardware virtualization (VT-x/AMD-V) enabled in BIOS.
- [Ollama](https://ollama.com/) installed and running on the host.
- *Note: The scripts hardcode the VM user as `agent` with password `password123`. This is intentional for 
unattended automation and completely safe, as the VM is physically disconnected from the network and 
strictly enforces ED25519 key-pair SSH access.*

---

## ⚙️ Phase 1: The deployment pipeline

Execute these five scripts sequentially to build and seal the environment.

### 1. `01_setup_host.sh`
Sets up host dependencies, Libvirt hook multiplexers, and creates the default `~/aider` shared directory 
with precise `setgid` permissions to prevent file ownership conflicts.

### 2. `02_build_vm.sh`
Downloads the latest Debian ISO, generates a secure preseed configuration, and executes an unattended 
installation of the base OS. *(Wait for the VM to automatically power off before proceeding).*

### 3. `03_setup_aider.sh`
Wakes the VM, establishes passwordless ED25519 SSH trust, and uses Astral's `uv` to install a sandboxed 
Python environment and `aider-chat`.

### 4. `04_share_dir.sh`
Injects a high-speed `virtiofs` configuration into the hypervisor XML, persistently mapping your host 
directory to the guest OS.

### 5. `05_seal_vault.sh`
Severs the internet. This script creates an isolated Libvirt network, locks the VM to a static IP (`192.168.100.100`), 
spins up a `socat` relay to route Ollama traffic over port `11434`, and injects an SSH alias into your host.

---

## 🚀 Phase 2: Daily zero-trust workflow

The network is mathematically sealed, but true zero-trust requires securing the workspace *before* 
the agent touches it. **Never point AgentVault directly at your active production directories.** 
Follow this sequence to safely prep and mount your code:

### 1. Clone the target
Clone your active project into the shared sandbox directory.
```bash

cd ~/aider
git clone /path/to/your/production/repo secure-sandbox
cd secure-sandbox
```

### 2. Strip upstream remotes
Remove the upstream git remotes from the sandbox clone.
```bash

git remote remove origin
```
*Why?*
* **Extra hardening:** Even in a case of accidental network misconfiguration, your remote codebase cannot be pushed to.
* **Preventing Timeouts:** If the hallucinating agent accidentally executes `git push`, the lack of a remote forces an instant local failure instead of a TCP timeout hang inside the air-gapped VM.

### 3. Sanitize secrets
Ensure no active `.env` files, API tokens, or private keys were copied over.
```bash

rm -f .env .env.local *.pem *.key
```

### 4. Execute the agent
Enter the vault via the automatically generated SSH alias and launch your agent against the shared code.
```bash

ssh aider-vault

# Inside the vault:
cd ~/aider/secure-sandbox
aider --model=ollama_chat/qwen3.6:27b
```

### 5. Audit and merge
Once Aider has generated the `udiff` patches and completed its tasks, inspect the changes locally on your host machine. If the logic is sound, pull the sandboxed commits back into your main production repository.
```bash

cd /path/to/your/production/repo
git pull ~/aider/secure-sandbox
```

### ⚠ A note on data migration
When moving existing projects into the ~/aider directory, do not use standard copy commands, as they often reset ownership and file permissions, breaking the virtiofs bridge.

To safely import your project, use rsync to preserve the necessary permissions and group-sharing bits:
```Bash

# Safely sync your project into the sandbox
rsync -av --chown=$USER:libvirt-qemu /path/to/your/project/ ~/aider/your-project/
# Ensure the setgid bit is active on all directories
sudo find ~/aider/your-project -type d -exec chmod g+s {} +
```

### 💡 Security tip: principle of least privilege
Run inference engines (like Ollama) and your IDEs under dedicated, low-privilege user accounts without network access. 
By isolating your AI tooling from your main user account, you ensure that even a compromised model or plugin cannot access 
your browser cookies, SSH keys, or personal documents.

---

## 🏗️ Under the hood (the architecture)
Unlike Docker containers, which share the host kernel and are vulnerable to container-escape CVEs, AgentVault uses hardware-backed KVM virtualization. 
* **The Air-Gap:** Achieved via custom Libvirt `network.d` hooks. Iptables strictly drops all `NEW` TCP connections originating from the VM, while allowing established SSH returns.
* **The Bridge:** AI agents require massive context windows. Standard network shares (SMB/NFS) choke on parsing thousands of files. AgentVault utilizes `virtiofs`, allowing the guest OS to read host files directly from RAM without network overhead.