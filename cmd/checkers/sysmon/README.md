# serviceradar-sysmon

## Overview
`serviceradar-sysmon` is a system monitoring tool that collects and reports CPU usage, memory usage, disk I/O, and optionally ZFS pool/dataset metrics. It is designed to be lightweight and efficient, suitable for production environments.

## Installation

### Debian
```bash
dpkg -i serviceradar-sysmon-checker_1.0.33.deb
```

### RPM
```bash
rpm -i serviceradar-sysmon-checker-1.0.33-1.x86_64.rpm
```

## ZFS Requirements (Optional)
If monitoring ZFS pools/datasets:
- Install `zfsutils-linux`: `apt install zfsutils-linux` (Debian) or `dnf install zfs` (RPM-based).
- Grant permissions: `zfs allow serviceradar dataset,hold,mount rpool`.
- Example `sysmon.json`:
  ```json
  {
      "listen_addr": "0.0.0.0:50060",
      "zfs": {
          "enabled": true,
          "pools": ["rpool"],
          "include_datasets": true,
          "use_libzetta": true
      },
      "filesystems": [{"name": "/", "type": "ext4", "monitor": true}]
  }
  ```

## Non-ZFS Systems
The checker works without ZFS by monitoring standard filesystems (e.g., ext4) using `sysinfo`. The default configuration (`/etc/serviceradar/checkers/sysmon.json`) disables ZFS:
```json
{
    "listen_addr": "0.0.0.0:50060",
    "zfs": null,
    "filesystems": [{"name": "/", "type": "ext4", "monitor": true}]
}
```
The installer automatically detects ZFS availability and configures the appropriate binary and settings.

## Configuration
Edit `/etc/serviceradar/checkers/sysmon.json` to customize monitoring:
- Set `listen_addr` for the gRPC server.
- List `filesystems` to monitor (e.g., `"/mnt/data"`).
- Enable `zfs` for ZFS monitoring if available.

## Troubleshooting
- Check logs: `journalctl -u serviceradar-sysmon-checker.service`.
- Verify ZFS availability: `zfs list`.
- Ensure `serviceradar` user has permissions for ZFS pools.
