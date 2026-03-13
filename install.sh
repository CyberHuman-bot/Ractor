#!/bin/bash
# ╔═══════════════════════════════════════════════════════════╗
# ║           Ractor Installer                                ║
# ║           https://github.com/elezaio-linux/Ractor         ║
# ╚═══════════════════════════════════════════════════════════╝

set -euo pipefail

RACTOR_URL="https://raw.githubusercontent.com/elezaio-linux/Ractor/refs/heads/main/ractor.sh"

if [[ -t 1 ]]; then
    LGREEN='\033[1;32m'; CYAN='\033[0;36m'
    LRED='\033[1;31m';   YELLOW='\033[1;33m'
    BOLD='\033[1m';      NC='\033[0m'
else
    LGREEN=''; CYAN=''; LRED=''; YELLOW=''; BOLD=''; NC=''
fi

msg()     { echo -e "${LGREEN}==>${NC}${BOLD} $*${NC}"; }
info()    { echo -e "${CYAN} ->${NC} $*"; }
success() { echo -e "${CYAN} ✓${NC} $*"; }
error()   { echo -e "${LRED}[✗] Error:${NC} $*" >&2; exit 1; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }

# ───────── CHECK DEPS ─────────
for dep in curl tar jq; do
    command -v "$dep" &>/dev/null || {
        warn "Missing dependency: $dep"
        if command -v apt-get &>/dev/null; then
            info "Installing $dep..."
            sudo apt-get install -y "$dep" || error "Could not install $dep"
        else
            error "$dep is required. Please install it manually."
        fi
    }
done

# ───────── INSTALL DIR ─────────
if [[ $EUID -eq 0 ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

INSTALL_PATH="$INSTALL_DIR/ractor"

# ───────── DOWNLOAD ─────────
msg "Installing Ractor..."
info "Downloading latest version..."

tmp_file=$(mktemp /tmp/ractor.XXXXXX)
curl -fsSL "$RACTOR_URL" -o "$tmp_file" || {
    rm -f "$tmp_file"
    error "Failed to download Ractor"
}

VERSION=$(grep '^RACTOR_VERSION=' "$tmp_file" | cut -d'"' -f2 || echo "unknown")
chmod +x "$tmp_file"
mv "$tmp_file" "$INSTALL_PATH"

success "Ractor v$VERSION installed to $INSTALL_PATH"

# ───────── PATH CHECK ─────────
# Detect shell config
SHELL_RC=""
if [[ -f "$HOME/.zshrc" ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    SHELL_RC="$HOME/.bashrc"
fi

# Only add PATH if not already present in rc file
if [[ -n "$SHELL_RC" ]] && ! grep -q "$INSTALL_DIR" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Ractor" >> "$SHELL_RC"
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$SHELL_RC"
    success "Added $INSTALL_DIR to PATH in $SHELL_RC"
    warn "Run: source $SHELL_RC"
elif [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    warn "Run: source $SHELL_RC  (to load PATH)"
fi

# ───────── DONE ─────────
echo
echo -e "${BOLD}${CYAN}Ractor v$VERSION is ready!${NC}"
echo
echo -e "  ${BOLD}Usage:${NC}       ractor help"
echo -e "  ${BOLD}Install:${NC}     ractor install <package>"
echo -e "  ${BOLD}Update:${NC}      ractor self-update"
echo
