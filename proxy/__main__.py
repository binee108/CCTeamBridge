"""Entry point for running the proxy as `python -m proxy`."""
import logging
import os

from aiohttp import web

from .server import create_app
from .config import load_config, DEFAULTS

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("ccbridge-proxy")


def main():
    config_dir = os.path.expanduser("~/.ccbridge")
    os.makedirs(config_dir, exist_ok=True)

    config = DEFAULTS.copy()
    config_path = os.path.join(config_dir, "config.yaml")
    if os.path.exists(config_path):
        try:
            config = load_config(config_path)
        except Exception as e:
            logger.warning("Failed to load config: %s", e)

    # Env overrides
    port_env = os.environ.get("CCBRIDGE_PORT")
    port = int(port_env) if port_env else config.get("port", 8317)
    host = os.environ.get("CCBRIDGE_HOST") or config.get("host", "127.0.0.1")

    app = create_app(config)

    # Write PID file
    pid_path = os.path.join(config_dir, "proxy.pid")
    with open(pid_path, "w") as f:
        f.write(f"{os.getpid()}\n2.0.0\n")

    async def _cleanup(app_instance):
        try:
            os.remove(pid_path)
        except OSError:
            pass

    app.on_shutdown.append(_cleanup)

    logger.info("ccbridge-proxy starting on %s:%d", host, port)

    try:
        web.run_app(app, host=host, port=port, print=None)
    except KeyboardInterrupt:
        pass
    finally:
        logger.info("ccbridge-proxy stopped")
        try:
            os.remove(pid_path)
        except OSError:
            pass


if __name__ == "__main__":
    main()
