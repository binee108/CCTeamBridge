# Session Isolation Architecture (v1.6.0)

## Overview

v1.6.0 redesigns the `ct` command to support **concurrent sessions with different model configurations**. Prior versions used global state that caused race conditions when multiple `ct` sessions ran simultaneously.

### Supported Use Cases

```bash
ct -l codex -t glm       # Leader: Codex, Teammates: GLM
ct --teammate glm            # Leader: Anthropic, Teammates: GLM
ct -l glm -t codex        # Leader: GLM, Teammates: Codex
ct --worktree my-feature  # Teams in isolated Claude worktree
ct                         # Leader: Anthropic, Teammates: Anthropic
```

All combinations can run concurrently without interference.

---

## Problem: Global State Race Condition (pre-v1.6.0)

### Architecture Before v1.6.0

```
ct --teammate glm
  ├── echo "glm" > ~/.claude-hybrid-active        # Global file (PROBLEM)
  ├── tmux new-session
  │     └── tmux hook (session-created)
  │           └── ~/.tmux-hybrid-hook.sh           # Global hook (PROBLEM)
  │                 └── reads ~/.claude-hybrid-active
  │                 └── tmux set-environment (GLOBAL)
  └── tmux attach
```

### What Went Wrong

1. **Last-writer-wins**: `~/.claude-hybrid-active` is a single file. If two `ct` sessions start concurrently, the second overwrites the first's model choice.

2. **Global tmux hook**: `~/.tmux-hybrid-hook.sh` runs on every `session-created` event across ALL tmux sessions. A non-hybrid session could inherit model variables from a previous hybrid session.

3. **Global tmux environment**: `tmux set-environment` (without `-t`) sets variables globally. All sessions see the same values.

### Example: Race Condition

```
Terminal 1: ct --teammate glm
  → writes "glm" to ~/.claude-hybrid-active
  → creates tmux session

Terminal 2: ct --teammate codex           # Before Terminal 1's hook fires
  → writes "codex" to ~/.claude-hybrid-active   # OVERWRITES "glm"
  → creates tmux session

Terminal 1's hook fires:
  → reads ~/.claude-hybrid-active → finds "codex"   # WRONG! Should be "glm"
  → sets ANTHROPIC_BASE_URL = codex proxy URL
  → Terminal 1's teammates now use Codex instead of GLM
```

---

## Solution: Session-Scoped Environment

### Architecture After v1.6.0

```
ct -l codex -t glm
  ├── tmux new-session -s "claude-teams-codex-glm"
  ├── tmux set-environment -t "claude-teams-codex-glm" HYBRID_ACTIVE "glm"
  ├── tmux set-environment -t "claude-teams-codex-glm" ANTHROPIC_BASE_URL "https://..."
  ├── tmux set-environment -t "claude-teams-codex-glm" ANTHROPIC_DEFAULT_*_MODEL "..."
  ├── teammate pane shell startup resolves ANTHROPIC_AUTH_TOKEN via RR
  ├── tmux send-keys "_claude_load_model codex && ... claude --teammate-mode tmux"
  └── tmux attach
```

### Key Design Decisions

#### 1. Removed All Global State

| Removed Component | Reason |
|---|---|
| `~/.claude-hybrid-active` | Global file causes last-writer-wins race |
| `~/.tmux-hybrid-hook.sh` | Global hook affects all sessions |
| `tmux.conf` hook registration | Global hook trigger |
| `tmux set-environment` (global) | Global env pollutes non-hybrid sessions |
| `echo "$MODEL" > ~/.claude-hybrid-active` in `ct()` | Global state write |
| `rm -f ~/.claude-hybrid-active` in `ct()` | Cleanup of global state |

**Replacement**: `tmux set-environment -t "$SESSION"` (session-scoped). Each session has its own isolated set of environment variables.

#### 2. Leader/Teammate Model Separation

The `ct` function now accepts separate `--leader` and `--teammate` flags:

```bash
ct() {
    # Parse --leader/-l and --teammate/-t at wrapper level
    # Forward other flags to Claude CLI (e.g., --worktree)

    # Session env = teammate model (inherited by new panes)
    tmux set-environment -t "$SESSION" HYBRID_ACTIVE "$TEAMMATE"
    tmux set-environment -t "$SESSION" ANTHROPIC_BASE_URL "$TEAMMATE_URL"

    # Leader pane = leader model (loaded via send-keys, not session env)
    tmux send-keys "_claude_load_model $LEADER && claude --teammate-mode tmux"
}
```

**Why send-keys for the leader?** The leader model is set at the shell process level (via `_claude_load_model`), not the session level. This allows the leader to use a different model than the session env (which holds teammate values).

