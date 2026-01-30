# 🧑‍✈️Crew Airlink installer

[![License: Apache 2.0](https://img.shields.io/github/license/thavanish/Installer)](LICENSE)
[![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f.svg)](https://www.gnu.org/software/bash/)

Unofficial installation script for the Airlink Panel and Daemon.
This installer is intended to be merged upstream and become the official installer.

## Usage

Run the installer as root:

```bash
bash <(curl -s https://raw.githubusercontent.com/thavanish/Installer/refs/heads/main/airlink/installer.sh)
```

## Logging

Installer logs are written to:

```
/tmp/airlink.log
```

System services can be inspected with:

```bash
journalctl -u airlink-panel -f
journalctl -u airlink-daemon -f
```


### Supported operating systems

| Operating System | Version       | Supported |
| ---------------- | ------------- | --------- |
| Ubuntu           | 20.04 (Focal) | Yes       |
|                  | 22.04 (Jammy) | Yes       |
|                  | 24.04 (Noble) | Yes       |
|                  | 25.10 (Questing Quokka)| Yes       |
| Debian           | 10 (Buster)   | Yes       |
|                  | 11 (Bullseye) | Yes       |
|                  | 12 (Bookworm) | Yes       |
| Linux Mint       | 20.x          | Yes       |
|                  | 21.x          | Yes       |
| Pop!_OS          | 22.04         | Yes       |
| AlmaLinux        | 8             | Yes       |
|                  | 9             | Yes       |
| Rocky Linux      | 8             | Yes       |
|                  | 9             | Yes       |
| CentOS           | 7             | Limited   |
|                  | 8             | Limited   |
| Arch Linux       | Rolling       | Yes       |
| Manjaro          | Rolling       | Yes       |
| Alpine Linux     | 3.18          | Yes       |
|                  | 3.19          | Yes       |

**Notes**

* “Limited” means the installer may work but is not actively tested.
* Rolling releases track the latest stable packages.
* Node.js 20 is enforced by the installer across all supported systems.

## Features

  * Automatic installation of the Airlink Panel
  * Node.js 20
  * Prisma
  * PM2
  * systemd service
  * Automatic installation of the Airlink Daemon
  * Docker
  * systemd service
* Interactive TUI installer using dialog
* Automatic admin user creation
* Optional addon installation
* Full uninstall support (panel, daemon, dependencies)

## Addons

The installer supports optional Airlink addons.

### Available addons

* Modrinth
  [https://github.com/g-flame-oss/airlink-addons](https://github.com/g-flame-oss/airlink-addons) (branch: modrinth-addon)

* Parachute
  [https://github.com/g-flame-oss/airlink-addons](https://github.com/g-flame-oss/airlink-addons) (branch: parachute)

Addons are cloned into the panel addons directory and built automatically.

## License

Licensed under the Apache License 2.0.
See the LICENSE file for details.

## Author

Maintained by
[https://github.com/thavanish](https://github.com/thavanish)

