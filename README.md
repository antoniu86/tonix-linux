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
- **Survives OS upgrades** — 4-partition layout preserves /home across rebuilds
- **Dual boot support** — BIOS (legacy) + UEFI (32-bit and 64-bit)
- **XFCE desktop** — Lightweight GUI (boots to CLI by default)
- **Alfa WiFi support** — Auto-detects AWUS036ACM, AWUS036AXML, AWUS1900
- **WiFi security tools** — aircrack-ng, kismet, wireshark, bettercap, mdk4
- **Built-in steganography** — `stego` command for hiding encrypted data in files
- **Python security toolkit** — scapy, impacket, volatility3, pwntools pre-installed
- **Fast rebuilds** — Package cache makes subsequent builds 3-4x faster (15-25 min)
- **RAM wiping** — Clears sensitive data from memory on shutdown
- **No swap** — Prevents sensitive data from leaking to disk

## Quick Start

```bash
# 1. Build the OS image (on your Ubuntu machine)
sudo ./tonix.sh build
# First build downloads ~2-4GB and caches packages (45-60 min)
# Subsequent builds reuse cache and are 3-4x faster (15-25 min)

# 2a. Install directly to USB (recommended)
sudo ./tonix.sh install /dev/sdX

# 2b. OR build an installer ISO
sudo ./tonix.sh iso

# 2c. OR test in a VM first (faster than writing to USB every time)
sudo ./tonix.sh vm-test iso-with-disk   # boot ISO + attach virtual disk
# Inside the VM: run 'install-tonix', enter 'vda' as the target device
sudo ./tonix.sh vm-test disk            # boot the installed VM disk (UEFI)
sudo ./tonix.sh vm-test disk-bios       # boot the installed VM disk (legacy BIOS)
```

### Faster Rebuilds

After the first build, packages are cached for much faster subsequent builds:

```bash
sudo ./tonix.sh build              # Uses cache (15-25 min, 3-4x faster!)
sudo ./tonix.sh --refresh build    # Force fresh packages (45-60 min)
./tonix.sh cache-info              # Show cache statistics
```

## USB Partition Layout

```
32GB USB Drive:
+------+----------+----------------------------+--------------------------+
| BIOS | /boot    | /  (root)                  | /home                    |
| 1MB  | 512MB    | 10GB, ext4                 | remaining, LUKS2         |
| grub | FAT32    | read-only via overlayfs    | encrypted, persistent    |
|      | UEFI ESP | tmpfs overlay (RAM)        | your data survives here  |
+------+----------+----------------------------+--------------------------+
  p1      p2         p3                          p4

Partition 1: BIOS boot (for legacy GRUB on GPT disks, no filesystem)
Partition 2: ESP/Boot (UEFI + kernel/initrd)
Partition 3: Root filesystem (immutable by default)
Partition 4: Encrypted home (persistent across OS rebuilds)
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
tonix-tormode status        # Check current mode and exit IP
```

When active: all outbound TCP is transparently redirected through Tor, DNS goes through Tor (no leaks), all UDP except DHCP is blocked, IPv6 is fully blocked, direct connections are rejected.

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
sudo ./tonix.sh build
sudo ./tonix.sh install /dev/sdX
# Partitions 2 (ESP) and 3 (root) are replaced.
# Partitions 1 (BIOS boot) and 4 (encrypted /home) are untouched.
```

Temporary installs work too: `apt install something` in immutable mode lives in RAM and disappears on reboot. Your /home data is untouched either way.

## Project Structure

```
tonix/
├── tonix.sh                        Main entry point (build / install / iso / vm-test)
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
├── docs/                           Documentation
│   └── PACKAGE_CACHE.md           Cache system guide
├── cache/                          (generated, 2-4GB persistent package cache)
├── build/                          (generated, temporary build files)
└── output/                         (generated, final tarballs and ISOs)
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
- ~15-20GB free disk space (includes 2-4GB package cache)
- Internet connection (~2-4GB download for first build)
- Root access

**For VM testing (`vm-test`):** `sudo apt install qemu-system-x86 qemu-kvm ovmf`

**Note:** After the first build, the package cache speeds up subsequent builds by 3-4x. See `docs/PACKAGE_CACHE.md` for details.

## Package Cache & Build Performance

Tonix uses an intelligent package caching system that dramatically speeds up subsequent builds:

| Build Type | First Build | With Cache | Speedup |
|------------|-------------|------------|---------|
| OS Tarball | 45-60 min | 15-25 min | **3-4x faster** |
| ISO Build | 50-65 min | 20-30 min | **2.5-3x faster** |

**How it works:**
1. First build downloads ~2-4GB of Debian packages and saves them to `cache/`
2. Subsequent builds reuse cached packages (only downloads updates)
3. Rebuilds complete in 15-25 minutes instead of 45-60 minutes

**Cache commands:**
```bash
./tonix.sh build              # Use cache (default, fast!)
./tonix.sh --refresh build    # Force fresh packages (slower)
./tonix.sh cache-info         # Show cache statistics
rm -rf cache/                 # Manually clear cache
```

Perfect for development and testing — iterate on configs quickly without re-downloading packages every time.

See `docs/PACKAGE_CACHE.md` for complete documentation.

## Default Credentials

| Context | Username | Password |
|---------|----------|----------|
| Installed OS | `tonix` | `tonix` |
| Installer ISO (live env) | `root` | `tonix` |

Direct root login is disabled on the installed system — the root account is locked. Use `sudo -i` to get a root shell when needed. Change your password after first login with `passwd`.
