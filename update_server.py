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

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("hamclock-update-web")


def load_config():
    """Load configuration from /etc/default/hamclock.

    Returns:
        dict: Configuration values with defaults for missing settings.
    """
    default_config = {"HAMCLOCK_UPDATE_PORT": "8088", "HAMCLOCK_BRANCH": "master"}

    try:
        with open("/etc/default/hamclock", "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    default_config[key] = value.strip("\"'")
    except FileNotFoundError:
        logger.warning("Config file not found, using defaults")

    return default_config


# Load configuration
CONFIG = load_config()
PORT = int(os.getenv("HAMCLOCK_UPDATE_PORT", CONFIG["HAMCLOCK_UPDATE_PORT"]))
UPDATE_LOG = "/var/log/hamclock-update.log"
HTML_PATH = "/usr/local/sbin/update.html"


def get_update_status():
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


def get_log_tail(lines=50):
    """Get the last N lines of the update log.

    Args:
        lines (int): Number of lines to return from the end of the log.

    Returns:
        str: Last N lines of the log or error message.
    """
    try:
        with open(UPDATE_LOG, "r", encoding="utf-8") as f:
            return "".join(f.readlines()[-lines:])
    except FileNotFoundError:
        return "No log file found"


def get_hamclock_info():
    """Get HamClock version and build info.

    Returns:
        str: Version and build information or error message.
    """
    try:
        with subprocess.Popen(
            ["/usr/local/bin/hamclock", "-v"],
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


def get_git_info():
    """Get git repository information.

    Returns:
        str: Git commit info and branch or error message.
    """
    try:
        # Get current branch
        with subprocess.Popen(
            ["git", "-C", "/var/cache/hamclock/repo", "branch", "--show-current"],
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
                "/var/cache/hamclock/repo",
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


def run_update():
    """Run the update script.

    Returns:
        bool: True if update started successfully, error message otherwise.
    """
    try:
        # Check current version
        with subprocess.Popen(
            ["/usr/local/bin/hamclock", "-v"],
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
        with subprocess.Popen(
            ["/usr/local/sbin/hamclock-update"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True,
        ) as process:
            if process.poll() is None:  # Check if process started successfully
                logger.info("Update process started")
                return True
            return f"Update process failed to start: {process.returncode}"
    except subprocess.SubprocessError as e:
        return str(e)


class UpdateHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler for the update web interface."""

    def do_GET(self):
        """Handle GET requests for the web interface.

        Routes:
            /: Serves the main HTML interface
            /status: Returns JSON with current status
            /update: Triggers an update and returns result
            /favicon.png: Serves the favicon
            /stream: Streams update output
        """
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-type", "text/html")
            self.end_headers()

            with open(HTML_PATH, "r", encoding="utf-8") as f:
                html = f.read()
            self.wfile.write(html.encode())

        elif self.path == "/favicon.png":
            self.send_response(200)
            self.send_header("Content-type", "image/png")
            self.end_headers()
            with open("/usr/local/sbin/favicon.png", "rb") as f:
                self.wfile.write(f.read())

        elif self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            try:
                with subprocess.Popen(
                    ["/usr/local/sbin/hamclock-update"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    universal_newlines=True,
                ) as process:
                    while True:
                        line = process.stdout.readline()
                        if not line and process.poll() is not None:
                            break
                        if line:
                            # Ensure each line ends with a newline
                            if not line.endswith("\n"):
                                line += "\n"
                            self.wfile.write(f"data: {line}\n\n".encode())
                            self.wfile.flush()
            except (subprocess.SubprocessError, IOError) as e:
                self.wfile.write(f"data: Error: {str(e)}\n\n".encode())
                self.wfile.flush()

        elif self.path == "/status":
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

        elif self.path == "/update":
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()

            result = run_update()
            self.wfile.write(json.dumps({"success": result}).encode())

        else:
            self.send_error(404)


def run_server():
    """Start the web server on the configured port."""
    with http.server.HTTPServer(("", PORT), UpdateHandler) as httpd:
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
        sys.exit(1)

    run_server()
