# Tonix — Portable Encrypted Linux Distribution
## Codename: Mirage

A custom Debian-based Linux distribution designed to run entirely from a USB drive, leaving no traces on host systems, with full disk encryption for user data and Tails-inspired privacy features.

## Features

- **Immutable root** — OS runs read-only via overlayfs; changes live in RAM, gone on reboot
- **Encrypted /home** — LUKS2 with AES-512-XTS, SHA-512, persistent across reboots
- **Tor-only mode** — Toggle forces all traffic through Tor via transparent proxy + iptables
- **Tor Browser** — Pre-installed, runs as a dedicated sandboxed `tonix-browser` system user
- **Early MAC spoofing** — All interfaces randomized before NetworkManager starts
- **No host footprint** — System runs from USB, nothing written to host disk
- **Survives OS upgrades** — 4-partition layout preserves /home across rebuilds
- **Dual boot support** — BIOS (legacy) + UEFI (32-bit and 64-bit)
- **XFCE desktop** — Lightweight GUI with custom Tonix wallpapers (boots to CLI by default)
- **Alfa WiFi support** — Auto-detects AWUS036ACM, AWUS036AXML, AWUS1900
- **WiFi security tools** — aircrack-ng, kismet, wireshark, bettercap, mdk4, wifite, hcxdumptool, cowpatty, hping3, yersinia, ngrep, netsniff-ng
- **Penetration testing** — nikto, sqlmap, gobuster, dirb, wfuzz, whatweb, sslscan, hydra, medusa, radare2, nasm, gdb
- **OSINT & reconnaissance** — theharvester, recon-ng, dnsrecon, dnsenum, fierce, dmitry
- **Windows/SMB/AD** — enum4linux, smbclient, nbtscan, ldap-utils, samdump2, chntpw
- **MITM & traffic interception** — mitmproxy, sslsplit, ettercap, dsniff, p0f, tcpflow
- **Wordlist generation** — crunch, cewl for custom and pattern-based wordlists
- **File cracking** — fcrackzip, pdfcrack, ophcrack, exploitdb (searchsploit)
- **SNMP enumeration** — snmp, onesixtyone
- **Encryption toolkit** — gocryptfs, encfs, ccrypt, git-crypt, ssss (Shamir's Secret Sharing)
- **Hardware token support** — YubiKey, smart card, PIV via pcscd, opensc, scdaemon
- **SDR / radio** — rtl-sdr, Ubertooth for Bluetooth LE sniffing alongside Kismet
- **VPN support** — OpenVPN + WireGuard pre-installed
- **DNS encryption** — dnscrypt-proxy encrypts DNS queries, no leaks
- **Proxy routing** — proxychains4 routes any app through Tor/SOCKS
- **Tunneling** — iodine (DNS tunnel), proxytunnel (HTTP/S proxy tunnel), obfs4proxy (Tor bridges for censored networks)
- **Rootkit & integrity** — rkhunter, chkrootkit, lynis, aide, auditd
- **Enhanced forensics** — sleuthkit, dc3dd, gddrescue, hashdeep, bulk-extractor for disk imaging, carving and integrity verification
- **Hardware hacking** — minicom, picocom for serial; flashrom for firmware; avrdude, openocd for embedded/JTAG; sigrok-cli + pulseview for logic analysis
- **Modern terminal** — neovim, fzf, ripgrep, bat, fd-find, exa, tldr, pandoc, lnav, multitail, zsh with autosuggestions
- **System monitoring** — iotop, iftop, nethogs, sysstat, lm-sensors
- **RAM-only stability** — zram-tools compresses RAM, earlyoom prevents OOM lockup in RAM-only mode
- **Anonymous file sharing** — onionshare shares files and hosts sites over Tor
- **Anonymous networks** — Tor, I2P, obfs4proxy bridges; full multi-network anonymity stack
- **Antivirus** — clamav for scanning files and downloads
- **Encrypted backup** — borgbackup (deduplicated), rclone (cloud sync)
- **Hardware hacking** — minicom, picocom for serial consoles; flashrom for firmware read/write
- **Data processing** — miller (`mlr`) processes CSV/JSON/TSV alongside jq, yq, xmlstarlet
- **Media** — mpv, vlc, cmus, audacious for video/audio; feh, nsxiv, ristretto for images
- **Documents & office** — evince, zathura, mupdf for PDF; abiword, gnumeric for lightweight office
- **Email** — neomutt terminal email client with GPG integration
- **IRC** — weechat and irssi terminal IRC clients
- **Torrents** — rtorrent (CLI), transmission-gtk (GUI); aria2 also supports magnets/torrents
- **Built-in steganography** — `stego` command for hiding encrypted data in files
- **Media & documents** — mpv, vlc, cmus, feh; zathura, mupdf, evince; imagemagick for CLI image processing
- **Python security toolkit** — scapy, impacket, volatility3, pwntools, wafw00f, sublist3r, sslyze, visidata, stegcracker, arjun pre-installed
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
| 1MB  | 512MB    | 15GB, ext4                 | remaining, LUKS2         |
| grub | FAT32    | read-only via overlayfs    | encrypted, persistent    |
|      | UEFI ESP | tmpfs overlay (RAM)        | your data survives here  |
+------+----------+----------------------------+--------------------------+
  p1      p2         p3                          p4

Partition 1: BIOS boot (for legacy GRUB on GPT disks, no filesystem)
Partition 2: ESP/Boot (UEFI + kernel/initrd, FAT32 label TONIX)
Partition 3: Root filesystem (immutable by default)
Partition 4: Encrypted home (persistent across OS rebuilds)
```

## GRUB Boot Menu

On boot you get four options:

1. **Tonix — Immutable (default)** — Root is read-only with tmpfs overlay. Changes to the OS disappear on reboot. /home is persistent and encrypted. This is the normal mode.

2. **Tonix — Persistent Root (writable)** — Root is writable. Use this to make permanent changes to the OS (install packages that survive reboot, edit system configs). Then reboot back to immutable mode.

3. **Tonix — RAM Only** — Entire OS loads into RAM. USB can be removed after boot. Maximum speed, maximum privacy.

4. **Tonix — Recovery** — Single-user mode for troubleshooting.

## User Account Setup

There is **no hardcoded default user**. The installer prompts you to choose your own username and password at install time:

- **Fresh install** — you pick any valid username and set your password
- **Reinstall / upgrade** — the installer detects your existing encrypted `/home`, asks which user to restore, and lets you set a new login password while keeping all your data

The build bakes a template `tonix` user into the OS tarball; the installer renames it to your chosen username and updates sudo rules accordingly. The root account is locked — use `sudo -i` for a root shell.

## Tor-Only Mode

Force all network traffic through Tor:

```bash
sudo tonix-tormode on       # Enable — all traffic through Tor
sudo tonix-tormode off      # Disable — normal networking
tonix-tormode status        # Check current mode and exit IP
```

When active: all outbound TCP is transparently redirected through Tor, DNS goes through Tor on port 5300 (no leaks), all UDP except DHCP is blocked, IPv6 is fully blocked, direct connections are rejected.

**How it works under the hood:**

- Uses a drop-in config at `/etc/tor/torrc.d/tonix-transparent.conf` (never modifies the main torrc)
- AppArmor confinement is fully removed for Tor before startup so it can bind custom ports (TransPort 9040, DNSPort 5300)
- Waits up to 120 seconds for Tor to fully bootstrap *before* applying iptables rules — prevents locking Tor out of its own directory servers during startup
- Detects and reports crash loops, port conflicts, and bootstrap failures before locking down the network
- Tor only runs while tormode is active; it is stopped completely on `tonix-tormode off` and is not started at boot

**Tor Browser integration:**

- When tormode is **on**: Tor Browser routes through the system Tor SOCKS5 proxy at `127.0.0.1:9050` (transparent proxy handles everything else automatically)
- When tormode is **off**: Tor Browser falls back to its own built-in Tor client

## Tor Browser

Tor Browser is pre-installed to `/opt/tor-browser` and runs as a dedicated `tonix-browser` system user for isolation:

```bash
tor-browser          # Launch from your regular user account or as root
```

The launcher handles all execution contexts (root, regular user, or direct) and automatically configures the correct display authority. Stale lock files from crashed sessions are cleaned on each launch.

## Boot Mode

Tonix boots to command line. Start the GUI with:

```bash
startxfce4
```

The desktop loads with custom Tonix wallpapers (all Debian defaults are removed). The wallpaper applies reliably across all monitor configurations via a three-layer approach: system-wide xfconf defaults, per-user config in `/etc/skel`, and a login autostart script that enforces the correct wallpaper for the live monitor name.

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
# The installer detects your existing encrypted /home and preserves it.
```

Temporary installs work too: `apt install something` in immutable mode lives in RAM and disappears on reboot. Your /home data is untouched either way.

## Project Structure

```
tonix/
├── tonix.sh                        Main entry point (build / install / iso / vm-test)
├── config.sh                       All package lists and settings
├── install-common.sh               Shared install logic (partitioning, GRUB, user setup)
├── resources/
│   └── wallpapers/                 Custom wallpapers (add before building):
│                                   tonix-circuit.png, tonix-sunset.png,
│                                   tonix-blue.png, tonix-matrix.png
├── overlays/
│   ├── etc/
│   │   ├── initramfs-tools/        Overlay root hooks (immutable OS)
│   │   ├── udev/rules.d/          WiFi adapter auto-detection
│   │   ├── NetworkManager/         MAC randomization config
│   │   ├── systemd/system/         Services (MAC spoof, WiFi, RAM wipe, hardening)
│   │   └── modprobe.d/            WiFi driver config
│   └── usr/local/
│       ├── bin/                    Commands: stego, tonix-tormode, tor-browser, etc.
│       └── share/stego/           Steganography tool source
├── docs/                           Documentation
│   └── PACKAGE_CACHE.md           Cache system guide
├── cache/                          (generated, 2-4GB persistent package cache)
├── build/                          (generated, temporary build files)
└── output/                         (generated, final tarballs and ISOs)
```

## Penetration Testing Tools

Pre-installed toolkit beyond WiFi auditing:

| Category | Tools |
|----------|-------|
| Web scanning | nikto, dirb, gobuster, wfuzz, whatweb |
| Web exploitation | sqlmap, mitmproxy, sslsplit, sslscan |
| HTTP client | httpie |
| Login brute-forcing | hydra, medusa |
| File cracking | fcrackzip, pdfcrack, ophcrack |
| Wordlist generation | crunch, cewl |
| Password cracking | hashcat, john, cowpatty |
| SNMP enumeration | snmp, onesixtyone |
| OSINT & recon | theharvester, recon-ng, dnsrecon, dnsenum, fierce, dmitry |
| Windows / SMB / AD | enum4linux, smbclient, nbtscan, ldap-utils, samdump2, chntpw |
| Packet crafting | hping3 |
| Layer 2 attacks | yersinia, dsniff, ettercap |
| Passive analysis | p0f, tcpflow |
| Reverse engineering | radare2, nasm, gdb |
| Proxy & tunneling | proxychains4, iodine, proxytunnel, obfs4proxy |
| Network testing | iperf3, sshuttle, mtr |
| Packet capture | wireshark, tshark, tcpdump |
| Exploit database | exploitdb (searchsploit) |
| Hardware / embedded | avrdude, openocd, flashrom |
| SDR / radio | rtl-sdr, ubertooth |

## Tails-Inspired Security

| Feature | Tails | Tonix |
|---------|-------|-------|
| All traffic through Tor | Always on | Toggle with `tonix-tormode on` |
| Tor Browser | Default browser | Pre-installed, runs as sandboxed `tonix-browser` user |
| Immutable root | SquashFS | overlayfs with tmpfs (same effect) |
| MAC spoofing | Kernel-level at boot | Early systemd unit before NetworkManager |
| RAM wipe on shutdown | Custom kernel patch | sdmem + cache flush (userspace) |
| Encrypted persistence | Opt-in, limited dirs | Always-on encrypted /home |
| Writable mode | Not available | Boot option for maintenance |
| VPN support | Not built-in | OpenVPN + WireGuard pre-installed |
| DNS encryption | Custom setup | dnscrypt-proxy pre-installed |
| Rootkit detection | Not included | rkhunter + chkrootkit |
| Custom software | Requires rebuild | Temporarily via apt, or rebuild |

## WiFi Adapter Support

| Adapter | Chipset | Driver | Status |
|---------|---------|--------|--------|
| AWUS036ACM | MT7612U | mt76x2u (in-kernel) | Works out of box |
| AWUS036AXML | MT7921AUN | mt7921u (in-kernel) | Works out of box |
| AWUS1900 | RTL8814AU | 8814au (DKMS) | Built from source |

## Build Requirements

- Debian/Ubuntu host system (Linux only)
- ~25-30GB free disk space (15GB root image + 2-4GB package cache + build overhead)
- Internet connection (~4-6GB download for first build)
- Root access
- Wallpaper PNGs placed in `resources/wallpapers/` before building (see Project Structure above)

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

See `docs/PACKAGE_CACHE.md` for complete documentation.

## Default Credentials

| Context | Username | Password |
|---------|----------|----------|
| Installed OS | **chosen at install time** | **chosen at install time** |
| Installer ISO (live env) | `root` | `tonix` |

The installed system has no fixed default credentials — you set your own username and password during the installation wizard. The root account is locked on the installed system. Use `sudo -i` to get a root shell when needed.

## Technical Notes

**GRUB boot architecture:** BIOS boot uses `grub-mkimage` with an explicit `(,gpt2)/grub` prefix (resolves to the correct disk at runtime, works correctly from both live ISO and direct install — avoids the wrong-prefix-embedding bug that causes GRUB rescue shell on USB). UEFI boot uses `grub-mkstandalone` from the host with the full boot menu baked into the EFI binary, eliminating the failure mode where GRUB drops to rescue shell searching for a `/.disk/info` file. A custom `10_tonix` script in `/etc/grub.d/` handles kernel updates via `update-grub` on the running system; the standard Debian GRUB generators are disabled.

**Installer reliability:** USB autosuspend is disabled for the target drive during installation to prevent bus dropouts during heavy writes. `partx --delete` cleanly removes partition references before repartitioning (more reliable than `partprobe` on USB controllers that hold stale state). GPT backup headers are repaired with `sgdisk --move-second-header` after all writes complete, and the drive's internal cache is flushed with `blockdev --flushbufs` to prevent partition table corruption on replug. GNOME automount is suppressed during install to prevent the host from remounting partitions mid-operation.

**Tor transparent proxy:** DNS is redirected to Tor's DNSPort on `127.0.0.1:5300` — port 5300 is used deliberately (5353 is mDNS/Avahi and causes conflicts). The drop-in config only adds `TransPort` and `DNSPort`; `SocksPort 9050` stays in the default torrc to avoid a double-bind crash on Tor startup.

**Sensitive data handling:** `/tmp`, `/var/tmp`, `/var/log`, and `/run/shm` are all mounted as tmpfs — no sensitive runtime data touches disk. Swap is masked at the systemd level in addition to the sysctl `vm.swappiness=0` setting. The LUKS encryption password is zeroed from memory immediately after the install phase that needs it.