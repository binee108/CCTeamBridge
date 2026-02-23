# CCTeamBridge

Leader는 Anthropic 직접 연결, Teammate는 원하는 모델 프로필(Codex, GLM, Kimi 등)을 사용합니다.

macOS, Linux, WSL 모두 지원합니다.

---

## 설치

### 1. CLIProxyAPI 설치 (Codex/Kimi 사용 시 필수)

**macOS:**

```bash
brew install cliproxyapi
```

**Linux / WSL:**

외부 스크립트 원격 실행 명령은 제공하지 않습니다.
CLIProxyAPI 공식 저장소/공식 문서의 수동 설치 절차를 따라 설치하세요.

설치 후 Codex 계정 등록 (계정마다 반복):

```bash
cliproxyapi -codex-login
```

> 파일명에 `-plus` 또는 `-pro`를 포함하면 우선순위가 자동 설정됩니다.
> CLIProxyAPI는 Codex/Kimi 사용할 때만 필요하며, 미설치 상태에서도 GLM-only로 진행할 수 있습니다.
> 설치 스크립트는 CLIProxyAPI 미설치 시 설치를 제안합니다. macOS는 brew 자동 설치를 시도할 수 있고, Linux/WSL은 자동 실행 없이 수동 설치 안내 후 GLM-only로 계속 진행합니다.
> 비대화형(non-interactive, `/dev/tty` 없음) 환경에서는 CLIProxyAPI 자동 설치/설정 패치를 기본적으로 건너뜁니다.

### 2. CCTeamBridge 설치

```bash
curl -fsSLo ./install.sh https://raw.githubusercontent.com/binee108/CCTeamBridge/main/install.sh
chmod +x ./install.sh
# 검토 후 실행
bash ./install.sh
```

이미 설치된 경우 강제 재설치:

```bash
curl -fsSLo ./install.sh https://raw.githubusercontent.com/binee108/CCTeamBridge/main/install.sh
chmod +x ./install.sh
# 검토 후 강제 재설치
bash ./install.sh --force
```

**끝!** 설치 스크립트가 아래를 모두 자동 수행합니다:

- 모델 프로필 생성 (`~/.claude-models/codex.env`, `glm.env`, `kimi.env`)
- CLIProxyAPI 설정 파일 자동 구성 (`routing: fill-first`, `quota-exceeded: switch-project` 등)
- Codex 멀티 계정 우선순위 자동 설정 (`-plus` → 100, `-pro` → 0)
- CLIProxyAPI 설치 제안/설정 (필요 시), 서비스 시작/재시작
  - 비대화형에서는 CLIProxyAPI 자동 설치/자동 패치를 기본 건너뜀
- 셸 함수 설치 (`cc`, `ct`, `cdoctor`)

셸 재시작 또는:

```bash
source ~/.zshrc  # 또는 source ~/.bashrc
```

---

## 사용법

### Solo 모드

```bash
cc                    # Anthropic 직접 연결 (--dangerously-skip-permissions 사용)
cc --model glm        # GLM 모델 사용 (--dangerously-skip-permissions 사용)
cc --model codex      # Codex 모델 사용 (--dangerously-skip-permissions 사용)
```

### Teams 모드

```bash
ct                          # 전원 Anthropic (--dangerously-skip-permissions 사용)
ct --teammate codex         # Leader: Anthropic, Teammates: Codex (--dangerously-skip-permissions 사용)
ct --teammate glm           # Leader: Anthropic, Teammates: GLM (--dangerously-skip-permissions 사용)
ct --leader codex           # Leader: Codex, Teammates: Anthropic (--dangerously-skip-permissions 사용)
ct -l codex -t glm          # Leader: Codex, Teammates: GLM (--dangerously-skip-permissions 사용)
```

### 진단

```bash
cdoctor                     # 전체 설정 상태 확인
```

---

## 모델 프로필

프로필 위치: `~/.claude-models/*.env`

| 프로필 | 파일 | 비고 |
|--------|------|------|
| Codex | `codex.env` | CLIProxyAPI 필요, 자동 생성됨 |
| GLM | `glm.env` | API 키 직접 입력 필요 |
| Kimi | `kimi.env` | CLIProxyAPI 필요, 자동 생성됨 |

### Codex 계정 등록

CLIProxyAPI 설치 후 OAuth 로그인으로 계정을 등록합니다.

**단일 계정:**

```bash
cliproxyapi -codex-login
# 브라우저에서 로그인 → ~/.cli-proxy-api/codex-<계정ID>.json 생성됨
```

**멀티 계정:**

계정마다 반복 실행합니다. 로그인 후 파일명에 플랜 구분자를 포함하도록 변경하세요:

```bash
cliproxyapi -codex-login
# 로그인 완료 후 파일명 변경:
mv ~/.cli-proxy-api/codex-<계정ID>.json ~/.cli-proxy-api/codex-work-plus.json

cliproxyapi -codex-login
mv ~/.cli-proxy-api/codex-<계정ID>.json ~/.cli-proxy-api/codex-personal-pro.json
```

| 파일명 패턴 | 자동 우선순위 | 동작 |
|-------------|-------------|------|
| `codex-*-plus.json` | `priority: 100` | 먼저 사용 |
| `codex-*-pro.json` | `priority: 0` | Plus 소진 시 fallback |

> 설치 스크립트가 파일명을 감지하여 우선순위를 자동 설정합니다.
> quota 초과 시 `switch-project: true` 설정에 의해 다음 계정으로 자동 전환됩니다.

### GLM API 키 설정

API 키 발급: https://z.ai/manage-apikey/apikey-list

**단일 키:**

```bash
vim ~/.claude-models/glm.env
```

```bash
MODEL_AUTH_TOKEN="your-glm-api-key"
```

**멀티 키 (round-robin):**

여러 키를 쉼표로 구분하면 teammate pane 생성 시마다 자동 순환 배정됩니다:

```bash
MODEL_AUTH_TOKENS="GLM_KEY_1,GLM_KEY_2,GLM_KEY_3"
```

- `MODEL_AUTH_TOKENS` 설정 시 `MODEL_AUTH_TOKEN`보다 우선합니다
- 각 pane은 생성 시점에 배정된 키를 고정 사용합니다
- 상태 파일: `~/.claude-models/.hybrid-rr/<model>.idx`

### 커스텀 모델 추가

`~/.claude-models/<name>.env` 파일 생성:

```bash
MODEL_AUTH_TOKEN="your-key"
MODEL_BASE_URL="https://api.example.com"
MODEL_HAIKU="model-name"
MODEL_SONNET="model-name"
MODEL_OPUS="model-name"
```

사용: `ct --teammate <name>` 또는 `cc --model <name>`

---

## 서비스 관리

| 플랫폼 | 시작 | 중지 | 재시작 |
|--------|------|------|--------|
| macOS | `brew services start cliproxyapi` | `brew services stop cliproxyapi` | `brew services restart cliproxyapi` |
| Linux | `systemctl --user start cliproxyapi` | `systemctl --user stop cliproxyapi` | `systemctl --user restart cliproxyapi` |
| WSL | `tmux new-session -d -s cliproxyapi cliproxyapi` | `tmux kill-session -t cliproxyapi` | 중지 후 시작 |

---

## 문제 해결

```bash
cdoctor                                          # 전체 진단
curl -s http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-dummy"            # API 테스트
pgrep -f cliproxyapi                             # 프로세스 확인
```

---

## License

MIT
