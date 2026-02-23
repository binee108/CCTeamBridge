#!/usr/bin/env bash
set -euo pipefail

# Ensure running with bash (not sh)
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: This script requires bash. Run with: bash $0" >&2
    exit 1
fi

# CCTeamBridge Installer
# Usage: curl -fsSLo ./install.sh https://raw.githubusercontent.com/binee108/CCTeamBridge/main/install.sh && chmod +x ./install.sh && bash ./install.sh

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
echo -e "${BOLD}CCTeamBridge v${VERSION}${RESET}"
echo -e "Session-isolated | Leader & Teammates: Any model"
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

# CLIProxyAPI detection function (reusable after install)
_detect_cliproxy() {
    for p in \
        "$(command -v cliproxyapi 2>/dev/null)" \
        "$(command -v cli-proxy-api 2>/dev/null)" \
        /usr/local/bin/cliproxyapi \
        /usr/local/bin/cli-proxy-api \
        /opt/homebrew/bin/cliproxyapi \
        /opt/homebrew/bin/cli-proxy-api \
        /usr/bin/cliproxyapi \
        /usr/bin/cli-proxy-api \
        /snap/bin/cliproxyapi \
        /snap/bin/cli-proxy-api \
        "$HOME/.local/bin/cliproxyapi" \
        "$HOME/.local/bin/cli-proxy-api" \
        "$HOME/bin/cliproxyapi" \
        "$HOME/bin/cli-proxy-api" \
        "$HOME/go/bin/cliproxyapi" \
        "$HOME/go/bin/cli-proxy-api"; do
        [[ -n "$p" && -x "$p" ]] && echo "$p" && return 0
    done
    return 1
}

CLIPROXY_BIN="$(_detect_cliproxy)" || CLIPROXY_BIN=""

if [[ -n "$CLIPROXY_BIN" ]]; then
    ok "CLIProxyAPI found ($CLIPROXY_BIN)"
else
    warn "CLIProxyAPI not found"
    echo ""
    case "$(uname -s)" in
        Darwin*)
            echo "  실행할 명령어: brew install cliproxyapi"
            ;;
        *)
            echo "  Linux/WSL에서는 외부 설치 스크립트를 자동 실행하지 않습니다."
            echo "  CLIProxyAPI 공식 저장소/공식 문서의 수동 설치 절차를 따라 설치하세요."
            ;;
    esac
    echo ""
    echo -ne "  ${BOLD}CLIProxyAPI를 지금 설치하시겠습니까? [Y/n]:${RESET} "
    _read_tty_prompt_default _confirm "Y" "CLIProxyAPI install prompt" "N" >/dev/null || true
    if [[ -z "$_confirm" || "$_confirm" =~ ^[Yy] ]]; then
        echo ""
        case "$(uname -s)" in
            Darwin*)
                info "CLIProxyAPI 설치 중 (brew)..."
                if command -v brew &>/dev/null && brew install cliproxyapi; then
                    ok "brew로 CLIProxyAPI 설치 완료"
                else
                    warn "brew 설치가 실패했습니다. GLM-only 설치를 계속 진행합니다."
                fi
                ;;
            *)
                info "Linux/WSL에서는 CLIProxyAPI 자동 설치를 실행하지 않습니다."
                info "CLIProxyAPI 공식 저장소/공식 문서의 수동 설치 절차를 완료한 뒤 다시 실행할 수 있습니다."
                info "지금은 GLM-only 설치를 계속 진행합니다."
                ;;
        esac
        echo ""
        # Re-detect after install
        CLIPROXY_BIN="$(_detect_cliproxy)" || CLIPROXY_BIN=""
        if [[ -n "$CLIPROXY_BIN" ]]; then
            ok "CLIProxyAPI 설치 완료 ($CLIPROXY_BIN)"
        else
            warn "CLIProxyAPI 설치에 실패했습니다. GLM-only 사용은 계속 가능합니다."
        fi
    else
        info "CLIProxyAPI 설치를 건너뜁니다. GLM-only 설치를 계속 진행합니다."
    fi
fi

# ─── Step 1: Model profiles directory ───
info "Creating model profiles directory..."
mkdir -p "$MODELS_DIR" && chmod 700 "$MODELS_DIR"

if [[ ! -f "$MODELS_DIR/glm.env" ]]; then
    cat > "$MODELS_DIR/glm.env" << 'EOF'
