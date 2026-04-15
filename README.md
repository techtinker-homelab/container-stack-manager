# Container Stack Manager (CSM)

A unified CLI tool for managing Docker and Podman Compose stacks on a single host. CSM standardizes how you organize, create, and interact with your containerized applications, keeping your homelab or cloud server clean and easily backup-able.

---

## Features

- **Unified Interface**: Wraps standard `docker compose` / `podman compose` commands into short, memorable syntax (`csm up`, `csm down`, `csm logs`).
- **Auto Scope Detection**: Automatically detects whether a stack should run as Docker Swarm or local compose. Falls back to marker files (`.swarm` / `.local`) when needed.
- **Standardized Structure**: Forces all container stacks into a single root directory (`/srv/stacks` by default) with isolated `.env` and `appdata/` directories.
- **Automated Setup**: The installer detects your container runtime, creates directories, sets permissions, and symlinks everything.
- **Built-in Backups**: Easily snapshot a stack and its configuration to a centralized `.backup` directory.
- **Shell Aliases**: Source helper functions (`cds`, `hostip`, `vpncheck`, `lancheck`) in your shell rc for quick access.

---

- If you like this project and want to support me, here's a link:

<a href="https://ko-fi.com/drauku"><img src="https://ko-fi.com/img/githubbutton_sm.svg"></a>

---

## Installation Guide

**Prerequisites:** A Linux host (Debian, Ubuntu, Fedora, or Arch). You do not need a container runtime pre-installed; the installer can also handle this.

| Requirement | Notes |
|---|---|
| bash ≥ 4.2 | Ships with most modern Linux distros |
| sudo or root | Installer only; runtime does not need elevation |

Docker or Podman will be detected automatically, or you can choose which to install during setup.

### Step-by-step

1. **Clone the repository:**
  - Create the repository directory:
   ```bash
   mkdir -p ~/git/container-stack-manager
   ```
   ```bash
   git clone https://gitlab.com/techtinker/container-stack-manager.git ~/git/container-stack-manager
   cd ~/container-stack-manager
   ```

2. **Ensure the installer is executable:**
   ```bash
   chmod +x csm-install.sh
   ```

3. **Run the installer:**
  *NOTE*: You can change the default stacks directory from `/srv/stacks` ***if desired***:
  ```bash
  export CSM_ROOT_DIR=/srv/containers
  ```
  - Or any desired path, like `/opt/stacks`
  - Then, run the installer like normal:

   ```bash
   sudo ./csm-install.sh
   ```

4. **The installer will:**
   1. Detect or offer to install Podman, Docker Local, or Docker Swarm
   2. Check / start the container service
   3. Create a runtime group (`docker` or `podman`) at GID 2000 (if absent) and add your user to it
   4. Build the directory structure under `CSM_ROOT_DIR`
   5. Copy core files and set permissions
   6. Patch `default.conf` with the detected runtime and GID
   7. Create the `~/stacks` convenience symlink
   8. Symlink `csm` into `/usr/local/bin`

### Post-Installation

- **NOTE:** If you were added to the runtime group, **log out and log back in** to your terminal session (or reboot) so group ownership is applied before using the `csm` command.
- Access your stacks at `~/stacks`.
- Customize your setup by editing the user config: `micro ~/stacks/.configs/user.conf` (or use `nano` or `vi` etc).

---

## File Layout

### Repository (Pre-install)
```text
# Repository files:
#   ./<repo>/
#   ├── csm.sh              ← Main runtime script (symlinked to /usr/local/bin/csm during install)
#   ├── csm-install.sh      ← One-shot installer (run once; sets up the environment)
#   ├── example.conf        ← Default configuration values (copied as default.conf during install)
#   ├── example.conf        ← Example global environment template
#   └── README.md           ← Project description and instructions for installation and use.
```

### Installed Environment (Post-install)
By default, CSM installs everything to `/srv/stacks` (accessible via a `~/stacks` symlink in your home folder).

