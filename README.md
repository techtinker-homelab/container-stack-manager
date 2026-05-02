# Container Stack Manager (CSM)

A unified CLI tool for managing Docker and Podman Compose stacks on a single host. CSM standardizes how you organize, create, and interact with your containerized applications, keeping your homelab or cloud server clean and easily backup-able.

---

**WARNING**: This project works but probably contains bugs. Please make sure you back up any container configs before you use these scripts at your own risk. Please see the [Disclaimer](##Disclaimer) below.

```

## Features

- **Unified Interface**: Wraps standard `docker compose` / `podman compose` commands into short, memorable syntax (`csm up`, `csm down`, `csm logs`).
- **Auto Scope Detection**: Automatically detects whether a stack should run as Docker Swarm or local compose. Falls back to marker files (`.swarm` / `.local`) when needed.
- **Standardized Structure**: Forces all container stacks into a single root directory (`/srv/stacks` by default) with isolated `.env` and `appdata/` directories.
- **Automated Setup**: The installer detects your container runtime, creates directories, sets permissions, and symlinks everything.
- **Built-in Backups**: Easily snapshot a stack and its configuration to a centralized `.backups` directory.
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
   ```bash
   mkdir -p ~/git
   git clone https://gitlab.com/techtinker/container-stack-manager.git ~/git/container-stack-manager
   cd ~/git/container-stack-manager
   ```

2. **Ensure the installer is executable:**
   ```bash
   chmod +x csm-install.sh
   ```

3. **(Optional) Customize the installation:**
   You can change defaults before running the installer:
   ```bash
   export CSM_ROOT_DIR=/opt/docker        # default: /srv/stacks
   export CSM_STACKS_UID=1000             # default: 1000
   export CSM_STACKS_GID=2000             # default: 2000
   ```

4. **Run the installer:**
   ```bash
   sudo ./csm-install.sh
   ```

   The installer will prompt you for configuration values. Use `-f` flag to skip prompts (force mode):
   ```bash
   sudo ./csm-install.sh -f
   ```

5. **The installer will:**
   1. Detect or offer to install Podman, Docker Local, or Docker Swarm
   2. Check / start the container service
   3. Create a runtime group (`docker` or `podman`) at GID 2000 (if absent) and add your user to it
   4. Build the directory structure under `CSM_ROOT_DIR`
   5. Copy core files (`csm.sh`) and set permissions
   6. Create the `~/stacks` convenience symlink
   7. Symlink `csm` into `/usr/local/bin`

### Post-Installation

- **NOTE:** If you were added to the runtime group, **log out and log back in** to your terminal session (or reboot) so group ownership is applied before using the `csm` command.
- Access your stacks at `~/stacks` (symlinked to `CSM_ROOT_DIR`).
- Customize your setup by editing `user.conf`:
  ```bash
  csm config edit
  ```

---

## File Layout

### Repository (Pre-install)
```
./<repo>/
├── csm.sh              ← Main runtime script, symlinked to /usr/local/bin/csm
├── csm-install.sh      ← One-shot installer (run once; sets up the environment)
├── example.yml         ← Example compose config file
├── example.env         ← Example environment template
└── README.md           ← This file
```

### Installed Environment (Post-install)
By default, CSM installs everything to `/srv/stacks` (accessible via `~/stacks` symlink).

```
/srv/stacks/                     ← CSM root directory (customizable via CSM_ROOT_DIR)
├── .backups/                    ← Automated stack backups
│   └── <stack>/                 - Individual stack backups subfolder
│       └── <stack>-YYYYMMDD_HHMMSS.tar.gz
├── .configs/                    ← Shared resources and tools
│   ├── csm.sh                   ← Main CSM script
│   ├── local.env                ← Environment variables for local scoped containers
│   ├── swarm.env                ← Environment variables for swarm scoped containers
│   ├── local.yml                ← Compose template for local/Podman
│   ├── swarm.yml                ← Compose template for Docker Swarm scoped containers
│   ├── local.env                ← Environment variables for local scoped containers
│   └── user.conf                ← User configuration values
├── .secrets/                    ← Secrets and environment variable templates
│   └── <variable_name>.secret   ← Secret file per secret variable
├── .modules/                    ← Pre-configured stack templates (feature still in development)
└── <stack>/                     ← Individual stack directories
    ├── .env                     ← Stack-specific environment variables
    ├── .local or .swarm         ← Scope marker file
    ├── certs/                   ← Certificate files if used by the container
    ├── appdata/                 ← Container data/config directories
    └── compose.yml              ← Stack containers configuration
```

---

## Quick Start

Once installed, the `csm` command is available system-wide.

### 1. Create a new stack
Creates the folder structure and skeleton files for a container stack
```bash
csm create my_stack
```

### 2. Edit the Compose file
Opens the newly created `compose.yml` in your default `$EDITOR`.
```bash
csm edit my_stack
```

### 3. Start the stack
```bash
csm up my_stack
```

### 4. Check status
```bash
csm ps                  # Shows all containers across all stacks
csm status my_stack     # Shows status for a specific stack
```

### 5. View logs
```bash
csm logs my_stack
```

---

## Command Reference

Run `csm --help` at any time to see the full list of commands.

```
csm <command> [<stack-name>] [options]
```

### Stack Lifecycle

| Command | Aliases | Description |
|---|---|---|
| `create <stack>` | `c` | Scaffold a new stack directory + compose file |
| `new <stack>` | `n` | Alias for `create` |
| `edit <stack>` | `e` | Open `compose.yml` in `$EDITOR` |
| `rename <old> <new>` | `r` | Rename a stack directory |
| `remove <stack>` | `rm` | Stop and remove containers (prompts) |
| `delete <stack>` | `dt` | Permanently delete stack + all data (prompts) |
| `backup <stack>` | `bu` | Archive stack to `.backups/` as tar.gz |
| `recreate <stack>` | `rc` | Delete and recreate stack from scratch (prompts) |
| `purge [stack...]` | `xx` | Purge one or all stacks — **WARNING: FINAL** |

### Stack Operations

| Command | Aliases | Description |
|---|---|---|
| `up <stack>` | `u` | Deploy stack (`compose up -d --remove-orphans`) |
| `down <stack>` | `d`, `dn` | Stop and remove containers (`compose down`) |
| `bounce <stack>` | `b` | Bring stack down then back up |
| `start <stack>` | `st` | Start stopped containers |
| `stop <stack>` | `sp` | Stop containers without removing |
| `restart <stack>` | `rs` | Restart containers |
| `update <stack>` | `ud` | Pull latest images then redeploy |

### Information

| Command | Aliases | Description |
|---|---|---|
| `list` | `l`, `ls` | List all stacks with running state and scope |
| `status <stack>` | `s` | Show container/service status |
| `verify <stack>` | `v` | Validate `compose.yml` syntax |
| `inspect <stack>` | `i` | Inspect stack configuration |
| `logs <stack> [n]` | `g` | Follow logs (default: last 50 lines) |
| `ps` | | List all containers (formatted, colorized) |
| `net <action>` | | Network info: `host`, `inspect [name]`, `list` |
| `module` | `m` | Module management (not yet implemented) |

### Configuration

| Command | Aliases | Description |
|---|---|---|
| `config show` | `cfg show` | Print active config values |
| `config edit` | `cfg edit` | Open `user.conf` in `$EDITOR` |
| `config reload` | `cfg reload` | Re-source config files |

### Secrets Management

| Command | Aliases | Description |
|---|---|---|
| `secret <name>` | | Create a Docker secret (swarm required) |
| `secret ls` | | List all Docker secrets |
| `secret rm <name>` | | Remove a Docker secret and its backup file |

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

Some helpful shell aliases:

| Alias | Description |
|---|---|
| `cds [stack]` | cd into CSM root directory (`$CSM_ROOT_DIR`) |
| `hostip` | Show host public IP |
| `lanip <container>` | Show container IP via ipinfo.io |
| `vpnip <container>` | Show container IP + host IP side-by-side |
| `genkey [number]` | Generates random value using "openssl rand -hex ## (32 is default) |
| `wtup <container>` | Updates container using nicholas-fedor's Watchtower fork. |

```bash
eval "$(csm --aliases)"
```

  Suggestion: add the above line to your `.bashrc`/`.zshrc` or `.profile` so these aliases are loaded in each terminal session.

---

## Scope Detection

CSM automatically determines whether a stack runs as **Docker Swarm** or **local compose** (Docker Compose / Podman Compose):

1. **Podman** → always local
2. **Marker files** → `.swarm` or `.local` in stack directory (explicit override)
3. **Swarm inactive** → local
4. **Swarm active + stack deployed** → swarm
5. **Fallback** → local

Use `.swarm` or `.local` marker files to force a specific scope when needed.

---

## Configuration

Configuration values are loaded in this order (later sources override earlier):

1. **Defaults** — Built-in default values
2. **`user.conf`** — User configuration (created during install)
3. **Environment variables** — `CSM_*` prefix takes highest precedence

Edit with `csm config edit` or manually edit `CSM_ROOT_DIR/.configs/user.conf`.

### Configuration Variables

| Variable | Default Value | Description |
|---|---|---|
| `CSM_VERSION` | 0.5.0 | CSM version |
| `CSM_RUNTIME` | (auto-detect) | `docker` or `podman` |
| `CSM_UID` | (current user) | UID for stack directory ownership |
| `CSM_GID` | 2000 | GID for stack directory ownership |
| `CSM_DIR` | `/srv/stacks` | Base install directory |
| `CSM_BACKUPS` | `${CSM_DIR}/.backups` | Backup archive location |
| `CSM_CONFIGS` | `${CSM_DIR}/.configs` | Config files location |
| `CSM_SECRETS` | `${CSM_DIR}/.secrets` | Secrets backup location |
| `CSM_TEMPLATES` | `${CSM_DIR}/.templates` | Templates location |
| `CSM_NETWORK` | `external_edge` | Default external network |
| `CSM_NET_CIDR` | `172.20.0.0/16` | Network subnet |
| `CSM_VOLUME_SCOPE` | `local` | Volume scope |
| `CSM_VOLUME_LABEL` | `csm_volume` | Volume label |
| `CSM_BACKUP_MAX_AGE` | 30 | Backup retention (days) |
| `CSM_BACKUP_COMPRESSION` | `zip` | Backup compression format |
| `CSM_ENV_LOCAL` | `local.env` | Local environment file |
| `CSM_ENV_SWARM` | `swarm.env` | Swarm environment file |
| `CSM_YML_LOCAL` | `local.yml` | Local compose file |
| `CSM_YML_SWARM` | `swarm.yml` | Swarm compose file |

---

## Disclaimer

The idea for this project originated from @gkoerk's Docker setup for QTS. The scripting and recent rewrite are my own work, with assistance from LLMs for code review and bug finding.

Contributors have scripted this project to work as advertised to the best of their ability, but mistakes can and will happen. If you decide to use these scripts, you are expected to have done your own due diligence, read the scripts, and understood them — you accept all responsibility and risk associated herein.

For questions or issues, I'm active in the following communities:
- [QNAP Unofficial Discord](https://discord.gg/NaxEB4sz7G)
- [Ugreen Official Discord](https://discord.gg/JQywpNUZU7)
- [Techtinker Matrix](https://matrix.to/#/!AESnmgfDCZGhIREtbb:matrix.org?via=matrix.org)

## License

Use of this project is governed by the BSD 3-Clause License – see [LICENSE](LICENSE) for details.
