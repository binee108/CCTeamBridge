#!/usr/bin/env bash
set -euo pipefail

# Ensure running with bash (not sh)
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: This script requires bash. Run with: bash $0" >&2
    exit 1
fi

# CCTeamBridge Installer
# Usage: curl -fsSLo ./install.sh https://raw.githubusercontent.com/binee108/CCTeamBridge/main/install.sh && chmod +x ./install.sh && bash ./install.sh

VERSION="1.7.0"

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

# Interrupt handler for cleanup
trap 'warn "Interrupted! Partial installation may exist."; exit 130' INT

_has_tty_prompt() {
    [[ -r /dev/tty ]]
}

_read_tty_var() {
    local _var_name="$1"
    local _line=""
    _has_tty_prompt || return 1
    IFS= read -r _line < /dev/tty || return 1
    printf -v "$_var_name" '%s' "$_line"
}

_read_tty_prompt_default() {
    local _var_name="$1"
    local _default="${2:-}"
    local _label="${3:-prompt}"
    local _non_tty_default="${4:-$_default}"
    if _read_tty_var "$_var_name"; then
        return 0
    fi
    printf -v "$_var_name" '%s' "$_non_tty_default"
    warn "No interactive TTY for ${_label}; using default response"
    return 1
}

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
    for f in "$HOME/.zshrc" "$HOME/.bashrc"; do
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
echo -e "${BOLD}CCTeamBridge v${VERSION}${RESET}"
echo -e "Model switching for Claude Code"
echo "=================================================="
echo ""

# ─── Auto-backup before any modification ───
info "Creating backup..."
_do_backup
echo ""

# ─── Version check ───
# Detect shell config file
if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL:-}" == *zsh* ]]; then
    SHELL_RC="$HOME/.zshrc"
elif [[ -n "${BASH_VERSION:-}" ]] || [[ "${SHELL:-}" == *bash* ]]; then
    SHELL_RC="$HOME/.bashrc"
else
    if [[ -f "$HOME/.bashrc" ]] || [[ ! -f "$HOME/.zshrc" ]]; then
        SHELL_RC="$HOME/.bashrc"
    else
        SHELL_RC="$HOME/.zshrc"
    fi
    warn "Unknown shell (${SHELL:-unset}), defaulting to ${SHELL_RC}."
    warn "If you use another shell, source ${SHELL_RC} from your shell startup file."
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
        echo -e "  To force reinstall: ${BOLD}bash ./install.sh --force${RESET}"
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
        echo -e "  To force downgrade: ${BOLD}bash ./install.sh --force${RESET}"
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
    rm -f "$HOME/.tmux.conf.bak"
    _legacy_cleaned=$((_legacy_cleaned + 1))
fi

# Remove old-style shell blocks with different markers (pre-hybrid era)
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [[ -f "$RC" ]]; then
        if grep -q '# === LLM PROVIDER SWITCHER START ===' "$RC" 2>/dev/null; then
            sed -i.bak '/# === LLM PROVIDER SWITCHER START ===/,/# === LLM PROVIDER SWITCHER END ===/d' "$RC"
            rm -f "${RC}.bak"
            _legacy_cleaned=$((_legacy_cleaned + 1))
        fi
        if grep -q '# === CLAUDE CODE SHORTCUTS ===' "$RC" 2>/dev/null; then
            sed -i.bak '/# === CLAUDE CODE SHORTCUTS ===/,/# === CLAUDE CODE SHORTCUTS END ===/d' "$RC"
            rm -f "${RC}.bak"
            _legacy_cleaned=$((_legacy_cleaned + 1))
        fi
    fi
done
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
# CLIProxyAPI detection (kept for OAuth login migration)
_detect_cliproxy() {
    for p in \
        "$(command -v cliproxyapi 2>/dev/null)" \
        "$(command -v cli-proxy-api 2>/dev/null)" \
        /usr/local/bin/cliproxyapi \
        /usr/local/bin/cli-proxy-api \
        /opt/homebrew/bin/cliproxyapi \
        /opt/homebrew/bin/cli-proxy-api \
        "$HOME/.local/bin/cliproxyapi" \
        "$HOME/.local/bin/cli-proxy-api"; do
        [[ -n "$p" && -x "$p" ]] && echo "$p" && return 0
    done
    return 1
}

