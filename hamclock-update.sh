#!/bin/bash
# error handling and logging
set -euo pipefail
exec 1> >(tee -a /var/log/hamclock-update.log | logger -s -t "$(basename "$0")") 2>&1

# Parse command line arguments
FORCE_UPDATE=0
UPDATED=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE_UPDATE=1
            ;;
        --updated)
            UPDATED=1
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $(basename "$0") [--force] [--updated]" >&2
            exit 1
            ;;
  esac
    shift
done

logger -s -t "$(basename "$0")" "Update service started at $(date '+%Y-%m-%d %H:%M:%S')"

# Add lock file to prevent concurrent runs
LOCKFILE="/var/run/hamclock_update.lock"
if ! mkdir "$LOCKFILE" 2> /dev/null; then
  echo "Script is already running" >&2
  exit 1
fi

# Check for updates to the wrapper scripts
REPO_URL="https://github.com/k4drw/hamclock-fb"
INSTALL_DIR="/usr/local"
UPDATE_DIR=$(mktemp -d)
trap 'rm -rf "$LOCKFILE" "$UPDATE_DIR"' EXIT

logger -s -t "$(basename "$0")" "Checking for wrapper script updates..."
if curl -Ls "${REPO_URL}/archive/refs/heads/master.tar.gz" -o "${UPDATE_DIR}/repo.tar.gz"; then
  cd "$UPDATE_DIR"
  if tar xzf repo.tar.gz --strip-components=1; then
    # Check if any of the files differ from the installed versions
    UPDATE_NEEDED=false

    # Check hamclock-update.sh
    if [ -f hamclock-update.sh ] && ! cmp -s hamclock-update.sh "$INSTALL_DIR/sbin/hamclock-update"; then
      UPDATE_NEEDED=true
      logger -s -t "$(basename "$0")" "Update script has changed"
    fi

    # Check service files
    for service_file in hamclock.service hamclock-update.service hamclock-update.timer; do
      if [ -f "$service_file" ] && ! cmp -s "$service_file" "/etc/systemd/system/$service_file"; then
        UPDATE_NEEDED=true
        logger -s -t "$(basename "$0")" "Service file $service_file has changed"
      fi
    done

    # Update files if needed
    if $UPDATE_NEEDED; then
      # Update the scripts
      install -m 755 hamclock-update.sh "$INSTALL_DIR/sbin/hamclock-update"
      install -m 644 hamclock.service /etc/systemd/system/
      install -m 644 hamclock-update.service /etc/systemd/system/
      install -m 644 hamclock-update.timer /etc/systemd/system/
      systemctl daemon-reload
      logger -s -t "$(basename "$0")" "Wrapper scripts updated"

      # Enable services
      systemctl enable hamclock.service
      systemctl enable hamclock-update.timer
      systemctl start hamclock-update.timer

      # Exit and let the new version take over
      if [ "$UPDATED" -eq 0 ]; then
        exec "$INSTALL_DIR/sbin/hamclock-update" --updated
      fi
    else
      logger -s -t "$(basename "$0")" "No updates to wrapper scripts needed"
    fi
  fi
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
    logger -s -t "$(basename "$0")" "Force update requested"
    HCUPDATE=1
elif md5sum --quiet -c /tmp/md5; then
    logger -s -t "$(basename "$0")" "No update to HamClock"
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
  elif   [ "$FB_WIDTH" -ge 2400 ] && [ "$FB_HEIGHT" -ge 1440 ]; then
        RESOLUTION="hamclock-fb0-2400x1440"
  elif   [ "$FB_WIDTH" -ge 1600 ] && [ "$FB_HEIGHT" -ge 960 ]; then
        RESOLUTION="hamclock-fb0-1600x960"
  else
        RESOLUTION="hamclock-fb0-800x480"
  fi

    # Set framebuffer depth based on actual hardware
    if [ "$FB_DEPTH" -eq 32 ]; then
        logger -s -t "$(basename "$0")" "Configuring for 32-bit framebuffer"
        sed -i -re 's/(#define _16BIT_FB)/\/\/\1/' ArduinoLib/Adafruit_RA8875.h
  fi

    # I prefer a lower value for WiFi signal strength
    sed -i -re 's/MIN_WIFI_RSSI (-75)/MIN_WIFI_RSSI (-90)/' HamClock.h

    # Don't show the wifi setup on FB0
    sed -i '/#if defined (_USE_FB0)/,/#endif/c\#define _WIFI_NEVER' setup.cpp

    # Make hamclock with detected resolution
    logger -s -t "$(basename "$0")" "Building with resolution: $RESOLUTION"

    # Determine optimal number of make jobs (number of cores minus 1, minimum 1)
    NUM_CORES=$(nproc)
    MAKE_JOBS=$((NUM_CORES > 1 ? NUM_CORES - 1 : 1))
    logger -s -t "$(basename "$0")" "Using $MAKE_JOBS make jobs on $NUM_CORES cores"

    make -j"$MAKE_JOBS" "$RESOLUTION"
    make install

    # Remove the extracted files
    cd /var/cache/hamclock
    rm -rf ESPHamClock
fi

# Pre-configure tzdata to avoid prompts
export DEBIAN_FRONTEND=noninteractive
ln -fs /usr/share/zoneinfo/UTC /etc/localtime

# Run apt update, no need for the output
apt update > /dev/null 2>&1

UPDATES=$(apt list --upgradable | wc -l)

if [ "$UPDATES" -gt 1 ]; then
  logger -s -t "$(basename "$0")" "Updating $((UPDATES -= 1)) packages"
  systemctl stop hamclock.service

  # First handle regular updates
  apt upgrade -y

  # Explicitly handle tzdata if it's held back
  if apt list --upgradable 2> /dev/null | grep -q "^tzdata/"; then
    apt install --only-upgrade -y --allow-change-held-packages tzdata
  fi

  shutdown -r now
elif [ "$HCUPDATE" -eq 1 ]; then
  logger -s -t "$(basename "$0")" "Restarting hamclock"
  systemctl restart hamclock.service
fi
