# Ractor 🗃️
> A lightweight `.rac` package manager for Linux

[![Version](https://img.shields.io/badge/version-3.10r26-blue)](https://github.com/elezaio-linux/Ractor)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)](https://github.com/elezaio-linux/Ractor)

---

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/elezaio-linux/Ractor/main/install.sh | bash
```

---

## Requirements

- `curl`
- `tar`
- `jq`

> These will be installed automatically via `apt` if missing.

---

## Usage

```
ractor <command> [args]
```

| Command | Description |
|---|---|
| `install <name\|file.rac\|url>` | Install a package |
| `remove <name>` | Remove a package |
| `update [name\|--all]` | Update one or all packages |
| `list` | List installed packages |
| `search <query>` | Search the package index |
| `info <name>` | Show package details |
| `pack [directory]` | Create a `.rac` from a directory |
| `verify <file.rac>` | Validate a `.rac` file |
| `clean` | Clear cache and temp files |
| `logs [lines]` | Show recent log entries |
| `self-update` | Update ractor itself |
| `version` | Show version |
| `help` | Show help message |

### Examples

```bash
ractor install myapp.rac
ractor install https://example.com/pkg.rac
ractor install myapp
ractor update --all
ractor remove myapp
ractor search text-editor
ractor pack ./myapp/
ractor verify myapp.rac
```

---

## Creating a Package

### Directory Structure

```
myapp/
├── META                    # Package metadata (required)
├── binaries/               # Executables or app source (required)
├── afterinstall            # Post-install hook script (optional)
└── optional/
    └── recommended         # Suggested apt packages (optional)
```

### META File

```ini
name=myapp
version=1.0.0
description=My awesome app
maintainer=yourname
depends=curl,git
type=binary
license=MIT
arch=any
```

| Field | Required | Values |
|---|---|---|
| `name` | ✅ | Package name |
| `version` | ✅ | e.g. `1.0.0` |
| `description` | ❌ | Short description |
| `maintainer` | ❌ | Your name |
| `depends` | ❌ | Comma-separated commands |
| `type` | ❌ | `binary` `script` `react` `appimage` |
| `electron` | ❌ | `true` or `false` (react only) |
| `license` | ❌ | e.g. `MIT` |
| `arch` | ❌ | `x86_64` `aarch64` `any` |

### Build & Install

```bash
ractor pack ./myapp/
ractor install myapp-1.0.0.rac
```

---

## Package Types

| Type | Description |
|---|---|
| `binary` | Compiled executables — copied directly to `~/.local/bin` |
| `script` | Shell scripts — copied directly to `~/.local/bin` |
| `react` | React/Node app — runs `npm install` + `npm run build` |
| `appimage` | AppImage — wrapped with a launcher script |

---

## File Locations

| Path | Purpose |
|---|---|
| `~/.local/bin/ractor` | Ractor itself |
| `~/.local/bin/` | Installed package binaries |
| `~/.local/lib/ractor/` | Installed package files |
| `~/.local/share/ractor/installed/` | Package records (JSON) |
| `~/.local/share/ractor/cache/` | Package index cache |
| `~/.local/share/ractor/ractor.log` | Log file |

> Root installs use `/usr/local/bin`, `/usr/lib/ractor`, `/var/lib/ractor`

---

## Configuration

Ractor reads config from (in order):

- `/etc/ractor.conf`
- `~/.config/ractor/ractor.conf`

---

## Updating Ractor

```bash
ractor self-update
```

---

## License

MIT © [elezaio-linux](https://github.com/elezaio-linux)
