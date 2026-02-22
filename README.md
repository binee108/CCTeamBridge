# CCTeamBridge

Leader uses Anthropic directly. Teammates use the model profile you choose (GLM, Codex via CLIProxyAPI, Kimi, etc.).

This README supports **macOS, Linux, and WSL** with platform-specific instructions where needed.

---

## 1) Goal (Definition of Done)

Setup is complete only when all checks pass:

1. `~/.claude-models/codex.env` exists and contains:
   - `MODEL_BASE_URL="http://127.0.0.1:8317"`
   - `MODEL_HAIKU="gpt-5.3-codex"`
   - `MODEL_SONNET="gpt-5.3-codex"`
   - `MODEL_OPUS="gpt-5.3-codex"`
2. CLIProxyAPI service is running.
3. Config file has correct settings:
   - `routing.strategy: "fill-first"`
   - `quota-exceeded.switch-project: true`
4. Multi-account priority is set:
   - plus accounts: `"priority":"100"`
   - pro accounts: `"priority":"0"`
5. API tests succeed:
   - `GET /v1/models`
   - `POST /v1/chat/completions`
6. `ct --teammate codex` launches successfully.

---

## 2) Prerequisites

| Platform | Requirements |
|----------|--------------|
| **macOS** | Claude Code CLI, tmux, Homebrew |
| **Linux** | Claude Code CLI, tmux, systemd (user sessions) |
| **WSL** | Claude Code CLI, tmux, manual service management |

Verify prerequisites:

```bash
# Check Claude Code
claude --version

# Check tmux
tmux -V

# Check shell
echo "Shell: $SHELL"
```

> **Note:** If you only need GLM/direct providers (no Codex via CLIProxyAPI), skip Steps B-F and go directly to Step G2.

---

## 3) Platform Detection

Run this to detect your platform and config paths:

```bash
# Detect platform
detect_platform() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *) echo "unknown" ;;
  esac
}

PLATFORM=$(detect_platform)
echo "Detected platform: $PLATFORM"

# Detect CLIProxyAPI config path
detect_config_path() {
  local platform="$1"
  case "$platform" in
    macos)
      # Homebrew on Apple Silicon
      if [[ -f "/opt/homebrew/etc/cliproxyapi.conf" ]]; then
        echo "/opt/homebrew/etc/cliproxyapi.conf"
      # Homebrew on Intel Mac
      elif [[ -f "/usr/local/etc/cliproxyapi.conf" ]]; then
        echo "/usr/local/etc/cliproxyapi.conf"
      else
        echo "/opt/homebrew/etc/cliproxyapi.conf"  # default
      fi
      ;;
    linux|wsl)
      # Linux standard paths
      if [[ -f "/etc/cliproxyapi.conf" ]]; then
        echo "/etc/cliproxyapi.conf"
      elif [[ -f "/usr/local/etc/cliproxyapi.conf" ]]; then
        echo "/usr/local/etc/cliproxyapi.conf"
      elif [[ -f "$HOME/.config/cliproxyapi/cliproxyapi.conf" ]]; then
        echo "$HOME/.config/cliproxyapi/cliproxyapi.conf"
      else
        echo "/etc/cliproxyapi.conf"  # default
      fi
      ;;
    *)
      echo "/etc/cliproxyapi.conf"
      ;;
  esac
}

CONFIG_PATH=$(detect_config_path "$PLATFORM")
echo "Config path: $CONFIG_PATH"

# Export for later use
export CLIPROXY_CONFIG_PATH="$CONFIG_PATH"
export DETECTED_PLATFORM="$PLATFORM"
```

---

## 4) Deterministic Setup (Agent Procedure)

Execute steps in order.

### Step A — Install this project

All platforms:

```bash
curl -fsSL https://raw.githubusercontent.com/binee108/CCTeamBridge/main/install.sh | bash
```

Reload shell:

```bash
if [ -n "${ZSH_VERSION:-}" ] || [[ "$SHELL" == *"zsh"* ]]; then
  source ~/.zshrc
else
  source ~/.bashrc
fi
```

