#!/bin/bash
# Ractor - .rac Package Manager v.3.10r21
# https://github.com/CyberHuman-bot/Ractor

set -e

# ───────── CONFIGURATION ─────────
CONFIG_FILES=("/etc/ractor.conf" "$HOME/.config/ractor.conf")
RACTOR_REPO="https://raw.githubusercontent.com/CyberHuman-bot/Ractor/refs/heads/main/"

if [[ $EUID -eq 0 ]]; then
    INSTALL_BIN="/usr/bin"
    INSTALL_LIB="/usr/lib/ractor"
    RACTOR_LIB="/var/lib/ractor"
    DESKTOP_ENTRIES="/usr/share/applications"
else
    INSTALL_BIN="$HOME/.local/bin"
    INSTALL_LIB="$HOME/.local/lib/ractor"
    RACTOR_LIB="$HOME/.local/share/ractor"
    DESKTOP_ENTRIES="$HOME/.local/share/applications"
fi

RACTOR_CACHE="$RACTOR_LIB/cache"
RACTOR_INSTALLED="$RACTOR_LIB/installed"
RACTOR_TMP="$RACTOR_LIB/tmp"

for cfg in "${CONFIG_FILES[@]}"; do
    [[ -f "$cfg" ]] && source "$cfg"
done

# ───────── COLORS ─────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

msg()     { echo -e "${GREEN}${BOLD}==>${NC} $1"; }
error()   { echo -e "${RED}${BOLD}Error:${NC} $1" >&2; exit 1; }
warn()    { echo -e "${YELLOW}${BOLD}Warning:${NC} $1"; }
info()    { echo -e "${BLUE}${BOLD}::${NC} $1"; }
success() { echo -e "${CYAN}${BOLD} ✓${NC} $1"; }

# ───────── HELPERS ─────────
init_dirs() {
    mkdir -p "$INSTALL_BIN" "$INSTALL_LIB" "$RACTOR_CACHE" \
             "$RACTOR_INSTALLED" "$RACTOR_TMP" "$DESKTOP_ENTRIES"
}

check_deps() {
    local deps=("curl" "tar" "jq")
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || error "Dependency '$dep' is missing"
    done
}

# ───────── META PARSER ─────────
# META file format:
# name=myapp
# version=1.0.0
# description=My cool app
# maintainer=yaman
# depends=curl,git,node
# type=binary|react|script
# electron=true|false (only for react type)

parse_meta() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && error "META file not found in package"

    PKG_NAME=$(grep '^name=' "$meta_file" | cut -d= -f2)
    PKG_VERSION=$(grep '^version=' "$meta_file" | cut -d= -f2)
    PKG_DESC=$(grep '^description=' "$meta_file" | cut -d= -f2)
    PKG_MAINTAINER=$(grep '^maintainer=' "$meta_file" | cut -d= -f2)
    PKG_DEPENDS=$(grep '^depends=' "$meta_file" | cut -d= -f2)
    PKG_TYPE=$(grep '^type=' "$meta_file" | cut -d= -f2 || echo "binary")
    PKG_ELECTRON=$(grep '^electron=' "$meta_file" | cut -d= -f2 || echo "false")

    [[ -z "$PKG_NAME" ]] && error "META: 'name' is required"
    [[ -z "$PKG_VERSION" ]] && error "META: 'version' is required"
}

# ───────── DEPENDENCY CHECK ─────────
check_package_deps() {
    local deps="$1"
    [[ -z "$deps" ]] && return 0

    info "Checking dependencies..."
    IFS=',' read -ra dep_list <<< "$deps"
    local missing=()

    for dep in "${dep_list[@]}"; do
        dep=$(echo "$dep" | xargs) # trim whitespace
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        read -p "Try to install them with apt? [y/N] " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt install -y "${missing[@]}" || warn "Some dependencies could not be installed"
        else
            warn "Continuing without installing dependencies"
        fi
    else
        success "All dependencies satisfied"
    fi
}

