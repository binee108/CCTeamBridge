"""Health check and /v1/models endpoint."""
import time


def build_models_response(config, start_time):
    """Build Anthropic-format /v1/models response."""
    models = []

    glm_keys = config.get("glm", {}).get("api_keys", [])
    if glm_keys:
        models.extend([
            {"id": "glm-5.1", "object": "model", "owned_by": "glm"},
            {"id": "glm-5-turbo", "object": "model", "owned_by": "glm"},
            {"id": "glm-5", "object": "model", "owned_by": "glm"},
            {"id": "glm-4.7", "object": "model", "owned_by": "glm"},
        ])

    cred_dir = config.get("credential_dir", "")
    import os
    if os.path.isdir(cred_dir):
        for fname in os.listdir(cred_dir):
            if fname.startswith("codex-") and fname.endswith(".json"):
                models.extend([
                    {"id": "gpt-5.3-codex", "object": "model", "owned_by": "codex"},
                    {"id": "gpt-5.3-codex-spark", "object": "model", "owned_by": "codex"},
                ])
                break
        for fname in os.listdir(cred_dir):
            if fname.startswith("claude-") and fname.endswith(".json"):
                models.extend([
                    {"id": "claude-opus-4-6", "object": "model", "owned_by": "anthropic"},
                    {"id": "claude-sonnet-4-6", "object": "model", "owned_by": "anthropic"},
                ])
                break
        for fname in os.listdir(cred_dir):
            if fname.startswith("kimi-") and fname.endswith(".json"):
                models.append({"id": "kimi-latest", "object": "model", "owned_by": "kimi"})
                break

    uptime = time.time() - start_time

    return {
        "object": "list",
        "data": models,
        "meta": {
            "proxy_version": "2.0.0",
            "uptime_seconds": round(uptime, 1),
        },
    }


def build_health_json(start_time):
    """Build minimal health response."""
    return {
        "status": "ok",
        "uptime_seconds": round(time.time() - start_time, 1),
    }
