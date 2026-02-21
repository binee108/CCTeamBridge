#!/usr/bin/env bash
set -euo pipefail

# Claude Code Hybrid Model System Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/binee108/claude-code-hybrid/main/install.sh | bash

VERSION="1.6.0"

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

info()  { echo -e "${CYAN}[INFO]${RESET} $1"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; }

MODELS_DIR="$HOME/.claude-models"
MARKER_START="# === CLAUDE HYBRID START ==="
MARKER_END="# === CLAUDE HYBRID END ==="
VERSION_TAG="# CLAUDE_HYBRID_VERSION="

# ─── Parse arguments ───
ARG_FORCE=""
for arg in "$@"; do
    case "$arg" in
        --force) ARG_FORCE=1 ;;
    esac
done

# ─── Backup function ───
_do_backup() {
    local BACKUP_DIR="$HOME/.claude-hybrid-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    local count=0
    for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.tmux.conf" "$HOME/.tmux-hybrid-hook.sh"; do
        [[ -f "$f" ]] && cp -p "$f" "$BACKUP_DIR/" && count=$((count + 1))
    done
    [[ -d "$MODELS_DIR" ]] && cp -rp "$MODELS_DIR" "$BACKUP_DIR/claude-models/" && count=$((count + 1))
    if ((count > 0)); then
        ok "Backed up ${count} items to $BACKUP_DIR"
    else
        info "Nothing to back up (fresh install)"
    fi
}

echo ""
echo -e "${BOLD}Claude Code Hybrid Model System v${VERSION}${RESET}"
echo -e "Session-isolated | Leader & Teammates: Any model"
echo "=================================================="
echo ""

# ─── Auto-backup before any modification ───
info "Creating backup..."
_do_backup
echo ""

# ─── Version check ───
# Detect shell config file
if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == *zsh* ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == *bash* ]]; then
    SHELL_RC="$HOME/.bashrc"
else
    SHELL_RC="$HOME/.zshrc"
    warn "Unknown shell, defaulting to .zshrc"
fi