# ───────── OPTIONAL/RECOMMENDED ─────────
handle_optional() {
    local optional_file="$1"
    [[ ! -f "$optional_file" ]] && return 0

    info "Recommended packages:"
    cat "$optional_file"
    echo
    read -p "Install recommended packages? [y/N] " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        while IFS= read -r pkg; do
            [[ -z "$pkg" || "$pkg" == \#* ]] && continue
            sudo apt install -y "$pkg" 2>/dev/null || warn "Could not install recommended: $pkg"
        done < "$optional_file"
    fi
}

# ───────── INSTALL .rac ─────────
ractor_install() {
    check_deps
    init_dirs
    local input="$1"
    [[ -z "$input" ]] && error "No package specified. Usage: ractor install <file.rac|url|name>"

    local rac_file=""

    # Handle URL download
    if [[ "$input" =~ ^https?:// ]]; then
        info "Downloading package..."
        rac_file="$RACTOR_TMP/$(basename "$input")"
        curl -fsSL "$input" -o "$rac_file" || error "Download failed"

    # Handle local file
    elif [[ -f "$input" ]]; then
        rac_file="$input"

    # Handle repo lookup by name
    else
        info "Looking up '$input' in repository..."
        local pkg_url
        pkg_url=$(curl -fsSL "${RACTOR_REPO}packages.json" 2>/dev/null | \
            jq -r --arg n "$input" '.packages[] | select(.name==$n) | .url' 2>/dev/null)
        [[ -z "$pkg_url" || "$pkg_url" == "null" ]] && error "Package '$input' not found"
        info "Found: $pkg_url"
        rac_file="$RACTOR_TMP/${input}.rac"
        curl -fsSL "$pkg_url" -o "$rac_file" || error "Download failed"
    fi

    [[ ! -f "$rac_file" ]] && error "Package file not found: $rac_file"

    # Extract
    local extract_dir="$RACTOR_TMP/extract_$$"
    mkdir -p "$extract_dir"
    info "Extracting package..."
    tar -xzf "$rac_file" -C "$extract_dir" || error "Failed to extract .rac file (must be a gzipped tar)"

    # Parse META
    parse_meta "$extract_dir/META"

    msg "Installing $PKG_NAME v$PKG_VERSION"
    [[ -n "$PKG_DESC" ]] && info "$PKG_DESC"

    # Check if already installed
    if [[ -f "$RACTOR_INSTALLED/$PKG_NAME.json" ]]; then
        warn "$PKG_NAME is already installed"
        read -p "Reinstall? [y/N] " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { rm -rf "$extract_dir"; exit 0; }
        ractor_remove "$PKG_NAME"
    fi

    # Check dependencies
    check_package_deps "$PKG_DEPENDS"

    # Handle optional/recommended
    handle_optional "$extract_dir/optional/recommended"

    # Install based on type
    local install_dir="$INSTALL_LIB/$PKG_NAME"
    mkdir -p "$install_dir"

    case "$PKG_TYPE" in
        binary)
            if [[ -d "$extract_dir/binaries" ]]; then
                info "Installing binaries..."
                for bin in "$extract_dir/binaries/"*; do
                    [[ -f "$bin" ]] || continue
                    chmod +x "$bin"
                    cp "$bin" "$INSTALL_BIN/"
                    success "Installed: $(basename "$bin") → $INSTALL_BIN/"
                done
            fi
            cp -r "$extract_dir/." "$install_dir/"
            ;;

        react)
            info "React app detected"
            [[ ! -f "$extract_dir/binaries/package.json" ]] && error "React app missing package.json in binaries/"
            cp -r "$extract_dir/binaries/." "$install_dir/"
            cd "$install_dir"

            if [[ "$PKG_ELECTRON" == "true" ]]; then
                info "Electron app — installing electron..."
                command -v npm &>/dev/null || error "npm is required for React/Electron apps"
                npm install --prefer-offline --no-audit || error "npm install failed"
                npm run build 2>/dev/null || true
                # Create launcher
                cat > "$INSTALL_BIN/$PKG_NAME" <<EOF
#!/bin/bash
cd "$install_dir" && npm start
EOF
                chmod +x "$INSTALL_BIN/$PKG_NAME"
            else
                info "React app (no electron) — building..."
                command -v npm &>/dev/null || error "npm is required for React apps"
                npm install --prefer-offline --no-audit || error "npm install failed"
                npm run build || error "Build failed"
                cat > "$INSTALL_BIN/$PKG_NAME" <<EOF
#!/bin/bash
cd "$install_dir" && npx serve build
EOF
                chmod +x "$INSTALL_BIN/$PKG_NAME"
            fi
            ;;

        script)
            if [[ -d "$extract_dir/binaries" ]]; then
                info "Installing scripts..."
                for scr in "$extract_dir/binaries/"*; do
                    [[ -f "$scr" ]] || continue
                    chmod +x "$scr"
                    cp "$scr" "$INSTALL_BIN/"
                    success "Installed: $(basename "$scr") → $INSTALL_BIN/"
                done
            fi
            cp -r "$extract_dir/." "$install_dir/"
            ;;

        *)
            warn "Unknown type '$PKG_TYPE', treating as binary"
            cp -r "$extract_dir/." "$install_dir/"
            ;;
    esac

    # Run afterinstall
    if [[ -f "$extract_dir/afterinstall" ]]; then
        info "Running post-install script..."
        chmod +x "$extract_dir/afterinstall"
        bash "$extract_dir/afterinstall" || warn "Post-install script exited with errors"
    fi

    # Create desktop entry if icon/name present
    if [[ -f "$extract_dir/binaries/$PKG_NAME.png" ]] || [[ -n "$PKG_DESC" ]]; then
        cat > "$DESKTOP_ENTRIES/$PKG_NAME.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$PKG_NAME
Comment=$PKG_DESC
Exec=$INSTALL_BIN/$PKG_NAME
Icon=$install_dir/binaries/$PKG_NAME.png
Terminal=false
Categories=Application;
EOF
    fi

    # Save install record
    cat > "$RACTOR_INSTALLED/$PKG_NAME.json" <<EOF
{
    "name": "$PKG_NAME",
    "version": "$PKG_VERSION",
    "description": "$PKG_DESC",
    "maintainer": "$PKG_MAINTAINER",
    "type": "$PKG_TYPE",
    "install_date": "$(date -Iseconds)",
    "install_dir": "$install_dir"
}
EOF

    rm -rf "$extract_dir"
    msg "$PKG_NAME v$PKG_VERSION installed successfully!"
}

