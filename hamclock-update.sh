#!/bin/bash
# error handling and logging
set -euo pipefail

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to stdout
    echo "$timestamp $(basename "$0"): $message"

    # Log to system logger
    logger -p "user.$level" -t "$(basename "$0")" "$message"

    # Log to file
    echo "$timestamp $(basename "$0"): $message" >> /var/log/hamclock-update.log
}

# Ensure log directory exists
mkdir -p /var/log

# Ensure flock is available, install if needed
if ! command -v flock > /dev/null 2>&1; then
    log info "flock not found, installing util-linux..."
    apt-get update > /dev/null 2>&1
    apt-get install -y util-linux > /dev/null 2>&1
    if ! command -v flock > /dev/null 2>&1; then
        log err "Failed to install util-linux"
        exit 1
    fi
    log info "util-linux installed successfully"
fi

# Parse command line arguments
FORCE_UPDATE=0
UPDATED=0
TEST_MODE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE_UPDATE=1
            ;;
        --updated)
            UPDATED=1
            ;;
        --test)
            TEST_MODE=1
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $(basename "$0") [--force] [--updated] [--test]" >&2
            exit 1
            ;;
    esac
    shift
done

log info "Update service started at $(date '+%Y-%m-%d %H:%M:%S')"

# Add lock file to prevent concurrent runs
LOCKFILE="/var/run/hamclock_update.lock"

# Check if another instance is actually running (excluding our parent if we're a self-update)
if pgrep -f "^/usr/local/sbin/hamclock-update" | grep -v "$$" | grep -v "$PPID" > /dev/null; then
    log warning "Another instance is already running"
    exit 1
fi

# Clean up old lock directory if it exists
if [ -d "$LOCKFILE" ]; then
    log info "Removing old lock directory"
    rm -rf "$LOCKFILE"
fi

if ! exec 200> "$LOCKFILE"; then
    log err "Failed to create lock file $LOCKFILE"
    exit 1
fi

if ! flock -n 200; then
    log warning "Another instance is already running"
    exit 1
fi

# Define cleanup function and trap
cleanup() {
    local exit_code=$?
    log info "Cleaning up (exit code: $exit_code)"
    flock -u 200
    exit "$exit_code"
}
trap 'cleanup' EXIT

# Check for updates to the wrapper scripts
if [ "$TEST_MODE" -eq 0 ]; then
    REPO_URL="https://github.com/k4drw/hamclock-fb"
    INSTALL_DIR="/usr/local"
    REPO_DIR="/var/cache/hamclock/repo"

    # Load branch from config
    if [ -f /etc/default/hamclock ]; then
        # shellcheck source=/dev/null
        . /etc/default/hamclock
    fi
    HAMCLOCK_BRANCH=${HAMCLOCK_BRANCH:-master}

    log info "Checking for wrapper script updates..."

    # Ensure git is available
    if ! command -v git > /dev/null 2>&1; then
        log info "git not found, installing..."
        apt-get update > /dev/null 2>&1
        apt-get install -y git > /dev/null 2>&1
        if ! command -v git > /dev/null 2>&1; then
            log err "Failed to install git"
            exit 1
        fi
        log info "git installed successfully"
    fi

    # Clone or update repo
    if [ ! -d "$REPO_DIR" ]; then
        log info "Cloning repository (branch: $HAMCLOCK_BRANCH)..."
        if ! git clone -b "$HAMCLOCK_BRANCH" "$REPO_URL" "$REPO_DIR" > /dev/null 2>&1; then
            log err "Failed to clone repository"
            exit 1
        fi
    else
        log info "Updating repository (branch: $HAMCLOCK_BRANCH)..."
        cd "$REPO_DIR"
        if ! git fetch origin > /dev/null 2>&1 || ! git reset --hard "origin/$HAMCLOCK_BRANCH" > /dev/null 2>&1; then
            log err "Failed to update repository"
            exit 1
        fi
    fi

    # Check if any of the files differ from the installed versions
    UPDATE_NEEDED=false

    # Check hamclock-update.sh
    if [ -f "$REPO_DIR/hamclock-update.sh" ] && ! cmp -s "$REPO_DIR/hamclock-update.sh" "$INSTALL_DIR/sbin/hamclock-update"; then
        UPDATE_NEEDED=true
        log info "Update script has changed"
    fi

    # Check service files
    for service_file in hamclock.service hamclock-update.service hamclock-update.timer hamclock-update-web.service; do
        if [ -f "$REPO_DIR/$service_file" ] && ! cmp -s "$REPO_DIR/$service_file" "/etc/systemd/system/$service_file"; then
            UPDATE_NEEDED=true
            log info "Service file $service_file has changed"
        fi
    done

    # Check web interface files
    for web_file in update_server.py update.html; do
        if [ -f "$REPO_DIR/$web_file" ] && ! cmp -s "$REPO_DIR/$web_file" "/usr/local/sbin/$web_file"; then
            UPDATE_NEEDED=true
            log info "Web interface file $web_file has changed"
        fi
    done

    # Update files if needed
    if $UPDATE_NEEDED; then
        # Update the scripts
        install -m 755 "$REPO_DIR/hamclock-update.sh" "$INSTALL_DIR/sbin/hamclock-update"
        install -m 644 "$REPO_DIR/hamclock.service" /etc/systemd/system/
        install -m 644 "$REPO_DIR/hamclock-update.service" /etc/systemd/system/
        install -m 644 "$REPO_DIR/hamclock-update.timer" /etc/systemd/system/
        install -m 644 "$REPO_DIR/hamclock-update-web.service" /etc/systemd/system/
        install -m 755 "$REPO_DIR/update_server.py" /usr/local/sbin/
        install -m 644 "$REPO_DIR/update.html" /usr/local/sbin/
        systemctl daemon-reload
        log info "Wrapper scripts updated"

        # Enable services
        systemctl enable hamclock.service
        systemctl enable hamclock-update.timer
        systemctl enable hamclock-update-web.service
        systemctl start hamclock-update.timer
        systemctl start hamclock-update-web.service

        # Exit and let the new version take over
        if [ "$UPDATED" -eq 0 ]; then
            "$INSTALL_DIR/sbin/hamclock-update" --updated &
            exit 0
        fi
    else
        log info "No updates to wrapper scripts needed"
    fi
