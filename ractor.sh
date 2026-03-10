#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║         Ractor - .rac Package Manager v3.10r22            ║
# ║         https://github.com/CyberHuman-bot/Racto r         ║
# ╚═══════════════════════════════════════════════════════════╝

set -euo pipefail

# ───────── VERSION ─────────
RACTOR_VERSION="3.10r22"
RACTOR_REPO_RAW="https://raw.githubusercontent.com/CyberHuman-bot/Ractor/refs/heads/main"
RACTOR_SELF_URL="$RACTOR_REPO_RAW/ractor.sh"
RACTOR_PKG_INDEX="$RACTOR_REPO_RAW/packages.json"

# ───────── PATHS ─────────
CONFIG_FILES=("/etc/ractor.conf" "$HOME/.config/ractor/ractor.conf")

if [[ $EUID -eq 0 ]]; then
    INSTALL_BIN="/usr/local/bin"
    INSTALL_LIB="/usr/lib/ractor"
    RACTOR_LIB="/var/lib/ractor"
    DESKTOP_ENTRIES="/usr/share/applications"
    RACTOR_SELF="/usr/local/bin/ractor"
else
    INSTALL_BIN="$HOME/.local/bin"
    INSTALL_LIB="$HOME/.local/lib/ractor"
    RACTOR_LIB="$HOME/.local/share/ractor"
    DESKTOP_ENTRIES="$HOME/.local/share/applications"
    RACTOR_SELF="$HOME/.local/bin/ractor"
fi

RACTOR_CACHE="$RACTOR_LIB/cache"
RACTOR_INSTALLED="$RACTOR_LIB/installed"
RACTOR_TMP="$RACTOR_LIB/tmp"
RACTOR_LOG="$RACTOR_LIB/ractor.log"
RACTOR_LOCK="$RACTOR_LIB/ractor.lock"

for cfg in "${CONFIG_FILES[@]}"; do
    [[ -f "$cfg" ]] && source "$cfg"
done

# ───────── COLORS ─────────
if [[ -t 1 ]]; then
    RED='\033[0;31m';    LRED='\033[1;31m'
    GREEN='\033[0;32m';  LGREEN='\033[1;32m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
    BOLD='\033[1m';      DIM='\033[2m'
    NC='\033[0m'
else
    RED=''; LRED=''; GREEN=''; LGREEN=''; YELLOW=''
    BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; DIM=''; NC=''
fi

# ───────── LOGGING ─────────
mkdir -p "$(dirname "$RACTOR_LOG")" 2>/dev/null || true
touch "$RACTOR_LOG" 2>/dev/null || true
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$RACTOR_LOG" 2>/dev/null || true; }

msg()     { echo -e "${LGREEN}==>${NC}${BOLD} $*${NC}";      _log "INFO: $*"; }
info()    { echo -e "${BLUE} ->${NC} $*";                    _log "INFO: $*"; }
success() { echo -e "${CYAN} ✓${NC} $*";                     _log "OK:   $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[!]${NC} $*" >&2;       _log "WARN: $*"; }
error()   { echo -e "${LRED}${BOLD}[✗] Error:${NC} $*" >&2; _log "ERR:  $*"; exit 1; }
step()    { echo -e "${MAGENTA}  >${NC} $*"; }

