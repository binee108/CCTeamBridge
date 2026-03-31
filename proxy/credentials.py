"""Credential loading, migration, and multi-key rotation for ccbridge-proxy."""
import json
import os
import time
import logging
from datetime import datetime, timezone

logger = logging.getLogger("ccbridge-proxy")

COOLDOWN_SECONDS = 3600  # 1 hour


class CredentialStore:
    """Manages credentials for all providers with fill-first rotation."""

    def __init__(self, config):
        self.config = config
        self.glm_keys = []
        self.glm_key_index = 0
        self.glm_key_exhausted = {}  # key -> timestamp

        self.oauth_credentials = {
            "codex": [],
            "claude": [],
            "kimi": [],
        }
        self.oauth_credential_index = {
            "codex": 0,
            "claude": 0,
            "kimi": 0,
        }
        self.oauth_exhausted = {
            "codex": {},
            "claude": {},
            "kimi": {},
        }

    def load(self):
        """Load all credentials from disk."""
        self._load_glm_keys()
        self._load_oauth_credentials()
        logger.info(
            "Loaded credentials: GLM %d keys, Codex %d, Claude %d, Kimi %d",
            len(self.glm_keys),
            len(self.oauth_credentials["codex"]),
            len(self.oauth_credentials["claude"]),
            len(self.oauth_credentials["kimi"]),
        )

    def get_auth(self, provider):
        """Get the current auth value for a provider (fill-first strategy)."""
        if provider == "glm":
            return self._get_glm_auth()
        return self._get_oauth_auth(provider)

    def mark_exhausted(self, provider, auth_value):
        """Mark a credential as exhausted (quota exceeded)."""
        if provider == "glm":
            self._mark_glm_exhausted(auth_value)
        else:
            self._mark_oauth_exhausted(provider, auth_value)

    def _load_glm_keys(self):
        """Load GLM API keys from config."""
        glm_config = self.config.get("glm", {})
        self.glm_keys = list(glm_config.get("api_keys", []))
        self.glm_key_index = 0
        self.glm_key_exhausted = {}

    def _load_oauth_credentials(self):
        """Load OAuth credentials from credential directory."""
        cred_dir = self.config.get("credential_dir", "")
        if not os.path.isdir(cred_dir):
            return

        for provider in ("codex", "claude", "kimi"):
            creds = []
            for fname in sorted(os.listdir(cred_dir)):
                if fname.startswith(f"{provider}-") and fname.endswith(".json"):
                    fpath = os.path.join(cred_dir, fname)
                    try:
                        cred = self._load_credential_file(fpath)
                        if cred and not cred.get("disabled", False):
                            creds.append(cred)
                    except Exception as e:
                        logger.warning("Failed to load credential %s: %s", fname, e)

            # Sort by priority descending
            creds.sort(
                key=lambda c: int(c.get("attributes", {}).get("priority", "0")),
                reverse=True,
            )
            self.oauth_credentials[provider] = creds

    def _load_credential_file(self, path):
        """Load a single credential JSON file, preserving all fields."""
        with open(path) as f:
            return json.load(f)

    def _get_glm_auth(self):
        """Get current GLM API key (fill-first)."""
        now = time.time()
        # Try current index, then advance
        for _ in range(len(self.glm_keys)):
            if self.glm_key_index >= len(self.glm_keys):
                self.glm_key_index = 0

            key = self.glm_keys[self.glm_key_index]
            exhausted_at = self.glm_key_exhausted.get(key, 0)

            if now - exhausted_at > COOLDOWN_SECONDS:
                return key

            self.glm_key_index += 1

        # All exhausted, try first anyway
        if self.glm_keys:
            return self.glm_keys[0]
        return None

    def _get_oauth_auth(self, provider):
        """Get current OAuth access_token (fill-first)."""
        now = time.time()
        creds = self.oauth_credentials.get(provider, [])
        exhausted = self.oauth_exhausted.get(provider, {})

        for i, cred in enumerate(creds):
            access_token = cred.get("access_token", "")
            exhausted_at = exhausted.get(access_token, 0)

            if now - exhausted_at > COOLDOWN_SECONDS:
                self.oauth_credential_index[provider] = i
                return access_token

        # All exhausted, try first anyway
        if creds:
            return creds[0].get("access_token", "")
        return None

    def _mark_glm_exhausted(self, key):
        """Mark a GLM API key as exhausted."""
        self.glm_key_exhausted[key] = time.time()
        self.glm_key_index = (self.glm_key_index + 1) % max(len(self.glm_keys), 1)
        logger.info("GLM key exhausted, switching to index %d", self.glm_key_index)

    def _mark_oauth_exhausted(self, provider, auth_value):
        """Mark an OAuth credential as exhausted."""
        self.oauth_exhausted.setdefault(provider, {})[auth_value] = time.time()
        idx = self.oauth_credential_index.get(provider, 0)
        count = len(self.oauth_credentials.get(provider, []))
        self.oauth_credential_index[provider] = (idx + 1) % max(count, 1)
        logger.info("%s credential exhausted, switching", provider)


def migrate_credentials(config):
    """One-time migration from ~/.cli-proxy-api/ to ~/.ccbridge/credentials/."""
    cred_dir = config.get("credential_dir", "")
    if not cred_dir:
        return

    marker = os.path.join(os.path.dirname(cred_dir), ".migrated-from-cliproxyapi")
    if os.path.exists(marker):
        return

    source_dir = os.path.expanduser("~/.cli-proxy-api")
    if not os.path.isdir(source_dir):
        return

    os.makedirs(cred_dir, exist_ok=True)

    count = 0
    for fname in os.listdir(source_dir):
        if fname.endswith(".json") and (
            fname.startswith("codex-")
            or fname.startswith("claude-")
            or fname.startswith("kimi-")
        ):
            src = os.path.join(source_dir, fname)
            dst = os.path.join(cred_dir, fname)
            if not os.path.exists(dst):
                with open(src) as f:
                    data = json.load(f)
                # Round-trip to preserve all fields
                _atomic_write_json(dst, data)
                count += 1

    if count > 0:
        with open(marker, "w") as f:
            f.write(f"migrated {count} files at {datetime.now(timezone.utc).isoformat()}")
        logger.info("Migrated %d credential files to %s", count, cred_dir)


def _atomic_write_json(path, data):
    """Write JSON atomically using temp file + rename."""
    import tempfile

    dir_name = os.path.dirname(path)
    fd, tmp_path = tempfile.mkstemp(dir=dir_name, suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
