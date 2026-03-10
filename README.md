# Container Stack Manager (CSM)

A unified CLI tool for managing Docker / Podman Compose stacks on a single host.

---

## File Layout

### Repository (pre-install)

```
<repo>/
├── csm.sh              ← main runtime script (symlinked to /usr/local/bin/csm)
├── csm_functions.sh    ← core function library (sourced by csm.sh)
├── csm-install.sh      ← one-shot installer (run once; kept for re-installs)
├── default.conf        ← default configuration values
└── example.env         ← example per-stack .env template
```

### Installed structure

```
/srv/stacks/                        ← CSM_ROOT_DIR
├── backup/
│   └── <stack>/<stack>-YYYYMMDD_HHMMSS.tar.gz
├── common/
│   ├── configs/
│   │   ├── default.conf            ← shipped defaults (do not edit directly)
│   │   └── user.conf               ← your overrides (created on first edit)
│   ├── csm.sh
│   ├── csm_functions.sh
│   ├── csm-install.sh
│   └── secrets/                    ← mode 600; store .secret files here
└── stacks/
    └── <stack>/
        ├── .env                    ← per-stack environment variables
        ├── compose.yml
        └── appdata/
```

A convenience symlink `~/stacks → /srv/stacks` and a PATH entry `/usr/local/bin/csm → /srv/stacks/csm.sh` are created by the installer.

---

## Requirements

| Requirement | Notes |
|---|---|
| bash ≥ 4.2 | Ships with most modern Linux distros |
| docker compose v2 | `docker compose version` must work (`docker-compose` v1 is **not** supported) |
| sudo or root | Installer only; runtime does not need elevation |

Podman with `podman compose` is auto-detected as a fallback.

---

## Installation

```bash
git clone https://gitlab.com/techtinker/container-stack-manager.git
cd container-stack-manager
sudo ./csm-install.sh
```

The installer will:

1. Check / start the Docker service
2. Create a `docker` user and group at UID/GID 2000 (if absent)
3. Install Docker via `get.docker.com` (if absent)
4. Build the directory structure under `/srv/stacks`
5. Copy core files and set permissions
6. Create the `~/stacks` convenience symlink
7. Symlink `csm` into `/usr/local/bin`

> **Note:** If you are added to the `docker` group during install, log out and back in before using `csm`.

### Custom install root

```bash
CSM_ROOT_DIR=/opt/csm sudo ./csm-install.sh
```

---

## Usage

```
csm <command> [<stack-name>]
```

### Stack Lifecycle

| Command | Aliases | Description |
|---|---|---|
| `create <n>` | `c` | Scaffold a new stack directory |
| `modify <n>` | `m` | Open `compose.yml` in `$EDITOR` |
| `remove <n>` | `rm` | Stop + remove directory (prompts) |
| `delete <n>` | `dt` | Stop + permanently delete all data (prompts) |
| `backup <n>` | `bu` | Tar-gz the stack to `backup/` |

### Stack Operations

| Command | Aliases | Description |
|---|---|---|
| `up <n>` | `u`, `start` | `compose up -d` |
| `down <n>` | `d`, `dn`, `stop` | `compose down` |
| `bounce <n>` | `b`, `recreate` | down then up (full recreate) |
| `restart <n>` | `r`, `rs` | `compose restart` (no recreate) |
| `update <n>` | `ud` | Pull images then `compose up -d` |

### Information

| Command | Aliases | Description |
|---|---|---|
| `list` | `l`, `ls` | List all stacks with running state |
| `status <n>` | `s` | `compose ps` output |
| `validate <n>` | `v` | `compose config -q` syntax check |

### Configuration

```bash
csm config show    # print active config values
csm config edit    # open user.conf in $EDITOR
csm config reload  # re-source config files
```

---

## Configuration

Edit `CSM_ROOT_DIR/common/configs/user.conf` (or `~/.config/csm/config`) to override defaults. Environment variables with a `CSM_` prefix take highest precedence.

Key variables:

| Variable | Default | Description |
|---|---|---|
| `CSM_ROOT_DIR` | `/srv/stacks` | Base install directory |
| `CSM_STACKS_DIR` | `$CSM_ROOT_DIR/stacks` | Where stacks live |
| `CSM_BACKUP_DIR` | `$CSM_ROOT_DIR/backup` | Backup archive location |
| `CSM_NETWORK_NAME` | `csm_network` | Default external Docker network |
| `CSM_STACK_FILE` | `compose.yml` | Compose filename per stack |

---

## License

MIT License – see [LICENSE](LICENSE) for details.
