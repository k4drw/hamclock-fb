#!/bin/bash

# Exit on any error
set -e

# Must be run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Define repository URL
REPO_URL="https://github.com/k4drw/hamclock-fb/raw/refs/heads/master"

# Create cache directory
mkdir -p /var/cache/hamclock
chown root:root /var/cache/hamclock
chmod 755 /var/cache/hamclock

# Install update script
echo "Downloading hamclock-update script..."
wget -qO /usr/local/sbin/hamclock-update "${REPO_URL}/hamclock-update.sh"

# Make update script executable
chmod +x /usr/local/sbin/hamclock-update

# Detect default user (pi, orangepi, etc.)
DEFAULT_USER=""
for user in pi orangepi banana; do
  if id "$user" > /dev/null 2>&1; then
    DEFAULT_USER="$user"
    break
  fi
done

# If no default user found, use first non-root user with UID >= 1000
if [ -z "$DEFAULT_USER" ]; then
  DEFAULT_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 != 65534 {print $1; exit}')
fi

# Fallback to root if no suitable user found
if [ -z "$DEFAULT_USER" ]; then
  DEFAULT_USER="root"
fi

# Create environment file for hamclock service
cat > /etc/default/hamclock << EOF
HAMCLOCK_USER=$DEFAULT_USER
EOF

# Download and install service files
echo "Downloading service files..."
wget -qO /etc/systemd/system/hamclock.service "${REPO_URL}/hamclock.service"
wget -qO /etc/systemd/system/hamclock-update.service "${REPO_URL}/hamclock-update.service"
wget -qO /etc/systemd/system/hamclock-update.timer "${REPO_URL}/hamclock-update.timer"

# Run the update script once to download and install hamclock
echo "Running initial update to download and install hamclock..."
if ! /usr/local/sbin/hamclock-update; then
  echo "Initial update failed. This is normal if HamClock is not yet installed."
  echo "The update will be attempted again during the scheduled update time."
fi

# Reload systemd to recognize new services
systemctl daemon-reload

# Enable and start services
systemctl enable hamclock.service
systemctl enable hamclock-update.timer
systemctl start hamclock-update.timer

echo "Installation complete!"
echo "Services have been installed and enabled."
echo "The update script will run daily between 2:00 AM and 3:00 AM."
