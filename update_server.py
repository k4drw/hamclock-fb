#!/usr/bin/env python3
"""HamClock Update Web Server.

A simple web server that provides a web interface for managing HamClock updates.
It allows checking update status, viewing logs, and triggering updates.
"""

import http.server
import json
import logging
import os
import subprocess
import sys
from datetime import datetime
from typing import Dict, Union
import shutil

try:
    from http.server import ThreadingHTTPServer
except ImportError:
    from http.server import HTTPServer as ThreadingHTTPServer

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("hamclock-update-web")


def load_config() -> Dict[str, str]:
    """Load configuration from /etc/default/hamclock.

    Returns:
        Dict[str, str]: Configuration values with defaults for missing settings.
    """
    default_config = {
        "HAMCLOCK_UPDATE_PORT": "8088",
        "HAMCLOCK_BRANCH": "master",
        "HAMCLOCK_STATUS_INTERVAL": "30",  # seconds
    }

    try:
        if os.path.exists("/etc/default/hamclock"):
            with open("/etc/default/hamclock", "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        try:
                            key, value = line.split("=", 1)
                            default_config[key] = value.strip("\"'")
                        except ValueError:
                            continue
    except OSError as e:
        logger.warning(f"Error reading config file: {e}")

    return default_config


# Load configuration
CONFIG = load_config()
PORT = int(os.getenv("HAMCLOCK_UPDATE_PORT", CONFIG["HAMCLOCK_UPDATE_PORT"]))
UPDATE_LOG = "/var/log/hamclock-update.log"
HTML_PATH = "/usr/local/sbin/update.html"
STATUS_UPDATE_INTERVAL = int(
    os.getenv("HAMCLOCK_STATUS_INTERVAL", CONFIG["HAMCLOCK_STATUS_INTERVAL"])
)  # seconds


def get_update_status() -> str:
    """Get the status of the update timer and service.

    Returns:
        str: Status output from systemctl or error message.
    """
    try:
        timer_status = subprocess.check_output(
            ["systemctl", "status", "hamclock-update.timer"], stderr=subprocess.STDOUT
        ).decode()
        return timer_status
    except subprocess.CalledProcessError as e:
        return f"Error getting status: {e.output.decode()}"
    except FileNotFoundError:
        return "Error: systemctl not found"


def get_log_tail(lines: int = 50) -> str:
    """Get the last N lines of the update log.

    Args:
        lines (int): Number of lines to return from the end of the log.

    Returns:
        str: Last N lines of the log or error message.
    """
    try:
        if not os.path.exists(UPDATE_LOG):
            return "No log file found"

        with open(UPDATE_LOG, "r", encoding="utf-8") as f:
            return "".join(f.readlines()[-lines:])
    except OSError as e:
        return f"Error reading log: {str(e)}"


def get_hamclock_info() -> str:
    """Get HamClock version and build info.

    Returns:
        str: Version and build information or error message.
    """
    try:
        hamclock_path = shutil.which("hamclock")
        if not hamclock_path:
            if os.path.exists("/usr/local/bin/hamclock"):
                hamclock_path = "/usr/local/bin/hamclock"
            elif os.path.exists("/usr/bin/hamclock"):
                hamclock_path = "/usr/bin/hamclock"
            else:
                return "HamClock binary not found"

        with subprocess.Popen(
            [hamclock_path, "-v"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            _stdout, stderr = process.communicate()
            if process.returncode == 0:
                return stderr.strip()
            return f"Error: {stderr.strip()}"
    except subprocess.SubprocessError as e:
        return f"Error getting version: {str(e)}"


def get_git_info() -> str:
    """Get git repository information.

    Returns:
        str: Git commit info and branch or error message.
    """
    repo_path = "/var/cache/hamclock/repo"
    if not os.path.exists(repo_path):
        return "Repository not found"

    try:
        # Get current branch
        with subprocess.Popen(
            ["git", "-C", repo_path, "branch", "--show-current"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            branch_stdout, branch_stderr = process.communicate()
            if process.returncode != 0:
                return f"Error: {branch_stderr.strip()}"
            branch = branch_stdout.strip()

        # Get latest commit info
        with subprocess.Popen(
            [
                "git",
                "-C",
                repo_path,
                "log",
                "-1",
                "--format=%h %ad",
                "--date=short",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            commit_stdout, commit_stderr = process.communicate()
            if process.returncode == 0:
                return f"{branch} ({commit_stdout.strip()})"
            return f"Error: {commit_stderr.strip()}"
    except subprocess.SubprocessError as e:
        return f"Error getting git info: {str(e)}"
    except FileNotFoundError:
        return "Error: git command not found"


def run_update() -> Union[bool, str]:
    """Run the update script.

    Returns:
        Union[bool, str]: True if update started successfully, error message otherwise.
    """
    try:
        update_script = "/usr/local/sbin/hamclock-update"
        if not os.path.exists(update_script):
            return "Update script not found"

        # Check current version
        hamclock_path = shutil.which("hamclock")
        if not hamclock_path:
            if os.path.exists("/usr/local/bin/hamclock"):
                hamclock_path = "/usr/local/bin/hamclock"
            elif os.path.exists("/usr/bin/hamclock"):
                hamclock_path = "/usr/bin/hamclock"
            else:
                # Should not happen if we are running update, but safe default
                hamclock_path = "/usr/local/bin/hamclock"

        with subprocess.Popen(
            [hamclock_path, "-v"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ) as process:
            _stdout, stderr = process.communicate()
            if process.returncode == 0:
                logger.info(f"Current version: {stderr.strip()}")
            else:
                logger.error(f"Error getting version: {stderr.strip()}")

        # Run update in background with output capture
        # We use Popen to start it and let it run
        # pylint: disable=consider-using-with
        process = subprocess.Popen(
            [update_script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            close_fds=True,
        )

        if process.poll() is None:  # Check if process started successfully
            logger.info(f"Update process started with PID {process.pid}")
            return True
        return f"Update process failed to start: {process.returncode}"

    except subprocess.SubprocessError as e:
        return str(e)


class UpdateHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler for the update web interface."""

    def do_GET(self) -> None:
        """Handle GET requests for the web interface."""
        if self.path == "/":
            self._handle_root()
        elif self.path == "/favicon.png":
            self._handle_favicon()
        elif self.path == "/stream":
            self._handle_stream()
        elif self.path == "/status":
            self._handle_status()
        elif self.path == "/update":
            self._handle_update()
        elif self.path == "/health":
            self._handle_health()
        else:
            self.send_error(404)

    def _handle_root(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()

        try:
            if os.path.exists(HTML_PATH):
                with open(HTML_PATH, "r", encoding="utf-8") as f:
                    html = f.read()
                # Replace the interval placeholder with the actual value
                html = html.replace(
                    "${STATUS_UPDATE_INTERVAL}", str(STATUS_UPDATE_INTERVAL)
                )
                self.wfile.write(html.encode())
            else:
                self.wfile.write(b"<h1>Error: HTML file not found</h1>")
        except OSError as e:
            logger.error(f"Failed to read HTML file: {e}")
            self.send_error(500, "Failed to read HTML file")

    def _handle_favicon(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "image/png")
        self.end_headers()
        favicon_path = "/usr/local/sbin/favicon.png"
        if os.path.exists(favicon_path):
            with open(favicon_path, "rb") as f:
                self.wfile.write(f.read())
        else:
            self.send_error(404, "Favicon not found")

    def _handle_stream(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        try:
            update_script = "/usr/local/sbin/hamclock-update"
            if not os.path.exists(update_script):
                self.wfile.write(b"data: Error: Update script not found\n\n")
                return

            with subprocess.Popen(
                [update_script],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                universal_newlines=True,
            ) as process:
                while True:
                    if process.stdout:
                        line = process.stdout.readline()
                        if not line and process.poll() is not None:
                            break
                        if line:
                            # Ensure each line ends with a newline
                            if not line.endswith("\n"):
                                line += "\n"
                            self.wfile.write(f"data: {line}\n\n".encode())
                            self.wfile.flush()
        except (subprocess.SubprocessError, OSError) as e:
            try:
                self.wfile.write(f"data: Error: {str(e)}\n\n".encode())
                self.wfile.flush()
            except OSError:
                pass  # Client likely disconnected

    def _handle_status(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()

        status = {
            "timer_status": get_update_status(),
            "log_tail": get_log_tail(),
            "hamclock_info": get_hamclock_info(),
            "git_info": get_git_info(),
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        }
        self.wfile.write(json.dumps(status).encode())

    def _handle_update(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()

        result = run_update()
        self.wfile.write(json.dumps({"success": result}).encode())

    def _handle_health(self) -> None:
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"status": "healthy"}).encode())


def run_server() -> None:
    """Start the web server on the configured port."""
    # Allow binding to all interfaces as per user request/default
    server_address = ("", PORT)

    # Use ThreadingHTTPServer if available (Python 3.7+) for better responsiveness
    # but fallback to HTTPServer if needed (though 3.7+ is standard now)
    # Handler logic handles serving, server_class is now ThreadingHTTPServer
    # (or fallback) from generic import
    server_class = ThreadingHTTPServer

    with server_class(server_address, UpdateHandler) as httpd:
        logger.info(f"Serving at port {PORT}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            logger.info("Server stopped by user")
            sys.exit(0)


if __name__ == "__main__":
    # Ensure we're running as root
    if os.geteuid() != 0:
        logger.error("This script must be run as root")
        print("Error: This script must be run as root", file=sys.stderr)
        sys.exit(1)

    run_server()
