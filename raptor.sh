#!/bin/bash
# Raptor - React App Package Manager v0.2.0
# https://github.com/CyberHuman-bot/Raptor/raptor.sh

set -e

# ───────── CONFIGURATION ─────────
CONFIG_FILES=("/etc/raptor.conf" "$HOME/.config/raptor.conf")
RAPTOR_REPO="https://raw.githubusercontent.com/CyberHuman-bot/Raptor/apps"
DESKTOP_ENTRIES_SYSTEM="/usr/share/applications"
DESKTOP_ENTRIES_USER="$HOME/.local/share/applications"

# Detect user vs root install
if [[ $EUID -eq 0 ]]; then
    RAPTOR_DIR="${RAPTOR_DIR:-/opt/raptor-apps}"
    RAPTOR_LIB="${RAPTOR_LIB:-/var/lib/raptor}"
    DESKTOP_ENTRIES="${DESKTOP_ENTRIES:-$DESKTOP_ENTRIES_SYSTEM}"
else
    RAPTOR_DIR="${RAPTOR_DIR:-$HOME/.local/share/raptor/apps}"
    RAPTOR_LIB="${RAPTOR_LIB:-$HOME/.local/share/raptor}"
    DESKTOP_ENTRIES="${DESKTOP_ENTRIES:-$DESKTOP_ENTRIES_USER}"
fi

RAPTOR_CACHE="$RAPTOR_LIB/cache"
RAPTOR_INSTALLED="$RAPTOR_LIB/installed"

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
init_dirs() { mkdir -p "$RAPTOR_DIR" "$RAPTOR_CACHE" "$RAPTOR_INSTALLED"; }

# ───────── INSTALL ─────────
raptor_install() {
    check_deps
    init_dirs
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"

    msg "Installing $app..."

    local app_dir="$RAPTOR_DIR/$app"
    if [[ -f "$RAPTOR_INSTALLED/$app.json" ]]; then
        warn "$app already installed"
        read -p "Reinstall? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
        raptor_remove "$app"
    fi

    # Install from Git URL or repo
    if [[ "$app" =~ ^https?:// ]] || [[ "$app" =~ ^git@ ]]; then
        info "Cloning from Git repository..."
        git clone "$app" "$app_dir" || error "Clone failed"
    else
        info "Fetching package info..."
        local manifest="$RAPTOR_CACHE/$app.json"
        curl -fsSL "$RAPTOR_REPO/packages/$app.json" -o "$manifest" 2>/dev/null || error "Package '$app' not found"
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
    cat > "$RAPTOR_INSTALLED/$app.json" <<EOF
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
raptor_remove() {
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"
    [[ ! -f "$RAPTOR_INSTALLED/$app.json" ]] && error "$app is not installed"

    msg "Removing $app..."
    local app_dir
    app_dir=$(jq -r '.directory' "$RAPTOR_INSTALLED/$app.json")
    [[ -d "$app_dir" ]] && rm -rf "$app_dir"
    rm -f "$DESKTOP_ENTRIES/$app.desktop"
    rm -f "$RAPTOR_INSTALLED/$app.json"
    msg "$app removed successfully!"
}

# ───────── UPDATE ─────────
raptor_update() {
    check_deps
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"
    [[ ! -f "$RAPTOR_INSTALLED/$app.json" ]] && error "$app is not installed"

    msg "Updating $app..."
    local app_dir
    app_dir=$(jq -r '.directory' "$RAPTOR_INSTALLED/$app.json")
    cd "$app_dir"
    info "Pulling latest changes..."
    git pull origin main || git pull origin master || warn "Pull may have failed"

    info "Updating dependencies..."
    npm install --prefer-offline --no-audit

    info "Rebuilding application..."
    npm run build || warn "Build may have failed"

    # Update metadata
    jq --arg date "$(date -Iseconds)" '.install_date=$date' "$RAPTOR_INSTALLED/$app.json" > "$RAPTOR_INSTALLED/$app.json.tmp"
    mv "$RAPTOR_INSTALLED/$app.json.tmp" "$RAPTOR_INSTALLED/$app.json"

    msg "$app updated successfully!"
}

# ───────── LIST ─────────
raptor_list() {
    [[ ! -d "$RAPTOR_INSTALLED" ]] || [[ -z "$(ls -A "$RAPTOR_INSTALLED" 2>/dev/null)" ]] && { info "No apps installed"; return; }
    msg "Installed React apps:"
    printf "%-20s %-15s %-30s\n" "NAME" "VERSION" "INSTALLED"
    printf "%-20s %-15s %-30s\n" "----" "-------" "---------"
    for f in "$RAPTOR_INSTALLED"/*.json; do
        printf "%-20s %-15s %-30s\n" \
        "$(jq -r '.name' "$f")" \
        "$(jq -r '.version' "$f")" \
        "$(jq -r '.install_date' "$f")"
    done
}

# ───────── SEARCH ─────────
raptor_search() {
    local q="$1"
    [[ -z "$q" ]] && error "No query specified"
    msg "Searching for '$q'..."
    curl -fsSL "$RAPTOR_REPO/packages.json" -o "$RAPTOR_CACHE/packages.json" || error "Fetch failed"
    echo
    jq -r --arg q "$q" '.packages[] | select(.name | contains($q)) | "\(.name) - \(.description)"' "$RAPTOR_CACHE/packages.json" || info "No packages found"
}

# ───────── INFO ─────────
raptor_info() {
    local app="$1"
    [[ -z "$app" ]] && error "No app specified"

    # Check installed
    if [[ -f "$RAPTOR_INSTALLED/$app.json" ]]; then
        jq -r '. | "Name: \(.name)\nVersion: \(.version)\nInstalled: \(.install_date)\nDirectory: \(.directory)"' "$RAPTOR_INSTALLED/$app.json"
        return
    fi

    # Check repo
    local manifest="$RAPTOR_CACHE/$app.json"
    curl -fsSL "$RAPTOR_REPO/packages/$app.json" -o "$manifest" 2>/dev/null || { warn "Package '$app' not found"; return; }
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
raptor_self_update() {
    local url="https://raw.githubusercontent.com/your-repo/raptor/main/raptor.sh"
    msg "Updating Raptor..."
    curl -fsSL "$url" -o /usr/local/bin/raptor || error "Download failed"
    chmod +x /usr/local/bin/raptor
    msg "Raptor updated successfully!"
}

# ───────── HELP ─────────
raptor_help() {
    cat <<EOF
Raptor - React App Package Manager v0.2.0

Usage: raptor <command> [options]

Commands:
    install <name|url>    Install a React app
    remove <name>         Remove an installed app
    update <name>         Update an installed app
    list                  List all installed apps
    search <query>        Search repository for apps
    info <name>           Show info for installed or repo app
    self-update           Update Raptor script
    help                  Show this message

EOF
}

# ───────── COMMAND DISPATCH ─────────
case "$1" in
    install) raptor_install "$2" ;;
    remove|uninstall) raptor_remove "$2" ;;
    update|upgrade) raptor_update "$2" ;;
    list|ls) raptor_list ;;
    search) raptor_search "$2" ;;
    info) raptor_info "$2" ;;
    self-update) raptor_self_update ;;
    help|--help|-h|"") raptor_help ;;
    *) error "Unknown command: $1" ;;
esac
