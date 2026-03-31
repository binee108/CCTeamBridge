"""Configuration loading for ccbridge-proxy."""
import os
import yaml


DEFAULTS = {
    "port": 8317,
    "host": "127.0.0.1",
    "glm": {
        "base_url": "https://api.z.ai/api/anthropic",
        "api_keys": [],
    },
    "codex": {
        "base_url": "https://api.anthropic.com",
    },
    "claude": {
        "base_url": "https://api.anthropic.com",
    },
    "kimi": {
        "base_url": "https://api.anthropic.com",
    },
    "credential_dir": "~/.ccbridge/credentials",
    "feature_flags": {
        "proxy_enabled": True,
    },
}

MODEL_PROVIDER_MAP = {
    "glm-": "glm",
    "gpt-": "codex",
    "claude-": "claude",
    "kimi-": "kimi",
}


def load_config(path):
    """Load configuration from YAML file."""
    with open(path) as f:
        data = yaml.safe_load(f) or {}

    config = _deep_merge(DEFAULTS.copy(), data)

    credential_dir = config.get("credential_dir", DEFAULTS["credential_dir"])
    config["credential_dir"] = os.path.expanduser(credential_dir)

    _apply_env_overrides(config)

    return config


def get_provider_for_model(config, model_name):
    """Determine which provider handles a given model name."""
    if not model_name:
        return None
    model_lower = model_name.lower()
    for prefix, provider in MODEL_PROVIDER_MAP.items():
        if model_lower.startswith(prefix):
            return provider
    return None


def get_provider_config(config, provider):
    """Get the config section for a provider."""
    return config.get(provider, {})  # noqa: B019


def _deep_merge(base, override):
    """Merge override into base dict recursively."""
    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _apply_env_overrides(config):
    """Apply environment variable overrides."""
    if os.environ.get("CCBRIDGE_PROXY_ENABLED") is not None:
        val = os.environ.get("CCBRIDGE_PROXY_ENABLED")
        config["feature_flags"]["proxy_enabled"] = val in ("1", "true", "yes")
    if os.environ.get("CCBRIDGE_PORT"):
        config["port"] = int(os.environ["CCBRIDGE_PORT"])
    if os.environ.get("CCBRIDGE_HOST"):
        config["host"] = os.environ["CCBRIDGE_HOST"]