# GLM API Profile
# Get your API key at: https://z.ai/manage-apikey/apikey-list
MODEL_AUTH_TOKEN="YOUR_GLM_API_KEY_HERE"
MODEL_BASE_URL="https://open.bigmodel.cn/api/anthropic"
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
    echo "    Max 플랜:       5개 (동시 세션 15개로 팀 작업에 최적)"
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
            if [[ "$_key" == *'"'* ]] || [[ "$_key" == *$'\n'* ]] || [[ "$_key" == *'`'* ]]; then
                warn "키에 허용되지 않는 문자가 포함되어 있습니다. 다시 입력하세요."
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
                echo 'MODEL_BASE_URL="https://open.bigmodel.cn/api/anthropic"'
                echo 'MODEL_HAIKU="glm-4.7"'
                echo 'MODEL_SONNET="glm-5"'
                echo 'MODEL_OPUS="glm-5"'
            } > "$MODELS_DIR/glm.env"
            chmod 600 "$MODELS_DIR/glm.env"

            ok "GLM API 키 ${#_glm_keys[@]}개 등록 완료"
            if [[ ${#_glm_keys[@]} -gt 1 ]]; then
                info "멀티 키 round-robin: teammate pane마다 자동 순환 배정됩니다"
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

# ─── Step: Codex Account Registration ───
if [[ -n "$CLIPROXY_BIN" ]]; then
    _codex_cred_count=0
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
            for _f in "$HOME/.cli-proxy-api/codex-"*.json; do
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

# ─── Step: CLIProxyAPI Auto-Configuration ───
if [[ -n "$CLIPROXY_BIN" ]]; then
    info "Auto-configuring CLIProxyAPI..."

    # Detect config path
    CLIPROXY_CONF=""
    case "$(uname -s)" in
        Darwin*)
            for _p in /opt/homebrew/etc/cliproxyapi.conf /usr/local/etc/cliproxyapi.conf; do
                [[ -f "$_p" ]] && CLIPROXY_CONF="$_p" && break
            done
            [[ -z "$CLIPROXY_CONF" ]] && CLIPROXY_CONF="/opt/homebrew/etc/cliproxyapi.conf"
            ;;
        Linux*)
            for _p in /etc/cliproxyapi.conf /usr/local/etc/cliproxyapi.conf "$HOME/.config/cliproxyapi/cliproxyapi.conf"; do
                [[ -f "$_p" ]] && CLIPROXY_CONF="$_p" && break
            done
            [[ -z "$CLIPROXY_CONF" ]] && CLIPROXY_CONF="$HOME/.config/cliproxyapi/cliproxyapi.conf"
            ;;
        *)
            CLIPROXY_CONF="$HOME/.config/cliproxyapi/cliproxyapi.conf"
            ;;
    esac

    # Fallback to user config if no write permission
    if [[ -n "$CLIPROXY_CONF" ]]; then
        _conf_dir="$(dirname "$CLIPROXY_CONF")"
        if { [[ -f "$CLIPROXY_CONF" ]] && [[ ! -w "$CLIPROXY_CONF" ]]; } || \
           { [[ ! -f "$CLIPROXY_CONF" ]] && [[ ! -w "$_conf_dir" ]]; }; then
            CLIPROXY_CONF="$HOME/.config/cliproxyapi/cliproxyapi.conf"
        fi
    fi

    # Create or patch config
    if [[ ! -f "$CLIPROXY_CONF" ]]; then
        mkdir -p "$(dirname "$CLIPROXY_CONF")"
        cat > "$CLIPROXY_CONF" <<'CONFEOF'
# CLIProxyAPI Configuration (auto-generated by CCTeamBridge)
listen: "127.0.0.1:8317"
request-retry: 3
max-retry-interval: 30
routing:
  strategy: "fill-first"
quota-exceeded:
  switch-project: true
  switch-preview-model: true
