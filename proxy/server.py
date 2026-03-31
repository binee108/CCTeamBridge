"""Async HTTP server for ccbridge-proxy.

Handles Anthropic API passthrough for all providers (GLM, Codex, Claude, Kimi).
Routes both /v1/* and /api/anthropic/* paths.
"""
import json
import asyncio
import time
import logging

import aiohttp
from aiohttp import web

from .config import get_provider_for_model, get_provider_config
from .health import build_models_response
from .credentials import CredentialStore, migrate_credentials
from .interceptor import should_intercept, intercept_upstream_error
from .errors import (
    PROVIDER_UNKNOWN,
    NO_CREDENTIALS,
    UPSTREAM_ERROR,
    build_anthropic_error,
    serialize_error,
)

logger = logging.getLogger("ccbridge-proxy")


def create_app(config):
    """Create the aiohttp application with routes."""
    app = web.Application()
    app["config"] = config
    app["start_time"] = time.time()

    # Initialize credential store
    migrate_credentials(config)
    store = CredentialStore(config)
    store.load()
    app["credential_store"] = store

    # Standard Anthropic API paths
    app.router.add_post("/v1/messages", handle_messages)
    app.router.add_get("/v1/models", handle_models)

    # Alternative paths (kimi.env compatibility)
    app.router.add_post("/api/anthropic/v1/messages", handle_messages)
    app.router.add_get("/api/anthropic/v1/models", handle_models)

    return app


async def handle_models(request):
    """Handle GET /v1/models health check."""
    app = request.app
    config = app["config"]
    response_data = build_models_response(config, app["start_time"])
    return web.json_response(response_data)


async def handle_messages(request):
    """Handle POST /v1/messages - main Anthropic API passthrough."""
    app = request.app
    config = app["config"]

    # Read request body
    try:
        body = await request.read()
        body_json = json.loads(body)
    except (json.JSONDecodeError, Exception) as e:
        status, error_data = build_anthropic_error(
            "invalid_request_error",
            message=f"Invalid request body: {e}",
            status=400,
        )
        return web.Response(
            status=status,
            content_type="application/json",
            body=serialize_error(error_data),
        )

    model_name = body_json.get("model", "")
    provider = get_provider_for_model(config, model_name)

    if provider is None:
        status, error_data = build_anthropic_error(PROVIDER_UNKNOWN)
        return web.Response(
            status=status,
            content_type="application/json",
            body=serialize_error(error_data),
        )

    provider_config = get_provider_config(config, provider)
    base_url = provider_config.get("base_url", "")

    if not base_url:
        status, error_data = build_anthropic_error(PROVIDER_UNKNOWN)
        return web.Response(
            status=status,
            content_type="application/json",
            body=serialize_error(error_data),
        )

    # Get auth credential for this provider
    credential_store = app.get("credential_store")
    auth_value = None
    if credential_store:
        auth_value = credential_store.get_auth(provider)

    if auth_value is None:
        # All providers need credentials
        api_keys = provider_config.get("api_keys", [])
        if not api_keys:
            status, error_data = build_anthropic_error(NO_CREDENTIALS)
            return web.Response(
                status=status,
                content_type="application/json",
                body=serialize_error(error_data),
            )

    # Build upstream request
    upstream_url = f"{base_url}/v1/messages"
    is_streaming = body_json.get("stream", False)

    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if is_streaming else "application/json",
    }

    if auth_value:
        if provider == "glm":
            headers["x-api-key"] = auth_value
            headers["anthropic-version"] = "2023-06-01"
        else:
            headers["Authorization"] = f"Bearer {auth_value}"
            headers["anthropic-version"] = "2023-06-01"

    return await _forward_request(
        request, upstream_url, headers, body, is_streaming,
        provider, auth_value, credential_store,
    )


async def _forward_request(request, upstream_url, headers, body, is_streaming,
                          provider, auth_value, credential_store):
    """Forward request to upstream and stream response back."""
    try:
        timeout = aiohttp.ClientTimeout(total=300, connect=10)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(
                upstream_url,
                headers=headers,
                data=body,
            ) as upstream_response:
                status_code = upstream_response.status

                if is_streaming and status_code == 200:
                    return await _stream_response(request, upstream_response)

                response_body = await upstream_response.read()

                # Intercept non-2xx errors for normalization
                if should_intercept(status_code):
                    intercept_status, intercept_body = await intercept_upstream_error(
                        status_code, response_body, provider,
                        auth_value, credential_store,
                    )
                    return web.Response(
                        status=intercept_status,
                        content_type="application/json",
                        body=intercept_body,
                    )

                content_type = upstream_response.headers.get(
                    "Content-Type", "application/json"
                )
                return web.Response(
                    status=status_code,
                    content_type=content_type,
                    body=response_body,
                )
    except aiohttp.ClientError as e:
        logger.error("Upstream connection error: %s", e)
        status, error_data = build_anthropic_error(
            UPSTREAM_ERROR,
            message=f"Failed to connect to upstream: {e}",
        )
        return web.Response(
            status=status,
            content_type="application/json",
            body=serialize_error(error_data),
        )
    except Exception as e:
        logger.error("Unexpected proxy error: %s", e)
        status, error_data = build_anthropic_error(
            UPSTREAM_ERROR,
            message=f"Proxy error: {e}",
        )
        return web.Response(
            status=status,
            content_type="application/json",
            body=serialize_error(error_data),
        )


async def _stream_response(request, upstream_response):
    """Stream SSE response bytes from upstream to client."""
    stream = web.StreamResponse()
    stream.set_status(upstream_response.status)
    stream.content_type = upstream_response.headers.get(
        "Content-Type", "text/event-stream"
    )
    stream.headers["Cache-Control"] = "no-cache"
    stream.headers["Connection"] = "keep-alive"

    await stream.prepare(request)

    try:
        async for chunk in upstream_response.content.iter_any():
            await stream.write(chunk)
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        await stream.write_eof()

    return stream