else
    log info "Test mode: Skipping wrapper script updates"
fi

# Ensure cache directory exists
if [ ! -d /var/cache/hamclock ]; then
    log info "Creating cache directory"
    mkdir -p /var/cache/hamclock
fi

cd /var/cache/hamclock || exit 1

# Initialize hamclock update flag
HCUPDATE=0

if [ ! -f /var/cache/hamclock/ESPHamClock.tgz ]; then
    touch --date="$(date -d 'last year' +'%Y-%m-%d %H:%M:%S')" /var/cache/hamclock/ESPHamClock.tgz
fi

# Save MD5 to /tmp/md5
md5sum ESPHamClock.tgz > /tmp/md5

# Download only if newer
curl --output ESPHamClock.tgz -Rs -z ESPHamClock.tgz https://www.clearskyinstitute.com/ham/HamClock/ESPHamClock.tgz

# Check if the MD5 matches
if [ "$FORCE_UPDATE" -eq 1 ]; then
    log info "Force update requested"
    HCUPDATE=1
elif md5sum --quiet -c /tmp/md5; then
    log info "No update to HamClock"
    HCUPDATE=0
else
    HCUPDATE=1
fi
rm /tmp/md5

# Update HamClock if needed or forced
if [ "$HCUPDATE" -eq 1 ]; then
    # Extract hamclock
    tar -xf ESPHamClock.tgz
    VER=$(grep hc_version ESPHamClock/version.cpp | sed 's/.*"\([0-9]*\.[0-9]*\)".*$/\1/')
    cp ESPHamClock.tgz "ESPHamClock-${VER}.tgz"
    cd ESPHamClock

    # Get current framebuffer info
    FB_INFO=$(fbset -i | grep geometry)
    FB_WIDTH=$(echo "$FB_INFO" | awk '{print $2}')
    FB_HEIGHT=$(echo "$FB_INFO" | awk '{print $3}')
    FB_DEPTH=$(echo "$FB_INFO" | awk '{print $6}')

    # Determine closest resolution that fits within screen dimensions
    if [ "$FB_WIDTH" -ge 3200 ] && [ "$FB_HEIGHT" -ge 1920 ]; then
        RESOLUTION="hamclock-fb0-3200x1920"
    elif [ "$FB_WIDTH" -ge 2400 ] && [ "$FB_HEIGHT" -ge 1440 ]; then
        RESOLUTION="hamclock-fb0-2400x1440"
    elif [ "$FB_WIDTH" -ge 1600 ] && [ "$FB_HEIGHT" -ge 960 ]; then
        RESOLUTION="hamclock-fb0-1600x960"
    else
        RESOLUTION="hamclock-fb0-800x480"
    fi

    # Set framebuffer depth based on actual hardware
    if [ "$FB_DEPTH" -eq 32 ]; then
        log info "Configuring for 32-bit framebuffer"
        sed -i -re 's/(#define _16BIT_FB)/\/\/\1/' ArduinoLib/Adafruit_RA8875.h
    fi

    # Don't show the wifi setup on FB0
    sed -i '/#if defined (_USE_FB0)/,/#endif/c\#define _WIFI_NEVER' setup.cpp

    # Make hamclock with detected resolution
    log info "Building with resolution: $RESOLUTION"

    # Determine optimal number of make jobs (number of cores minus 1, minimum 1)
    NUM_CORES=$(nproc)
    MAKE_JOBS=$((NUM_CORES > 1 ? NUM_CORES - 1 : 1))
    log info "Using $MAKE_JOBS make jobs on $NUM_CORES cores"

    make -j"$MAKE_JOBS" "$RESOLUTION"
    make install

    # Remove the extracted files
    cd /var/cache/hamclock
    rm -rf ESPHamClock
fi

# Pre-configure tzdata to avoid prompts
export DEBIAN_FRONTEND=noninteractive
ln -fs /usr/share/zoneinfo/UTC /etc/localtime

# Run apt-get update, no need for the output
log info "Checking for system updates..."
apt-get update > /dev/null 2>&1

# Count upgradable packages more accurately
UPDATES=$(apt list --upgradable 2> /dev/null | wc -l)
log info "Found $((UPDATES -= 1)) packages to update"

if [ "$UPDATES" -gt 0 ]; then
    systemctl stop hamclock.service

    # First handle regular updates
    log info "Starting system update"
    apt-get upgrade -y > /dev/null 2>&1

    # Explicitly handle tzdata if it's held back
    if apt list --upgradable 2> /dev/null | grep -q "^tzdata/"; then
        apt-get install --only-upgrade -y --allow-change-held-packages tzdata > /dev/null 2>&1
    fi

    log info "System update complete, rebooting"
    shutdown -r now
elif [ "$HCUPDATE" -eq 1 ]; then
    log info "Restarting hamclock"
    systemctl restart hamclock.service
fi