#### 3. Session Naming Convention

```
ct                          → claude-teams
ct --teammate glm              → claude-teams-glm
ct -l codex -t glm          → claude-teams-codex-glm
ct -l glm -t codex          → claude-teams-glm-codex
```

If a session name already exists, a numeric suffix is appended:
```
claude-teams-glm            → claude-teams-glm-1 → claude-teams-glm-2
```

Note: tmux uses prefix matching for session targets (`-t`). When `claude-teams-glm-glm` exists, `tmux has-session -t claude-teams-glm` matches it as a prefix. This causes `ct --teammate glm` to see a "conflict" and increment to `claude-teams-glm-1`. This is cosmetic and does not affect isolation.

---

## Teammate Environment Propagation

### The Challenge

When Claude Code creates a teammate pane (`tmux split-window`), the new pane starts a new shell. That shell needs the **teammate's** model environment, not the leader's.

### Three-Layer Defense

```
Layer 1: tmux session env
  └── HYBRID_ACTIVE=glm set via "tmux set-environment -t $SESSION"
  └── Inherited by all new panes in the session

Layer 2: .zshenv / .bashrc
  └── Detects HYBRID_ACTIVE in shell startup
  └── Sources the correct model profile
  └── Exports ANTHROPIC_* variables
  └── Defines env() wrapper function

Layer 3: env() wrapper
  └── Intercepts Claude Code CLI's inline "env ANTHROPIC_BASE_URL=..."
  └── Replaces leader's URL with teammate's URL
```

### Layer 1: tmux Session Environment

```bash
tmux set-environment -t "$SESSION" HYBRID_ACTIVE "$TEAMMATE"
tmux set-environment -t "$SESSION" ANTHROPIC_BASE_URL "$URL"
tmux set-environment -t "$SESSION" ANTHROPIC_DEFAULT_*_MODEL "..."
# ANTHROPIC_AUTH_TOKEN is resolved per pane at shell startup
```

`$TOKEN` is selected at pane(shell)-startup time:

- Prefer `MODEL_AUTH_TOKENS` (comma-separated list) from the teammate profile
- Fallback to `MODEL_AUTH_TOKEN` when multi-key is unset/empty
- Pick exactly one key per new pane/shell via round-robin
- Persist round-robin state at `~/.claude-models/.hybrid-rr/<model>.idx`
- Update the index file without locks (best-effort under concurrent launches, avoids lock-related deadlock risk)

When a new pane is created in this session, it inherits session-scoped model selectors (`HYBRID_ACTIVE`, URL/model names). Then pane startup logic resolves `ANTHROPIC_AUTH_TOKEN` via round-robin.

### Layer 2: Shell Startup (.zshenv / .bashrc)

```bash
# .zshenv (for zsh) — runs in ALL shells including non-interactive
if [[ -n "$HYBRID_ACTIVE" ]] && [[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]] && \
   [[ -f "$HOME/.claude-models/${HYBRID_ACTIVE}.env" ]]; then
    source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"

    # Keep pane-local token pinned; resolve only if empty
    if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
        # MODEL_AUTH_TOKENS preferred, MODEL_AUTH_TOKEN fallback
        # (first non-empty token is used)
        export ANTHROPIC_AUTH_TOKEN="..."
    fi

    export ANTHROPIC_BASE_URL="$MODEL_BASE_URL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL_HAIKU"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL_SONNET"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL_OPUS"
fi
```

**Why `.zshenv`?** Claude Code uses `zsh -c "command"` for teammate shells, which is non-interactive. `.zshrc` only runs in interactive shells. `.zshenv` runs in ALL zsh invocations (interactive, non-interactive, `zsh -c`), making it the most reliable propagation point.

**Why `.bashrc` for bash?** Bash sources `.bashrc` for interactive shells. Non-interactive bash reads `$BASH_ENV` if set. Since tmux panes are interactive by default, `.bashrc` is sufficient for bash users.

**Why re-source the profile?** Even though tmux session env has the correct values, we re-source from the `.env` file to guarantee consistency. The session env might have stale values if the profile was updated between session creation and pane creation.

### Layer 3: `env()` Wrapper Function

This is the most critical and non-obvious part of the design.

#### The Problem

Claude Code CLI's internal teammate spawning mechanism (the `WlT()` function) reads `ANTHROPIC_BASE_URL` from the **leader process's environment** and forwards it to the teammate via an inline `env` prefix:

```bash
# What Claude Code CLI sends to the teammate pane:
cd /project && env CLAUDECODE=1 \
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \    # ← Leader's Codex URL!
    /path/to/claude --agent-id ... --model sonnet
```

