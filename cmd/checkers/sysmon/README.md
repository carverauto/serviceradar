# serviceradar-sysmon

## Overview
`serviceradar-sysmon` is a system monitoring tool that collects and reports various system metrics. It is designed to be lightweight and efficient, making it suitable for use in production environments.
It can be used to monitor CPU usage, memory usage, disk I/O, network activity, and more.

## ZFS Requirements

- Install `libzfs-dev`: `apt install libzfs-dev`.
- Grant permissions: `zfs allow serviceradar dataset,hold,mount rpool`.
- Example `sysman.json`:
  ```json
  {
      "zfs": {
          "enabled": true,
          "pools": ["rpool"],
          "include_datasets": true,
          "use_libzetta": true
      }
  }