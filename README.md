# HamClock Installation

This package installs HamClock with automatic daily updates.

## Prerequisites

- Raspberry Pi or compatible system
- Debian/Ubuntu-based Linux
- Root access
- Network connection
- Framebuffer support

## Installation

### Quick Install
Install directly using curl:
```bash
curl -sSL https://github.com/k4drw/hamclock-fb/raw/refs/heads/master/install.sh | sudo bash
```

### From GitHub
1. Clone the repository:
   ```bash
   git clone https://github.com/k4drw/hamclock-fb.git
   cd hamclock-fb/install
   ```
2. Make the install script executable:
   ```bash
   chmod +x install.sh
   ```
3. Run the installation script as root:
   ```bash
   sudo ./install.sh
   ```

### Manual Installation
If you prefer to install manually, follow these steps:

1. Create the update script:
   ```bash
   sudo install -m 755 hamclock-update.sh /usr/local/sbin/hamclock-update
   ```

2. Configure the service user:
   ```bash
   # Create the environment file with your username
   echo "HAMCLOCK_USER=$(whoami)" | sudo tee /etc/default/hamclock
   ```

3. Install the systemd services:
   ```bash
   sudo install -m 644 hamclock.service /etc/systemd/system/
   sudo install -m 644 hamclock-update.service /etc/systemd/system/
   sudo install -m 644 hamclock-update.timer /etc/systemd/system/
   ```

4. Enable and start the services:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable hamclock.service
   sudo systemctl enable hamclock-update.timer
   sudo systemctl start hamclock-update.timer
   ```

## Configuration

The update script will:
- Check for HamClock updates daily between 2:00 AM and 3:00 AM
- Automatically install system updates when available
- Restart the system if needed after updates
- Auto-restart HamClock service on failure
- Use 30-second timeout for service startup
- Use 30-minute timeout for update operations
- Set timezone to UTC

## Display Resolution and Color Depth

The installation automatically detects your framebuffer settings using `fbset -i` and configures HamClock appropriately:

### Resolution
The script will select the best resolution that fits your display from these options:
- 800x480 (Small display)
- 1600x960 (Medium display)
- 2400x1440 (Large display)
- 3200x1920 (Huge display)

### Color Depth
The color depth (16-bit or 32-bit) will be automatically configured based on your framebuffer settings.

Note: If you need to override these automatic settings, you can modify the script at `/usr/local/sbin/hamclock-update` and comment out the automatic detection code.

## Files Installed

- `/usr/local/sbin/hamclock-update` - Daily update script
- `/etc/systemd/system/hamclock.service` - HamClock service
- `/etc/systemd/system/hamclock-update.service` - Update service
- `/etc/systemd/system/hamclock-update.timer` - Update timer
- `/var/cache/hamclock/` - Cache directory for downloads and backups
- `/var/run/hamclock_update.lock` - Lock file during updates
- `/etc/default/hamclock` - Service configuration

## Troubleshooting

Check service status:
   ```bash
   systemctl status hamclock.service
   systemctl status hamclock-update.timer
   ```

Check logs:
   ```bash
   # View update script logs
   journalctl -u hamclock-update.service

   # Check for locked update process
   ls -l /var/run/hamclock_update.lock

   # View cached files
   ls -l /var/cache/hamclock/
   ```

## Notes
- The script modifies the MIN_WIFI_RSSI value to -90 for better WiFi connectivity
- All times are in UTC
- Previous versions are backed up as ESPHamClock-[version].tgz

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [HamClock](https://www.clearskyinstitute.com/ham/HamClock/) by Elwood Downey, WB0OEW