---

### Step B — Install CLIProxyAPI

#### macOS (Homebrew)

```bash
brew install cliproxyapi
```

#### Linux

```bash
# Option 1: Installer script
curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash

# Option 2: Build from source (requires Go)
go install github.com/router-for-me/CLIProxyAPI/cmd/server@latest
```

#### WSL

Use the same installation methods as Linux.

For WSL environments where `systemd` is not enabled, use the manual/tmux run mode in Step C instead of `systemctl --user`.

---

### Step C — Start CLIProxyAPI Service

#### macOS (Homebrew services)

```bash
brew services start cliproxyapi
```

#### Linux (systemd user service)

Create systemd user service:

```bash
mkdir -p ~/.config/systemd/user

if command -v cliproxyapi >/dev/null 2>&1; then
  CLIPROXY_BIN="$(command -v cliproxyapi)"
elif command -v cli-proxy-api >/dev/null 2>&1; then
  CLIPROXY_BIN="$(command -v cli-proxy-api)"
else
  echo "ERROR: CLIProxyAPI command not found in PATH" >&2
  exit 1
fi

cat > ~/.config/systemd/user/cliproxyapi.service <<EOF
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
EOF

# Enable and start
systemctl --user daemon-reload
systemctl --user enable cliproxyapi
systemctl --user start cliproxyapi
```

#### WSL (manual execution)

WSL does not support systemd by default. Run manually or use tmux:

```bash
# Option 1: Run in foreground (for testing)
cliproxyapi

# Option 2: Run in background
nohup cliproxyapi > ~/.cache/cliproxyapi.log 2>&1 &

# Option 3: Run in tmux (recommended for persistence)
tmux new-session -d -s cliproxyapi cliproxyapi
```

To check if running:

```bash
# Check process
pgrep -f cliproxyapi && echo "CLIProxyAPI is running" || echo "CLIProxyAPI is NOT running"

# For tmux session
tmux list-sessions 2>/dev/null | grep cliproxyapi && echo "Found in tmux"
```

---

### Step D — Verify Service Status

```bash
# Check if service is listening on port 8317
curl -s http://127.0.0.1:8317/health 2>/dev/null && echo "Service OK" || echo "Service NOT responding"

# Alternative: check port
if command -v lsof >/dev/null 2>&1; then
  lsof -i :8317
elif command -v ss >/dev/null 2>&1; then
  ss -tlnp | grep 8317
elif command -v netstat >/dev/null 2>&1; then
  netstat -tlnp 2>/dev/null | grep 8317
fi
```

---

### Step E — Resolve Executable Name

```bash
if command -v cliproxyapi >/dev/null 2>&1; then
  CLIPROXY_CMD="cliproxyapi"
elif command -v cli-proxy-api >/dev/null 2>&1; then
  CLIPROXY_CMD="cli-proxy-api"
else
  echo "ERROR: CLIProxyAPI command not found" >&2
  echo "Please ensure CLIProxyAPI is installed and in PATH" >&2
  exit 1
fi

echo "CLIProxyAPI command: $CLIPROXY_CMD"
```

---

### Step F — Register Codex OAuth Accounts

Run once per account (repeat for each account):

```bash
"$CLIPROXY_CMD" -codex-login
```

Verify files were created:

```bash
ls -1 ~/.cli-proxy-api/codex-*.json 2>/dev/null || echo "No codex credential files found"
```

> **Tip:** Name your files with `-plus` or `-pro` suffix for priority routing (e.g., `codex-work-plus.json`, `codex-personal-pro.json`).

---

### Step G — Force Codex Hybrid Profile

```bash
mkdir -p ~/.claude-models

cat > ~/.claude-models/codex.env <<'EOF'
# Codex API Profile (CLIProxyAPI required)
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="gpt-5.3-codex"
MODEL_SONNET="gpt-5.3-codex"
MODEL_OPUS="gpt-5.3-codex"
EOF
chmod 600 ~/.claude-models/codex.env

echo "Created: ~/.claude-models/codex.env"
```