# ───────── REMOVE ─────────
ractor_remove() {
    local name="$1"
    [[ -z "$name" ]] && error "No package specified"
    [[ ! -f "$RACTOR_INSTALLED/$name.json" ]] && error "$name is not installed"

    msg "Removing $name..."
    local install_dir
    install_dir=$(jq -r '.install_dir' "$RACTOR_INSTALLED/$name.json")
    local pkg_type
    pkg_type=$(jq -r '.type' "$RACTOR_INSTALLED/$name.json")

    # Remove binaries
    if [[ "$pkg_type" == "binary" || "$pkg_type" == "script" ]]; then
        for bin in "$install_dir/binaries/"*; do
            [[ -f "$bin" ]] && rm -f "$INSTALL_BIN/$(basename "$bin")"
        done
    elif [[ "$pkg_type" == "react" ]]; then
        rm -f "$INSTALL_BIN/$name"
    fi

    [[ -d "$install_dir" ]] && rm -rf "$install_dir"
    rm -f "$DESKTOP_ENTRIES/$name.desktop"
    rm -f "$RACTOR_INSTALLED/$name.json"
    success "$name removed"
}

# ───────── UPDATE ─────────
ractor_update() {
    local name="$1"
    [[ -z "$name" ]] && error "No package specified"
    [[ ! -f "$RACTOR_INSTALLED/$name.json" ]] && error "$name is not installed"

    local old_version
    old_version=$(jq -r '.version' "$RACTOR_INSTALLED/$name.json")
    msg "Updating $name (current: v$old_version)..."

    # Re-install from repo
    ractor_install "$name"
}