# --- Python proxy setup ---
_setup_proxy() {
    local CCBRIDGE_DIR="$HOME/.ccbridge"
    local VENV_DIR="$CCBRIDGE_DIR/venv"
    local PROXY_SRC

    # Find proxy source (git repo or standalone)
    local _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_script_dir/proxy/__init__.py" ]]; then
        PROXY_SRC="$_script_dir"
    elif [[ -f "$HOME/CCTeamBridge/proxy/__init__.py" ]]; then
        PROXY_SRC="$HOME/CCTeamBridge"
    else
        warn "Proxy source not found"
        return 1
    fi

    # Create venv and install deps
    if [[ ! -f "$VENV_DIR/bin/python3" ]]; then
        info "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR" || { warn "Failed to create venv"; return 1; }
    fi

    if ! "$VENV_DIR/bin/python3" -c "import aiohttp" 2>/dev/null; then
        info "Installing proxy dependencies..."
        "$VENV_DIR/bin/pip" install -q aiohttp pyyaml || { warn "Failed to install deps"; return 1; }
    fi

    # Copy proxy files to ~/.ccbridge/proxy/
    mkdir -p "$CCBRIDGE_DIR/proxy"
    cp -r "$PROXY_SRC/proxy/"* "$CCBRIDGE_DIR/proxy/" 2>/dev/null || true

    # Create default config if missing
    if [[ ! -f "$CCBRIDGE_DIR/config.yaml" ]]; then
        cat > "$CCBRIDGE_DIR/config.yaml" << 'CONFEOF'
port: 8317
host: "127.0.0.1"

glm:
  base_url: "https://api.z.ai/api/anthropic"
  api_keys: []

codex:
  base_url: "https://api.anthropic.com"

claude:
  base_url: "https://api.anthropic.com"

kimi:
  base_url: "https://api.anthropic.com"

credential_dir: "~/.ccbridge/credentials"
CONFEOF
        ok "Created default config: $CCBRIDGE_DIR/config.yaml"
    fi

    ok "Proxy setup complete"
}

CLIPROXY_BIN="$(_detect_cliproxy)" || CLIPROXY_BIN=""

# Detect Python 3 and setup the built-in proxy
PROXY_READY=0
if command -v python3 &>/dev/null; then
    _py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")"
    if [[ "$(echo "$_py_ver" | awk -F. '{print ($1*100)+$2}')" -ge 309 ]]; then
        ok "Python ${_py_ver} found"
        if _setup_proxy; then
            PROXY_READY=1
        else
            warn "Proxy setup failed; proxy-dependent profiles may not work"
        fi
    else
        warn "Python ${_py_ver} found but >= 3.9 required for built-in proxy"
        info "GLM-only installation will continue"
    fi
else
    warn "Python3 not found; built-in proxy unavailable"
    info "GLM-only installation will continue"
fi

# ─── Step 1: Model profiles directory ───
info "Creating model profiles directory..."
mkdir -p "$MODELS_DIR" && chmod 700 "$MODELS_DIR"

if [[ ! -f "$MODELS_DIR/glm.env" ]]; then
    cat > "$MODELS_DIR/glm.env" << 'EOF'
# GLM API Profile
# Get your API key at: https://z.ai/manage-apikey/apikey-list
MODEL_AUTH_TOKEN="YOUR_GLM_API_KEY_HERE"
MODEL_BASE_URL="https://api.z.ai/api/anthropic"
MODEL_HAIKU="glm-4.7"
MODEL_SONNET="glm-5"
MODEL_OPUS="glm-5"
EOF
    chmod 600 "$MODELS_DIR/glm.env"
    ok "Created glm.env"
fi

# GLM API key registration
_glm_needs_key=0
if grep -q 'YOUR_GLM_API_KEY_HERE' "$MODELS_DIR/glm.env" 2>/dev/null; then
    _glm_needs_key=1
fi