---

### Step G2 — Configure GLM API Key (Optional)

If you want to use GLM without CLIProxyAPI, create `~/.claude-models/glm.env`:

```bash
mkdir -p ~/.claude-models

cat > ~/.claude-models/glm.env <<'EOF'
# GLM API Profile
# Optional multi-key for teammate round-robin (comma-separated)
MODEL_AUTH_TOKENS="YOUR_GLM_API_KEY_1,YOUR_GLM_API_KEY_2,YOUR_GLM_API_KEY_3"
# Backward-compatible fallback (used if MODEL_AUTH_TOKENS is unset/empty)
MODEL_AUTH_TOKEN="YOUR_GLM_API_KEY_HERE"
MODEL_BASE_URL="https://open.bigmodel.cn/api/anthropic"
MODEL_HAIKU="glm-4.7-flashx"
MODEL_SONNET="glm-5"
MODEL_OPUS="glm-5"
EOF
chmod 600 ~/.claude-models/glm.env

echo "Created: ~/.claude-models/glm.env"
echo "Edit the file and add your GLM API key"
```

Use GLM profile:

```bash
cc --model glm
ct --teammate glm
```

`ct --teammate glm`은 teammate pane(shell) 시작 시 `MODEL_AUTH_TOKENS`를 우선 사용해 key를 round-robin으로 1개 선택해 pane의 `ANTHROPIC_AUTH_TOKEN`에 설정합니다.

- 상태 파일: `~/.claude-models/.hybrid-rr/<model>.idx`
- `MODEL_AUTH_TOKENS`가 없거나 비어 있으면 `MODEL_AUTH_TOKEN`으로 fallback합니다.
- 토큰 원문은 로그/출력에 노출하지 마세요.
- 동시 pane/session 생성 수가 key 수보다 많아도 생성 시점마다 round-robin으로 계속 순환 배정됩니다(키 공유 가능).

---

### Step H — Configure Routing and Rate-Limit Behavior

First, detect the config path (from Section 3):

```bash
# If not already set, detect config path
if [[ -z "$CLIPROXY_CONFIG_PATH" ]]; then
  echo "ERROR: CLIPROXY_CONFIG_PATH not set. Run platform detection first." >&2
  exit 1
fi

if [[ "$CLIPROXY_CONFIG_PATH" == /etc/* ]]; then
  if [[ -f "$CLIPROXY_CONFIG_PATH" ]] && [[ ! -w "$CLIPROXY_CONFIG_PATH" ]]; then
    echo "No write permission for existing $CLIPROXY_CONFIG_PATH, falling back to user config path..."
    CLIPROXY_CONFIG_PATH="$HOME/.config/cliproxyapi/cliproxyapi.conf"
    export CLIPROXY_CONFIG_PATH
  elif [[ ! -f "$CLIPROXY_CONFIG_PATH" ]] && [[ ! -w "$(dirname "$CLIPROXY_CONFIG_PATH")" ]]; then
    echo "No write permission for $CLIPROXY_CONFIG_PATH, falling back to user config path..."
    CLIPROXY_CONFIG_PATH="$HOME/.config/cliproxyapi/cliproxyapi.conf"
    export CLIPROXY_CONFIG_PATH
  fi
fi

if [[ ! -f "$CLIPROXY_CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: $CLIPROXY_CONFIG_PATH" >&2
  echo "Creating default config..."
  mkdir -p "$(dirname "$CLIPROXY_CONFIG_PATH")"
  cat > "$CLIPROXY_CONFIG_PATH" <<'EOF'
# CLIProxyAPI Configuration
listen: "127.0.0.1:8317"
request-retry: 3
max-retry-interval: 30
routing:
  strategy: "fill-first"
quota-exceeded:
  switch-project: true
  switch-preview-model: true
EOF
fi
```

Patch required values:

```bash
python3 - <<'PY'
import os
import re
from pathlib import Path

config_path = os.environ.get('CLIPROXY_CONFIG_PATH', '/etc/cliproxyapi.conf')
p = Path(config_path)

if not p.exists():
    print(f"ERROR: Config file not found: {p}")
    exit(1)

s = p.read_text()

# Ensure request-retry and max-retry-interval
if re.search(r'(?m)^\s*request-retry\s*:', s):
    s = re.sub(r'(?m)^\s*request-retry\s*:\s*.*$', 'request-retry: 3', s)
else:
    s += '\nrequest-retry: 3\n'

if re.search(r'(?m)^\s*max-retry-interval\s*:', s):
    s = re.sub(r'(?m)^\s*max-retry-interval\s*:\s*.*$', 'max-retry-interval: 30', s)
else:
    s += 'max-retry-interval: 30\n'

# Ensure quota-exceeded block exists and switch-project is true
if not re.search(r'(?m)^quota-exceeded\s*:\s*$', s):
    s += '\nquota-exceeded:\n  switch-project: true\n  switch-preview-model: true\n'
else:
    if re.search(r'(?m)^\s*switch-project\s*:', s):
        s = re.sub(r'(?m)^\s*switch-project\s*:\s*(true|false).*$','  switch-project: true', s)
    else:
        s = re.sub(r'(?m)^quota-exceeded\s*:\s*$','quota-exceeded:\n  switch-project: true', s)

# Ensure routing strategy is fill-first
if not re.search(r'(?m)^routing\s*:\s*$', s):
    s += '\nrouting:\n  strategy: "fill-first"\n'
else:
    if re.search(r'(?m)^\s*strategy\s*:', s):
        s = re.sub(r'(?m)^\s*strategy\s*:\s*"[^"]*".*$','  strategy: "fill-first"', s)
    else:
        s = re.sub(r'(?m)^routing\s*:\s*$','routing:\n  strategy: "fill-first"', s)

p.write_text(s)
print(f'Patched: {p}')
PY
```

---

### Step I — Set Multi-Account Priority

Rules:
- filename contains `-plus` → `priority=100` (used first)
- filename contains `-pro` → `priority=0` (fallback)

```bash
python3 - <<'PY'
import glob
import json
import os
from pathlib import Path

for f in glob.glob(os.path.expanduser('~/.cli-proxy-api/codex-*.json')):
    p = Path(f)
    name = p.name.lower()
    data = json.loads(p.read_text())
    attrs = data.get('attributes', {})

    if '-plus' in name:
        attrs['priority'] = '100'
    elif '-pro' in name:
        attrs['priority'] = '0'
    else:
        continue

    data['attributes'] = attrs
    p.write_text(json.dumps(data, separators=(',', ':')))
    print(f'Updated: {p.name}')
PY
```

---

### Step J — Restart Service

#### macOS

```bash
brew services restart cliproxyapi
sleep 2
brew services list | grep cliproxyapi
```

#### Linux (systemd)

```bash
systemctl --user restart cliproxyapi
sleep 2
systemctl --user status cliproxyapi --no-pager
```

#### WSL

```bash
# Kill existing process
pkill -f cliproxyapi 2>/dev/null || true

# Restart in tmux
tmux kill-session -t cliproxyapi 2>/dev/null || true
tmux new-session -d -s cliproxyapi cliproxyapi

sleep 2
tmux list-sessions | grep cliproxyapi
```

---

### Step K — Verification

#### K0 — Hybrid Installer/Uninstaller Static Checks

```bash
bash -n install.sh
bash -n uninstall.sh
```

#### K0.1 — Single-key Backward Compatibility

- Configure only `MODEL_AUTH_TOKEN` in `~/.claude-models/glm.env`.
- Run `ct --teammate glm` and confirm teammate sessions work exactly as before.

#### K0.2 — Multi-key Round-robin Assignment (Pane-level)