# ───────── LIST ─────────
ractor_list() {
    [[ ! -d "$RACTOR_INSTALLED" ]] || [[ -z "$(ls -A "$RACTOR_INSTALLED" 2>/dev/null)" ]] && {
        info "No packages installed"
        return
    }
    msg "Installed packages:"
    echo
    printf "${BOLD}%-20s %-10s %-10s %-30s${NC}\n" "NAME" "VERSION" "TYPE" "DESCRIPTION"
    printf "%-20s %-10s %-10s %-30s\n" "────────────────────" "─────────" "─────────" "──────────────────────────────"
    for f in "$RACTOR_INSTALLED"/*.json; do
        printf "%-20s %-10s %-10s %-30s\n" \
            "$(jq -r '.name' "$f")" \
            "$(jq -r '.version' "$f")" \
            "$(jq -r '.type' "$f")" \
            "$(jq -r '.description' "$f" | cut -c1-30)"
    done
    echo
}

# ───────── PACK ─────────
# Create a .rac package from a directory
ractor_pack() {
    local dir="$1"
    [[ -z "$dir" ]] && error "No directory specified. Usage: ractor pack <directory>"
    [[ ! -d "$dir" ]] && error "Directory not found: $dir"
    [[ ! -f "$dir/META" ]] && error "META file not found in $dir"

    parse_meta "$dir/META"
    local output="${PKG_NAME}-${PKG_VERSION}.rac"

    info "Packing $PKG_NAME v$PKG_VERSION..."
    tar -czf "$output" -C "$dir" . || error "Failed to create package"
    success "Created: $output"
}

# ───────── INFO ─────────
ractor_info() {
    local name="$1"
    [[ -z "$name" ]] && error "No package specified"

    if [[ -f "$RACTOR_INSTALLED/$name.json" ]]; then
        msg "Package info: $name (installed)"
        jq -r '. | "  Name:        \(.name)\n  Version:     \(.version)\n  Type:        \(.type)\n  Description: \(.description)\n  Maintainer:  \(.maintainer)\n  Installed:   \(.install_date)\n  Location:    \(.install_dir)"' \
            "$RACTOR_INSTALLED/$name.json"
    else
        info "Looking up '$name' in repository..."
        local result
        result=$(curl -fsSL "${RACTOR_REPO}packages.json" 2>/dev/null | \
            jq -r --arg n "$name" '.packages[] | select(.name==$n) | "  Name:        \(.name)\n  Version:     \(.version // "unknown")\n  Description: \(.description)\n  URL:         \(.url)"' 2>/dev/null)
        [[ -z "$result" ]] && error "Package '$name' not found"
        msg "Package info: $name"
        echo "$result"
    fi
}

# ───────── SEARCH ─────────
ractor_search() {
    local q="$1"
    [[ -z "$q" ]] && error "No query specified"
    msg "Searching for '$q'..."
    curl -fsSL "${RACTOR_REPO}packages.json" -o "$RACTOR_CACHE/packages.json" 2>/dev/null || error "Failed to fetch package index"
    echo
    local results
    results=$(jq -r --arg q "$q" '.packages[] | select(.name | contains($q)) | "  \(.name) v\(.version // "?") - \(.description)"' "$RACTOR_CACHE/packages.json" 2>/dev/null)
    [[ -z "$results" ]] && { info "No packages found for '$q'"; return; }
    echo "$results"
    echo
}

# ───────── SELF-UPDATE ─────────
ractor_self_update() {
    msg "Updating Ractor..."
    local url="https://raw.githubusercontent.com/CyberHuman-bot/Ractor/refs/heads/main/ractor.sh"
    curl -fsSL "$url" -o /tmp/ractor.new || error "Download failed"
    chmod +x /tmp/ractor.new
    sudo mv /tmp/ractor.new /usr/local/bin/ractor
    success "Ractor updated!"
}

# ───────── HELP ─────────
ractor_help() {
    cat <<EOF

${BOLD}Ractor${NC} - .rac Package Manager v1.0.0

${BOLD}Usage:${NC}
  ractor <command> [options]

${BOLD}Commands:${NC}
  install <name|file.rac|url>   Install a .rac package
  remove  <name>                Remove an installed package
  update  <name>                Update an installed package
  list                          List installed packages
  search  <query>               Search repository
  info    <name>                Show package info
  pack    <directory>           Create a .rac from a directory
  self-update                   Update ractor itself
  help                          Show this message

${BOLD}.rac Package Structure:${NC}
  META                          Package metadata (required)
  binaries/                     Executables or app files
  afterinstall                  Post-install script (optional)
  optional/recommended          Recommended packages list (optional)

${BOLD}META Format:${NC}
  name=myapp
  version=1.0.0
  description=My cool app
  maintainer=yourname
  depends=curl,git
  type=binary|script|react
  electron=true|false

EOF
}

# ───────── DISPATCH ─────────
case "$1" in
    install)      ractor_install "$2" ;;
    remove|uninstall) ractor_remove "$2" ;;
    update|upgrade)   ractor_update "$2" ;;
    list|ls)      ractor_list ;;
    search)       ractor_search "$2" ;;
    info)         ractor_info "$2" ;;
    pack)         ractor_pack "$2" ;;
    self-update)  ractor_self_update ;;
    help|--help|-h|"") ractor_help ;;
    *)            error "Unknown command: $1. Run 'ractor help'" ;;
esac