# Compare semver: returns 0 if $1 > $2, 1 otherwise
_version_gt() {
    local IFS=.
    local i a=($1) b=($2)
    for ((i=0; i<${#a[@]}; i++)); do
        local va=${a[i]:-0} vb=${b[i]:-0}
        if ((va > vb)); then return 0; fi
        if ((va < vb)); then return 1; fi
    done
    return 1
}

INSTALLED_VERSION=""
if [[ -f "$SHELL_RC" ]] && grep -q "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    INSTALLED_VERSION=$(grep "$VERSION_TAG" "$SHELL_RC" 2>/dev/null | head -1 | sed "s/.*${VERSION_TAG}//")
fi

if [[ -n "$INSTALLED_VERSION" ]]; then
    if [[ "$INSTALLED_VERSION" == "$VERSION" ]]; then
        ok "Already installed (v${INSTALLED_VERSION}) - same version"
        echo ""
        echo -e "  To force reinstall: ${BOLD}curl -fsSL ... | bash -s -- --force${RESET}"
        echo ""
        if [[ -z "$ARG_FORCE" ]]; then
            exit 0
        fi
        warn "Force reinstall requested"
    elif _version_gt "$VERSION" "$INSTALLED_VERSION"; then
        info "Updating v${INSTALLED_VERSION} -> v${VERSION}"
    else
        warn "Installed version (v${INSTALLED_VERSION}) is newer than installer (v${VERSION})"
        echo ""
        echo -e "  To force downgrade: ${BOLD}curl -fsSL ... | bash -s -- --force${RESET}"
        echo ""
        if [[ -z "$ARG_FORCE" ]]; then
            exit 0
        fi
        warn "Force downgrade requested"
    fi
else
    info "Fresh installation"
fi

# ─── Legacy cleanup (remove global state from pre-v1.6.0) ───
info "Cleaning up legacy global state..."
_legacy_cleaned=0

# Remove global state file
if [[ -f "$HOME/.claude-hybrid-active" ]]; then
    rm -f "$HOME/.claude-hybrid-active"
    _legacy_cleaned=$((_legacy_cleaned + 1))
fi

# Remove global hook script
if [[ -f "$HOME/.tmux-hybrid-hook.sh" ]]; then
    rm -f "$HOME/.tmux-hybrid-hook.sh"
    _legacy_cleaned=$((_legacy_cleaned + 1))
fi

# Remove hook entries from tmux.conf
if [[ -f "$HOME/.tmux.conf" ]] && grep -q 'tmux-hybrid-hook' "$HOME/.tmux.conf" 2>/dev/null; then
    sed -i.bak '/HYBRID MODEL HOOK/d; /tmux-hybrid-hook/d' "$HOME/.tmux.conf"
    _legacy_cleaned=$((_legacy_cleaned + 1))
fi

# Remove old-style shell blocks with different markers (pre-hybrid era)
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [[ -f "$RC" ]]; then
        if grep -q '# === LLM PROVIDER SWITCHER START ===' "$RC" 2>/dev/null; then
            sed -i.bak '/# === LLM PROVIDER SWITCHER START ===/,/# === LLM PROVIDER SWITCHER END ===/d' "$RC"
            _legacy_cleaned=$((_legacy_cleaned + 1))
        fi
        if grep -q '# === CLAUDE CODE SHORTCUTS ===' "$RC" 2>/dev/null; then
            sed -i.bak '/# === CLAUDE CODE SHORTCUTS ===/,/# === CLAUDE CODE SHORTCUTS END ===/d' "$RC"
            _legacy_cleaned=$((_legacy_cleaned + 1))
        fi
    fi
done

# Clear global tmux env vars from old hook (6 specific variables)
if command -v tmux &>/dev/null && tmux list-sessions &>/dev/null 2>&1; then
    tmux set-environment -gu HYBRID_ACTIVE 2>/dev/null || true
    tmux set-environment -gu ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
    tmux set-environment -gu ANTHROPIC_BASE_URL 2>/dev/null || true
    tmux set-environment -gu ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null || true
    tmux set-environment -gu ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null || true
    tmux set-environment -gu ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null || true
    _legacy_cleaned=$((_legacy_cleaned + 1))
fi

if ((_legacy_cleaned > 0)); then
    ok "Cleaned up ${_legacy_cleaned} legacy items"
else
    ok "No legacy artifacts found"
fi

# ─── Prerequisites check ───
info "Checking prerequisites..."

# Claude Code CLI
if command -v claude &>/dev/null; then
    ok "Claude Code CLI found: $(claude --version 2>/dev/null || echo 'installed')"
else
    error "Claude Code CLI not found"
    echo ""
    echo "  Install: https://docs.anthropic.com/en/docs/claude-code"
    echo "  npm install -g @anthropic-ai/claude-code"
    echo ""
    exit 1
fi

# tmux (required) - check multiple install paths
TMUX_BIN=""
for p in \
    "$(command -v tmux 2>/dev/null)" \
    /usr/bin/tmux \
    /usr/local/bin/tmux \
    /opt/homebrew/bin/tmux \
    /snap/bin/tmux \
    "$HOME/.local/bin/tmux" \
    "$HOME/bin/tmux"; do
    [[ -n "$p" && -x "$p" ]] && TMUX_BIN="$p" && break
done

if [[ -n "$TMUX_BIN" ]]; then
    ok "tmux found: $("$TMUX_BIN" -V 2>/dev/null) ($TMUX_BIN)"
else
    error "tmux is required but not installed"
    echo ""
    echo "  Install tmux using one of these methods:"
    echo ""
    case "$(uname -s)" in
        Darwin)
            echo "  Homebrew:       brew install tmux"
            echo "  MacPorts:       sudo port install tmux"
            echo "  Nix:            nix-env -iA nixpkgs.tmux"
            ;;
        Linux)
            echo "  Ubuntu/Debian:  sudo apt install tmux"
            echo "  Fedora/RHEL:    sudo dnf install tmux"
            echo "  Arch Linux:     sudo pacman -S tmux"
            echo "  Alpine:         sudo apk add tmux"
            echo "  openSUSE:       sudo zypper install tmux"
            echo "  Snap:           sudo snap install tmux --classic"
            echo "  Nix:            nix-env -iA nixpkgs.tmux"
            echo "  From source:    https://github.com/tmux/tmux/wiki/Installing"
            ;;
        *)
            echo "  https://github.com/tmux/tmux/wiki/Installing"
            ;;
    esac
    echo ""
    exit 1