# ───────── LOCK ─────────
acquire_lock() {
    mkdir -p "$RACTOR_LIB"
    if [[ -f "$RACTOR_LOCK" ]]; then
        local pid
        pid=$(cat "$RACTOR_LOCK" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            error "Another ractor process is running (PID $pid)"
        fi
        rm -f "$RACTOR_LOCK"
    fi
    echo $$ > "$RACTOR_LOCK"
    trap 'rm -f "$RACTOR_LOCK"' EXIT INT TERM
}

# ───────── INIT ─────────
init_dirs() {
    mkdir -p "$INSTALL_BIN" "$INSTALL_LIB" "$RACTOR_CACHE" \
             "$RACTOR_INSTALLED" "$RACTOR_TMP" "$DESKTOP_ENTRIES" \
             "$(dirname "$RACTOR_LOG")"
    touch "$RACTOR_LOG"
}

check_deps() {
    local deps=("curl" "tar" "jq")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && error "Missing required tools: ${missing[*]}"
}

# ───────── META PARSER ─────────
# META file format:
#   name=myapp
#   version=1.0.0
#   description=My app
#   maintainer=yaman
#   depends=curl,git,node
#   type=binary|script|react|appimage
#   electron=true|false
#   license=MIT
#   arch=x86_64|any

parse_meta() {
    local meta_file="$1"
    [[ ! -f "$meta_file" ]] && error "META file not found in package"

    _get() { grep "^${1}=" "$meta_file" 2>/dev/null | cut -d= -f2- || echo ""; }

    PKG_NAME=$(_get name)
    PKG_VERSION=$(_get version)
    PKG_DESC=$(_get description)
    PKG_MAINTAINER=$(_get maintainer)
    PKG_DEPENDS=$(_get depends)
    PKG_TYPE=$(_get type)
    PKG_ELECTRON=$(_get electron)
    PKG_LICENSE=$(_get license)
    PKG_ARCH=$(_get arch)

    PKG_TYPE="${PKG_TYPE:-binary}"
    PKG_ELECTRON="${PKG_ELECTRON:-false}"
    PKG_ARCH="${PKG_ARCH:-any}"

    [[ -z "$PKG_NAME" ]]    && error "META: 'name' is required"
    [[ -z "$PKG_VERSION" ]] && error "META: 'version' is required"

    local sys_arch
    sys_arch=$(uname -m)
    if [[ "$PKG_ARCH" != "any" && "$PKG_ARCH" != "$sys_arch" ]]; then
        error "Package is for $PKG_ARCH but system is $sys_arch"
    fi
}

# ───────── DEPENDENCY HANDLING ─────────
handle_deps() {
    local deps="$1"
    [[ -z "$deps" ]] && return 0

    info "Checking dependencies: $deps"
    IFS=',' read -ra dep_list <<< "$deps"
    local missing=()

    for dep in "${dep_list[@]}"; do
        dep=$(echo "$dep" | xargs)
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All dependencies satisfied"
        return 0
    fi

    warn "Missing: ${missing[*]}"
    read -rp "$(echo -e "${YELLOW}Install missing dependencies with apt?${NC} [Y/n] ")" choice
    choice="${choice:-y}"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sudo apt-get install -y "${missing[@]}" 2>/dev/null || \
            warn "Some dependencies could not be auto-installed"
    fi
}

handle_optional() {
    local opt_file="$1"
    [[ ! -f "$opt_file" ]] && return 0
    local pkgs=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        pkgs+=("$line")
    done < "$opt_file"
    [[ ${#pkgs[@]} -eq 0 ]] && return 0

    echo
    info "Recommended packages:"
    for p in "${pkgs[@]}"; do step "$p"; done
    echo
    read -rp "$(echo -e "${YELLOW}Install recommended packages?${NC} [y/N] ")" choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sudo apt-get install -y "${pkgs[@]}" 2>/dev/null || \
            warn "Some recommended packages could not be installed"
    fi
}

# ───────── PACKAGE FETCH ─────────
_refresh_index() {
    local index="$RACTOR_CACHE/packages.json"
    if [[ ! -f "$index" ]] || \
       [[ -n "$(find "$index" -mmin +60 2>/dev/null)" ]]; then
        step "Refreshing package index..."
        curl -fsSL "$RACTOR_PKG_INDEX" -o "$index" 2>/dev/null || \
            error "Failed to fetch package index"
    fi
}

fetch_rac() {
    local input="$1"
    local out_file=""

    if [[ "$input" =~ ^https?:// ]]; then
        out_file="$RACTOR_TMP/download_$$.rac"
        info "Downloading from $input"
        curl -fSL --progress-bar "$input" -o "$out_file" || error "Download failed"

    elif [[ -f "$input" ]]; then
        out_file="$input"

    else
        info "Looking up '$input' in package index..."
        _refresh_index
        local index="$RACTOR_CACHE/packages.json"
        local pkg_url
        pkg_url=$(jq -r --arg n "$input" \
            '.packages[] | select(.name==$n) | .url' "$index" 2>/dev/null || echo "")
        [[ -z "$pkg_url" || "$pkg_url" == "null" ]] && \
            error "Package '$input' not found. Try: ractor search $input"
        out_file="$RACTOR_TMP/${input}_$$.rac"
        info "Found: $pkg_url"
        curl -fSL --progress-bar "$pkg_url" -o "$out_file" || error "Download failed"
    fi

    echo "$out_file"
}

# ───────── INSTALL ─────────
ractor_install() {
    check_deps; init_dirs; acquire_lock
    local input="$1"
    [[ -z "$input" ]] && error "Usage: ractor install <name|file.rac|url>"

    local rac_file
    rac_file=$(fetch_rac "$input")

    local extract_dir="$RACTOR_TMP/extract_$$"
    mkdir -p "$extract_dir"
    step "Extracting package..."
    tar -xzf "$rac_file" -C "$extract_dir" 2>/dev/null || \
        error "Failed to extract — is this a valid .rac file?"

    parse_meta "$extract_dir/META"

    echo
    echo -e "${BOLD}Package:${NC}     $PKG_NAME"
    echo -e "${BOLD}Version:${NC}     $PKG_VERSION"
    echo -e "${BOLD}Type:${NC}        $PKG_TYPE"
    [[ -n "$PKG_DESC" ]]       && echo -e "${BOLD}Description:${NC} $PKG_DESC"
    [[ -n "$PKG_MAINTAINER" ]] && echo -e "${BOLD}Maintainer:${NC}  $PKG_MAINTAINER"
    [[ -n "$PKG_LICENSE" ]]    && echo -e "${BOLD}License:${NC}     $PKG_LICENSE"
    echo

    if [[ -f "$RACTOR_INSTALLED/$PKG_NAME.json" ]]; then
        local installed_ver
        installed_ver=$(jq -r '.version' "$RACTOR_INSTALLED/$PKG_NAME.json")
        warn "$PKG_NAME v$installed_ver is already installed"
        read -rp "$(echo -e "${YELLOW}Reinstall?${NC} [y/N] ")" choice
        [[ ! "$choice" =~ ^[Yy]$ ]] && { rm -rf "$extract_dir"; exit 0; }
        _do_remove "$PKG_NAME"
    fi

    read -rp "$(echo -e "${CYAN}Proceed with installation?${NC} [Y/n] ")" choice
    choice="${choice:-y}"
    [[ ! "$choice" =~ ^[Yy]$ ]] && { rm -rf "$extract_dir"; info "Aborted."; exit 0; }

    handle_deps "$PKG_DEPENDS"
    handle_optional "$extract_dir/optional/recommended"

    local install_dir="$INSTALL_LIB/$PKG_NAME"
    mkdir -p "$install_dir"

    msg "Installing $PKG_NAME v$PKG_VERSION..."

    case "$PKG_TYPE" in
        binary|script)  _install_binaries "$extract_dir" "$install_dir" ;;
        react)          _install_react "$extract_dir" "$install_dir" ;;
        appimage)       _install_appimage "$extract_dir" "$install_dir" ;;
        *)
            warn "Unknown type '$PKG_TYPE', treating as binary"
            _install_binaries "$extract_dir" "$install_dir"
            ;;
    esac

    cp -r "$extract_dir/." "$install_dir/" 2>/dev/null || true

    if [[ -f "$install_dir/afterinstall" ]]; then
        step "Running post-install script..."
        chmod +x "$install_dir/afterinstall"
        (cd "$install_dir" && bash afterinstall) || \
            warn "Post-install script exited with errors"
    fi

    _create_desktop_entry "$install_dir"

    cat > "$RACTOR_INSTALLED/$PKG_NAME.json" << EOF
{
    "name": "$PKG_NAME",
    "version": "$PKG_VERSION",
    "description": "$PKG_DESC",
    "maintainer": "$PKG_MAINTAINER",
    "license": "$PKG_LICENSE",
    "type": "$PKG_TYPE",
    "arch": "$PKG_ARCH",
    "install_date": "$(date -Iseconds)",
    "install_dir": "$install_dir"
}
EOF

    rm -rf "$extract_dir"
    [[ "$rac_file" == "$RACTOR_TMP/"* ]] && rm -f "$rac_file"

    echo
    success "$PKG_NAME v$PKG_VERSION installed successfully!"
    _log "INSTALLED: $PKG_NAME v$PKG_VERSION"
}

_install_binaries() {
    local src="$1"
    [[ ! -d "$src/binaries" ]] && return 0
    local count=0
    for bin in "$src/binaries/"*; do
        [[ -f "$bin" ]] || continue
        chmod +x "$bin"
        cp "$bin" "$INSTALL_BIN/"
        step "$(basename "$bin") → $INSTALL_BIN/"
        (( count++ )) || true
    done
    [[ $count -eq 0 ]] && warn "No binaries found to install"
}

_install_react() {
    local src="$1" dest="$2"
    [[ ! -f "$src/binaries/package.json" ]] && \
        error "React app missing package.json in binaries/"
    command -v npm &>/dev/null || error "npm is required for React apps"

    cp -r "$src/binaries/." "$dest/"
    cd "$dest"

    step "Installing npm dependencies..."
    npm install --prefer-offline --no-audit --loglevel=error || error "npm install failed"

    if [[ "$PKG_ELECTRON" == "true" ]]; then
        step "Building Electron app..."
        npm run build 2>/dev/null || true
        printf '#!/bin/bash\ncd "%s" && npm start "$@"\n' "$dest" > "$INSTALL_BIN/$PKG_NAME"
    else
        step "Building React app..."
        npm run build || error "React build failed"
        printf '#!/bin/bash\ncd "%s" && npx serve build "$@"\n' "$dest" > "$INSTALL_BIN/$PKG_NAME"
    fi
    chmod +x "$INSTALL_BIN/$PKG_NAME"
    step "Launcher → $INSTALL_BIN/$PKG_NAME"
}

_install_appimage() {
    local src="$1" dest="$2"
    local appimg
    appimg=$(find "$src/binaries/" -name "*.AppImage" | head -1)
    [[ -z "$appimg" ]] && error "No .AppImage found in binaries/"
    chmod +x "$appimg"
    cp "$appimg" "$dest/$PKG_NAME.AppImage"
    printf '#!/bin/bash\n"%s/%s.AppImage" "$@"\n' "$dest" "$PKG_NAME" > "$INSTALL_BIN/$PKG_NAME"
    chmod +x "$INSTALL_BIN/$PKG_NAME"
    step "AppImage launcher → $INSTALL_BIN/$PKG_NAME"
}

_create_desktop_entry() {
    local dir="$1"
    local icon=""
    for ext in png svg xpm ico; do
        local f
        f=$(find "$dir" -maxdepth 2 -name "*.${ext}" 2>/dev/null | head -1)
        [[ -n "$f" ]] && { icon="$f"; break; }
    done
    cat > "$DESKTOP_ENTRIES/$PKG_NAME.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$PKG_NAME
Comment=${PKG_DESC:-$PKG_NAME}
Exec=$INSTALL_BIN/$PKG_NAME
Icon=${icon:-application-x-executable}
Terminal=false
Categories=Application;
EOF
    step "Desktop entry created"
}

# ───────── REMOVE ─────────
_do_remove() {
    local name="$1"
    local record="$RACTOR_INSTALLED/$name.json"
    [[ ! -f "$record" ]] && return

    local install_dir pkg_type
    install_dir=$(jq -r '.install_dir' "$record")
    pkg_type=$(jq -r '.type' "$record")

    if [[ -d "$install_dir/binaries" ]]; then
        for bin in "$install_dir/binaries/"*; do
            [[ -f "$bin" ]] && rm -f "$INSTALL_BIN/$(basename "$bin")"
        done
    fi
    [[ "$pkg_type" == "react" || "$pkg_type" == "appimage" ]] && \
        rm -f "$INSTALL_BIN/$name"

    [[ -d "$install_dir" ]] && rm -rf "$install_dir"
    rm -f "$DESKTOP_ENTRIES/$name.desktop"
    rm -f "$record"
}

ractor_remove() {
    init_dirs; acquire_lock
    local name="$1"
    [[ -z "$name" ]] && error "Usage: ractor remove <name>"
    [[ ! -f "$RACTOR_INSTALLED/$name.json" ]] && error "$name is not installed"

    local ver
    ver=$(jq -r '.version' "$RACTOR_INSTALLED/$name.json")
    warn "This will remove $name v$ver"
    read -rp "$(echo -e "${YELLOW}Continue?${NC} [y/N] ")" choice
    [[ ! "$choice" =~ ^[Yy]$ ]] && { info "Aborted."; exit 0; }

    msg "Removing $name..."
    _do_remove "$name"
    success "$name removed"
    _log "REMOVED: $name v$ver"
}

# ───────── UPDATE ─────────
ractor_update() {
    init_dirs
    local name="${1:-}"

    if [[ -z "$name" || "$name" == "--all" ]]; then
        local files=("$RACTOR_INSTALLED"/*.json)
        [[ ! -f "${files[0]}" ]] && { info "Nothing installed."; return; }
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            local n
            n=$(jq -r '.name' "$f")
            msg "Updating $n..."
            ractor_install "$n" || true
        done
        return
    fi

    [[ ! -f "$RACTOR_INSTALLED/$name.json" ]] && error "$name is not installed"
    local old_ver
    old_ver=$(jq -r '.version' "$RACTOR_INSTALLED/$name.json")
    msg "Updating $name (current: v$old_ver)..."
    ractor_install "$name"
}

# ───────── LIST ─────────
ractor_list() {
    init_dirs
    local files=("$RACTOR_INSTALLED"/*.json)
    if [[ ! -f "${files[0]}" ]]; then
        info "No packages installed"
        return
    fi

    echo
    printf "${BOLD}${CYAN}%-22s %-12s %-10s %-8s %s${NC}\n" \
        "NAME" "VERSION" "TYPE" "ARCH" "DESCRIPTION"
    printf "${DIM}%-22s %-12s %-10s %-8s %s${NC}\n" \
        "──────────────────────" "────────────" "──────────" "────────" "───────────────────"
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        printf "%-22s %-12s %-10s %-8s %s\n" \
            "$(jq -r '.name' "$f")" \
            "$(jq -r '.version' "$f")" \
            "$(jq -r '.type' "$f")" \
            "$(jq -r '.arch' "$f")" \
            "$(jq -r '.description' "$f" | cut -c1-35)"
    done
    echo
    local count
    count=$(ls "$RACTOR_INSTALLED"/*.json 2>/dev/null | wc -l)
    info "$count package(s) installed"
}

# ───────── SEARCH ─────────
ractor_search() {
    init_dirs
    local query="$1"
    [[ -z "$query" ]] && error "Usage: ractor search <query>"
    _refresh_index

    msg "Results for '$query':"
    echo
    local results
    results=$(jq -r --arg q "$query" \
        '.packages[] | select(
            (.name | ascii_downcase | contains($q | ascii_downcase)) or
            (.description | ascii_downcase | contains($q | ascii_downcase))
        ) | "  \(.name) v\(.version // "?")  —  \(.description // "no description")"' \
        "$RACTOR_CACHE/packages.json" 2>/dev/null || echo "")

    if [[ -z "$results" ]]; then
        info "No packages found for '$query'"
    else
        echo -e "$results"
    fi
    echo
}

# ───────── INFO ─────────
ractor_info() {
    init_dirs
    local name="$1"
    [[ -z "$name" ]] && error "Usage: ractor info <name>"

    if [[ -f "$RACTOR_INSTALLED/$name.json" ]]; then
        local f="$RACTOR_INSTALLED/$name.json"
        echo
        echo -e "${BOLD}${CYAN}$name${NC} ${DIM}(installed)${NC}"
        echo -e "  ${BOLD}Version:${NC}     $(jq -r '.version' "$f")"
        echo -e "  ${BOLD}Type:${NC}        $(jq -r '.type' "$f")"
        echo -e "  ${BOLD}Description:${NC} $(jq -r '.description' "$f")"
        echo -e "  ${BOLD}Maintainer:${NC}  $(jq -r '.maintainer' "$f")"
        echo -e "  ${BOLD}License:${NC}     $(jq -r '.license' "$f")"
        echo -e "  ${BOLD}Arch:${NC}        $(jq -r '.arch' "$f")"
        echo -e "  ${BOLD}Installed:${NC}   $(jq -r '.install_date' "$f")"
        echo -e "  ${BOLD}Location:${NC}    $(jq -r '.install_dir' "$f")"
        echo
    else
        _refresh_index
        local result
        result=$(jq -r --arg n "$name" \
            '.packages[] | select(.name==$n)' \
            "$RACTOR_CACHE/packages.json" 2>/dev/null || echo "")
        [[ -z "$result" || "$result" == "null" ]] && \
            error "Package '$name' not found"
        echo
        echo -e "${BOLD}${CYAN}$name${NC} ${DIM}(not installed)${NC}"
        echo "$result" | jq -r \
            '"  Version:     \(.version // "unknown")\n  Description: \(.description // "")\n  URL:         \(.url // "")"'
        echo
    fi
}

# ───────── PACK ─────────
ractor_pack() {
    local dir="${1:-.}"
    [[ ! -d "$dir" ]] && error "Directory not found: $dir"
    [[ ! -f "$dir/META" ]] && error "META file not found in $dir"

    parse_meta "$dir/META"
    local output="${PKG_NAME}-${PKG_VERSION}.rac"

    msg "Packing $PKG_NAME v$PKG_VERSION..."
    [[ ! -d "$dir/binaries" ]] && warn "No binaries/ directory found"

    tar -czf "$output" -C "$dir" . || error "Failed to create package"
    local size
    size=$(du -sh "$output" | cut -f1)
    success "Created: $output ($size)"
    _log "PACKED: $output"
}

# ───────── VERIFY ─────────
ractor_verify() {
    local file="$1"
    [[ -z "$file" ]] && error "Usage: ractor verify <file.rac>"
    [[ ! -f "$file" ]] && error "File not found: $file"

    msg "Verifying $file..."
    local tmp="$RACTOR_TMP/verify_$$"
    mkdir -p "$tmp"

    tar -tzf "$file" &>/dev/null || { rm -rf "$tmp"; error "Not a valid .rac archive"; }
    tar -xzf "$file" -C "$tmp" 2>/dev/null

    local issues=0
    [[ ! -f "$tmp/META" ]]     && { warn "Missing: META";      (( issues++ )) || true; }
    [[ ! -d "$tmp/binaries" ]] && { warn "Missing: binaries/"; (( issues++ )) || true; }

    if [[ -f "$tmp/META" ]]; then
        parse_meta "$tmp/META"
        success "META: name=$PKG_NAME, version=$PKG_VERSION, type=$PKG_TYPE"
    fi

    rm -rf "$tmp"
    [[ $issues -eq 0 ]] && success "Package is valid" || warn "$issues issue(s) found"
}

# ───────── LOGS ─────────
ractor_logs() {
    local lines="${1:-50}"
    [[ ! -f "$RACTOR_LOG" ]] && { info "No logs yet"; return; }
    tail -n "$lines" "$RACTOR_LOG"
}

# ───────── CLEAN ─────────
ractor_clean() {
    init_dirs
    msg "Cleaning cache and temp files..."
    rm -rf "${RACTOR_TMP:?}/"*
    rm -f "$RACTOR_CACHE/packages.json"
    success "Cache cleared"
}

# ───────── SELF-UPDATE ─────────
ractor_self_update() {
    msg "Checking for Ractor updates..."
    local tmp_file
    tmp_file=$(mktemp /tmp/ractor.XXXXXX)

    curl -fsSL "$RACTOR_SELF_URL" -o "$tmp_file" || {
        rm -f "$tmp_file"
        error "Failed to download update"
    }

    local new_ver
    new_ver=$(grep '^RACTOR_VERSION=' "$tmp_file" 2>/dev/null | cut -d'"' -f2 || echo "")

    if [[ "$new_ver" == "$RACTOR_VERSION" ]]; then
        rm -f "$tmp_file"
        success "Already up to date (v$RACTOR_VERSION)"
        return
    fi

    [[ -n "$new_ver" ]] && info "New version: $new_ver (current: $RACTOR_VERSION)"
    chmod +x "$tmp_file"

    local target="$RACTOR_SELF"
    mkdir -p "$(dirname "$target")"

    if [[ -w "$(dirname "$target")" ]]; then
        mv "$tmp_file" "$target"
    else
        sudo mv "$tmp_file" "$target"
    fi

    success "Ractor updated to v${new_ver:-latest}!"
    _log "SELF-UPDATE: $RACTOR_VERSION -> ${new_ver:-?}"
}

# ───────── HELP ─────────
ractor_help() {
    cat << EOF

${BOLD}${CYAN}Ractor${NC} ${DIM}v${RACTOR_VERSION}${NC} — .rac Package Manager

${BOLD}Usage:${NC}
  ractor <command> [args]

${BOLD}Commands:${NC}
  ${GREEN}install${NC} <name|file.rac|url>   Install a package
  ${GREEN}remove${NC}  <name>                Remove a package
  ${GREEN}update${NC}  [name|--all]          Update one or all packages
  ${GREEN}list${NC}                          List installed packages
  ${GREEN}search${NC}  <query>               Search the package index
  ${GREEN}info${NC}    <name>                Show package details
  ${GREEN}pack${NC}    [directory]           Create a .rac from a directory
  ${GREEN}verify${NC}  <file.rac>            Validate a .rac file
  ${GREEN}clean${NC}                         Clear cache and temp files
  ${GREEN}logs${NC}    [lines]               Show recent log entries
  ${GREEN}self-update${NC}                   Update ractor itself
  ${GREEN}version${NC}                       Show version
  ${GREEN}help${NC}                          Show this message

${BOLD}.rac Structure:${NC}
  META                    Package metadata ${DIM}(required)${NC}
  binaries/               Executables, scripts, or app source
  afterinstall            Post-install hook ${DIM}(optional)${NC}
  optional/recommended    Suggested packages ${DIM}(optional)${NC}

${BOLD}META Fields:${NC}
  name=myapp              Package name ${DIM}(required)${NC}
  version=1.0.0           Version ${DIM}(required)${NC}
  description=...         Short description
  maintainer=yourname     Your name
  depends=curl,git        Required commands
  type=binary             binary | script | react | appimage
  electron=false          true | false ${DIM}(react only)${NC}
  license=MIT             License
  arch=any                x86_64 | aarch64 | any

${BOLD}Examples:${NC}
  ractor install myapp.rac
  ractor install https://example.com/pkg.rac
  ractor install myapp
  ractor pack ./myapp/
  ractor update --all
  ractor verify myapp.rac

EOF
}

# ───────── DISPATCH ─────────
cmd="${1:-help}"
shift || true

case "$cmd" in
    install)             ractor_install "$@" ;;
    remove|uninstall|rm) ractor_remove "$@" ;;
    update|upgrade)      ractor_update "$@" ;;
    list|ls)             ractor_list ;;
    search)              ractor_search "$@" ;;
    info|show)           ractor_info "$@" ;;
    pack|build)          ractor_pack "$@" ;;
    verify|check)        ractor_verify "$@" ;;
    clean)               ractor_clean ;;
    logs)                ractor_logs "$@" ;;
    self-update)         ractor_self_update ;;
    version|-v|--version) echo "Ractor v$RACTOR_VERSION" ;;
    help|--help|-h)      ractor_help ;;
    *) error "Unknown command: '$cmd'. Run 'ractor help'" ;;
esac
