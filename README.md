# Tonix — Portable Encrypted Linux Distribution
## Codename: Mirage

A custom Debian-based Linux distribution designed to run entirely from a USB drive, leaving no traces on host systems, with full disk encryption for user data and Tails-inspired privacy features.

## Features

- **Immutable root** — OS runs read-only via overlayfs; changes live in RAM, gone on reboot
- **Encrypted /home** — LUKS2 with AES-512-XTS, SHA-512, persistent across reboots
- **Tor-only mode** — Toggle forces all traffic through Tor via iptables, blocks direct access
- **Tor Browser** — Pre-installed alongside Firefox ESR
- **Early MAC spoofing** — All interfaces randomized before NetworkManager starts
- **No host footprint** — System runs from USB, nothing written to host disk
- **Survives OS upgrades** — 3-partition layout preserves /home across rebuilds
- **Dual boot support** — BIOS (legacy) + UEFI (32-bit and 64-bit)
- **XFCE desktop** — Lightweight GUI (boots to CLI by default)
- **Alfa WiFi support** — Auto-detects AWUS036ACM, AWUS036AXML, AWUS1900
- **WiFi security tools** — aircrack-ng, kismet, wireshark, bettercap, mdk4
- **Built-in steganography** — `stego` command for hiding encrypted data in files
- **Python security toolkit** — scapy, impacket, volatility3, pwntools pre-installed
- **RAM wiping** — Clears sensitive data from memory on shutdown
- **No swap** — Prevents sensitive data from leaking to disk

## Quick Start

```bash
# 1. Build the OS image (on your Ubuntu machine)
sudo ./secure-os.sh build

# 2a. Install directly to USB (recommended)
sudo ./secure-os.sh install /dev/sdX

# 2b. OR build an installer ISO
sudo ./secure-os.sh iso
```

## USB Partition Layout

```
32GB USB Drive:
+-----------+----------------------------+--------------------------+
| /boot     | /  (root)                  | /home                    |
| 512MB     | 10GB, ext4                 | remaining, LUKS2         |
| FAT32     | read-only via overlayfs    | encrypted, persistent    |
| UEFI ESP  | tmpfs overlay (RAM)        | your data survives here  |
+-----------+----------------------------+--------------------------+
```

## GRUB Boot Menu

On boot you get four options:

1. **Tonix — Immutable (default)** — Root is read-only with tmpfs overlay. Changes to the OS disappear on reboot. /home is persistent and encrypted. This is the normal mode.

2. **Tonix — Persistent Root (writable)** — Root is writable. Use this to make permanent changes to the OS (install packages that survive reboot, edit system configs). Then reboot back to immutable mode.

3. **Tonix — RAM Only** — Entire OS loads into RAM. USB can be removed after boot. Maximum speed, maximum privacy.

4. **Tonix — Recovery** — Single-user mode for troubleshooting.

## Tor-Only Mode

Force all network traffic through Tor:

```bash
sudo tonix-tormode on       # Enable — all traffic through Tor
sudo tonix-tormode off      # Disable — normal networking
tonix-tormode status        # Check current mode
```

When active: all outbound TCP is redirected through Tor's transparent proxy, DNS goes through Tor, direct connections are blocked by iptables, IPv6 is disabled entirely.

## Boot Mode

Tonix boots to command line. Start the GUI with:

```bash
startxfce4
```

## Steganography Tool

```bash
stego hide /path/to/folder -o output.jpg    # Hide data
stego show output.jpg -o /path/to/output    # Extract data
stego scan /path/to/files -r -v             # Scan for hidden data
```

## Upgrade Flow

```bash
# Edit config.sh to add/change packages, then:
sudo ./secure-os.sh build
sudo ./secure-os.sh install /dev/sdX
# /home is preserved, only /boot and / are replaced
```

Temporary installs work too: `apt install something` in immutable mode lives in RAM and disappears on reboot. Your /home data is untouched either way.

## Project Structure

```
tonix/
├── secure-os.sh                    Main entry point (build / install / iso)
├── config.sh                       All package lists and settings
├── install-common.sh               Shared install logic
├── overlays/
│   ├── etc/
│   │   ├── initramfs-tools/        Overlay root hooks (immutable OS)
│   │   ├── udev/rules.d/          WiFi adapter auto-detection
│   │   ├── NetworkManager/         MAC randomization config
│   │   ├── systemd/system/         Services (MAC spoof, WiFi, RAM wipe)
│   │   └── modprobe.d/            WiFi driver config
│   └── usr/local/
│       ├── bin/                    Commands: stego, tonix-tormode, etc.
│       └── share/stego/           Steganography tool source
├── build/                          (generated)
└── output/                         (generated)
```

## Tails-Inspired Security

| Feature | Tails | Tonix |
|---------|-------|-------|
| All traffic through Tor | Always on | Toggle with `tonix-tormode on` |
| Tor Browser | Default browser | Pre-installed alongside Firefox |
| Immutable root | SquashFS | overlayfs with tmpfs (same effect) |
| MAC spoofing | Kernel-level at boot | Early systemd unit before NetworkManager |
| RAM wipe on shutdown | Custom kernel patch | sdmem + cache flush (userspace) |
| Encrypted persistence | Opt-in, limited dirs | Always-on encrypted /home |
| Writable mode | Not available | Boot option for maintenance |
| Custom software | Requires rebuild | Temporarily via apt, or rebuild |

## WiFi Adapter Support

| Adapter | Chipset | Driver | Status |
|---------|---------|--------|--------|
| AWUS036ACM | MT7612U | mt76x2u (in-kernel) | Works out of box |
| AWUS036AXML | MT7921AUN | mt7921u (in-kernel) | Works out of box |
| AWUS1900 | RTL8814AU | 8814au (DKMS) | Built from source |

## Build Requirements

- Debian/Ubuntu host system (Linux only)
- ~15-20GB free disk space
- Internet connection (~2-4GB download)
- Root access

## Default Credentials

- Root password: `tonix` (change immediately with `passwd`)