fi

# CLIProxyAPI (optional, needed for codex/kimi) - check multiple install paths
CLIPROXY_BIN=""
for p in \
    "$(command -v cli-proxy-api 2>/dev/null)" \
    /usr/local/bin/cli-proxy-api \
    /opt/homebrew/bin/cli-proxy-api \
    "$HOME/.local/bin/cli-proxy-api" \
    "$HOME/bin/cli-proxy-api" \
    "$HOME/go/bin/cli-proxy-api"; do
    [[ -n "$p" && -x "$p" ]] && CLIPROXY_BIN="$p" && break
done

if [[ -n "$CLIPROXY_BIN" ]]; then
    ok "CLIProxyAPI found ($CLIPROXY_BIN)"
else
    warn "CLIProxyAPI not found (optional)"
    echo ""
    echo "  CLIProxyAPI is required for Codex and Kimi models."
    echo "  If you only use GLM or other direct-API models, you can skip this."
    echo ""
    echo "  Install using one of these methods:"
    echo ""
    case "$(uname -s)" in
        Darwin)
            echo "  Homebrew:       brew install cliproxyapi"
            echo "  Go:             go install github.com/router-for-me/CLIProxyAPI/cmd/server@latest"
            echo "  Docker:         docker run --rm -p 8317:8317 cliproxyapi/cliproxyapi"
            echo "  Binary:         https://github.com/router-for-me/CLIProxyAPI/releases"
            ;;
        Linux)
            echo "  One-liner:      curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash"
            echo "  Arch (AUR):     yay -S cli-proxy-api-bin"
            echo "  Go:             go install github.com/router-for-me/CLIProxyAPI/cmd/server@latest"
            echo "  Docker:         docker run --rm -p 8317:8317 cliproxyapi/cliproxyapi"
            echo "  Binary:         https://github.com/router-for-me/CLIProxyAPI/releases"
            ;;
        *)
            echo "  Download:       https://github.com/router-for-me/CLIProxyAPI/releases"
            ;;
    esac
    echo ""
    echo "  After install:"
    echo "    cli-proxy-api --codex-login          # Login to ChatGPT (for Codex)"
    echo "    brew services start cliproxyapi       # Start proxy (macOS)"
    echo "    systemctl --user start cliproxyapi    # Start proxy (Linux)"
    echo ""
fi

# ─── Step 1: Model profiles directory ───
info "Creating model profiles directory..."
mkdir -p "$MODELS_DIR" && chmod 700 "$MODELS_DIR"

if [[ ! -f "$MODELS_DIR/glm.env" ]]; then
    cat > "$MODELS_DIR/glm.env" << 'EOF'
# GLM API Profile
# Get your API key at: https://open.bigmodel.cn/
MODEL_AUTH_TOKEN="YOUR_GLM_API_KEY_HERE"
MODEL_BASE_URL="https://open.bigmodel.cn/api/anthropic"
MODEL_HAIKU="glm-4.7-flashx"
MODEL_SONNET="glm-5"
MODEL_OPUS="glm-5"
EOF
    chmod 600 "$MODELS_DIR/glm.env"
    ok "Created glm.env (edit API key before use)"
else
    ok "glm.env already exists, skipping"
fi

if [[ ! -f "$MODELS_DIR/codex.env" ]]; then
    cat > "$MODELS_DIR/codex.env" << 'EOF'