The `env` command sets `ANTHROPIC_BASE_URL` **only for the claude process**, overriding whatever `.zshenv` set in the shell. This means:
- Shell env: `ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic` (correct, GLM)
- Claude process: `ANTHROPIC_BASE_URL=http://127.0.0.1:8317` (wrong, Codex from leader)

#### The Solution

Define a shell function named `env` that intercepts the command and replaces any `ANTHROPIC_*` values with the teammate's correct values:

```bash
env() {
    local -a _args
    for _a in "$@"; do
        case "$_a" in
            ANTHROPIC_AUTH_TOKEN=*)
                _args+=("ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}") ;;
            ANTHROPIC_BASE_URL=*)
                _args+=("ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}") ;;
            ANTHROPIC_DEFAULT_HAIKU_MODEL=*)
                _args+=("ANTHROPIC_DEFAULT_HAIKU_MODEL=${ANTHROPIC_DEFAULT_HAIKU_MODEL}") ;;
            ANTHROPIC_DEFAULT_SONNET_MODEL=*)
                _args+=("ANTHROPIC_DEFAULT_SONNET_MODEL=${ANTHROPIC_DEFAULT_SONNET_MODEL}") ;;
            ANTHROPIC_DEFAULT_OPUS_MODEL=*)
                _args+=("ANTHROPIC_DEFAULT_OPUS_MODEL=${ANTHROPIC_DEFAULT_OPUS_MODEL}") ;;
            *) _args+=("$_a") ;;
        esac
    done
    command env "${_args[@]}"
}
```

#### How It Works

1. In zsh/bash, **shell functions take precedence over external commands**
2. When Claude Code sends `env ANTHROPIC_BASE_URL=codex_url claude ...`, the shell calls our `env()` function, not `/usr/bin/env`
3. The function iterates arguments, replacing any `ANTHROPIC_*=value` with the shell's current `${ANTHROPIC_*}` values (set by `.zshenv` to teammate profile)
4. `command env` explicitly calls the real `/usr/bin/env`, bypassing the function, with the corrected arguments

#### Why This Is Safe

| Scenario | Behavior |
|---|---|
| Non-hybrid shell (`HYBRID_ACTIVE` unset) | `env()` function is NOT defined. Normal `env` behavior. |
| `env` with no args (list vars) | No `ANTHROPIC_*=*` matches. `command env` called with no args. Works normally. |
| `env FOO=bar command` | `FOO=bar` doesn't match `ANTHROPIC_*`. Passed through unchanged. |
| `env -i command` | `-i` doesn't match `ANTHROPIC_*`. Passed through unchanged. |
| Leader pane uses `env` | Leader's shell has codex values (from `_claude_load_model`). `${ANTHROPIC_BASE_URL}` resolves to codex. Correct for leader. |

#### Why Not Other Approaches?

| Approach | Why Not |
|---|---|
| Patch Claude Code CLI | Not an option (closed source internal behavior) |
| tmux `after-split-window` hook | Hooks can't modify process environment variables |
| `preexec` zsh hook | Can observe commands but can't modify them |
| Wrapper binary at claude path | Fragile; Claude Code uses full path, not `$PATH` lookup |
| `LD_PRELOAD` / `DYLD_INSERT_LIBRARIES` | Extremely hacky and platform-specific |

---

## Heredoc Split Design

### Problem

The shell RC block (`.zshrc` or `.bashrc`) was written as a single heredoc. But zsh and bash need different env propagation:
- **zsh**: Uses `.zshenv` for env propagation (handles non-interactive shells)
- **bash**: Needs an env block in `.bashrc` (no `.bashenv` equivalent)

### Solution: Three-Part Heredoc

```bash
# Part 1: Marker + version tag (common)
cat >> "$SHELL_RC" << SHELLEOF
# === CLAUDE HYBRID START ===
# CLAUDE_HYBRID_VERSION=1.6.0
SHELLEOF

# Part 2: Env propagation (bash only)
if [[ "$SHELL_RC" == *".bashrc" ]]; then
    cat >> "$SHELL_RC" << 'BASHEOF'
    # HYBRID_ACTIVE detection + profile sourcing + env() wrapper
BASHEOF
fi

# Part 3: Helpers + functions (common)
cat >> "$SHELL_RC" << SHELLEOF
    # _claude_unset_model_vars(), _claude_load_model(), cc(), ct()
SHELLEOF
```

**Part 1** uses unquoted `SHELLEOF` to expand `$MARKER_START` and `$VERSION_TAG` at install time.

**Part 2** uses quoted `'BASHEOF'` to prevent expansion — the content is literal shell code that runs at source time, not install time. It's conditionally included only for `.bashrc`.

