#!/bin/bash
# Ractor - React App Package Manager v0.2.0
# https://github.com/CyberHuman-bot/Ractor/ractor.sh

set -e

# ───────── CONFIGURATION ─────────
CONFIG_FILES=("/etc/ractor.conf" "$HOME/.config/ractor.conf")
RACTOR_REPO="https://raw.githubusercontent.com/CyberHuman-bot/Ractor/refs/heads/apps/"
DESKTOP_ENTRIES_SYSTEM="/usr/share/applications"
DESKTOP_ENTRIES_USER="$HOME/.local/share/applications"

# Detect user vs root install
if [[ $EUID -eq 0 ]]; then
    RACTOR_DIR="${RACTOR_DIR:-/opt/ractor-apps}"
    RACTOR_LIB="${RACTOR_LIB:-/var/lib/ractor}"
    DESKTOP_ENTRIES="${DESKTOP_ENTRIES:-$DESKTOP_ENTRIES_SYSTEM}"
else
    RACTOR_DIR="${RACTOR_DIR:-$HOME/.local/share/ractor/apps}"
    RACTOR_LIB="${RACTOR_LIB:-$HOME/.local/share/ractor}"
    DESKTOP_ENTRIES="${DESKTOP_ENTRIES:-$DESKTOP_ENTRIES_USER}"
fi

RACTOR_CACHE="$RACTOR_LIB/cache"
RACTOR_INSTALLED="$RACTOR_LIB/installed"

# Load configuration files
for cfg in "${CONFIG_FILES[@]}"; do
    [[ -f "$cfg" ]] && source "$cfg"
done

# ───────── COLORS ─────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

msg()   { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; exit 1; }
warn()  { echo -e "${YELLOW}Warning:${NC} $1"; }
info()  { echo -e "${BLUE}::${NC} $1"; }

# ───────── HELPERS ─────────
check_root() { [[ $EUID -ne 0 ]] && [[ "$1" != "user" ]] && error "Run as root or use user mode"; }
check_deps() {
    local deps=("node" "npm" "git" "curl" "jq")
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || error "Dependency '$dep' missing"
    done
}
init_dirs() { mkdir -p "$RACTOR_DIR" "$RACTOR_CACHE" "$RACTOR_INSTALLED"; }