CONFEOF
        ok "Created CLIProxyAPI config: $CLIPROXY_CONF"
    else
        _conf_content="$(cat "$CLIPROXY_CONF")"
        _changes=()
        _change_actions=()

        # Detect needed changes
        if echo "$_conf_content" | grep -q 'strategy:'; then
            if ! echo "$_conf_content" | grep -q 'strategy:.*"fill-first"'; then
                _old=$(echo "$_conf_content" | grep -m1 'strategy:' | sed 's/^[[:space:]]*//')
                _changes+=("  ${_old}  →  strategy: \"fill-first\"")
                _change_actions+=("strategy_patch")
            fi
        elif echo "$_conf_content" | grep -q 'routing:'; then
            _changes+=("  routing.strategy: (routing 섹션 내 키 없음)  →  \"fill-first\"")
            _change_actions+=("strategy_insert_in_routing")
        else
            _changes+=("  routing.strategy: (없음)  →  \"fill-first\"")
            _change_actions+=("strategy_add")
        fi

        if echo "$_conf_content" | grep -q 'switch-project:'; then
            if ! echo "$_conf_content" | grep -q 'switch-project:.*true'; then
                _old=$(echo "$_conf_content" | grep -m1 'switch-project:' | sed 's/^[[:space:]]*//')
                _changes+=("  ${_old}  →  switch-project: true")
                _change_actions+=("switch_patch")
            fi
        elif echo "$_conf_content" | grep -q 'quota-exceeded:'; then
            _changes+=("  quota-exceeded.switch-project: (quota-exceeded 섹션 내 키 없음)  →  true")
            _change_actions+=("switch_insert_in_quota")
        else
            _changes+=("  quota-exceeded.switch-project: (없음)  →  true")
            _change_actions+=("switch_add")
        fi

        if ! echo "$_conf_content" | grep -q 'request-retry:'; then
            _changes+=("  request-retry: (없음)  →  3")
            _change_actions+=("retry_add")
        fi

        if ! echo "$_conf_content" | grep -q 'max-retry-interval:'; then
            _changes+=("  max-retry-interval: (없음)  →  30")
            _change_actions+=("interval_add")
        fi

        if [[ ${#_changes[@]} -gt 0 ]]; then
            echo ""
            info "기존 CLIProxyAPI 설정을 감지했습니다: $CLIPROXY_CONF"
            echo "  다음 설정을 변경합니다:"
            for _c in "${_changes[@]}"; do
                echo -e "    $_c"
            done
            echo ""
            echo -ne "  ${BOLD}적용하시겠습니까? (기존 사용자가 아니면 Enter) [Y/n]:${RESET} "
            _read_tty_prompt_default _confirm "Y" "CLIProxyAPI config patch prompt" "N" >/dev/null || true
            if [[ -z "$_confirm" || "$_confirm" =~ ^[Yy] ]]; then
                _patched=0
                for _action in "${_change_actions[@]}"; do
                    case "$_action" in
                        strategy_patch)
                            sed -i.bak 's/strategy:.*$/strategy: "fill-first"/' "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        strategy_add)
                            printf '\nrouting:\n  strategy: "fill-first"\n' >> "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        strategy_insert_in_routing)
                            awk '
                                BEGIN { inserted=0 }
                                {
                                    print
                                    if (!inserted && $0 ~ /^[[:space:]]*routing:[[:space:]]*$/) {
                                        print "  strategy: \"fill-first\""
                                        inserted=1
                                    }
                                }
                            ' "$CLIPROXY_CONF" > "${CLIPROXY_CONF}.tmp" && mv "${CLIPROXY_CONF}.tmp" "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        switch_patch)
                            sed -i.bak 's/switch-project:.*$/switch-project: true/' "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        switch_add)
                            printf '\nquota-exceeded:\n  switch-project: true\n  switch-preview-model: true\n' >> "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        switch_insert_in_quota)
                            awk '
                                BEGIN { inserted=0 }
                                {
                                    print
                                    if (!inserted && $0 ~ /^[[:space:]]*quota-exceeded:[[:space:]]*$/) {
                                        print "  switch-project: true"
                                        inserted=1
                                    }
                                }
                            ' "$CLIPROXY_CONF" > "${CLIPROXY_CONF}.tmp" && mv "${CLIPROXY_CONF}.tmp" "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        retry_add)
                            printf 'request-retry: 3\n' >> "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                        interval_add)
                            printf 'max-retry-interval: 30\n' >> "$CLIPROXY_CONF"
                            _patched=$((_patched + 1)) ;;
                    esac
                done
                rm -f "${CLIPROXY_CONF}.bak"
                ok "CLIProxyAPI 설정 ${_patched}건 변경 완료: $CLIPROXY_CONF"
            else
                warn "CLIProxyAPI 설정 변경을 건너뛰었습니다"
            fi
        else
            ok "CLIProxyAPI config already correct: $CLIPROXY_CONF"
        fi
    fi

    # Set multi-account priority on codex credentials
    _priority_changes=()
    _priority_files=()
    _priority_values=()
    for _cred in "$HOME/.cli-proxy-api/codex-"*.json; do
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
        _priority_changes+=("$(basename "$_cred"): priority → ${_priority}")
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
import json, sys
p, pri = sys.argv[1], sys.argv[2]
d = json.loads(open(p).read())
d.setdefault('attributes', {})['priority'] = pri
open(p, 'w').write(json.dumps(d, separators=(',', ':')))
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

    # Start/restart CLIProxyAPI service
    case "$(uname -s)" in
        Darwin*)
            if command -v brew &>/dev/null; then
                if brew services list 2>/dev/null | grep -Eq '^cliproxyapi[[:space:]]+started'; then
                    brew services restart cliproxyapi >/dev/null 2>&1
                    ok "Restarted CLIProxyAPI service (brew)"
                else
                    brew services start cliproxyapi >/dev/null 2>&1
                    ok "Started CLIProxyAPI service (brew)"
                fi
            else
                warn "Homebrew not found — start CLIProxyAPI manually: $CLIPROXY_BIN"
            fi
            ;;
        Linux*)
            if command -v systemctl &>/dev/null && systemctl --user list-unit-files >/dev/null 2>&1; then
                # Create systemd service if missing
                if [[ ! -f "$HOME/.config/systemd/user/cliproxyapi.service" ]]; then
                    mkdir -p "$HOME/.config/systemd/user"
                    cat > "$HOME/.config/systemd/user/cliproxyapi.service" <<SVCEOF
