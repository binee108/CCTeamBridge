"""Process lifecycle management for ccbridge-proxy.

Handles PID file management, health-based liveness detection,
stale PID cleanup, and graceful shutdown.
"""
import os
import sys
import signal
import time
import logging
import subprocess

logger = logging.getLogger("ccbridge-proxy")

PID_PATH = os.path.expanduser("~/.ccbridge/proxy.pid")
HEALTH_URL = "http://127.0.0.1:8317/v1/models"
HEALTH_TIMEOUT = 2
STARTUP_TIMEOUT = 10


def read_pid():
    """Read PID from pidfile. Returns None if file doesn't exist or is invalid."""
    if not os.path.exists(PID_PATH):
        return None
    try:
        with open(PID_PATH) as f:
            content = f.read().strip()
            if content:
                return int(content.split("\n")[0])
    except (ValueError, OSError):
        pass
    return None


def write_pid():
    """Write current PID to pidfile."""
    pid_dir = os.path.dirname(PID_PATH)
    os.makedirs(pid_dir, exist_ok=True)
    with open(PID_PATH, "w") as f:
        f.write(f"{os.getpid()}\n2.0.0\n")


def remove_pid():
    """Remove pidfile."""
    try:
        os.remove(PID_PATH)
    except OSError:
        pass


def is_process_alive(pid):
    """Check if a process with given PID is alive."""
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Process exists but we can't signal it


def check_health(timeout=HEALTH_TIMEOUT):
    """Check if proxy is healthy via HTTP health endpoint."""
    try:
        import urllib.request
        req = urllib.request.Request(HEALTH_URL)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def is_proxy_running():
    """Check if proxy is running and healthy.

    Returns True if proxy PID exists, process is alive, and health check passes.
    Cleans up stale PID files.
    """
    pid = read_pid()
    if pid is None:
        return False

    if not is_process_alive(pid):
        logger.info("Stale PID file found (pid=%d), cleaning up", pid)
        remove_pid()
        return False

    return check_health()


def stop_proxy():
    """Stop a running proxy process gracefully."""
    pid = read_pid()
    if pid is None:
        return True

    if not is_process_alive(pid):
        remove_pid()
        return True

    logger.info("Stopping proxy (pid=%d)", pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        remove_pid()
        return True

    # Wait for process to exit (max 10s)
    for _ in range(10):
        time.sleep(1)
        if not is_process_alive(pid):
            remove_pid()
            return True

    # Force kill
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    remove_pid()
    return True


def start_proxy(config):
    """Start the proxy as a background process.

    Returns True if proxy started successfully.
    """
    if is_proxy_running():
        return True

    # Clean up stale PID
    remove_pid()

    # Determine python path
    venv_python = os.path.expanduser("~/.ccbridge/venv/bin/python3")
    python_path = venv_python if os.path.exists(venv_python) else sys.executable

    proxy_dir = os.path.expanduser("~/.ccbridge/proxy")
    if not os.path.isdir(proxy_dir):
        logger.error("Proxy directory not found: %s", proxy_dir)
        return False

    cmd = [python_path, "-m", "proxy"]
    log_path = os.path.expanduser("~/.ccbridge/logs/proxy.log")
    os.makedirs(os.path.dirname(log_path), exist_ok=True)

    try:
        with open(log_path, "a") as log_f:
            subprocess.Popen(
                cmd,
                stdout=log_f,
                stderr=log_f,
                cwd=proxy_dir,
                start_new_session=True,
            )
    except Exception as e:
        logger.error("Failed to start proxy: %s", e)
        return False

    # Wait for health check
    for _ in range(STARTUP_TIMEOUT):
        time.sleep(1)
        if check_health():
            logger.info("Proxy started successfully")
            return True

    logger.error("Proxy failed to start within %ds", STARTUP_TIMEOUT)
    return False


def ensure_proxy(config):
    """Ensure proxy is running, starting if necessary.

    Returns True if proxy is available.
    """
    if is_proxy_running():
        return True
    return start_proxy(config)