# ───────── INSTALL ─────────
ractor_install() {
    check_deps
    init_dirs
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"

    msg "Installing $app..."

    local app_dir="$RACTOR_DIR/$app"
    if [[ -f "$RACTOR_INSTALLED/$app.json" ]]; then
        warn "$app already installed"
        read -p "Reinstall? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
        ractor_remove "$app"
    fi

    # Install from Git URL or repo
    if [[ "$app" =~ ^https?:// ]] || [[ "$app" =~ ^git@ ]]; then
        info "Cloning from Git repository..."
        git clone "$app" "$app_dir" || error "Clone failed"
    else
        info "Fetching package info..."
        local manifest="$RACTOR_CACHE/$app.json"
        curl -fsSL "$RACTOR_REPO/packages/$app.json" -o "$manifest" 2>/dev/null || error "Package '$app' not found"
        local repo_url
        repo_url=$(jq -r '.repository' "$manifest" 2>/dev/null)
        [[ "$repo_url" == "null" ]] && error "Invalid package manifest"
        info "Cloning from $repo_url..."
        git clone "$repo_url" "$app_dir" || error "Clone failed"
    fi

    cd "$app_dir"
    info "Installing dependencies..."
    npm install --prefer-offline --no-audit || error "npm install failed"

    info "Building application..."
    npm run build || warn "Build may have failed"

    create_desktop_entry "$app" "$app_dir"

    # Save metadata
    cat > "$RACTOR_INSTALLED/$app.json" <<EOF
{
    "name": "$app",
    "install_date": "$(date -Iseconds)",
    "directory": "$app_dir",
    "version": "$(jq -r '.version' package.json 2>/dev/null || echo 'unknown')"
}
EOF

    msg "$app installed successfully!"
    info "Location: $app_dir"
}

# ───────── REMOVE ─────────
ractor_remove() {
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"
    [[ ! -f "$RACTOR_INSTALLED/$app.json" ]] && error "$app is not installed"

    msg "Removing $app..."
    local app_dir
    app_dir=$(jq -r '.directory' "$RACTOR_INSTALLED/$app.json")
    [[ -d "$app_dir" ]] && rm -rf "$app_dir"
    rm -f "$DESKTOP_ENTRIES/$app.desktop"
    rm -f "$RACTOR_INSTALLED/$app.json"
    msg "$app removed successfully!"
}

# ───────── UPDATE ─────────
ractor_update() {
    check_deps
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"
    [[ ! -f "$RACTOR_INSTALLED/$app.json" ]] && error "$app is not installed"

    msg "Updating $app..."
    local app_dir
    app_dir=$(jq -r '.directory' "$RACTOR_INSTALLED/$app.json")
    cd "$app_dir"
    info "Pulling latest changes..."
    git pull origin main || git pull origin master || warn "Pull may have failed"

    info "Updating dependencies..."
    npm install --prefer-offline --no-audit

    info "Rebuilding application..."
    npm run build || warn "Build may have failed"

    # Update metadata
    jq --arg date "$(date -Iseconds)" '.install_date=$date' "$RACTOR_INSTALLED/$app.json" > "$RACTOR_INSTALLED/$app.json.tmp"
    mv "$RACTOR_INSTALLED/$app.json.tmp" "$RACTOR_INSTALLED/$app.json"

    msg "$app updated successfully!"
}

# ───────── LIST ─────────
ractor_list() {
    [[ ! -d "$RACTOR_INSTALLED" ]] || [[ -z "$(ls -A "$RACTOR_INSTALLED" 2>/dev/null)" ]] && { info "No apps installed"; return; }
    msg "Installed React apps:"
    printf "%-20s %-15s %-30s\n" "NAME" "VERSION" "INSTALLED"
    printf "%-20s %-15s %-30s\n" "----" "-------" "---------"
    for f in "$RACTOR_INSTALLED"/*.json; do
        printf "%-20s %-15s %-30s\n" \
        "$(jq -r '.name' "$f")" \
        "$(jq -r '.version' "$f")" \
        "$(jq -r '.install_date' "$f")"
    done
}

# ───────── SEARCH ─────────
ractor_search() {
    local q="$1"
    [[ -z "$q" ]] && error "No query specified"
    msg "Searching for '$q'..."
    curl -fsSL "$RACTOR_REPO/packages.json" -o "$RACTOR_CACHE/packages.json" || error "Fetch failed"
    echo
    jq -r --arg q "$q" '.packages[] | select(.name | contains($q)) | "\(.name) - \(.description)"' "$RACTOR_CACHE/packages.json" || info "No packages found"
}

# ───────── INFO ─────────
ractor_info() {
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"

    # Check installed
    if [[ -f "$RACTOR_INSTALLED/$app.json" ]]; then
        jq -r '. | "Name: \(.name)\nVersion: \(.version)\nInstalled: \(.install_date)\nDirectory: \(.directory)"' "$RACTOR_INSTALLED/$app.json"
        return
    fi

    # Check repo
    local manifest="$RACTOR_CACHE/$app.json"
    curl -fsSL "$RACTOR_REPO/packages/$app.json" -o "$manifest" 2>/dev/null || { warn "Package '$app' not found"; return; }
    jq -r '. | "Name: \(.name)\nVersion: \(.version)\nDescription: \(.description)\nRepository: \(.repository)"' "$manifest"
}

# ───────── DESKTOP ENTRY ─────────
create_desktop_entry() {
    local app="$1" dir="$2"
    local display_name="$app" description="React Application"
    [[ -f "$dir/package.json" ]] && {
        display_name=$(jq -r '.name // .displayName' "$dir/package.json" 2>/dev/null || echo "$app")
        description=$(jq -r '.description' "$dir/package.json" 2>/dev/null || echo "$description")
    }
    mkdir -p "$(dirname "$DESKTOP_ENTRIES")"
    cat > "$DESKTOP_ENTRIES/$app.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$display_name
Comment=$description
Exec=bash -c 'cd "$dir" && npm start'
Icon=applications-internet
Terminal=false
Categories=Development;WebDevelopment;
EOF
    chmod +x "$DESKTOP_ENTRIES/$app.desktop"
}

# ───────── SELF-UPDATE ─────────
ractor_self_update() {
    local url="https://raw.githubusercontent.com/CyberHuman-bot/Ractor/refs/heads/main/ractor.sh"
    msg "Updating Ractor..."
    curl -fsSL "$url" -o /usr/local/bin/ractor || error "Download failed"
    chmod +x /usr/local/bin/ractor
    msg "Ractor updated successfully!"
}

# ───────── HELP ─────────
ractor_help() {
    cat <<EOF
Ractor - React App Package Manager v0.2.0

Usage: ractor <command> [options]

Commands:
    install <name|url>    Install a React app
    remove <name>         Remove an installed app
    update <name>         Update an installed app
    list                  List all installed apps
    search <query>        Search repository for apps
    info <name>           Show info for installed or repo app
    self-update           Update Ractor script
    help                  Show this message

EOF
}

# ───────── COMMAND DISPATCH ─────────
case "$1" in
    install) ractor_install "$2" ;;
    remove|uninstall) ractor_remove "$2" ;;
    update|upgrade) ractor_update "$2" ;;
    list|ls) ractor_list ;;
    search) ractor_search "$2" ;;
    info) ractor_info "$2" ;;
    self-update) ractor_self_update ;;
    help|--help|-h|"") ractor_help ;;
    *) error "Unknown command: $1" ;;
esac