# Codex API Profile (requires CLIProxyAPI)
# Install: brew install cliproxyapi && cli-proxy-api --codex-login
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="gpt-5.3-codex"
MODEL_SONNET="gpt-5.3-codex"
MODEL_OPUS="gpt-5.3-codex"
EOF
    chmod 600 "$MODELS_DIR/codex.env"
    ok "Created codex.env (CLIProxyAPI required)"
else
    ok "codex.env already exists, skipping"
fi

if [[ ! -f "$MODELS_DIR/kimi.env" ]]; then
    cat > "$MODELS_DIR/kimi.env" << 'EOF'
# Kimi API Profile (requires CLIProxyAPI)
MODEL_AUTH_TOKEN="PLACEHOLDER"
MODEL_BASE_URL="http://localhost:8317/api/anthropic"
MODEL_HAIKU="kimi-latest"
MODEL_SONNET="kimi-latest"
MODEL_OPUS="kimi-latest"
EOF
    chmod 600 "$MODELS_DIR/kimi.env"
    ok "Created kimi.env (CLIProxyAPI required)"
else
    ok "kimi.env already exists, skipping"
fi

# ─── Step 2: zshenv (non-interactive shell support) ───
if [[ "$SHELL_RC" == *".zshrc" ]]; then
    info "Installing teammate env override to ~/.zshenv..."
    ZSHENV="$HOME/.zshenv"
    touch "$ZSHENV"

    # Remove existing block if present
    if grep -q "$MARKER_START" "$ZSHENV" 2>/dev/null; then
        sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$ZSHENV"
    fi

    cat >> "$ZSHENV" << 'ZSHENVEOF'
# === CLAUDE HYBRID START ===
# Teammate panes: force-reload model profile (runs in non-interactive shells too)
if [[ -n "$HYBRID_ACTIVE" ]] && [[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$HOME/.claude-models/${HYBRID_ACTIVE}.env" ]]; then
    source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"
    export ANTHROPIC_AUTH_TOKEN="$MODEL_AUTH_TOKEN"
    export ANTHROPIC_BASE_URL="$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL_OPUS"
    # Fix: Claude Code CLI forwards leader's ANTHROPIC_BASE_URL to teammate
    # via inline "env" prefix. This wrapper intercepts and replaces with
    # the correct teammate values from the session profile.
    env() {
        local -a _args
        for _a in "$@"; do
            case "$_a" in
                ANTHROPIC_AUTH_TOKEN=*)           _args+=("ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}") ;;
                ANTHROPIC_BASE_URL=*)             _args+=("ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}") ;;
                ANTHROPIC_DEFAULT_HAIKU_MODEL=*)  _args+=("ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL}") ;;
                ANTHROPIC_DEFAULT_SONNET_MODEL=*) _args+=("ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL}") ;;
                ANTHROPIC_DEFAULT_OPUS_MODEL=*)   _args+=("ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL}") ;;
                *) _args+=("$_a") ;;
            esac
        done
        command env "${_args[@]}"
    }
fi
# === CLAUDE HYBRID END ===
ZSHENVEOF
    ok "Installed teammate env override to ~/.zshenv"
fi

# ─── Step 4: Shell functions ───
info "Installing shell functions to $SHELL_RC..."

touch "$SHELL_RC"

# Remove existing block if present (update path)
if grep -q "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    info "Removed previous version, installing v${VERSION}"
fi

# Part 1: Marker + version tag (common to both shells)
cat >> "$SHELL_RC" << SHELLEOF
$MARKER_START
${VERSION_TAG}${VERSION}
SHELLEOF

# Part 2: Env propagation block (bash only — zsh uses .zshenv)
if [[ "$SHELL_RC" == *".bashrc" ]]; then
    cat >> "$SHELL_RC" << 'BASHEOF'