if [[ "$_glm_needs_key" -eq 1 ]]; then
    echo ""
    info "GLM API 키가 설정되지 않았습니다."
    echo "  API 키 발급: https://z.ai/manage-apikey/apikey-list"
    echo ""
    echo "  API 키 1개당 동시 세션 3개가 할당됩니다."
    echo "  복수 키 등록 시 동시 세션 수가 비례하여 증가합니다. (키 5개 = 세션 15개)"
    echo ""
    echo "  ${CYAN}권장 등록 수:${RESET}"
    echo "    Lite/Pro 플랜:  1개"
    echo "    Max 플랜:       5개 (동시 세션 15개로 다중 세션에 최적)"
    echo ""
    echo -ne "  ${BOLD}지금 GLM API 키를 등록하시겠습니까? [Y/n]:${RESET} "
    _read_tty_prompt_default _confirm "N" "GLM key registration prompt" >/dev/null || true
    if [[ -z "$_confirm" || "$_confirm" =~ ^[Yy] ]]; then
        _glm_keys=()
        while true; do
            echo ""
            echo -ne "  ${BOLD}GLM API 키를 입력하세요:${RESET} "
            if ! _read_tty_var _key; then
                warn "No interactive TTY for GLM key input; stopping key registration loop"
                break
            fi
            _key="${_key#"${_key%%[![:space:]]*}"}"
            _key="${_key%"${_key##*[![:space:]]}"}"
            if [[ -z "$_key" ]]; then
                warn "빈 값은 무시됩니다."
                continue
            fi
            if [[ "$_key" == *'"'* ]] || [[ "$_key" == *"'"* ]] || [[ "$_key" == *'$'* ]] || [[ "$_key" == *'\'* ]] || [[ "$_key" == *$'\n'* ]] || [[ "$_key" == *'`'* ]]; then
                warn "키에 허용되지 않는 특수문자가 포함되어 있습니다. 다시 입력하세요."
                continue
            fi
            if [[ ${#_key} -lt 8 ]]; then
                warn "키가 너무 짧습니다 (${#_key}자). 올바른 키인지 확인하세요."
                continue
            fi
            _glm_keys+=("$_key")
            ok "키 ${#_glm_keys[@]}개 등록됨"
            echo ""
            echo -ne "  ${BOLD}추가 키를 등록하시겠습니까? [y/N]:${RESET} "
            _read_tty_prompt_default _more "N" "GLM additional key prompt" >/dev/null || true
            if [[ "$_more" =~ ^[Yy] ]]; then
                continue
            else
                break
            fi
        done

        if [[ ${#_glm_keys[@]} -gt 0 ]]; then
            # Rewrite glm.env safely (avoids sed metacharacter issues with API keys)
            _glm_token_str=""
            for _k in "${_glm_keys[@]}"; do
                if [[ -n "$_glm_token_str" ]]; then
                    _glm_token_str="${_glm_token_str},${_k}"
                else
                    _glm_token_str="$_k"
                fi
            done

            {
                echo "# GLM API Profile"
                echo "# Get your API key at: https://z.ai/manage-apikey/apikey-list"
                if [[ ${#_glm_keys[@]} -gt 1 ]]; then
                    echo "MODEL_AUTH_TOKENS=\"${_glm_token_str}\""
                fi
                echo "MODEL_AUTH_TOKEN=\"${_glm_keys[0]}\""
                echo 'MODEL_BASE_URL="https://api.z.ai/api/anthropic"'
                echo 'MODEL_HAIKU="glm-4.7"'
                echo 'MODEL_SONNET="glm-5"'
                echo 'MODEL_OPUS="glm-5"'
            } > "$MODELS_DIR/glm.env"
            chmod 600 "$MODELS_DIR/glm.env"

            ok "GLM API 키 ${#_glm_keys[@]}개 등록 완료"
            if [[ ${#_glm_keys[@]} -gt 1 ]]; then
                info "멀티 키 등록 완료 (첫 번째 키가 사용됩니다)"
            fi
        fi
    else
        info "GLM 키 등록을 건너뛰었습니다 (나중에 편집: vim $MODELS_DIR/glm.env)"
    fi
else
    ok "glm.env already configured"
fi

if [[ ! -f "$MODELS_DIR/codex.env" ]]; then
    cat > "$MODELS_DIR/codex.env" << 'EOF'
# Codex API Profile (via ccbridge-proxy)
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="gpt-5.3-codex-spark"
MODEL_SONNET="gpt-5.3-codex"
MODEL_OPUS="gpt-5.3-codex"
EOF
    chmod 600 "$MODELS_DIR/codex.env"
    ok "Created codex.env (requires ccbridge-proxy)"
else
    ok "codex.env already exists, skipping"
fi

if [[ ! -f "$MODELS_DIR/kimi.env" ]]; then
    cat > "$MODELS_DIR/kimi.env" << 'EOF'
# Kimi API Profile (via ccbridge-proxy)
MODEL_AUTH_TOKEN="PLACEHOLDER"
MODEL_BASE_URL="http://localhost:8317/api/anthropic"
MODEL_HAIKU="kimi-latest"
MODEL_SONNET="kimi-latest"
MODEL_OPUS="kimi-latest"
EOF
    chmod 600 "$MODELS_DIR/kimi.env"
    ok "Created kimi.env (requires ccbridge-proxy)"
else
    ok "kimi.env already exists, skipping"
fi

if [[ ! -f "$MODELS_DIR/hybrid.env" ]]; then
    cat > "$MODELS_DIR/hybrid.env" << 'EOF'
# Hybrid API Profile (Custom multi-model via ccbridge-proxy)
# Configure any model combination for Opus/Sonnet/Haiku roles
# Requires: ccbridge-proxy with appropriate model credentials
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="glm-5-turbo"
MODEL_SONNET="glm-5.1"
MODEL_OPUS="claude-opus-4-6"
EOF
    chmod 600 "$MODELS_DIR/hybrid.env"
    ok "Created hybrid.env (requires ccbridge-proxy — configure any model combination)"
else
    ok "hybrid.env already exists, skipping"
fi

# ─── Step: Codex Account Registration ───
# Note: OAuth login still requires CLIProxyAPI binary for now.
# This will be replaced with a native implementation in a future version.
if [[ -n "$CLIPROXY_BIN" ]]; then
    _codex_cred_count=0
    for _f in "$HOME/.ccbridge/credentials/codex-"*.json; do
        [[ -f "$_f" ]] && _codex_cred_count=$((_codex_cred_count + 1))
    done
    # Also check legacy path for migration
    for _f in "$HOME/.cli-proxy-api/codex-"*.json; do
        [[ -f "$_f" ]] && _codex_cred_count=$((_codex_cred_count + 1))
    done

    if [[ "$_codex_cred_count" -eq 0 ]]; then
        echo ""
        info "Codex 계정이 등록되지 않았습니다."
        echo "  OAuth 로그인으로 계정을 등록합니다. (브라우저가 열립니다)"
        echo ""
        echo -e "  ${YELLOW}Tip:${RESET} 파일명에 -plus 또는 -pro를 포함하면 우선순위가 자동 설정됩니다."
        echo "    예: codex-work-plus, codex-personal-pro"
        echo ""
        echo -ne "  ${BOLD}지금 Codex 계정을 등록하시겠습니까? [Y/n]:${RESET} "
        _read_tty_prompt_default _confirm "N" "Codex registration prompt" >/dev/null || true
        if [[ -z "$_confirm" || "$_confirm" =~ ^[Yy] ]]; then
            while true; do
                echo ""
                info "Codex OAuth 로그인을 시작합니다..."
                "$CLIPROXY_BIN" -codex-login
                echo ""
                echo -ne "  ${BOLD}추가 계정을 등록하시겠습니까? [y/N]:${RESET} "
                _read_tty_prompt_default _more "N" "Codex additional account prompt" >/dev/null || true
                if [[ "$_more" =~ ^[Yy] ]]; then
                    continue
                else
                    break
                fi
            done
            _codex_cred_count=0
            for _f in "$HOME/.ccbridge/credentials/codex-"*.json; do
                [[ -f "$_f" ]] && _codex_cred_count=$((_codex_cred_count + 1))
            done
            ok "Codex 계정 ${_codex_cred_count}개 등록됨"
        else
            info "Codex 계정 등록을 건너뛰었습니다 (나중에 실행: $CLIPROXY_BIN -codex-login)"
        fi
    else
        ok "Codex 계정 ${_codex_cred_count}개 감지됨"
    fi
fi

# ─── Step: Proxy Configuration & Service Start ───
if [[ "$PROXY_READY" -eq 1 ]]; then
    CCBRIDGE_DIR="$HOME/.ccbridge"
    VENV_PYTHON="$CCBRIDGE_DIR/venv/bin/python3"
    PID_FILE="$CCBRIDGE_DIR/proxy.pid"

    # Inject GLM API keys from glm.env into config.yaml
    if [[ -f "$MODELS_DIR/glm.env" ]]; then
        _glm_key="$(grep '^MODEL_AUTH_TOKEN=' "$MODELS_DIR/glm.env" 2>/dev/null | head -1 | sed 's/^MODEL_AUTH_TOKEN="//;s/"$//')"
        if [[ -n "$_glm_key" && "$_glm_key" != "YOUR_GLM_API_KEY_HERE" ]]; then
            # Build api_keys list from MODEL_AUTH_TOKENS or single token
            _glm_tokens="$(
                grep '^MODEL_AUTH_TOKENS=' "$MODELS_DIR/glm.env" 2>/dev/null | head -1 | sed 's/^MODEL_AUTH_TOKENS="//;s/"$//' || true
            )"
            if [[ -z "$_glm_tokens" ]]; then
                _glm_tokens="$_glm_key"
            fi
            # Update config.yaml with GLM keys
            if command -v python3 &>/dev/null; then
                python3 -c "
import yaml, sys, os
cfg_path = os.path.expanduser('~/.ccbridge/config.yaml')
try:
    with open(cfg_path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    cfg = {}
keys_str = sys.argv[1]
cfg.setdefault('glm', {})['api_keys'] = [k.strip() for k in keys_str.split(',') if k.strip()]
with open(cfg_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
" "$_glm_tokens" 2>/dev/null && ok "Updated config.yaml with GLM API keys"
            fi
        fi
    fi

    # Migrate legacy CLIProxyAPI credentials if present
    if [[ -d "$HOME/.cli-proxy-api" ]]; then
        _migrated=0
        mkdir -p "$CCBRIDGE_DIR/credentials"
        for _f in "$HOME/.cli-proxy-api/codex-"*.json; do
            [[ -f "$_f" ]] || continue
            cp "$_f" "$CCBRIDGE_DIR/credentials/" && _migrated=$((_migrated + 1))
        done
        if [[ $_migrated -gt 0 ]]; then
            ok "Migrated ${_migrated} credential(s) from ~/.cli-proxy-api/ to ~/.ccbridge/credentials/"
        fi
    fi

    # Set multi-account priority on codex credentials
    _priority_changes=()
    _priority_files=()
    _priority_values=()
    for _cred in "$CCBRIDGE_DIR/credentials/codex-"*.json; do
        [[ -f "$_cred" ]] || continue
        _name="$(basename "$_cred" | tr '[:upper:]' '[:lower:]')"
        _priority=""
        case "$_name" in
            *-plus*) _priority="100" ;;
            *-pro*)  _priority="0" ;;
            *)       continue ;;
        esac
        _priority_files+=("$_cred")
        _priority_values+=("$_priority")
        _priority_changes+=("$(basename "$_cred"): priority -> ${_priority}")
    done

    if [[ ${#_priority_changes[@]} -gt 0 ]]; then
        echo ""
        info "Codex 계정 우선순위를 설정합니다:"
        for _c in "${_priority_changes[@]}"; do
            echo "    $_c"
        done
        echo ""
        echo -ne "  ${BOLD}적용하시겠습니까? (기존 사용자가 아니면 Enter) [Y/n]:${RESET} "
        _read_tty_prompt_default _confirm "Y" "Codex priority prompt" "N" >/dev/null || true
        if [[ -z "$_confirm" || "$_confirm" =~ ^[Yy] ]]; then
            _priority_count=0
            for _i in "${!_priority_files[@]}"; do
                _cred="${_priority_files[$_i]}"
                _priority="${_priority_values[$_i]}"
                if command -v python3 &>/dev/null; then
                    python3 -c "
import json, os, sys, tempfile
p, pri = sys.argv[1], sys.argv[2]
d = json.loads(open(p).read())
d.setdefault('attributes', {})['priority'] = pri
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
try:
    with os.fdopen(fd, 'w') as f: f.write(json.dumps(d, separators=(',', ':')))
    os.replace(tmp, p)
    tmp = None
finally:
    if tmp: os.unlink(tmp)
" "$_cred" "$_priority" 2>/dev/null && _priority_count=$((_priority_count + 1))
                elif command -v jq &>/dev/null; then
                    _tmp="$(jq --arg p "$_priority" '.attributes.priority = $p' "$_cred")" && \
                        echo "$_tmp" > "$_cred" && _priority_count=$((_priority_count + 1))
                fi
            done
            ok "Codex 계정 우선순위 ${_priority_count}건 설정 완료"
        else
            warn "Codex 계정 우선순위 설정을 건너뛰었습니다"
        fi
    fi

    # Start/restart the Python proxy service
    info "Starting ccbridge-proxy..."

    # Stop any existing proxy process
    if [[ -f "$PID_FILE" ]]; then
        _old_pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [[ -n "$_old_pid" ]] && kill -0 "$_old_pid" 2>/dev/null; then
            kill "$_old_pid" 2>/dev/null
            sleep 1
        fi
        rm -f "$PID_FILE"
    fi

    case "$(uname -s)" in
        Darwin*)
            # Use launchd plist for macOS
            _plist_label="com.ccbridge.proxy"
            _plist_path="$HOME/Library/LaunchAgents/${_plist_label}.plist"
            mkdir -p "$HOME/Library/LaunchAgents"

            # Unload existing if present
            launchctl unload "$_plist_path" 2>/dev/null || true

            cat > "$_plist_path" << PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${_plist_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_PYTHON}</string>
        <string>-m</string>
        <string>proxy</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${CCBRIDGE_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CCBRIDGE_DIR}/proxy.log</string>
    <key>StandardErrorPath</key>
    <string>${CCBRIDGE_DIR}/proxy.log</string>
</dict>
</plist>
PLEOF
            launchctl load "$_plist_path" 2>/dev/null
            ok "Started ccbridge-proxy via launchd"
            ;;
        Linux*)
            if command -v systemctl &>/dev/null && systemctl --user list-unit-files >/dev/null 2>&1; then
                # Create systemd user service
                mkdir -p "$HOME/.config/systemd/user"
                cat > "$HOME/.config/systemd/user/ccbridge-proxy.service" << SVCEOF
[Unit]
Description=CCTeamBridge Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=${VENV_PYTHON} -m proxy
WorkingDirectory=${CCBRIDGE_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
                systemctl --user daemon-reload
                systemctl --user enable ccbridge-proxy >/dev/null 2>&1
                if systemctl --user is-active ccbridge-proxy >/dev/null 2>&1; then
                    systemctl --user restart ccbridge-proxy >/dev/null 2>&1
                    ok "Restarted ccbridge-proxy service (systemd)"
                else
                    systemctl --user start ccbridge-proxy >/dev/null 2>&1
                    ok "Started ccbridge-proxy service (systemd)"
                fi
            else
                # WSL or no systemd - use nohup
                mkdir -p "$CCBRIDGE_DIR"
                nohup "$VENV_PYTHON" -m proxy > "$CCBRIDGE_DIR/proxy.log" 2>&1 &
                echo $! > "$PID_FILE"
                sleep 1
                _proxy_pid="$(cat "$PID_FILE" 2>/dev/null)"
                if [[ -n "$_proxy_pid" ]] && kill -0 "$_proxy_pid" 2>/dev/null; then
                    ok "Started ccbridge-proxy in background (PID: $_proxy_pid)"
                else
                    warn "ccbridge-proxy background start may have failed (check $CCBRIDGE_DIR/proxy.log)"
                fi
            fi
            ;;
    esac

    # Verify service health with retry
    _health_attempts=0
    _health_max=10
    _health_ok=0
    while ((_health_attempts < _health_max)); do
        if curl -s --connect-timeout 1 http://127.0.0.1:8317/v1/models -H "Authorization: Bearer sk-dummy" >/dev/null 2>&1; then
            _health_ok=1
            break
        fi
        sleep 1
        _health_attempts=$((_health_attempts + 1))
    done
    if ((_health_ok)); then
        ok "ccbridge-proxy responding on port 8317"
    else
        warn "ccbridge-proxy not responding on port 8317 after ${_health_max}s"
    fi
    echo ""
fi

# ─── Shell functions installation ───
info "Installing shell functions to $SHELL_RC..."

touch "$SHELL_RC" 2>/dev/null || { error "Cannot write to $SHELL_RC (check permissions)"; exit 1; }

# Remove existing block if present (update path)
if grep -q "$MARKER_START" "$SHELL_RC" 2>/dev/null; then
    sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$SHELL_RC"
    rm -f "${SHELL_RC}.bak"
    info "Removed previous version, installing v${VERSION}"
fi

# Part 1: Marker + version tag (common to both shells)
cat >> "$SHELL_RC" << SHELLEOF
$MARKER_START
${VERSION_TAG}${VERSION}
SHELLEOF

# Part 2: Helpers + functions (common to both shells)
cat >> "$SHELL_RC" << SHELLEOF

# --- Helpers ---
_claude_unset_model_vars() {
    unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL
}

_claude_collect_model_tokens_from_loaded_env() {
    local _raw_tokens="\${MODEL_AUTH_TOKENS:-\${MODEL_AUTH_TOKEN:-}}"
    local _tok
    local _trimmed

    [[ -z "\$_raw_tokens" ]] && return 0

    while IFS= read -r _tok; do
        _trimmed="\${_tok#"\${_tok%%[![:space:]]*}"}"
        _trimmed="\${_trimmed%"\${_trimmed##*[![:space:]]}"}"
        [[ -n "\$_trimmed" ]] && printf '%s\n' "\$_trimmed"
    done < <(printf '%s\n' "\$_raw_tokens" | tr ',' '\n')
}

_claude_first_model_token_from_loaded_env() {
    local _first
    _first="\$(_claude_collect_model_tokens_from_loaded_env | head -n 1)"
    [[ -n "\$_first" ]] && printf '%s' "\$_first"
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
    local _selected_token=""
    _selected_token="\$(_claude_first_model_token_from_loaded_env)"
    export ANTHROPIC_AUTH_TOKEN="\$_selected_token"
    export ANTHROPIC_BASE_URL="\$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="\$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="\$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="\$MODEL_OPUS"
}

# --- cdoctor: Validate setup ---
cdoctor() {
    local ok_count=0
    local warn_count=0
    local err_count=0

    _doctor_ok() {
        echo "[OK]   \$1"
        ok_count=\$((ok_count + 1))
    }
    _doctor_warn() {
        echo "[WARN] \$1"
        warn_count=\$((warn_count + 1))
    }
    _doctor_err() {
        echo "[ERR]  \$1"
        err_count=\$((err_count + 1))
    }

    echo ""
    echo "CCTeamBridge Doctor"
    echo "===================="

    if command -v claude >/dev/null 2>&1; then
        _doctor_ok "Claude Code CLI found: \$(claude --version 2>/dev/null || echo installed)"
    else
        _doctor_err "Claude Code CLI not found in PATH"
    fi
    if [[ -d "\$HOME/.claude-models" ]]; then
        _doctor_ok "Model profile directory exists: \$HOME/.claude-models"
    else
        _doctor_err "Model profile directory missing: \$HOME/.claude-models"
    fi

    for profile in glm codex kimi hybrid; do
        if [[ -f "\$HOME/.claude-models/\${profile}.env" ]]; then
            _doctor_ok "Profile exists: \${profile}.env"
        else
            _doctor_warn "Profile missing: \${profile}.env"
        fi
    done

    if [[ -f "\$HOME/.claude-models/codex.env" ]]; then
        local missing=0
        for key in MODEL_AUTH_TOKEN MODEL_BASE_URL MODEL_HAIKU MODEL_SONNET MODEL_OPUS; do
            if ! grep -q "^\${key}=\".*\"$" "\$HOME/.claude-models/codex.env" 2>/dev/null; then
                _doctor_warn "codex.env missing or invalid key: \${key}"
                missing=\$((missing + 1))
            fi
        done
        if ((missing == 0)); then
            _doctor_ok "codex.env required keys are present"
        fi
    fi

    local shell_blocks=0
    for rc in "\$HOME/.zshrc" "\$HOME/.bashrc"; do
        if [[ -f "\$rc" ]] && grep -q "# === CLAUDE HYBRID START ===" "\$rc" 2>/dev/null; then
            _doctor_ok "Shell function block found in \${rc}"
            shell_blocks=\$((shell_blocks + 1))
        fi
    done
    if ((shell_blocks == 0)); then
        _doctor_err "Shell function block not found in ~/.zshrc or ~/.bashrc"
    fi

    local _proxy_venv="\$HOME/.ccbridge/venv/bin/python3"
    if [[ -f "\$_proxy_venv" ]]; then
        _doctor_ok "ccbridge-proxy venv found: \$_proxy_venv"

        # Check feature flag
        if [[ "\${CCBRIDGE_PROXY_ENABLED:-1}" == "1" || "\${CCBRIDGE_PROXY_ENABLED:-true}" == "true" ]]; then
            _doctor_ok "CCBRIDGE_PROXY_ENABLED=true"
        else
            _doctor_warn "CCBRIDGE_PROXY_ENABLED=false (proxy disabled)"
        fi

        # Check if proxy process is running
        local _proxy_running=0
        if [[ -f "\$HOME/.ccbridge/proxy.pid" ]]; then
            local _pid="\$(cat "\$HOME/.ccbridge/proxy.pid" 2>/dev/null)"
            if [[ -n "\$_pid" ]] && kill -0 "\$_pid" 2>/dev/null; then
                _proxy_running=1
            fi
        fi
        if [[ "\$_proxy_running" -eq 0 ]]; then
            # Also check via pgrep or systemctl/launchd
            case "\$(uname -s)" in
                Darwin*)
                    if launchctl list 2>/dev/null | grep -q 'com.ccbridge.proxy'; then
                        _proxy_running=1
                    fi
                    ;;
                Linux*)
                    if command -v systemctl &>/dev/null && systemctl --user is-active ccbridge-proxy >/dev/null 2>&1; then
                        _proxy_running=1
                    elif pgrep -f "python3 -m proxy" >/dev/null 2>&1; then
                        _proxy_running=1
                    fi
                    ;;
            esac
        fi

        if [[ "\$_proxy_running" -eq 1 ]]; then
            _doctor_ok "ccbridge-proxy process is running"
        else
            _doctor_warn "ccbridge-proxy process is not running"
        fi

        # Check health endpoint
        local _health_resp
        _health_resp="\$(curl -s --connect-timeout 2 http://127.0.0.1:8317/v1/models -H "Authorization: Bearer sk-dummy" 2>/dev/null)"
        if [[ -n "\$_health_resp" ]]; then
            _doctor_ok "ccbridge-proxy responding on port 8317"
        else
            _doctor_warn "ccbridge-proxy not responding on port 8317"
        fi
    else
        _doctor_warn "ccbridge-proxy venv not found (required for Codex/Kimi profiles)"
    fi

    echo ""
    echo "Doctor Summary: OK=\${ok_count}, WARN=\${warn_count}, ERR=\${err_count}"

    if ((err_count > 0)); then
        echo "Result: FAIL"
        return 1
    fi

    echo "Result: PASS (with warnings possible)"
    return 0
}

# --- ccd: Claude Code dangerously-skip-permissions ---
_ccbridge_ensure_proxy() {
    # Quick health check — if proxy responds, we're done
    if curl -s --connect-timeout 1 http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
        return 0
    fi
    # Try to start proxy
    local _venv_python="\$HOME/.ccbridge/venv/bin/python3"
    if [[ ! -f "\$_venv_python" ]]; then
        return 1
    fi
    "\$_venv_python" -m proxy >/dev/null 2>&1 &
    local _wait=0
    while [[ \$_wait -lt 5 ]]; do
        sleep 1
        if curl -s --connect-timeout 1 http://127.0.0.1:8317/v1/models >/dev/null 2>&1; then
            return 0
        fi
        _wait=\$((\_wait + 1))
    done
    return 1
}

function ccd() {
    local MODEL=""
    local ARGS=()
    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --model|-m) [[ \$# -lt 2 ]] && echo "Error: --model requires a value" && return 1; MODEL="\$2"; shift 2 ;;
            --)
                ARGS+=("\$@")
                break
                ;;
            *) ARGS+=("\$1"); shift ;;
        esac
    done
    if [[ -n "\$MODEL" ]]; then
        _claude_load_model "\$MODEL" || return 1
        # Ensure proxy is running for proxy-dependent models
        if [[ "\$MODEL_BASE_URL" == *"8317"* ]]; then
            if ! _ccbridge_ensure_proxy; then
                echo "Warning: ccbridge-proxy not available. Start manually: ~/.ccbridge/venv/bin/python3 -m proxy"
            fi
        fi
    else
        _claude_unset_model_vars
    fi
    claude --dangerously-skip-permissions "\${ARGS[@]}"
}

# --- Aliases ---
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
echo "  ccd                          # Claude Code (Anthropic direct)"
echo "  ccd --model glm              # Claude Code with GLM"
echo "  ccd --model codex            # Claude Code with Codex"
echo "  ccd --model kimi             # Claude Code with Kimi"
echo "  ccd --model hybrid           # Claude Code with custom multi-model"
echo "  cdoctor                      # 진단 도구"
echo ""
echo -e "${BOLD}Configure your API keys:${RESET}"
echo "  vim ~/.claude-models/glm.env      # Set GLM API key"
echo "  vim ~/.claude-models/codex.env    # Set Codex"
echo ""
echo -e "${BOLD}Add a new model:${RESET}"
echo "  Create ~/.claude-models/<name>.env with:"
echo "    MODEL_AUTH_TOKEN, MODEL_BASE_URL, MODEL_HAIKU, MODEL_SONNET, MODEL_OPUS"
echo "  Then use: ccd --model <name>"
echo ""
