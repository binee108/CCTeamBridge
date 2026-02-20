# Claude Code Hybrid Model System

Leader uses Anthropic directly. Teammates use the model profile you choose (GLM, Codex via CLIProxyAPI, Kimi, etc.).

This README is written for **AI agents** to execute setup with minimal ambiguity.

---

## 1) Goal (Definition of Done)

Setup is complete only when all checks pass:

1. `~/.claude-models/codex.env` exists and contains:
   - `MODEL_BASE_URL="http://127.0.0.1:8317"`
   - `MODEL_HAIKU="gpt-5.3-codex-spark"`
   - `MODEL_SONNET="gpt-5.3-codex"`
   - `MODEL_OPUS="gpt-5.3-codex"`
2. CLIProxyAPI service is running.
3. `/opt/homebrew/etc/cliproxyapi.conf` has:
   - `routing.strategy: "fill-first"`
   - `quota-exceeded.switch-project: true`
4. Multi-account priority is set:
   - plus accounts: `"priority":"100"`
   - pro accounts: `"priority":"0"`
5. API tests succeed:
   - `GET /v1/models`
   - `POST /v1/chat/completions`
6. `ct --model codex` launches successfully.

---

## 2) Prerequisites

- Claude Code CLI installed (`claude --version`)
- tmux installed (`tmux -V`)
- zsh or bash
- macOS + Homebrew (this guide targets this environment)

If you only need GLM/direct providers, CLIProxyAPI is optional.

---

## 3) Deterministic Setup (Agent Procedure)

Execute steps in order.

### Step A — Install this project

```bash
curl -fsSL https://raw.githubusercontent.com/binee108/claude-code-hybrid/main/install.sh | bash
```

Reload shell:

```bash
if [ -n "${ZSH_VERSION:-}" ] || [[ "$SHELL" == *"zsh"* ]]; then
  source ~/.zshrc
else
  source ~/.bashrc
fi
```

### Step B — Install and start CLIProxyAPI

```bash
brew install cliproxyapi
brew services start cliproxyapi
```

Resolve executable name:

```bash
if command -v cliproxyapi >/dev/null 2>&1; then
  CLIPROXY_CMD="cliproxyapi"
elif command -v cli-proxy-api >/dev/null 2>&1; then
  CLIPROXY_CMD="cli-proxy-api"
else
  echo "ERROR: CLIProxyAPI command not found" >&2
  exit 1
fi
```

### Step C — Register Codex OAuth accounts

Run once per account (repeat for each account):

```bash
"$CLIPROXY_CMD" -codex-login
```

Verify files were created:

```bash
ls -1 ~/.cli-proxy-api/codex-*.json
```

### Step D — Force Codex hybrid profile

```bash
cat > ~/.claude-models/codex.env <<'EOF'
# Codex API Profile (CLIProxyAPI required)
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="gpt-5.3-codex-spark"
MODEL_SONNET="gpt-5.3-codex"
MODEL_OPUS="gpt-5.3-codex"
EOF
chmod 600 ~/.claude-models/codex.env
```

### Step D2 — Configure GLM API key (optional, direct provider)

If you want to use GLM without CLIProxyAPI, create/update `~/.claude-models/glm.env`:

```bash
cat > ~/.claude-models/glm.env <<'EOF'
# GLM API Profile
MODEL_AUTH_TOKEN="YOUR_GLM_API_KEY_HERE"
MODEL_BASE_URL="https://open.bigmodel.cn/api/anthropic"
MODEL_HAIKU="glm-4.7-flashx"
MODEL_SONNET="glm-5"
MODEL_OPUS="glm-5"
EOF
chmod 600 ~/.claude-models/glm.env
```

Use GLM profile:

```bash
cc --model glm
ct --model glm
```

### Step E — Configure routing and rate-limit behavior

Target config path (Homebrew):

- `/opt/homebrew/etc/cliproxyapi.conf`

Patch required values:

```bash
python3 - <<'PY'
from pathlib import Path
import re

p = Path('/opt/homebrew/etc/cliproxyapi.conf')
if not p.exists():
    raise SystemExit(f"Missing config file: {p}")

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
print('patched', p)
PY
```

### Step F — Set multi-account priority (plus first, pro fallback)

Rules:
- filename contains `-plus` → `priority=100`
- filename contains `-pro` → `priority=0`

```bash
python3 - <<'PY'
import glob, json, os
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
    print('updated', p.name)
PY
```

### Step G — Restart and verify

```bash
brew services restart cliproxyapi
brew services list | grep cliproxyapi || true
```

Verify required config values:

```bash
grep -n "request-retry\|max-retry-interval\|quota-exceeded\|switch-project\|routing\|strategy" /opt/homebrew/etc/cliproxyapi.conf
```

Verify priority assignment counts:

```bash
grep -R --line-number '"priority":"100"' ~/.cli-proxy-api/codex-*.json || true
grep -R --line-number '"priority":"0"' ~/.cli-proxy-api/codex-*.json || true
```

### Step H — API health tests

Model list:

```bash
curl -s http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-dummy"
```

Completion test:

```bash
curl -s http://127.0.0.1:8317/v1/chat/completions \
  -H "Authorization: Bearer sk-dummy" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gpt-5.3-codex-spark",
    "messages":[{"role":"user","content":"ping"}],
    "max_tokens":24
  }'
```

### Step I — Launch

```bash
ct --model codex
```

---

## 4) Operational Notes (Important)

- `round-robin`: distribute requests across matching credentials.
- `fill-first`: consume one eligible credential first, then move to next.
- For mixed plans (plus + pro), use `fill-first` + priority for deterministic plus-first behavior.
- `quota-exceeded.switch-project: true` is key for account switching under quota/rate-limit conditions.
- Docs clearly define `round-robin`/`fill-first`, but do not clearly specify numeric `attributes.priority` direction.
  - Source code (`selector.go`) uses `priority > bestPriority`, so larger numeric values win.

---

## 5) Commands Provided by This Project

| Command | Description |
|---|---|
| `cc` | Claude Code solo (Anthropic direct) |
| `cc --model <name>` | Claude Code solo with profile model |
| `ct` | Teams mode (all Anthropic) |
| `ct --model <name>` | Teams hybrid (leader Anthropic, teammates profile model) |
| `ccw` | `cc` with `--worktree` |
| `ctw` | `ct` with `--worktree` |

Profiles are stored at `~/.claude-models/*.env`.

---

## 6) Final Machine-Readable Report Format

When an AI agent finishes setup, output exactly this structure:

```text
[SETUP RESULT]
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