- Configure `MODEL_AUTH_TOKENS` with 3 keys in `~/.claude-models/glm.env`.
- Start one session (`ct --teammate glm`) and create multiple panes.
- In each pane, run `echo "$ANTHROPIC_AUTH_TOKEN"` and verify token assignment rotates per pane creation.

#### K0.3 — Pane Token Pinning

- In one running `ct --teammate glm` session, pick a pane and run `echo "$ANTHROPIC_AUTH_TOKEN"`.
- Execute additional commands in the same pane and confirm the token value remains unchanged for that pane.

#### K0.4 — Concurrency Check

- Launch multiple `ct --teammate glm` commands and/or create panes in short intervals.
- Verify key selection rotates per pane/shell creation in short-interval concurrent launches (best-effort file updates).

#### K1 — Verify Config Values

```bash
echo "=== Checking config file: $CLIPROXY_CONFIG_PATH ==="

if [[ -f "$CLIPROXY_CONFIG_PATH" ]]; then
  echo "--- request-retry ---"
  grep -n "request-retry" "$CLIPROXY_CONFIG_PATH" || echo "NOT FOUND"

  echo "--- max-retry-interval ---"
  grep -n "max-retry-interval" "$CLIPROXY_CONFIG_PATH" || echo "NOT FOUND"

  echo "--- quota-exceeded / switch-project ---"
  grep -n "quota-exceeded\|switch-project" "$CLIPROXY_CONFIG_PATH" || echo "NOT FOUND"

  echo "--- routing / strategy ---"
  grep -n "routing\|strategy" "$CLIPROXY_CONFIG_PATH" || echo "NOT FOUND"
else
  echo "ERROR: Config file not found"
fi
```

#### K2 — Verify Priority Assignment

```bash
echo "=== Priority counts ==="

PLUS_COUNT=$(grep -l '"priority":"100"' ~/.cli-proxy-api/codex-*.json 2>/dev/null | wc -l | tr -d ' ')
PRO_COUNT=$(grep -l '"priority":"0"' ~/.cli-proxy-api/codex-*.json 2>/dev/null | wc -l | tr -d ' ')

echo "Plus accounts (priority=100): $PLUS_COUNT"
echo "Pro accounts (priority=0): $PRO_COUNT"

# Show details
echo ""
echo "=== Priority assignments ==="
grep -R --line-number '"priority"' ~/.cli-proxy-api/codex-*.json 2>/dev/null || echo "No priority assignments found"
```

#### K3 — Verify Codex Env File

```bash
echo "=== Checking ~/.claude-models/codex.env ==="

if [[ -f ~/.claude-models/codex.env ]]; then
  cat ~/.claude-models/codex.env
  echo ""
  echo "File permissions:"
  ls -la ~/.claude-models/codex.env
else
  echo "ERROR: codex.env not found"
fi
```

---

### Step L — API Health Tests

#### L1 — Model List Test

```bash
echo "=== GET /v1/models ==="

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-dummy" 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "SUCCESS (HTTP 200)"
  echo "$BODY" | head -c 500
else
  echo "FAILED (HTTP $HTTP_CODE)"
  echo "$BODY"
fi
```

#### L2 — Completion Test

```bash
echo "=== POST /v1/chat/completions ==="

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" http://127.0.0.1:8317/v1/chat/completions \
  -H "Authorization: Bearer sk-dummy" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gpt-5.3-codex",
    "messages":[{"role":"user","content":"ping"}],
    "max_tokens":24
  }' 2>/dev/null)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "SUCCESS (HTTP 200)"
  echo "$BODY"
else
  echo "FAILED (HTTP $HTTP_CODE)"
  echo "$BODY"
fi
```

---

### Step M — Launch Test

```bash
echo "=== Testing ct --teammate codex ==="

# Verify command exists
if ! command -v ct >/dev/null 2>&1; then
  echo "ERROR: ct command not found. Did you run install.sh?"
  exit 1
fi

# Show version/help to verify it works
ct --help 2>&1 | head -20 || echo "Command failed"

echo ""
echo "To start a session, run:"
echo "  ct --teammate codex"
```

