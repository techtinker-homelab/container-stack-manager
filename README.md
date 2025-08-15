# Container Stack Manager (CSM)

A unified container stack management tool supporting multiple container runtimes (Docker, Podman, etc.).

## Features

- Stack lifecycle management (create, edit, remove, delete)
- Stack operations (up, down, restart, update)
- Stack information (list, status, validate)
- Template management
- Multi-runtime support
- Backup functionality

## Usage

```bash
./csm <command> [arguments]
```

### Stack Lifecycle

- `create <name>` - Create a new stack
- `modify <name>` - Edit stack configuration
- `remove <name>` - Remove stack (keep data)
- `delete <name>` - Delete stack and all data
- `backup <name>` - Backup stack configuration

### Stack Operations

- `up <name>` - Start a stack
- `down <name>` - Stop a stack
- `restart <name>` - Restart a stack
- `update <name>` - Update stack images

### Information

- `list` - List all stacks
- `status [name]` - Show stack status
- `validate <name>` - Validate stack configuration

### Templates

- `template <action>` - Manage templates (list, add, remove, update)

### Setup

- `install` - Run initial installation setup

## Installation

```bash
git clone https://github.com/Drauku/container-stack-manager.git
cd container-stack-manager
./install
```

## License

MIT License