**Part 3** uses unquoted `SHELLEOF` because it contains `\$` escaped variables that need to be written literally but also `$MARKER_END` that needs expansion.

---

## Security Hardening

### HYBRID_ACTIVE Path Traversal Prevention

The `HYBRID_ACTIVE` value is used in `source "$HOME/.claude-models/${HYBRID_ACTIVE}.env"`. Without validation, an attacker who controls tmux session env could set `HYBRID_ACTIVE=../../etc/passwd` to source arbitrary files.

**Fix**: Regex validation before any use:

```bash
[[ "$HYBRID_ACTIVE" =~ ^[a-zA-Z0-9_-]+$ ]]
```

Applied in three locations:
1. `.zshenv` env propagation block
2. `.bashrc` env propagation block
3. `_claude_load_model()` function

### `((count++))` Arithmetic Bug

Under `set -euo pipefail`, bash's `((expr))` returns the expression's value as exit status. `((0++))` evaluates to 0, which is falsy, causing exit status 1 and script abort.

```bash
# BROKEN: count starts at 0, ((0++)) returns exit 1 → script aborts
count=0
((count++))    # EXIT STATUS 1 → pipefail kills script

# FIXED: $((expr)) is command substitution, always exit 0
count=0
count=$((count + 1))    # EXIT STATUS 0
```

Fixed in 7 locations across `_do_backup()`, legacy cleanup, and `ct()` session increment.

---

## Legacy Cleanup

The installer automatically removes artifacts from pre-v1.6.0 installations:

| Artifact | Cleanup Method |
|---|---|
| `~/.claude-hybrid-active` | `rm -f` |
| `~/.tmux-hybrid-hook.sh` | `rm -f` |
| tmux.conf hook entries | `sed` remove lines |
| Global tmux env vars (6) | `tmux set-environment -gu` |
| `~/.claude-models/.hybrid-rr` round-robin state | `rm -rf` |
| `# === LLM PROVIDER SWITCHER START/END ===` in RC | `sed` remove block |
| `# === CLAUDE CODE SHORTCUTS/END ===` in RC | `sed` remove block |

The last two entries handle an even older installation format that used different marker strings.

---

## Uninstall

`uninstall.sh` was updated to also clear global tmux env vars:

```bash
tmux set-environment -gu HYBRID_ACTIVE
tmux set-environment -gu ANTHROPIC_AUTH_TOKEN
tmux set-environment -gu ANTHROPIC_BASE_URL
tmux set-environment -gu ANTHROPIC_DEFAULT_HAIKU_MODEL
tmux set-environment -gu ANTHROPIC_DEFAULT_SONNET_MODEL
tmux set-environment -gu ANTHROPIC_DEFAULT_OPUS_MODEL
```

---

## Verification Matrix

| Scenario | Leader | Teammate | Session Env | Tested |
|---|---|---|---|---|
| `ct` | Anthropic | Anthropic | (unset) | Yes |
| `ct --teammate glm` (single key) | Anthropic | GLM | GLM (+ pane token RR) | Yes |
| `ct --teammate glm` (multi key RR) | Anthropic | GLM | GLM (+ pane token RR) | Yes |
| `ct -l codex -t glm` | Codex | GLM | GLM | Yes |
| `ct -l glm -t glm` | GLM | GLM | GLM | Yes |
| `ct -l glm` | GLM | Anthropic | (unset) | Yes |
| Concurrent sessions | Independent | Independent | Isolated | Yes |
| Pane token remains pinned after assignment | - | Yes | Isolated | Yes |
| Path traversal `../..` | - | - | Blocked | Yes |
| Special chars `a;rm` | - | - | Blocked | Yes |
| `env` wrapper intercept | - | Correct URL | - | Yes |

### Verification Procedure (Round-robin and pinning)

1. Static checks
   - `bash -n install.sh`
   - `bash -n uninstall.sh`
2. Backward compatibility
   - Set only `MODEL_AUTH_TOKEN` and run `ct --teammate glm`
3. Multi-key round-robin (pane-level)
   - Set `MODEL_AUTH_TOKENS` with 3 keys
   - Start one `ct --teammate glm` session and create multiple panes
   - In each pane, run `echo "$ANTHROPIC_AUTH_TOKEN"` and confirm rotation by pane creation order
4. Pane token pinning
   - In a single pane, run additional commands and confirm token value stays unchanged for that pane
5. Concurrency sanity
   - Launch multiple `ct --teammate glm` and/or create panes in short intervals
   - Confirm key selection continues to rotate per pane/shell creation (best-effort file updates, no lock dependency)

Operational note: if concurrent session count exceeds key count, key sharing is expected by design.
