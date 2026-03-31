# CCTeamBridge

Claude Code를 다양한 모델(GLM, Codex, Kimi, Hybrid 등)과 함께 사용할 수 있게 해주는 모델 스위칭 도구입니다.

> **참고:** `ccd` 명령은 `claude --dangerously-skip-permissions`의 단축어입니다. 모든 권한 프롬프트를 건너뛰고 실행되므로, 신뢰할 수 있는 환경에서만 사용하세요.

macOS, Linux, WSL 모두 지원합니다.

---

## 설치

### 1. CCTeamBridge 설치

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

- Python 3.9+ 감지 및 가상환경 생성 (`~/.ccbridge/venv/`)
- aiohttp, pyyaml 의존성 설치
- ccbridge-proxy 자동 시작 (`~/.ccbridge/`)
- 모델 프로필 생성 (`~/.claude-models/codex.env`, `glm.env`, `kimi.env`, `hybrid.env`)
- Codex 멀티 계정 우선순위 자동 설정 (`-plus` → 100, `-pro` → 0)
- 셸 함수 설치 (`ccd`, `cdoctor`)

셸 재시작 또는:

```bash
source ~/.zshrc  # 또는 source ~/.bashrc
```

### 2. OAuth 로그인 (Codex/Kimi 사용 시)

> **마이그레이션 참고:** OAuth 로그인은 현재 CLIProxyAPI 바이너리가 필요합니다. `cliproxyapi -codex-login`으로 계정을 등록하세요. 자격 증명은 자동으로 `~/.ccbridge/credentials/`로 마이그레이션됩니다.

---

## 사용법

```bash
ccd                    # Claude Code (Anthropic direct)
ccd --model glm        # Claude Code with GLM
ccd --model codex      # Claude Code with Codex
ccd --model kimi       # Claude Code with Kimi
ccd --model hybrid     # Claude Code with custom multi-model
```

> **보안:** `ccd`는 `--dangerously-skip-permissions` 플래그로 실행됩니다. 파일 쓰기, 명령 실행 등 모든 권한 확인을 자동 승인합니다.

### 진단

```bash
cdoctor                     # 전체 설정 상태 확인
```

---

## 모델 프로필

프로필 위치: `~/.claude-models/*.env`

| 프로필 | 파일 | 비고 |
|--------|------|------|
| GLM | `glm.env` | z.ai API key 직접 입력 |
| Codex | `codex.env` | ccbridge-proxy 경유 |
| Kimi | `kimi.env` | ccbridge-proxy 경유 |
| Hybrid | `hybrid.env` | ccbridge-proxy 경유, 자유로운 모델 조합 |

### Codex 계정 등록

> **참고:** OAuth 로그인은 현재 CLIProxyAPI 바이너리가 필요합니다. `cliproxyapi -codex-login`으로 계정을 등록하면 자격 증명이 자동으로 `~/.ccbridge/credentials/`로 마이그레이션됩니다.

**단일 계정:**

```bash
# CLIProxyAPI 필요 (OAuth 로그인 전용)
cliproxyapi -codex-login
# 브라우저에서 로그인 → 자격 증명이 ~/.ccbridge/credentials/로 마이그레이션됨
```

**멀티 계정:**

계정마다 반복 실행합니다. 로그인 후 파일명에 플랜 구분자를 포함하도록 변경하세요:

```bash
cliproxyapi -codex-login
# 로그인 완료 후 파일명 변경:
mv ~/.ccbridge/credentials/codex-<계정ID>.json ~/.ccbridge/credentials/codex-work-plus.json

cliproxyapi -codex-login
mv ~/.ccbridge/credentials/codex-<계정ID>.json ~/.ccbridge/credentials/codex-personal-pro.json
```

| 파일명 패턴 | 자동 우선순위 | 동작 |
|-------------|-------------|------|
| `codex-*-plus.json` | `priority: 100` | 먼저 사용 |
| `codex-*-pro.json` | `priority: 0` | Plus 소진 시 fallback |

