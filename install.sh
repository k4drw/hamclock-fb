#!/bin/bash

# Exit on any error
set -e

# Must be run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Set default branch if not specified
HAMCLOCK_BRANCH=${HAMCLOCK_BRANCH:-master}

# Determine base directory
HAMCLOCK_BASE_DIR=/usr/local
if [ -d /usr/local/bin/.git ] || [ -d /usr/local/sbin/.git ]; then
    HAMCLOCK_BASE_DIR=/usr
fi

# Install required packages
echo "Installing required packages..."
apt update > /dev/null 2>&1
apt install -y util-linux git python3 > /dev/null 2>&1

# Clean up any existing lock files/directories
LOCKFILE="/var/run/hamclock_update.lock"
if [ -e "$LOCKFILE" ]; then
    echo "Removing existing lock file/directory..."
    rm -rf "$LOCKFILE"
fi

# Clone repository to temporary location
TEMP_DIR=$(mktemp -d)
echo "Cloning repository..."
if ! git clone -b "$HAMCLOCK_BRANCH" "https://github.com/k4drw/hamclock-fb.git" "$TEMP_DIR"; then
    echo "Failed to clone repository"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Install update script
echo "Installing hamclock-update script..."
install -m 755 "$TEMP_DIR/hamclock-update.sh" $HAMCLOCK_BASE_DIR/sbin/hamclock-update

# Install web interface
echo "Installing web interface..."
install -m 755 "$TEMP_DIR/update_server.py" $HAMCLOCK_BASE_DIR/sbin/update_server.py
install -m 644 "$TEMP_DIR/update.html" $HAMCLOCK_BASE_DIR/sbin/update.html
install -m 644 "$TEMP_DIR/favicon.png" $HAMCLOCK_BASE_DIR/sbin/favicon.png || true # Optional favicon
install -m 644 "$TEMP_DIR/hamclock-update-web.service" /etc/systemd/system/hamclock-update-web.service

# Install service files
echo "Installing service files..."
install -m 644 "$TEMP_DIR/hamclock.service" /etc/systemd/system/hamclock.service
install -m 644 "$TEMP_DIR/hamclock-update.service" /etc/systemd/system/hamclock-update.service
install -m 644 "$TEMP_DIR/hamclock-update.timer" /etc/systemd/system/hamclock-update.timer

# Clean up
rm -rf "$TEMP_DIR"

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
HAMCLOCK_BRANCH=$HAMCLOCK_BRANCH
HAMCLOCK_BASE_DIR=$HAMCLOCK_BASE_DIR
HAMCLOCK_UPDATE_PORT=8088
HAMCLOCK_STATUS_INTERVAL=5
HAMCLOCK_AUTO_UPDATE=1
EOF

# Run the update script once to download and install hamclock
echo "Running initial update to download and install hamclock..."
if ! $HAMCLOCK_BASE_DIR/sbin/hamclock-update; then
    echo "Initial update failed. This is normal if HamClock is not yet installed."
    echo "The update will be attempted again during the scheduled update time."
fi

# Reload systemd to recognize new services
systemctl daemon-reload

# Enable and start services
systemctl enable hamclock.service
systemctl enable hamclock-update.timer
systemctl enable hamclock-update-web.service
systemctl start hamclock-update.timer
systemctl start hamclock-update-web.service

echo "Installation complete!"
echo "Services have been installed and enabled."
echo "The update script will run daily between 2:00 AM and 3:00 AM."
echo "Web interface is available at http://localhost:8088"
