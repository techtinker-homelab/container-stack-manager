# Container Stack Manager (CSM)

A unified CLI tool for managing Docker and Podman Compose stacks on a single host. CSM standardizes how you organize, create, and interact with your containerized applications, keeping your homelab or cloud server clean and easily backup-able.

---

## 🚀 Features

- **Unified Interface**: Wraps standard `docker compose` commands into short, memorable syntax (`csm up`, `csm down`, `csm logs`).
- **Standardized Structure**: Forces all container stacks into a single root directory (`/srv/stacks` by default) with isolated `.env` and `appdata/` directories.
- **Automated Setup**: The installer handles Docker installation, user group permissions, directory generation, and symlinking.
- **Built-in Backups**: Easily snapshot a stack and its configuration to a centralized `.backup` directory.

---

## 📂 File Layout

### Repository (Pre-install)
```text
<repo>/
├── csm.sh              ← Main runtime script (symlinked to /usr/local/bin/csm during install)
├── csm-install.sh      ← One-shot installer (run once; sets up the environment)
├── default.conf        ← Default configuration values
└── example.env         ← Example global environment template
```

### Installed Environment (Post-install)
By default, CSM installs everything to `/srv/stacks` (accessible via a `~/stacks` symlink in your home folder).

```text
/srv/stacks/                           ← CSM_ROOT_DIR
   ├── .backup/                        ← Automated stack tarball backups
   │  └── <stack_name>_YYYYMMDD.tar.gz - Archived stack directory
   ├── .common/                        ← Shared resources and tools
   │  ├── .docker.env                  ← Global shared environment variables
   │  ├── csm.sh                       ← The CSM script with all container management functions
   │  ├── configs/                     - Variables and configuration files
   │  │  ├── default.conf              ← CSM default configs
   │  │  └── user.conf                 ← User overrides (edit this!)
   │  ├── secrets/                     ← Directory for shared docker secrets
   │  │  └── <variable_name>.secret    - Secret variables (one line per file)
   │  └── templates/                   - Pre-built stacks with compose and .env
   │     └── <stack>/                  -
   │        ├── compose.yml            -
   │        └── example.env            -
   └── <stack_name>/                   ← Your actual container stacks
      ├── .env                         ← Stack-specific environment variables (or symlink to global)
      ├── compose.yml                  ← The compose file
      └── appdata/                     ← Persistent mapped volumes
```

---

## 🛠️ Installation Guide

**Prerequisites:** A Linux host (Debian, Ubuntu, Fedora, or Arch). You do not need Docker pre-installed; the script will handle it.

| Requirement | Notes |
|---|---|
| bash ≥ 4.2 | Ships with most modern Linux distros |
| docker compose v2 | `docker compose version` must work (`docker-compose` v1 is **not** supported) |
| sudo or root | Installer only; runtime does not need elevation |

Podman with `podman compose` is auto-detected as a fallback.

---

1. **Clone the repository:**
   ```bash
   git clone https://github.com/yourusername/container-stack-manager.git ~/container-stack-manager
   cd ~/container-stack-manager
   ```

2. **Make the installer executable:**
   ```bash
   chmod +x csm-install.sh
   ```

3. **Run the installer with sudo:**
   ```bash
   sudo ./csm-install.sh
   ```

4. **The installer will:**

   1. Create a `docker` user and group at UID/GID 2000 (if absent)
   2. Install Docker via `get.docker.com` (if absent)
   3. Check / start the Docker service
   4. Build the directory structure under `/srv/stacks`
   5. Copy core files and set permissions
   6. Create the `~/stacks` convenience symlink
   7. Symlink `csm` into `/usr/local/bin`

   > **Note:** If you are added to the `docker` group during install, log out and back in before using `csm`.

### Install using custom stacks directory:

```bash
CSM_ROOT_DIR=/srv/stacks # modify if you want a different stacks root dir
sudo ./csm-install.sh
```


5. **Post-Installation:**
   - The installer automatically adds your user to the `docker` group. **You must log out and log back in** (or reboot) for this to take effect.
   - Your stacks directory is now accessible at `~/stacks`.
   - Customize your setup by editing the user config: `nano ~/stacks/.common/configs/user.conf`.

---

## 📖 Quick Start & Usage

Once installed, the `csm` command is available system-wide.

### 1. Create a new stack
This generates the folder structure and a boilerplate `compose.yml`.
```bash
csm create my-app
```

### 2. Edit the Compose file
Opens the newly created `compose.yml` in your default `$EDITOR`.
```bash
csm modify my-app
```

### 3. Start the stack
Pulls the required images and starts the containers in the background.
```bash
csm up my-app
```

### 4. Check the status
View running containers and ports.
```bash
csm ps          # Shows all containers across all stacks
csm status my-app   # Shows status for a specific stack
```

### 5. View Logs
Follow the live logs for your stack (press `Ctrl+C` to exit).
```bash
csm logs my-app
```

---

## 💻 Command Reference

Run `csm --help` at any time to see the full list of commands:

```
csm <command> [<stack-name>]
```

### Stack Lifecycle

| Command | Aliases | Description |
|---|---|---|
| `create <stack>` | `c` | Scaffold a new stack directory |
| `modify <stack>` | `m` | Open `compose.yml` in `$EDITOR` |
| `remove <stack>` | `rm` | Stop + remove directory (prompts) |
| `delete <stack>` | `dt` | Stop + permanently delete all data (prompts) |
| `backup <stack>` | `bu` | Archive the stack to `backup/` using tar.gz |

### Stack Operations

| Command | Aliases | Description |
|---|---|---|
| `up <stack>` | `u`, `start` | Start the stack (`compose up -d`) |
| `down <stack>` | `d`, `dn`, `stop` | Stop the stack (`compose down`) |
| `bounce <stack>` | `b`, `recreate` | Fully recreate the stack |
| `restart <stack>` | `r`, `rs` | Restart the stack (`compose restart`) |
| `update <stack>` | `ud` | Pull images then start the stack |

### Information

| Command | Aliases | Description |
|---|---|---|
| `list` | `l`, `ls` | List all stacks with running state |
| `status <stack>` | `s` | List containers in stack (`compose ps`) |
| `validate <stack>` | `v` | Check compose syntax (`compose config -q`) |

### Configuration

```bash
csm config show    # print active config values
csm config edit    # open user.conf in $EDITOR
csm config reload  # re-source config files
```

---

## Configuration

Edit `CSM_ROOT_DIR/.common/configs/user.conf` (or `~/.config/csm/config`) to override defaults. Environment variables with a `CSM_` prefix take highest precedence.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `CSM_ROOT_DIR` | `/srv/stacks` | Base install directory |
| `CSM_STACKS_DIR` | `$CSM_ROOT_DIR` | Where stacks live |
| `CSM_BACKUP_DIR` | `$CSM_ROOT_DIR/.backup` | Backup archive location |
| `CSM_COMMON_DIR` | `$CSM_ROOT_DIR/.common` | Common config files |
| `CSM_NETWORK_NAME` | `csm_network` | Default external facing network |
| `CSM_STACK_FILE` | `compose.yml` | Compose filename per stack |

---

## License

MIT License – see [LICENSE](LICENSE) for details.
