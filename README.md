# RAM Optimizer

**zRAM + Swap management for Linux servers, desktops, and containers**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Linux-ready-blue.svg)](https://www.linux.org/)
[![Systemd](https://img.shields.io/badge/systemd-ready-blue.svg)](https://systemd.io/)
[![Prometheus](https://img.shields.io/badge/Prometheus-ready-orange.svg)](https://prometheus.io/)
[![Version](https://img.shields.io/badge/version-3.2.2-red.svg)](https://github.com/nam348tnh3gp/RAM-opt)

This Bash script provides a complete, automated solution for configuring and managing zRAM (compressed RAM‑based swap) alongside a traditional swap file. It delivers faster swap performance, reduces disk wear (especially on SSDs), and improves overall memory efficiency – all with full systemd integration, Prometheus metrics, and automatic health monitoring.

---

## 📋 Table of Contents

- [Features](#features)
- [System Requirements](#system-requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Example Session](#example-session)
- [Monitoring & Metrics](#monitoring--metrics)
- [Health Checks](#health-checks)
- [Dry‑Run Mode](#dry‑run-mode)
- [Backup & Restore](#backup--restore)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Acknowledgements](#acknowledgements)

---

## ✨ Features

- **🧠 Smart capacity planning** – Automatically calculates optimal zRAM and swap sizes based on available RAM and disk space.
- **⚙️ Adaptive compression** – Selects the best algorithm (zstd, lz4, or lzo) depending on your CPU core count.
- **🐳 Container‑aware** – Detects Docker, Podman, Toolbox, and Kubernetes environments, and adjusts parameters automatically.
- **📈 Prometheus metrics** – Exports detailed zRAM usage statistics (size, original data, compressed data) for real‑time monitoring.
- **🩺 Automated health checks** – Hourly systemd timer logs a warning when zRAM usage exceeds 90% (optional email alerts).
- **💾 Backup & restore** – Automatically backs up `/etc/sysctl.conf` and `/etc/fstab` before making changes; restores them with a single command.
- **🗑️ Complete uninstall** – Removes all services, configuration files, and optionally restores the last working backup.
- **🎛️ Dry‑run mode** – Preview what would be changed without touching your system.
- **🔇 Quiet mode** – Minimal output (warnings/errors only), perfect for automation.
- **⚡ Force mode** – Skip all confirmation prompts for CI/CD and cloud-init.
- **🌈 Colour output** – Clean, user‑friendly terminal logs (auto‑disabled when run non‑interactively).

---

## 💻 System Requirements

- **Linux kernel** with zRAM support (built into most modern distributions)
- **systemd** (required for service and timer units)
- **bash 4.0+**
- **Root privileges** – the script will refuse to run without `sudo`

---

## 📥 Installation

### Direct Download

```bash
# Download the script
sudo curl -o /usr/local/bin/ram-opt \
  https://raw.githubusercontent.com/nam348tnh3gp/RAM-opt/main/ram-opt.sh

# Make it executable
sudo chmod +x /usr/local/bin/ram-opt

# Run it
sudo ram-opt
```

Manual Copy

Copy the entire script content to /usr/local/bin/ram-opt and set the executable bit:

```bash
sudo nano /usr/local/bin/ram-opt   # paste the script
sudo chmod +x /usr/local/bin/ram-opt
```

Create a .deb Package (Debian/Ubuntu)

```bash
mkdir -p ram-opt_3.2.2/usr/local/bin
cp ram-opt ram-opt_3.2.2/usr/local/bin/
dpkg-deb --build ram-opt_3.2.2
sudo dpkg -i ram-opt_3.2.2.deb
```

---

⚙️ Configuration

All settings are stored in /etc/zram-optimizer.conf, which is created automatically on the first run with the following defaults:

```ini
# /etc/zram-optimizer.conf
ZRAM_PERCENT=50          # Percentage of physical RAM for zRAM
MAX_ZRAM_MB=4096         # Maximum zRAM size in MB
SWAP_FACTOR=1.0          # Multiplier for swap file size (0.5–2.0)
MAX_SWAP_MB=8192         # Maximum swap file size in MB
MIN_SWAP_MB=2048         # Minimum swap file size in MB
ZRAM_DEVICES=1           # Number of zRAM devices (for striping)
ALGORITHM=auto           # auto, zstd, lz4, or lzo
SWAPPINESS=auto          # auto, or a value from 0 to 100
VFS_CACHE_PRESSURE=50    # 0–100
SWAP_FILE_PATH="/swapfile"  # Path to swap file or block device
ALERT_EMAIL=             # Email address for health alerts (optional,not avaible)
METRICS_PORT=9100        # Prometheus metrics port
```

Edit this file with your preferred values, then re‑run the script to apply the changes.

---

🚀 Usage

Command Description
sudo ram-opt Run the full configuration (interactive)
sudo ram-opt --status Show current swap, memory, and service status
sudo ram-opt --dry-run Test without making any changes
sudo ram-opt --quiet Minimal output, only warnings/errors
sudo ram-opt --force Skip all confirmation prompts
sudo ram-opt --restore /path/to/backup Restore configuration from a previous backup
sudo ram-opt --uninstall Completely remove RAM Optimizer from the system
sudo ram-opt --help Display the help message

---

📺 Example Session

```bash
$ sudo ram-opt
=========================================
ZRAM Optimizer Suite v3.2.2
Started at: Thu Jan 15 10:00:00 UTC 2026
=========================================
[INFO] Detected RAM: 7824MB
[INFO] Planned: zRAM=3912MB, Swap=4096MB at /swapfile

Proceed with configuration? (y/n): y

[OK] Backup saved to /root/zram-backup-20260115_100000
[INFO] Starting configuration...
[OK] Created swap file (4096MB) via fallocate
[INFO] Creating 1 zRAM device(s)...
[OK] zRAM0: 3912MB, lz4
[OK] Kernel parameters configured (swappiness=10)
[OK] Configuration completed

========================================
  SYSTEM STATUS
========================================
Active swaps:
NAME       TYPE       SIZE USED PRIO
/swapfile  file       4G   0B   -2
/dev/zram0 partition  3.8G 0B   100

Memory usage:
              total        used        free      shared  buff/cache   available
Mem:           7.6G        512M        6.2G         12M        987M        6.8G
Swap:          7.8G          0B        7.8G

Compression algorithm: lz4
Compression ratio: 0:1
Service status:
  ✓ zram-setup: Active
  ✓ zram-health.timer: Active
  ✓ zram-metrics: Active

[OK] === CONFIGURATION COMPLETE ===
Backup : /root/zram-backup-20260115_100000
Log    : /var/log/zram-optimizer.log
Config : /etc/zram-optimizer.conf

Reboot now? (y/n): n
```

---

📊 Monitoring & Metrics

The script starts a Prometheus‑compatible metrics exporter that writes a file (/var/lib/node_exporter/zram.prom) containing the following metrics:

```
zram_disksize_bytes{device="zram0"} 4100000000
zram_orig_data_size_bytes{device="zram0"} 1500000000
zram_compr_data_size_bytes{device="zram0"} 600000000
```

You can configure Prometheus to scrape this file using the node_exporter textfile collector. A minimal prometheus.yml snippet:

```yaml
scrape_configs:
  - job_name: 'zram'
    static_configs:
      - targets: ['localhost:9100']
    metrics_path: '/metrics'
    params:
      format: ['prometheus']
```

---

🩺 Health Checks

A systemd timer runs health-check.sh every hour. If zRAM usage exceeds 90%, it logs a warning to /var/log/zram-health.log. If ALERT_EMAIL is set in the configuration, the warning is also sent via email.

---

🎯 Dry‑Run Mode

Always test the changes before applying them:

```bash
sudo ram-opt --dry-run
```

This shows what would be changed without touching any configuration files or swap devices.

---

💾 Backup & Restore

Every successful run creates a timestamped backup in /root/zram-backup-YYYYMMDD_HHMMSS/. To restore:

```bash
sudo ram-opt --restore /root/zram-backup-20260115_100000
```

After restoring, you must reboot the system for the changes to take full effect.

---

🗑️ Uninstalling

To completely remove RAM Optimizer and revert to the previous state (using the latest backup):

```bash
sudo ram-opt --uninstall
```

You will be prompted to confirm and optionally restore the last backup.

---

🔧 Troubleshooting

zRAM not supported by the kernel

If you see [ERROR] Kernel doesn't support zRAM!, you need a kernel built with CONFIG_ZRAM=y. Most modern distributions already include it. If not, rebuild your kernel or switch to a distribution that provides zRAM support.

Low disk space for swap

The script checks available disk space before creating the swap file. If there is not enough room, it will automatically reduce the swap size (keeping at least 512 MB free). If that is still insufficient, the configuration fails with an error message.

Missing bc or other commands

The script attempts to install missing packages automatically using apt, dnf, or pacman. If none of these package managers is available, you must install bc and util-linux manually.

Swap file size mismatch

If the script reports a swap file size mismatch, it means the created file does not match the expected size. This can happen on some exotic filesystems. The script will automatically clean up and exit safely.

---

📄 License

Distributed under the MIT License. See the LICENSE file for more information.

---

👀 Acknowledgements

· The Linux kernel developers for the zRAM module
· The systemd project for service and timer management
· The Prometheus community for metric standards
· All contributors and users who provided feedback

---

<div align="center">Built with ❤️ for system administrators everywhere

Report Bug · Request Feature

</div>