# --- LLM Provider Switcher ---
# Teammate panes: reload model profile to override any leaked leader env vars
if [[ -n "$HYBRID_ACTIVE" ]] && [[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$HOME/.claude-models/${HYBRID_ACTIVE}.env" ]]; then
    source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"
    export ANTHROPIC_AUTH_TOKEN="$MODEL_AUTH_TOKEN"
    export ANTHROPIC_BASE_URL="$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL_OPUS"
    # Fix: Claude Code CLI forwards leader's ANTHROPIC_BASE_URL to teammate
    env() {
        local -a _args
        for _a in "$@"; do
            case "$_a" in
                ANTHROPIC_AUTH_TOKEN=*)           _args+=("ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}") ;;
                ANTHROPIC_BASE_URL=*)             _args+=("ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}") ;;
                ANTHROPIC_DEFAULT_HAIKU_MODEL=*)  _args+=("ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL}") ;;
                ANTHROPIC_DEFAULT_SONNET_MODEL=*) _args+=("ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL}") ;;
                ANTHROPIC_DEFAULT_OPUS_MODEL=*)   _args+=("ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL}") ;;
                *) _args+=("$_a") ;;
            esac
        done
        command env "${_args[@]}"
    }
fi
BASHEOF
fi

# Part 3: Helpers + functions (common to both shells)
cat >> "$SHELL_RC" << SHELLEOF

# --- Helpers ---
_claude_unset_model_vars() {
    unset HYBRID_ACTIVE ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
    if [[ -n "\$TMUX" ]]; then
        tmux set-environment -u HYBRID_ACTIVE 2>/dev/null
        tmux set-environment -u ANTHROPIC_AUTH_TOKEN 2>/dev/null
        tmux set-environment -u ANTHROPIC_BASE_URL 2>/dev/null
        tmux set-environment -u ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null
        tmux set-environment -u ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null
        tmux set-environment -u ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null
    fi
}