[Unit]
Description=CLIProxyAPI Service
After=network.target

[Service]
Type=simple
ExecStart=${CLIPROXY_BIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF
                    systemctl --user daemon-reload
                    ok "Created systemd user service"
                fi
                systemctl --user enable cliproxyapi >/dev/null 2>&1
                if systemctl --user is-active cliproxyapi >/dev/null 2>&1; then
                    systemctl --user restart cliproxyapi >/dev/null 2>&1
                    ok "Restarted CLIProxyAPI service (systemd)"
                else
                    systemctl --user start cliproxyapi >/dev/null 2>&1
                    ok "Started CLIProxyAPI service (systemd)"
                fi
            else
                # WSL or no systemd
                if pgrep -f cliproxyapi >/dev/null 2>&1; then
                    pkill -f cliproxyapi 2>/dev/null || true
                    sleep 1
                fi
                if [[ -n "$TMUX_BIN" ]]; then
                    "$TMUX_BIN" kill-session -t cliproxyapi 2>/dev/null || true
                    "$TMUX_BIN" new-session -d -s cliproxyapi "$CLIPROXY_BIN"
                    if "$TMUX_BIN" has-session -t cliproxyapi 2>/dev/null; then
                        ok "Started CLIProxyAPI in tmux session"
                    else
                        warn "Failed to start CLIProxyAPI in tmux session"
                    fi
                else
                    mkdir -p "$HOME/.cache"
                    nohup "$CLIPROXY_BIN" > "$HOME/.cache/cliproxyapi.log" 2>&1 &
                    sleep 1
                    if pgrep -f cliproxyapi >/dev/null 2>&1; then
                        ok "Started CLIProxyAPI in background"
                    else
                        warn "CLIProxyAPI background start may have failed (check $HOME/.cache/cliproxyapi.log)"
                    fi
                fi
            fi
            ;;
    esac

    # Verify service health
    sleep 2
    if curl -s http://127.0.0.1:8317/v1/models -H "Authorization: Bearer sk-dummy" >/dev/null 2>&1; then
        ok "CLIProxyAPI responding on port 8317"
    else
        warn "CLIProxyAPI not responding on port 8317 (may need codex-login first)"
    fi
    echo ""
fi

# ─── Step 2: zshenv (non-interactive shell support) ───
if [[ "$SHELL_RC" == *".zshrc" ]]; then
    info "Installing teammate env override to ~/.zshenv..."
    ZSHENV="$HOME/.zshenv"
    touch "$ZSHENV" 2>/dev/null || { error "Cannot write to $ZSHENV (check permissions)"; exit 1; }

    # Remove existing block if present
    if grep -q "$MARKER_START" "$ZSHENV" 2>/dev/null; then
        sed -i.bak "/$MARKER_START/,/$MARKER_END/d" "$ZSHENV"
        rm -f "${ZSHENV}.bak"
    fi

    cat >> "$ZSHENV" << 'ZSHENVEOF'
# === CLAUDE HYBRID START ===
# Teammate panes: force-reload model profile (runs in non-interactive shells too)
if [[ -n "$HYBRID_ACTIVE" ]] && [[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$HOME/.claude-models/${HYBRID_ACTIVE}.env" ]]; then
    source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"
    # NOTE: RR token-selection logic is duplicated in zshenv/bashrc blocks; keep both blocks in sync when editing.
    if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
        _HYBRID_TOKEN_CANDIDATES="${MODEL_AUTH_TOKENS:-${MODEL_AUTH_TOKEN:-}}"
        _HYBRID_RR_COUNT=0

        if [[ -n "$_HYBRID_TOKEN_CANDIDATES" ]]; then
            while IFS= read -r _HYBRID_TOKEN_ITEM; do
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM#"${_HYBRID_TOKEN_ITEM%%[![:space:]]*}"}"
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM%"${_HYBRID_TOKEN_ITEM##*[![:space:]]}"}"
                if [[ -n "$_HYBRID_TOKEN_ITEM" ]]; then
                    _HYBRID_RR_COUNT=$((_HYBRID_RR_COUNT + 1))
                fi
            done < <(printf '%s\n' "$_HYBRID_TOKEN_CANDIDATES" | tr ',' '\n')
        fi

        if ((_HYBRID_RR_COUNT > 0)); then
            _HYBRID_RR_DIR="$HOME/.claude-models/.hybrid-rr"
            _HYBRID_RR_IDX_FILE="${_HYBRID_RR_DIR}/${HYBRID_ACTIVE}.idx"
            _HYBRID_RR_INDEX=0

            if [[ -f "$_HYBRID_RR_IDX_FILE" ]]; then
                read -r _HYBRID_RR_INDEX < "$_HYBRID_RR_IDX_FILE" || _HYBRID_RR_INDEX=0
            fi
            if [[ ! "$_HYBRID_RR_INDEX" =~ ^[0-9]+$ ]]; then
                _HYBRID_RR_INDEX=0
            fi

            _HYBRID_RR_INDEX=$((_HYBRID_RR_INDEX % _HYBRID_RR_COUNT))
            _HYBRID_RR_POS=0
            _HYBRID_RR_SELECTED=""

            while IFS= read -r _HYBRID_TOKEN_ITEM; do
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM#"${_HYBRID_TOKEN_ITEM%%[![:space:]]*}"}"
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM%"${_HYBRID_TOKEN_ITEM##*[![:space:]]}"}"
                if [[ -n "$_HYBRID_TOKEN_ITEM" ]]; then
                    if ((_HYBRID_RR_POS == _HYBRID_RR_INDEX)); then
                        _HYBRID_RR_SELECTED="$_HYBRID_TOKEN_ITEM"
                        break
                    fi
                    _HYBRID_RR_POS=$((_HYBRID_RR_POS + 1))
                fi
            done < <(printf '%s\n' "$_HYBRID_TOKEN_CANDIDATES" | tr ',' '\n')

            if [[ -n "$_HYBRID_RR_SELECTED" ]]; then
                export ANTHROPIC_AUTH_TOKEN="$_HYBRID_RR_SELECTED"
            fi

            _HYBRID_RR_NEXT=$(((_HYBRID_RR_INDEX + 1) % _HYBRID_RR_COUNT))
            mkdir -p "$_HYBRID_RR_DIR"
            printf '%s\n' "$_HYBRID_RR_NEXT" > "$_HYBRID_RR_IDX_FILE" 2>/dev/null || true
        fi

        unset _HYBRID_TOKEN_CANDIDATES _HYBRID_TOKEN_ITEM _HYBRID_RR_COUNT _HYBRID_RR_DIR _HYBRID_RR_IDX_FILE _HYBRID_RR_INDEX _HYBRID_RR_POS _HYBRID_RR_SELECTED _HYBRID_RR_NEXT
    fi
    export ANTHROPIC_BASE_URL="$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL_OPUS"
    # Fix: Claude Code CLI forwards leader's ANTHROPIC_BASE_URL to teammate
    # via inline "env" prefix. This wrapper intercepts and replaces with
    # the correct teammate values from the session profile.
    env() {
        local _args
        _args=()
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

# Part 2: Env propagation block (bash only — zsh uses .zshenv)
if [[ "$SHELL_RC" == *".bashrc" ]]; then
    cat >> "$SHELL_RC" << 'BASHEOF'

# --- LLM Provider Switcher ---
# Teammate panes: reload model profile to override any leaked leader env vars
if [[ -n "$HYBRID_ACTIVE" ]] && [[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ -f "$HOME/.claude-models/${HYBRID_ACTIVE}.env" ]]; then
    source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"
    # NOTE: RR token-selection logic is duplicated in zshenv/bashrc blocks; keep both blocks in sync when editing.
    if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
        _HYBRID_TOKEN_CANDIDATES="${MODEL_AUTH_TOKENS:-${MODEL_AUTH_TOKEN:-}}"
        _HYBRID_RR_COUNT=0

        if [[ -n "$_HYBRID_TOKEN_CANDIDATES" ]]; then
            while IFS= read -r _HYBRID_TOKEN_ITEM; do
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM#"${_HYBRID_TOKEN_ITEM%%[![:space:]]*}"}"
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM%"${_HYBRID_TOKEN_ITEM##*[![:space:]]}"}"
                if [[ -n "$_HYBRID_TOKEN_ITEM" ]]; then
                    _HYBRID_RR_COUNT=$((_HYBRID_RR_COUNT + 1))
                fi
            done < <(printf '%s\n' "$_HYBRID_TOKEN_CANDIDATES" | tr ',' '\n')
        fi

        if ((_HYBRID_RR_COUNT > 0)); then
            _HYBRID_RR_DIR="$HOME/.claude-models/.hybrid-rr"
            _HYBRID_RR_IDX_FILE="${_HYBRID_RR_DIR}/${HYBRID_ACTIVE}.idx"
            _HYBRID_RR_INDEX=0

            if [[ -f "$_HYBRID_RR_IDX_FILE" ]]; then
                read -r _HYBRID_RR_INDEX < "$_HYBRID_RR_IDX_FILE" || _HYBRID_RR_INDEX=0
            fi
            if [[ ! "$_HYBRID_RR_INDEX" =~ ^[0-9]+$ ]]; then
                _HYBRID_RR_INDEX=0
            fi

            _HYBRID_RR_INDEX=$((_HYBRID_RR_INDEX % _HYBRID_RR_COUNT))
            _HYBRID_RR_POS=0
            _HYBRID_RR_SELECTED=""

            while IFS= read -r _HYBRID_TOKEN_ITEM; do
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM#"${_HYBRID_TOKEN_ITEM%%[![:space:]]*}"}"
                _HYBRID_TOKEN_ITEM="${_HYBRID_TOKEN_ITEM%"${_HYBRID_TOKEN_ITEM##*[![:space:]]}"}"
                if [[ -n "$_HYBRID_TOKEN_ITEM" ]]; then
                    if ((_HYBRID_RR_POS == _HYBRID_RR_INDEX)); then
                        _HYBRID_RR_SELECTED="$_HYBRID_TOKEN_ITEM"
                        break
                    fi
                    _HYBRID_RR_POS=$((_HYBRID_RR_POS + 1))
                fi
            done < <(printf '%s\n' "$_HYBRID_TOKEN_CANDIDATES" | tr ',' '\n')

            if [[ -n "$_HYBRID_RR_SELECTED" ]]; then
                export ANTHROPIC_AUTH_TOKEN="$_HYBRID_RR_SELECTED"
            fi

            _HYBRID_RR_NEXT=$(((_HYBRID_RR_INDEX + 1) % _HYBRID_RR_COUNT))
            mkdir -p "$_HYBRID_RR_DIR"
            printf '%s\n' "$_HYBRID_RR_NEXT" > "$_HYBRID_RR_IDX_FILE" 2>/dev/null || true
        fi

        unset _HYBRID_TOKEN_CANDIDATES _HYBRID_TOKEN_ITEM _HYBRID_RR_COUNT _HYBRID_RR_DIR _HYBRID_RR_IDX_FILE _HYBRID_RR_INDEX _HYBRID_RR_POS _HYBRID_RR_SELECTED _HYBRID_RR_NEXT
    fi
    export ANTHROPIC_BASE_URL="$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL_OPUS"
    # Fix: Claude Code CLI forwards leader's ANTHROPIC_BASE_URL to teammate
    env() {
        local _args
        _args=()
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

_claude_select_rr_token_for_model() {
    local model="\$1"
    local profile="\$HOME/.claude-models/\${model}.env"
    local rr_dir="\$HOME/.claude-models/.hybrid-rr"
    local idx_file="\${rr_dir}/\${model}.idx"
    local tokens=()
    local count=0
    local idx=0
    local token=""
    local next_idx=0

    if [[ -z "\$model" ]] || [[ ! "\$model" =~ ^[a-zA-Z0-9_-]+\$ ]] || [[ ! -f "\$profile" ]]; then
        return 1
    fi

    source "\$profile"
    while IFS= read -r token; do
        tokens+=("\$token")
    done < <(_claude_collect_model_tokens_from_loaded_env)

    count=\${#tokens[@]}
    if ((count == 0)); then
        return 1
    fi

    mkdir -p "\$rr_dir"

    if [[ -f "\$idx_file" ]]; then
        read -r idx < "\$idx_file" || idx=0
    else
        idx=0
    fi

    if [[ ! "\$idx" =~ ^[0-9]+\$ ]]; then
        idx=0
    fi

    idx=\$((idx % count))
    token="\${tokens[idx]}"
    next_idx=\$(((idx + 1) % count))

    printf '%s\n' "\$next_idx" > "\$idx_file" 2>/dev/null || true
    printf '%s' "\$token"
    return 0
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

# --- cdoctor: Validate current hybrid setup ---
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
    echo "Claude Hybrid Doctor"
    echo "===================="

    if command -v claude >/dev/null 2>&1; then
        _doctor_ok "Claude Code CLI found: \$(claude --version 2>/dev/null || echo installed)"
    else
        _doctor_err "Claude Code CLI not found in PATH"
    fi

    if command -v tmux >/dev/null 2>&1; then
        _doctor_ok "tmux found: \$(tmux -V 2>/dev/null || echo installed)"
    else
        _doctor_err "tmux not found in PATH"
    fi

    if [[ -d "\$HOME/.claude-models" ]]; then
        _doctor_ok "Model profile directory exists: \$HOME/.claude-models"
    else
        _doctor_err "Model profile directory missing: \$HOME/.claude-models"
    fi

    for profile in glm codex kimi; do
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
            _doctor_ok "Hybrid shell block found in \${rc}"
            shell_blocks=\$((shell_blocks + 1))
        fi
    done
    if ((shell_blocks == 0)); then
        _doctor_err "Hybrid shell block not found in ~/.zshrc or ~/.bashrc"
    fi

    if [[ -n "\${ZSH_VERSION:-}" ]] || [[ "\${SHELL:-}" == *zsh* ]]; then
        if [[ -f "\$HOME/.zshenv" ]] && grep -q "# === CLAUDE HYBRID START ===" "\$HOME/.zshenv" 2>/dev/null; then
            _doctor_ok "zsh teammate env block found in ~/.zshenv"
        else
            _doctor_warn "zsh detected but ~/.zshenv hybrid block is missing"
        fi
    fi

    local cliproxy_bin=""
    for p in \
        "\$(command -v cliproxyapi 2>/dev/null)" \
        "\$(command -v cli-proxy-api 2>/dev/null)" \
        /usr/local/bin/cliproxyapi \
        /usr/local/bin/cli-proxy-api \
        /opt/homebrew/bin/cliproxyapi \
        /opt/homebrew/bin/cli-proxy-api \
        /usr/bin/cliproxyapi \
        /usr/bin/cli-proxy-api \
        /snap/bin/cliproxyapi \
        /snap/bin/cli-proxy-api \
        "\$HOME/.local/bin/cliproxyapi" \
        "\$HOME/.local/bin/cli-proxy-api" \
        "\$HOME/bin/cliproxyapi" \
        "\$HOME/bin/cli-proxy-api" \
        "\$HOME/go/bin/cliproxyapi" \
        "\$HOME/go/bin/cli-proxy-api"; do
        if [[ -n "\$p" && -x "\$p" ]]; then
            cliproxy_bin="\$p"
            break
        fi
    done

    if [[ -n "\$cliproxy_bin" ]]; then
        _doctor_ok "CLIProxyAPI binary found: \${cliproxy_bin}"

        if [[ "\$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
            if brew services list 2>/dev/null | grep -Eq '^cliproxyapi[[:space:]]+started'; then
                _doctor_ok "CLIProxyAPI service started (brew services)"
            else
                _doctor_warn "brew services reports cliproxyapi not started"
            fi
        elif command -v systemctl >/dev/null 2>&1; then
            if systemctl --user is-active cliproxyapi >/dev/null 2>&1; then
                _doctor_ok "CLIProxyAPI service active (systemctl --user)"
            else
                if [[ -r /proc/version ]] && grep -qiE '(microsoft|wsl)' /proc/version; then
                    _doctor_warn "WSL detected and cliproxyapi service is not active. systemd may be disabled; run manually."
                else
                    _doctor_warn "cliproxyapi service is not active (systemctl --user)"
                fi
            fi
        else
            _doctor_warn "No service manager detected. Start CLIProxyAPI manually."
        fi
    else
        _doctor_warn "CLIProxyAPI binary not found (required for Codex/Kimi profiles)"
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

# --- cc: Claude Code solo ---
function cc() {
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
    else
        _claude_unset_model_vars
    fi
    claude --dangerously-skip-permissions "\${ARGS[@]}"
}

# --- ct: Claude Code Teams (hybrid) ---
ct() {
    local LEADER=""
    local TEAMMATE=""
    local CLAUDE_ARGS=()

    while [[ \$# -gt 0 ]]; do
        case "\$1" in
            --leader|-l) [[ \$# -lt 2 ]] && echo "Error: --leader requires a value" && return 1; LEADER="\$2"; shift 2 ;;
            --teammate|-t) [[ \$# -lt 2 ]] && echo "Error: --teammate requires a value" && return 1; TEAMMATE="\$2"; shift 2 ;;
            --)
                CLAUDE_ARGS+=("\$@")
                break
                ;;
            *)
                CLAUDE_ARGS+=("\$1")
                shift
                ;;
        esac
    done

    # Validate model profile names early (allowlist)
    if [[ -n "\$LEADER" && ! "\$LEADER" =~ ^[a-zA-Z0-9_-]+\$ ]]; then
        echo "Error: Invalid leader model name '\$LEADER' (alphanumeric, dash, underscore only)"
        return 1
    fi
    if [[ -n "\$TEAMMATE" && ! "\$TEAMMATE" =~ ^[a-zA-Z0-9_-]+\$ ]]; then
        echo "Error: Invalid teammate model name '\$TEAMMATE' (alphanumeric, dash, underscore only)"
        return 1
    fi

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
    tmux new-session -d -s "\$SESSION" -n "\$PROJECT_NAME" -c "\$PROJECT_DIR" || {
        echo "Error: Failed to create tmux session '\$SESSION'"
        return 1
    }
    if ! tmux has-session -t "\$SESSION" 2>/dev/null; then
        echo "Error: tmux session '\$SESSION' was not created"
        return 1
    fi

    # Also set session-specific env (overrides global for this session)
    if [[ -n "\$TEAMMATE" ]]; then
        (
            source "\$HOME/.claude-models/\${TEAMMATE}.env"
            tmux set-environment -t "\$SESSION" HYBRID_ACTIVE "\$TEAMMATE"
            tmux set-environment -t "\$SESSION" -u ANTHROPIC_AUTH_TOKEN 2>/dev/null
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

    local CLAUDE_CMD="claude --dangerously-skip-permissions --teammate-mode tmux"
    local _claude_arg
    for _claude_arg in "\${CLAUDE_ARGS[@]}"; do
        CLAUDE_CMD+=" \$(printf '%q' "\$_claude_arg")"
    done

    # Launch leader pane
    if [[ -n "\$LEADER" ]]; then
        local _leader_quoted
        _leader_quoted="\$(printf '%q' "\$LEADER")"
        tmux send-keys -t "\$SESSION" \\
            "_claude_load_model \${_leader_quoted} && \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 && \\
            \$CLAUDE_CMD" Enter
    else
        tmux send-keys -t "\$SESSION" \\
            "unset HYBRID_ACTIVE ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; \\
            export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; \\
            \$CLAUDE_CMD" Enter
    fi

    tmux attach -t "\$SESSION"
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
echo "  cc                          # Claude Code (Anthropic direct)"
echo "  cc --model glm              # Claude Code with GLM"
echo "  ct                          # Teams (all Anthropic)"
echo "  ct --teammate glm           # Teams (leader: Anthropic, teammates: GLM)"
echo "  ct -l codex -t glm          # Teams (leader: Codex, teammates: GLM)"
echo "  ct --leader kimi            # Teams (leader: Kimi, teammates: Anthropic)"
echo "  cdoctor                     # Diagnose hybrid setup health"
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
