# AI Sandbox devcontainer

A sandboxed development environment for running **Claude Code** and **OpenAI Codex** with dangerous permissions safely enabled. Use strong agent defaults inside an isolated container instead of on your host.

This project lives at **[github.com/damianrusinek/ai-sandbox-devcontainer](https://github.com/damianrusinek/ai-sandbox-devcontainer)**. It started from **[Trail of Bits’ claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer)** and extends it for a broader "AI coding agent" sandbox.

## Compared to the Trail of Bits upstream

- **OpenAI Codex** — Codex-oriented VS Code / Cursor extension (`openai.chatgpt`), persistent **`~/.codex`** data via a Docker volume, and host read-only **`~/.codex/commands`**. Use **`devc upgrade-agents`** to refresh **Claude Code** and the **Codex CLI** (`npm install -g @openai/codex@latest`) inside a running container.
- **Shared Docker image** — Workspaces reference a **fixed image name** (`my-ai-sandbox/devcontainer:local` in `devcontainer.json`). You **`devc build-image` once** (from this repo); every new folder that runs `devc .` / `devc up` **reuses that image** and only creates a **new container** plus **per-workspace named volumes**. You avoid rebuilding a full image for each project.
- **Custom Dockerfile mode** — Use `devc . --custom` to copy a customizable `Dockerfile` into your project's `.devcontainer/` directory. This lets you add project-specific dependencies or modifications while still extending the base image.
- **Other tweaks** — Naming, volume prefixes (`ai-sandbox-*`), container `runArgs` (e.g. predictable `--name`), npm defaults in `containerEnv`, and small quality-of-life changes on top of the upstream design.

## Why use this?

Running agents with broad permissions on your host is risky: they can run commands without your usual guardrails. This devcontainer gives **filesystem isolation** so you get aggressive agent defaults **without** exposing your home directory or unrelated projects.

**Designed for:**

- **Security audits** — Review client code without risking your host  
- **Untrusted repositories** — Explore unknown codebases safely  
- **Experimental work** — Let agents change code freely inside the sandbox  
- **Multi-repo engagements** — Shared workspace layout or per-project containers  

## Prerequisites

- **Docker** (one of):
  - [Docker Desktop](https://docker.com/products/docker-desktop) — keep it running  
  - [OrbStack](https://orbstack.dev/)  
  - [Colima](https://github.com/abiosoft/colima): `brew install colima docker && colima start`

- **For terminal workflows** (one-time):

  ```bash
  npm install -g @devcontainers/cli
  git clone https://github.com/damianrusinek/ai-sandbox-devcontainer ~/.ai-sandbox-devcontainer
  ~/.ai-sandbox-devcontainer/install.sh self-install
  ```

That installs the **`devc`** helper into `~/.local/bin` (see `devc self-install`).

<details>
<summary><strong>Optimizing Colima for Apple Silicon</strong></summary>

Colima’s defaults (QEMU + sshfs) are conservative. For better performance:

```bash
# Stop and delete current VM (removes containers/images)
colima stop && colima delete

# Start with optimized settings
colima start \
  --cpu 4 \
  --memory 8 \
  --disk 100 \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs
```

Adjust `--cpu` and `--memory` for your machine (e.g. 6/16 on Pro, 8/32 on Max).

| Option | Benefit |
|--------|---------|
| `--vm-type vz` | Apple Virtualization.framework (faster than QEMU) |
| `--mount-type virtiofs` | Much faster file I/O than sshfs |
| `--vz-rosetta` | Run x86 containers via Rosetta |

`colima status` should show Virtualization.framework and virtiofs.

</details>

## Build the image once (shared across workspaces)

Before (or after) cloning individual projects, build the image **from this repo** so all sandboxes share it:

```bash
devc build-image
```

That produces **`my-ai-sandbox/devcontainer:local`**, which `devcontainer.json` in each copied template references. New workspaces only need the **`.devcontainer` template** + **`devc up`** (or `devc .`); they do **not** each trigger a full image rebuild unless you change the Dockerfile and run **`devc build-image`** again.

## Quick start

### Pattern A: Per-project container (isolated)

Each project gets its own **container** and **per-instance volumes** (history, Claude, Codex, `gh`). Good when you want isolation between repos.

**Terminal:**

```bash
git clone <repo>
cd repo
devc .          # Drop in .devcontainer template + start container
devc shell
```

**VS Code / Cursor**

1. Install **Dev Containers**  
   - VS Code: `ms-vscode-remote.remote-containers`  
   - Cursor: `anysphere.remote-containers`

2. Add the template:

   ```bash
   devc .
   ```

3. Open **your project folder** in VS Code, then:
   - Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
   - Type "Reopen in Container" and select **Dev Containers: Reopen in Container**

### Pattern B: Shared workspace container (grouped)

One parent directory holds `.devcontainer`; you clone multiple repos **under** it. **Volumes are shared** for that devcontainer instance—good for one engagement with many related repos.

```bash
mkdir -p ~/sandbox/client-name
cd ~/sandbox/client-name
devc .
devc shell

# Inside the container:
git clone <client-repo-1>
git clone <client-repo-2>
cd client-repo-1
claude-yolo    # or: codex-yolo
```

## CLI helper (`devc`)

```
devc .               Install template + start container (current directory)
devc . --custom      Install template with custom Dockerfile build mode
devc up              Start the devcontainer
devc rebuild         Recreate container (keeps named volumes)
devc down            Stop the devcontainer
devc shell           Open zsh in the container
devc build-image     Build my-ai-sandbox/devcontainer:local (once; shared by workspaces)
devc upgrade-agents  Upgrade Claude Code + Codex CLI inside the container
devc mount           Add a bind mount (recreates container)
devc self-install    Symlink devc into ~/.local/bin
devc update          Git-pull this repo (where install.sh lives)
```

### Custom Dockerfile mode

By default, `devc .` uses the prebuilt `my-ai-sandbox/devcontainer:local` image (requires `devc build-image` first). For projects that need additional dependencies or customizations, use the `--custom` flag:

```bash
devc . --custom
```

This copies a `Dockerfile` into `.devcontainer/` that extends the base image:

```dockerfile
FROM my-ai-sandbox/devcontainer:local

# Add your project-specific customizations here
```

The container builds locally each time, allowing you to add project-specific tools, dependencies, or configurations. Edit `.devcontainer/Dockerfile` after installation to customize.

## Network isolation

By default the container has **full outbound network**. To harden reviews, use **iptables** (the image includes `iptables` / `ipset`).

### When to Enable Network Isolation
- Reviewing code that may contain malicious dependencies
- Auditing software with telemetry or phone-home behavior
- Maximum isolation for highly sensitive reviews

### Example: Claude, Codex, GitHub, registries

Allow Anthropic, OpenAI (Codex), GitHub, and common package hosts—then default-deny the rest:

```bash
sudo iptables -A OUTPUT -d api.anthropic.com -j ACCEPT
sudo iptables -A OUTPUT -d api.openai.com -j ACCEPT
sudo iptables -A OUTPUT -d github.com -j ACCEPT
sudo iptables -A OUTPUT -d raw.githubusercontent.com -j ACCEPT
sudo iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT
sudo iptables -A OUTPUT -d pypi.org -j ACCEPT
sudo iptables -A OUTPUT -d files.pythonhosted.org -j ACCEPT
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -j DROP
```

Tune the allowlist for your workflow (ChatGPT / device flows may need extra hosts).

### Trade-offs

- Package installs fail unless you allowlist their registries  
- Some tools need network you did not anticipate  
- DNS may still resolve; block explicitly if you need stricter control  

## Security model

This setup gives **filesystem isolation**, not a full formal sandbox.

**Isolated:** Workspace filesystem (bind-mounted project), processes, and package installs stay in the container.

**Not isolated by default:** Outbound **network** (see above), **git identity** (`~/.gitconfig` bind-mounted read-only), Docker socket 
(not mounted by default), and anything you add to the workspace.

**Claude** is configured for **`bypassPermissions`** inside the container so it can run commands without per-step confirmation—that is intentional **inside** this environment, not something you want unchecked on your host.

**Codex** is intended to be used with similarly **permissive approval and sandbox defaults** for the workspace **inside** this container (for example low-friction command execution in devcontainer workflows)—keep stricter Codex policies on machines where the agent can reach your real home directory and projects outside the sandbox.

## Container Details

| Item | Notes |
|------|--------|
| Base | Ubuntu 24.04 (Microsoft devcontainers base), Node 22 (fnm), Python 3.13 + uv, zsh |
| User | `vscode`, passwordless `sudo`, workdir `/workspace` |
| Agents | Claude Code; OpenAI Codex in the editor; refresh **Claude + Codex CLI** with `devc upgrade-agents` (installs or upgrades `@openai/codex`) |
| Tools | `rg`, `fd`, `tmux`, `fzf`, `delta`, `ast-grep`, `iptables`, `ipset`, … |
| Image | `my-ai-sandbox/devcontainer:local` — **one build**, many containers |
| Volumes (per devcontainer id) | Shell history (`/commandhistory`), `~/.claude`, `~/.codex`, `~/.config/gh` |

Host **`~/.gitconfig`** is mounted read-only for commits; **`~/.claude/commands`** and **`~/.codex/commands`** are optional read-only command folders from the host.

## Troubleshooting

### "`devcontainer` CLI not found"

```bash
npm install -g @devcontainers/cli
```

### Container won't start

1. Confirm Docker is running  
2. Ensure the image exists: `devc build-image` from the **ai-sandbox-devcontainer** clone  
3. Rebuild container: `devc rebuild`  
4. Logs: `docker logs $(docker ps -lq)`  

### GitHub CLI auth not persisting

The gh volume may need ownership fix:

```bash
sudo chown -R "$(id -u):$(id -g)" ~/.config/gh
```

### Python/uv not working

Python is managed via uv:

```bash
uv run script.py              # Run a script
uv add package                # Add project dependency
uv run --with requests py.py  # Ad-hoc dependency
```

