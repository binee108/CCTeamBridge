"""Error code constants and Anthropic error format builders."""
import json

# Error codes
TOKEN_EXPIRED = "ccbridge_token_expired"
REFRESH_FAILED = "ccbridge_refresh_failed"
REFRESH_ENDPOINT_UNKNOWN = "ccbridge_refresh_endpoint_unknown"
ALL_CREDENTIALS_EXHAUSTED = "ccbridge_all_credentials_exhausted"
NO_CREDENTIALS = "ccbridge_no_credentials"
CREDENTIAL_DISABLED = "ccbridge_credential_disabled"
UPSTREAM_ERROR = "ccbridge_upstream_error"
PROVIDER_UNKNOWN = "ccbridge_provider_unknown"

ERROR_HTTP_STATUS = {
    TOKEN_EXPIRED: 401,
    REFRESH_FAILED: 401,
    REFRESH_ENDPOINT_UNKNOWN: 401,
    ALL_CREDENTIALS_EXHAUSTED: 429,
    NO_CREDENTIALS: 401,
    CREDENTIAL_DISABLED: 401,
    UPSTREAM_ERROR: 502,
    PROVIDER_UNKNOWN: 400,
}

ERROR_ACTIONS = {
    TOKEN_EXPIRED: "Re-run: ccbridge -{provider_type}-login",
    REFRESH_FAILED: "Check network connectivity. Re-run: ccbridge -{provider_type}-login",
    REFRESH_ENDPOINT_UNKNOWN: "Re-run: ccbridge -{provider_type}-login",
    ALL_CREDENTIALS_EXHAUSTED: "Wait for cooldown or add more credentials",
    NO_CREDENTIALS: "Register credentials for this provider",
    CREDENTIAL_DISABLED: "Enable credentials for this provider",
    UPSTREAM_ERROR: "Retry or check upstream service status",
    PROVIDER_UNKNOWN: "Check model name in request",
}


def build_anthropic_error(code, message=None, status=None, **kwargs):
    """Build Anthropic-format error response."""
    if status is None:
        status = ERROR_HTTP_STATUS.get(code, 500)
    if message is None:
        action = ERROR_ACTIONS.get(code, "")
        for key, val in kwargs.items():
            action = action.replace("{" + key + "}", str(val))
        message = f"{code}: {action}" if action else code

    return (
        status,
        {"type": "error", "error": {"type": code, "message": message}},
    )


def serialize_error(error_dict):
    """Serialize error dict to JSON bytes."""
    return json.dumps(error_dict).encode("utf-8")