```text
# Installed layout:
#   /srv/stacks/                    ← CSM root directory
#   ├── .backups/                   ← automated stack tarball backup
#   │  └── <stack>/                 ← directory to hold stack backups
#   │     └── <stack>-YYYYMMDD_HHMMSS.tar.gz  ← backup of full stack directory
#   ├── .configs/                   ← shared resources and tools
#   │  ├── csm.sh                   ← main CSM script containing all helper scripts
#   │  ├── default.conf             ← default configuration variables
#   │  ├── local-compose.yml        ← example compose.yml for "local" Docker & Podman
#   │  ├── swarm-compose.yml        ← example compose.yml for Docker Swarm only
#   │  └── user.conf                ← user overrides (optional)
#   ├── .secrets/                   ← directory for shared docker secrets
#   │  ├── .local.env               ← Podman and Docker Local variables
#   │  ├── .swarm.env               ← Docker Swarm specific variables
#   │  ├── example.env              ← bare bones example .env variables
#   │  └── <variable_name>.secret   ← one secret file per secret variable
#   ├── .modules/                   ← pre-configured stack compose and environment vars
#   │  └── <stack>/                 ← descriptive name of the stack
#   │     ├── compose.yml           ← pre-made compose.yml tailored to work with CSM
#   │     └── example.env           ← variables required for this specific compose.yml
#   └── <stack>/                    ← directory for container stack configs and appdata
#      ├── .env                     ← symlinked to the .scope.env / custom .env
#      ├── compose.yml              ← stack containers configuration file
#      └── appdata/                 ← stack appdata directory for each container
# =============================================================================
```
---

## Quick Start

Once installed, the `csm` command is available system-wide.

### 1. Create a new stack
This generates the folder structure and a boilerplate `compose.yml`.
```bash
csm create my_stack
```

### 2. Edit the Compose file
Opens the newly created `compose.yml` in your default `$EDITOR`.
```bash
csm edit my_stack
```

### 3. Start the stack
Pulls the required images and starts the containers in the background.
```bash
csm up my_stack
```

Docker Swarm has a few more options for container starting/stopping:
```bash
csm start my_stack
csm stop my_stack
```

### 4. Check the status
```bash
csm ps                  # Shows all containers across all stacks
csm status my_stack     # Shows status for a specific stack
```

### 5. View Logs
Follow the live logs for your stack (press `Ctrl+C` to exit).
```bash
csm logs my_stack
```

---

## Command Reference

Run `csm --help` at any time to see the full list of commands:

```
csm <command> [<stack-name>] [options]
```

### Stack Lifecycle

| Command | Aliases | Description |
|---|---|---|
| `create <stack>` | `c` | Scaffold a new stack directory + compose file |
| `new <stack>` | `n` | Scaffold a new stack directory + compose file (duplicate of `create`) |
| `edit <stack>` | `e` | Open `compose.yml` in `$EDITOR` |
| `rename <old> <new>` | `r` | Rename a stack directory |
| `remove <stack>` | `rm` | Stop and remove containers (prompts) |
| `delete <stack>` | `dt` | Stop and permanently delete stack + all data (prompts) |
| `backup <stack>` | `bu` | Archive the stack directory to `.backup/` (tar.gz) |
| `recreate <stack>` | `rc` | Delete and recreate a stack from scratch (prompts) |
| `purge [stack...]` | `xx` | Purge one or all stacks — **WARNING: FINAL** |

### Stack Operations

| Command | Aliases | Description |
|---|---|---|
| `up <stack>` | `u` | Deploy a stack (`up -d --remove-orphans`) |
| `down <stack>` | `d`, `dn` | Stop and remove containers (`down`) |
| `bounce <stack>` | `b` | Bring stack down then back up (full recreate) |
| `start <stack>` | `st` | Start stopped containers |
| `stop <stack>` | `sp` | Stop containers without removing |
| `restart <stack>` | `r`, `rs` | Restart containers |
| `update <stack>` | `ud` | Pull latest images then redeploy |

### Information