---

## 5) Operational Notes (Important)

| Setting | Value | Purpose |
|---------|-------|---------|
| `round-robin` | distributes requests | across matching credentials |
| `fill-first` | consume one credential first | then move to next |
| `priority=100` | for plus accounts | used first |
| `priority=0` | for pro accounts | fallback when plus exhausted |
| `switch-project: true` | auto-switch on quota | key for account switching |

For mixed plans (plus + pro), use `fill-first` + priority for deterministic plus-first behavior.

---

## 6) Commands Provided by This Project

| Command | Description |
|---------|-------------|
| `cc` | Claude Code solo (Anthropic direct) |
| `cc --model <name>` | Claude Code solo with profile model |
| `ct` | Teams mode (all Anthropic) |
| `ct --leader <name>` | Teams (leader: profile model, teammates: Anthropic) |
| `ct --teammate <name>` | Teams (leader: Anthropic, teammates: profile model) |
| `ct -l <name> -t <name>` | Teams (leader and teammates each use different models) |
| `ct -w` / `ct --worktree [name]` | Start Teams in a new Claude worktree (optional name) |

Profiles are stored at `~/.claude-models/*.env`.

---

## 7) Platform-Specific Service Management

### macOS (Homebrew)

```bash
# Start service
brew services start cliproxyapi

# Stop service
brew services stop cliproxyapi

# Restart service
brew services restart cliproxyapi

# Check status
brew services list | grep cliproxyapi

# View logs
tail -f /opt/homebrew/var/log/cliproxyapi.log 2>/dev/null || \
  tail -f /usr/local/var/log/cliproxyapi.log 2>/dev/null
```

### Linux (systemd user)

```bash
# Start service
systemctl --user start cliproxyapi

# Stop service
systemctl --user stop cliproxyapi

# Restart service
systemctl --user restart cliproxyapi

# Check status
systemctl --user status cliproxyapi --no-pager

# View logs
journalctl --user -u cliproxyapi -f

# Enable at login
systemctl --user enable cliproxyapi

# Disable at login
systemctl --user disable cliproxyapi
```

### WSL (manual/tmux)

```bash
# Start in tmux
tmux new-session -d -s cliproxyapi cliproxyapi

# Check status
tmux list-sessions | grep cliproxyapi
pgrep -f cliproxyapi

# Stop
tmux kill-session -t cliproxyapi 2>/dev/null || pkill -f cliproxyapi

# View logs (if logging to file)
tail -f ~/.cache/cliproxyapi.log

# Attach to tmux session
tmux attach -t cliproxyapi
```

---

## 8) Troubleshooting

### Service not starting

```bash
# Check if port is already in use
lsof -i :8317 2>/dev/null || ss -tlnp | grep 8317

# Check process
pgrep -af cliproxyapi

# Check config syntax
cliproxyapi -validate-config 2>/dev/null || echo "Config validation not supported"
```

### API returning errors

```bash
# Check service health
curl -v http://127.0.0.1:8317/health

# Check credentials exist
ls -la ~/.cli-proxy-api/

# Test with verbose output
curl -v http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-dummy"
```

### Commands not found

```bash
# Check PATH
echo $PATH

# Check installation
which cc ct cliproxyapi

# Reload shell config
source ~/.zshrc 2>/dev/null || source ~/.bashrc
```

---

## 9) Final Machine-Readable Report Format

When an AI agent finishes setup, output exactly this structure:

```text
[SETUP RESULT]
Platform: macos/linux/wsl
- install.sh: OK/FAIL
- CLIProxyAPI service: OK/FAIL
- codex.env updated: OK/FAIL
- routing.strategy=fill-first: OK/FAIL
- switch-project=true: OK/FAIL
- plus priority count: N
- pro priority count: N
- /v1/models test: OK/FAIL
- /v1/chat/completions test: OK/FAIL

[NOTES]
- blocking issues (if any)
- manual actions required (if any)
```

---

## License

MIT