_claude_load_model() {
    local model="\$1"
    if [[ ! "\$model" =~ ^[a-zA-Z0-9_-]+\$ ]]; then
        echo "Error: Invalid model name '\$model' (alphanumeric, dash, underscore only)"
        return 1
    fi
    local profile="\$HOME/.claude-models/\${model}.env"
    if [[ ! -f "\$profile" ]]; then
        echo "Error: Unknown model '\$model'. Available:"
        ls ~/.claude-models/*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
        return 1
    fi
    source "\$profile"
    export ANTHROPIC_AUTH_TOKEN="\$MODEL_AUTH_TOKEN"
    export ANTHROPIC_BASE_URL="\$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="\$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="\$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="\$MODEL_OPUS"
}

# --- cc: Claude Code solo ---
function cc() {
    local MODEL=""
    local ARGS=()
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --model|-m) MODEL="\$2"; shift 2 ;;
            *) ARGS+=("\$1"); shift ;;
        esac
    done
    if [[ -n "\$MODEL" ]]; then
        _claude_load_model "\$MODEL" || return 1
    else
        _claude_unset_model_vars
    fi
    claude --dangerously-skip-permissions "\${ARGS[@]}"
}

# --- ct: Claude Code Teams (hybrid) ---
ct() {
    local LEADER=""
    local TEAMMATE=""
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --leader|-l) LEADER="\$2"; shift 2 ;;
            --teammate|-t) TEAMMATE="\$2"; shift 2 ;;
            --model|-m) TEAMMATE="\$2"; shift 2 ;;
            *) break ;;
        esac
    done

    # Validate model profiles
    if [[ -n "\$LEADER" && ! -f "\$HOME/.claude-models/\${LEADER}.env" ]]; then
        echo "Error: Unknown leader model '\$LEADER'. Available:"
        ls ~/.claude-models/*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
        return 1
    fi
    if [[ -n "\$TEAMMATE" && ! -f "\$HOME/.claude-models/\${TEAMMATE}.env" ]]; then
        echo "Error: Unknown teammate model '\$TEAMMATE'. Available:"
        ls ~/.claude-models/*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
        return 1
    fi

    local PROJECT_DIR="\$(pwd)"
    local PROJECT_NAME="\$(basename "\$PROJECT_DIR")"

    # Session naming
    local SESSION="claude-teams"
    if [[ -n "\$LEADER" && -n "\$TEAMMATE" ]]; then
        SESSION="claude-teams-\${LEADER}-\${TEAMMATE}"
    elif [[ -n "\$TEAMMATE" ]]; then
        SESSION="claude-teams-\${TEAMMATE}"
    elif [[ -n "\$LEADER" ]]; then
        SESSION="claude-teams-\${LEADER}"
    fi

    # Increment session name if already exists
    if tmux has-session -t "\$SESSION" 2>/dev/null; then
        local i=1
        while tmux has-session -t "\${SESSION}-\${i}" 2>/dev/null; do
            i=\$((i + 1))
        done
        SESSION="\${SESSION}-\${i}"
    fi

    # Create session (session-scoped env only, no global state)
    tmux new-session -d -s "\$SESSION" -n "\$PROJECT_NAME" -c "\$PROJECT_DIR"

    # Also set session-specific env (overrides global for this session)
    if [[ -n "\$TEAMMATE" ]]; then
        (
            source "\$HOME/.claude-models/\${TEAMMATE}.env"
            tmux set-environment -t "\$SESSION" HYBRID_ACTIVE "\$TEAMMATE"
            tmux set-environment -t "\$SESSION" ANTHROPIC_AUTH_TOKEN "\$MODEL_AUTH_TOKEN"
            tmux set-environment -t "\$SESSION" ANTHROPIC_BASE_URL "\$MODEL_BASE_URL"
            tmux set-environment -t "\$SESSION" ANTHROPIC_DEFAULT_HAIKU_MODEL "\$MODEL_HAIKU"
            tmux set-environment -t "\$SESSION" ANTHROPIC_DEFAULT_SONNET_MODEL "\$MODEL_SONNET"
            tmux set-environment -t "\$SESSION" ANTHROPIC_DEFAULT_OPUS_MODEL "\$MODEL_OPUS"
        )
    else
        tmux set-environment -t "\$SESSION" -u HYBRID_ACTIVE 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_AUTH_TOKEN 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_BASE_URL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null
    fi

    # Launch leader pane
    if [[ -n "\$LEADER" ]]; then
        tmux send-keys -t "\$SESSION" \\
            "_claude_load_model \$LEADER && \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && \\
            claude --dangerously-skip-permissions --teammate-mode tmux" Enter
    else
        tmux send-keys -t "\$SESSION" \\
            "unset HYBRID_ACTIVE ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; \\
            claude --dangerously-skip-permissions --teammate-mode tmux" Enter
    fi

    tmux attach -t "\$SESSION"
}

# --- Aliases ---
alias cc-glm='cc --model glm'
alias ct-glm='ct --model glm'
$MARKER_END
SHELLEOF

ok "Installed v${VERSION} to $SHELL_RC"

# ─── Done ───
echo ""
if [[ -n "$INSTALLED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$VERSION" ]]; then
    echo -e "${BOLD}Updated v${INSTALLED_VERSION} -> v${VERSION}!${RESET}"
else
    echo -e "${BOLD}Installation complete!${RESET}"
fi
echo ""
echo "  Restart your shell or run:  source $SHELL_RC"
echo ""
echo -e "${BOLD}Usage:${RESET}"
echo "  cc                          # Claude Code (Anthropic direct)"
echo "  cc --model glm              # Claude Code with GLM"
echo "  ct                          # Teams (all Anthropic)"
echo "  ct --model glm              # Teams (leader: Anthropic, teammates: GLM)"
echo "  ct -l codex -t glm          # Teams (leader: Codex, teammates: GLM)"
echo "  ct --leader kimi            # Teams (leader: Kimi, teammates: Anthropic)"
echo ""
echo -e "${BOLD}Configure your API keys:${RESET}"
echo "  vim ~/.claude-models/glm.env      # Set GLM API key"
echo "  vim ~/.claude-models/codex.env    # Set Codex (needs CLIProxyAPI)"
echo ""
echo -e "${BOLD}Add a new model:${RESET}"
echo "  Create ~/.claude-models/<name>.env with:"
echo "    MODEL_AUTH_TOKEN, MODEL_BASE_URL, MODEL_HAIKU, MODEL_SONNET, MODEL_OPUS"
echo "  Then use: ct --leader <name> or ct --teammate <name>"
echo ""
