"""Error response interceptor for ccbridge-proxy.

Normalizes non-2xx responses from upstream into consistent Anthropic-format
errors with actionable ccbridge error codes. Zero overhead on 2xx responses.
"""
import json
import logging

from .errors import (
    TOKEN_EXPIRED,
    ALL_CREDENTIALS_EXHAUSTED,
    UPSTREAM_ERROR,
    build_anthropic_error,
    serialize_error,
)

logger = logging.getLogger("ccbridge-proxy")


def should_intercept(status_code):
    """Check if response should be intercepted (non-2xx)."""
    return status_code < 200 or status_code >= 300


async def intercept_upstream_error(status_code, body_bytes, provider, auth_value,
                                   credential_store):
    """Intercept and normalize an upstream error response.

    Returns (status, error_body_bytes) in Anthropic error format.
    """
    # Try to parse upstream error as Anthropic format
    try:
        upstream_error = json.loads(body_bytes)
    except (json.JSONDecodeError, TypeError):
        upstream_error = None

    # Handle specific status codes
    if status_code == 429:
        return _handle_quota_exceeded(provider, auth_value, credential_store)
    elif status_code == 401:
        return _handle_auth_error(provider, upstream_error)
    elif status_code == 403:
        return _handle_forbidden(provider, auth_value, credential_store, upstream_error)
    else:
        return _handle_generic_error(status_code, upstream_error)


def _handle_quota_exceeded(provider, auth_value, credential_store):
    """Handle 429 Quota Exceeded - mark credential exhausted and check if all gone."""
    if credential_store and auth_value:
        credential_store.mark_exhausted(provider, auth_value)

    status, error_data = build_anthropic_error(ALL_CREDENTIALS_EXHAUSTED)
    return status, serialize_error(error_data)


def _handle_auth_error(provider, _upstream_error):
    """Handle 401 Unauthorized."""
    status, error_data = build_anthropic_error(
        TOKEN_EXPIRED,
        message=f"OAuth token expired for {provider}. "
                f"Re-run: ccbridge -{provider}-login",
        provider_type=provider,
    )
    return status, serialize_error(error_data)


def _handle_forbidden(provider, auth_value, credential_store, _upstream_error):
    """Handle 403 Forbidden - may be revoked credential."""
    if credential_store and auth_value:
        credential_store.mark_exhausted(provider, auth_value)

    status, error_data = build_anthropic_error(
        TOKEN_EXPIRED,
        message=f"Access denied for {provider}. Credential may be revoked. "
                f"Re-run: ccbridge -{provider}-login",
        provider_type=provider,
    )
    return status, serialize_error(error_data)


def _handle_generic_error(status_code, upstream_error):
    """Handle any other upstream error."""
    if upstream_error and isinstance(upstream_error, dict):
        error_msg = upstream_error.get("error", {})
        if isinstance(error_msg, dict):
            message = error_msg.get("message", f"Upstream error: HTTP {status_code}")
        else:
            message = str(error_msg)
    else:
        message = f"Upstream returned HTTP {status_code}"

    status, error_data = build_anthropic_error(
        UPSTREAM_ERROR,
        message=message,
        status=status_code,
    )
    return status, serialize_error(error_data)
