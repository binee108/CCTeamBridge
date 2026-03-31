#!/usr/bin/env bash
set -euo pipefail

# CCTeamBridge Uninstaller

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

info()  { echo -e "${CYAN}[INFO]${RESET} $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }

MARKER_START="# === CLAUDE HYBRID START ==="
MARKER_END="# === CLAUDE HYBRID END ==="

echo ""
echo -e "${BOLD}Uninstalling CCTeamBridge${RESET}"
echo "=============================================="
echo ""

# Remove shell function blocks from RC files
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [[ -f "$RC" ]] && grep -q "$MARKER_START" "$RC" 2>/dev/null; then
        sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$RC"
        rm -f "${RC}.bak"
        ok "Removed hybrid block from $RC"
    fi
done

# Remove zshenv block (legacy cleanup)
if [[ -f "$HOME/.zshenv" ]] && grep -q "$MARKER_START" "$HOME/.zshenv" 2>/dev/null; then
    sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$HOME/.zshenv"
    rm -f "$HOME/.zshenv.bak"
    ok "Removed hybrid block from ~/.zshenv"
fi

# Remove legacy artifacts
rm -f "$HOME/.claude-hybrid-active"
ok "Removed active marker"

if [[ -d "$HOME/.claude-models/.hybrid-rr" ]]; then
    rm -rf "$HOME/.claude-models/.hybrid-rr"
    ok "Removed round-robin state directory"
fi

# Stop ccbridge-proxy if running
if [[ -f "$HOME/.ccbridge/proxy.pid" ]]; then
    _proxy_pid="$(head -1 "$HOME/.ccbridge/proxy.pid" 2>/dev/null)"
    if [[ -n "$_proxy_pid" ]] && kill -0 "$_proxy_pid" 2>/dev/null; then
        kill "$_proxy_pid" 2>/dev/null
        sleep 1
        kill -9 "$_proxy_pid" 2>/dev/null || true
        ok "Stopped ccbridge-proxy (pid=$_proxy_pid)"
    fi
    rm -f "$HOME/.ccbridge/proxy.pid"
fi

# Remove launchd plist (macOS)
if [[ "$(uname -s)" == "Darwin" ]]; then
    _plist="$HOME/Library/LaunchAgents/com.ccbridge.proxy.plist"
    if [[ -f "$_plist" ]]; then
        launchctl unload "$_plist" 2>/dev/null || true
        rm -f "$_plist"
        ok "Removed launchd plist"
    fi
fi

# Remove systemd service (Linux)
if [[ "$(uname -s)" == "Linux" ]] && [[ -f "$HOME/.config/systemd/user/ccbridge-proxy.service" ]]; then
    systemctl --user stop ccbridge-proxy 2>/dev/null || true
    systemctl --user disable ccbridge-proxy 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/ccbridge-proxy.service"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Removed systemd service"
fi

# Ask about removing ~/.ccbridge/
echo ""
echo -ne "${YELLOW}Remove proxy data (~/.ccbridge/ including venv, config, credentials)? [y/N]:${RESET} "
read -r _remove_ccbridge </dev/tty || _remove_ccbridge="N"
if [[ "$_remove_ccbridge" =~ ^[Yy] ]]; then
    rm -rf "$HOME/.ccbridge"
    ok "Removed ~/.ccbridge/"
else
    info "Kept ~/.ccbridge/ (config and credentials preserved)"
fi

# Remove tmux hook script (legacy)
rm -f "$HOME/.tmux-hybrid-hook.sh"

# Remove hook entries from tmux.conf (legacy)
if [[ -f "$HOME/.tmux.conf" ]] && grep -q 'tmux-hybrid-hook' "$HOME/.tmux.conf" 2>/dev/null; then
    sed -i.bak '/HYBRID MODEL HOOK/d; /tmux-hybrid-hook/d' "$HOME/.tmux.conf"
    rm -f "$HOME/.tmux.conf.bak"
    ok "Removed legacy tmux hook from ~/.tmux.conf"
fi

echo ""
echo -e "${YELLOW}Kept:${RESET} ~/.claude-models/ (your API keys are safe)"
echo "  To remove model profiles too: rm -rf ~/.claude-models/"
echo ""
echo -e "${BOLD}Uninstall complete.${RESET} Restart your shell to apply."
echo ""