> quota 초과 시 ccbridge-proxy가 자동으로 다음 계정으로 전환합니다 (fill-first 전략, 소진 키 1시간 쿨다운).

### GLM API 키 설정

API 키 발급: https://z.ai/manage-apikey/apikey-list

`~/.ccbridge/config.yaml`을 편집합니다:

```yaml
glm:
  base_url: "https://api.z.ai/api/anthropic"
  api_keys:
    - "your-key-1"
    - "your-key-2"
```

- 여러 키 등록 시 fill-first 전략으로 자동 순환합니다
- 소진된 키는 1시간 쿨다운 후 재사용됩니다

### Hybrid 모델 설정

Hybrid 모델은 ccbridge-proxy를 통해 여러 모델을 자유롭게 조합할 수 있는 프로필입니다. Opus/Sonnet/Haiku 각 역할에 원하는 모델을 설정하세요.

**설정 예시:**

`~/.claude-models/hybrid.env`를 편집하여 모델을 조합합니다:

```bash
MODEL_AUTH_TOKEN="sk-dummy"
MODEL_BASE_URL="http://127.0.0.1:8317"
MODEL_HAIKU="glm-5-turbo"       # 빠른 응답용
MODEL_SONNET="gpt-5.3-codex"    # 일반 작업용
MODEL_OPUS="claude-opus-4-6"    # 복잡한 추론용
```

| 역할 | 기본값 | 설정 가능 모델 예시 |
|------|--------|-------------------|
| Opus | `claude-opus-4-6` | Claude, GPT, GLM, Kimi 등 |
| Sonnet | `glm-5.1` | Claude, GPT, GLM, Kimi 등 |
| Haiku | `glm-5-turbo` | Claude, GPT, GLM, Kimi 등 |

**사전 요구사항:**

1. ccbridge-proxy 실행 (install.sh로 자동 설정됨)
2. 사용하려는 모델의 인증 정보를 등록
   - Codex/Kimi: OAuth 로그인 후 자동 마이그레이션
   - GLM: `~/.ccbridge/config.yaml`에 API 키 등록

> 설치 스크립트가 `hybrid.env`를 자동 생성하지만, 모델 인증 정보 등록은 수동으로 진행해야 합니다.

### 커스텀 모델 추가

`~/.claude-models/<name>.env` 파일 생성:

```bash
MODEL_AUTH_TOKEN="your-key"
MODEL_BASE_URL="https://api.example.com"
MODEL_HAIKU="model-name"
MODEL_SONNET="model-name"
MODEL_OPUS="model-name"
```

사용: `ccd --model <name>`

---

## 서비스 관리

| 플랫폼 | 시작 | 중지 | 재시작 |
|--------|------|------|--------|
| macOS | `launchctl load ~/Library/LaunchAgents/com.ccbridge.proxy.plist` | `launchctl unload ~/Library/LaunchAgents/com.ccbridge.proxy.plist` | unload 후 load |
| Linux | `systemctl --user start ccbridge-proxy` | `systemctl --user stop ccbridge-proxy` | `systemctl --user restart ccbridge-proxy` |
| WSL | 백그라운드 프로세스 (install.sh가 자동 관리) | `pkill -f "python3 -m proxy"` | install.sh 재실행 |

> install.sh가 플랫폼에 맞게 서비스를 자동 구성하고 시작합니다.

---

## 문제 해결

```bash
cdoctor                                          # 전체 진단
curl -s http://127.0.0.1:8317/v1/models \
  -H "Authorization: Bearer sk-dummy"            # API 테스트
pgrep -f "python3 -m proxy"                      # 프로세스 확인
```

---

## 아키텍처

ccbridge-proxy는 aiohttp 기반 Python 프록시로 (~800 LOC), 순수 Anthropic API 패스스루를 제공합니다. 모든 요청을 Anthropic 호환 형식으로 전달하며, 멀티 키 순환(fill-first, 1시간 쿨다운)과 계정 자동 전환을 지원합니다.

---

## License

MIT
