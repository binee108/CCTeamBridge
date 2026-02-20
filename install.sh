#!/usr/bin/env bash
set -euo pipefail

# Claude Code Hybrid Model System Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/binee108/claude-code-hybrid/main/install.sh | bash

VERSION="1.1.0"

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
HOOK_PATH="$HOME/.tmux-hybrid-hook.sh"
MARKER_START="# === CLAUDE HYBRID START ==="
MARKER_END="# === CLAUDE HYBRID END ==="
VERSION_TAG="# CLAUDE_HYBRID_VERSION="

echo ""
echo -e "${BOLD}Claude Code Hybrid Model System v${VERSION}${RESET}"
echo -e "Leader: Anthropic (Opus) | Teammates: Any model"
echo "=================================================="
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
        if [[ "${1:-}" != "--force" ]]; then
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
        if [[ "${1:-}" != "--force" ]]; then
            exit 0
        fi
        warn "Force downgrade requested"
    fi
else
    info "Fresh installation"
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

# ─── Step 2: tmux hook script ───
info "Installing tmux hybrid hook..."
cat > "$HOOK_PATH" << 'HOOKEOF'
#!/bin/sh
# tmux session-created hook: hybrid model env injection
ACTIVE_MODEL=$(cat ~/.claude-hybrid-active 2>/dev/null)
PROFILE="$HOME/.claude-models/${ACTIVE_MODEL}.env"

[ -z "$ACTIVE_MODEL" ] && exit 0
[ ! -f "$PROFILE" ] && exit 0

. "$PROFILE"

tmux set-environment HYBRID_ACTIVE "$ACTIVE_MODEL"
tmux set-environment ANTHROPIC_AUTH_TOKEN "$MODEL_AUTH_TOKEN"
tmux set-environment ANTHROPIC_BASE_URL "$MODEL_BASE_URL"
tmux set-environment ANTHROPIC_DEFAULT_HAIKU_MODEL "$MODEL_HAIKU"
tmux set-environment ANTHROPIC_DEFAULT_SONNET_MODEL "$MODEL_SONNET"
tmux set-environment ANTHROPIC_DEFAULT_OPUS_MODEL "$MODEL_OPUS"
HOOKEOF
chmod 755 "$HOOK_PATH"
ok "Installed $HOOK_PATH"

# ─── Step 3: tmux.conf hook registration ───
info "Configuring tmux.conf..."
TMUX_CONF="$HOME/.tmux.conf"
touch "$TMUX_CONF"

# Remove old GLM hook if present
if grep -q 'tmux-glm-hook' "$TMUX_CONF" 2>/dev/null; then
    sed -i.bak '/tmux-glm-hook/d' "$TMUX_CONF"
    warn "Removed old GLM hook from tmux.conf"
fi

if grep -q 'tmux-hybrid-hook' "$TMUX_CONF" 2>/dev/null; then
    ok "Hybrid hook already in tmux.conf, skipping"
else
    echo '' >> "$TMUX_CONF"
    echo '# === HYBRID MODEL HOOK ===' >> "$TMUX_CONF"
    echo "set-hook -g session-created 'run-shell \"sh ~/.tmux-hybrid-hook.sh\"'" >> "$TMUX_CONF"
    ok "Added hybrid hook to tmux.conf"
fi

# Reload tmux if running
if command -v tmux &>/dev/null && tmux list-sessions &>/dev/null; then
    tmux source-file "$TMUX_CONF" 2>/dev/null && ok "Reloaded tmux config" || warn "tmux reload failed (non-critical)"
fi

# ─── Step 4: Shell functions ───
info "Installing shell functions to $SHELL_RC..."

touch "$SHELL_RC"

# Remove existing block if present (update path)
if grep -q "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    info "Removed previous version, installing v${VERSION}"
fi

cat >> "$SHELL_RC" << SHELLEOF
$MARKER_START
${VERSION_TAG}${VERSION}

# --- LLM Provider Switcher ---
# Teammate panes with HYBRID_ACTIVE keep their model env vars
if [[ -z "\$HYBRID_ACTIVE" ]]; then
    unset ANTHROPIC_BASE_URL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
fi

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
    local MODEL=""
    local WORKTREE=""
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --model|-m) MODEL="\$2"; shift 2 ;;
            --worktree|-w) WORKTREE="--worktree"; shift ;;
            *) break ;;
        esac
    done

    local PROJECT_DIR="\$(pwd)"
    local PROJECT_NAME="\$(basename "\$PROJECT_DIR")"
    local SESSION="claude-teams"

    if [[ -n "\$MODEL" ]]; then
        local PROFILE="\$HOME/.claude-models/\${MODEL}.env"
        if [[ ! -f "\$PROFILE" ]]; then
            echo "Error: Unknown model '\$MODEL'. Available:"
            ls ~/.claude-models/*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
            return 1
        fi
        echo "\$MODEL" > ~/.claude-hybrid-active
        SESSION="claude-teams-\${MODEL}"
    else
        rm -f ~/.claude-hybrid-active
    fi

    # Increment session name if already exists
    if tmux has-session -t "\$SESSION" 2>/dev/null; then
        local i=1
        while tmux has-session -t "\${SESSION}-\${i}" 2>/dev/null; do
            ((i++))
        done
        SESSION="\${SESSION}-\${i}"
    fi

    tmux new-session -d -s "\$SESSION" -n "\$PROJECT_NAME" -c "\$PROJECT_DIR"

    if [[ -n "\$MODEL" ]]; then
        tmux send-keys -t "\$SESSION" \\
            "unset HYBRID_ACTIVE ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; \\
            claude --dangerously-skip-permissions \$WORKTREE --teammate-mode tmux" Enter
    else
        tmux set-environment -t "\$SESSION" -u HYBRID_ACTIVE 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_AUTH_TOKEN 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_BASE_URL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null
        tmux set-environment -t "\$SESSION" -u ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null
        tmux send-keys -t "\$SESSION" \\
            "unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; \\
            claude --dangerously-skip-permissions \$WORKTREE --teammate-mode tmux" Enter
    fi
    tmux attach -t "\$SESSION"
}

# --- Aliases ---
alias cc-glm='cc --model glm'
alias ccw='cc --worktree'
alias ct-glm='ct --model glm'
alias ctw='ct --worktree'
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
echo "  cc                    # Claude Code (Anthropic direct)"
echo "  cc --model glm        # Claude Code with GLM"
echo "  ct                    # Teams (all Anthropic)"
echo "  ct --model glm        # Teams hybrid (leader: Opus, teammates: GLM)"
echo "  ct --model codex      # Teams hybrid (leader: Opus, teammates: Codex)"
echo "  ccw / ctw             # Same as above with --worktree"
echo ""
echo -e "${BOLD}Configure your API keys:${RESET}"
echo "  vim ~/.claude-models/glm.env      # Set GLM API key"
echo "  vim ~/.claude-models/codex.env    # Set Codex (needs CLIProxyAPI)"
echo ""
echo -e "${BOLD}Add a new model:${RESET}"
echo "  Create ~/.claude-models/<name>.env with:"
echo "    MODEL_AUTH_TOKEN, MODEL_BASE_URL, MODEL_HAIKU, MODEL_SONNET, MODEL_OPUS"
echo "  Then use: ct --model <name>"
echo ""