| Command | Aliases | Description |
|---|---|---|
| `list` | `l`, `ls` | List all stacks with running state and scope |
| `status <stack>` | `s` | Show container/service status for a stack |
| `validate <stack>` | `v` | Validate `compose.yml` syntax |
| `inspect <stack>` | `i` | Inspect stack configuration |
| `logs <stack> [n]` | `g` | Follow logs (default: last 50 lines) |
| `cd <stack>` | | Print the stack directory path |
| `ps` | | List all containers (formatted, colorized) |
| `net <action>` | | Network info: `list`, `host`, `inspect [name]` |
| `template` | `t` | Template management (not yet implemented) |

### Configuration

| Command | Description |
|---|---|
| `config show` | Print active config values |
| `config edit` | Open `user.conf` in `$EDITOR` |
| `config reload` | Re-source config files |

### Secrets Management

| Command | Aliases | Description |
|---|---|---|
| `secret <name>` | | Create a Docker secret from file, stdin, or prompt (swarm required) |
| `secret-rm <name>` | | Remove a Docker secret and its backup file |
| `secret-ls` | | List all Docker secrets |

Secrets are stored in `CSM_ROOT_DIR/.secrets/` as `<name>.secret` files with `600` permissions. When creating a secret, CSM will:
1. Use an existing `.secret` file if present
2. Read from stdin if piped
3. Prompt for input interactively (hidden)

### Options

| Flag | Description |
|---|---|
| `-h`, `--help` | Show help text |
| `-V`, `--version` | Show version |
| `--aliases` | Print shell aliases to eval in your shell rc |

---

## Shell Aliases

Source helper functions in your `.bashrc` or `.zshrc`:

```bash
eval "$(csm --aliases)"
```

This provides:

| Alias | Description |
|---|---|
| `cds <stack>` | cd into `/srv/stacks/<stack>` |
| `hostip` | Show host public IP |
| `lancheck <container>` | Show container IP via `ipinfo.io` |
| `vpncheck <container>` | Show container IP + host IP side-by-side (VPN leak check) |

---

## Scope Detection

CSM automatically determines whether a stack should run as **Docker Swarm** or **local compose** (Docker Compose / Podman Compose). The detection order is:

1. **Podman** → always local
2. **Marker files** → `.swarm` or `.local` in the stack directory (explicit override)
3. **Swarm inactive** → always local
4. **Swarm active + stack deployed** → swarm
5. **Swarm active + not deployed** → checks compose file for swarm-specific syntax (`deploy.mode`, `endpoint_mode`, `placement`)
6. **Fallback** → local

This means CSM works out of the box in any Docker or Podman environment without manual configuration. Use `.swarm` or `.local` marker files only when you need to force a specific scope.

---

## Configuration

Edit `CSM_ROOT_DIR/.configs/user.conf` (or `~/.config/csm/user.conf`) to override defaults. Environment variables with a `CSM_` prefix take highest precedence.

| Variable | Default | Description |
|---|---|---|
| `CSM_CONTAINER_RUNTIME` | (auto-detected) | `docker` or `podman` |
| `CSM_STACKS_UID` | (current user) | UID for stack directory ownership |
| `CSM_STACKS_GID` | (runtime group) | GID for stack directory ownership |
| `CSM_ROOT_DIR` | `/srv/stacks` | Base install directory |
| `CSM_BACKUPS_DIR` | `$CSM_ROOT_DIR/.backups` | Backup archive location |
| `CSM_CONFIGS_DIR` | `$CSM_ROOT_DIR/.configs` | Config files and script |
| `CSM_SECRETS_DIR` | `$CSM_ROOT_DIR/.secrets` | Secret variables and files |
| `CSM_NETWORK_NAME` | `csm_network` | Default external network |

---

## Disclaimer:

The idea for this project can be traced back to @gkoerk (RIP) with his Docker setup and aliases for QTS, but the scripting and recent rewrite is my work.

I used my own local LLM, Claude, and Gemma for code review and bug finding, but the scripting was done by me.

## License

MIT License – see [LICENSE](LICENSE) for details.
