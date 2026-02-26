#!/bin/bash
# ============================================================================
# Tonix Configuration
# ============================================================================
# All shared settings: package lists, versions, branding, partition sizes

OS_NAME="Tonix"
OS_VERSION="0.1"
OS_CODENAME="Mirage"
OS_HOSTNAME="tonix"
OS_PRETTY_NAME="${OS_NAME} ${OS_VERSION}"
OS_LOCALE="en_US.UTF-8"
OS_TIMEZONE="UTC"

# Build settings
DEBIAN_RELEASE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian/"

# Partition sizes (in MiB)
BOOT_SIZE_MIB=512
ROOT_SIZE_MIB=15360  # 15GB
# HOME gets everything remaining

# Architecture support
# Set to "amd64" for 64-bit only, or "both" to build separate 32+64 images
ARCH_MODE="amd64"  # Options: amd64, i386, both

# ============================================================================
# Package Lists
# ============================================================================

# --- Core System ---
PACKAGES_CORE=(
    linux-image-amd64
    systemd-sysv
    dbus
    policykit-1
    sudo
    locales
    console-setup
    keyboard-configuration
    bash
    coreutils
    util-linux
    procps
    kmod
)

# --- Bootloader ---
# NOTE: grub-pc is intentionally excluded — its postinst triggers a debconf
# dialog asking which disk to install GRUB to, which can hang noninteractive
# builds. grub-pc-bin provides the i386-pc modules we need, and grub-common
# (auto-pulled as a dependency) provides grub-install and grub-mkconfig.
PACKAGES_BOOTLOADER=(
    grub-common
    grub-pc-bin
    grub-efi-amd64-bin
    grub-efi-ia32-bin
    shim-signed
    efibootmgr
)

# --- Encryption ---
PACKAGES_ENCRYPTION=(
    cryptsetup
    cryptsetup-initramfs
    lvm2
    gnupg
    gnupg2
    keepassxc
    age
    paperkey
    openssl
    gocryptfs
    encfs
    ccrypt
    git-crypt
    ssss
    pwgen
    apg
    signify-openbsd
    pcscd
    opensc
    scdaemon
    yubikey-manager
)

# --- Desktop (XFCE) ---
PACKAGES_DESKTOP=(
    xfce4
    xfce4-goodies
    xfce4-terminal
    xfce4-power-manager
    xfce4-screenshooter
    xfce4-taskmanager
    xfce4-whiskermenu-plugin
    lightdm
    lightdm-gtk-greeter
    lightdm-gtk-greeter-settings
    thunar-archive-plugin
    thunar-volman
    ristretto
    feh
    nsxiv
    mousepad
    file-roller
    xfce4-clipman-plugin
    redshift-gtk
    catfish
)

# --- Firmware (broad hardware compatibility) ---
PACKAGES_FIRMWARE=(
    firmware-linux-free
    firmware-linux-nonfree
    firmware-iwlwifi
    firmware-realtek
    firmware-atheros
    firmware-misc-nonfree
    #firmware-mediatek
)

# --- Networking ---
PACKAGES_NETWORKING=(
    network-manager
    network-manager-gnome
    net-tools
    iputils-ping
    traceroute
    dnsutils
    wireless-tools
    wpasupplicant
    rfkill
    usb-modeswitch
    iw
)

# --- Privacy & Security ---
PACKAGES_PRIVACY=(
    tor
    torsocks
    proxychains4
    dnscrypt-proxy
    openvpn
    wireguard-tools
    ufw
    firejail
    macchanger
    mat2
    bleachbit
    secure-delete
    rng-tools
    apparmor
    apparmor-profiles
    apparmor-utils
    rkhunter
    chkrootkit
    lynis
    aide
    auditd
    pass
    onionshare
    obfs4proxy
)

# --- Browsers ---
PACKAGES_BROWSERS=(
    firefox-esr
)

# --- Editors & Terminal ---
PACKAGES_EDITORS=(
    vim
    neovim
    nano
    mc
    tmux
    screen
    htop
    btop
    bash-completion
    man-db
    less
    tree
    ncdu
    ranger
    fzf
    ripgrep
    bat
    fd-find
    exa
    tldr
    pandoc
    zsh
    zsh-autosuggestions
    zsh-syntax-highlighting
)

# --- File & Archive Tools ---
PACKAGES_FILES=(
    zip
    unzip
    tar
    gzip
    bzip2
    xz-utils
    zstd
    lz4
    p7zip-full
    unrar-free
)

# --- Network Tools ---
PACKAGES_NETTOOLS=(
    openssh-client
    wget
    curl
    rsync
    nmap
    whois
    netcat-openbsd
    socat
    aria2
    iperf3
    sshuttle
    mtr
    sshfs
    stunnel4
    iodine
    proxytunnel
    sshpass
    httpie
)

# --- Development (lightweight) ---
PACKAGES_DEV=(
    git
    build-essential
    python3
    python3-pip
    python3-venv
    ruby
    jq
    yq
    xmlstarlet
    miller
    sqlite3
    ltrace
    minicom
    picocom
    flashrom
    avrdude
    openocd
    dkms
    linux-headers-amd64
    linux-compiler-gcc-12-x86
)

# --- Media (minimal) ---
PACKAGES_MEDIA=(
    mpv
    vlc
    ffmpeg
    cmus
    audacious
    pipewire
    pipewire-pulse
    wireplumber
    pavucontrol
    pipewire-alsa
)

# --- System Utilities ---
PACKAGES_SYSUTIL=(
    gparted
    dosfstools
    ntfs-3g
    exfat-fuse
    exfatprogs
    smartmontools
    lsof
    strace
    usbutils
    pciutils
    hdparm
    parted
    testdisk
    pv
    dialog
    iotop
    iftop
    nethogs
    sysstat
    lm-sensors
    zram-tools
    earlyoom
)

# --- Steganography, Forensics & Dependencies ---
# Includes system packages needed by your custom stego-gui .deb tool
PACKAGES_STEGO=(
    # CLI steganography tools
    steghide
    outguess

    # Forensics
    libimage-exiftool-perl
    binwalk
    foremost
    hexedit
    xxd
    sleuthkit
    dc3dd
    gddrescue
    hashdeep

    # Python dependencies for your stego-gui app
    python3-tk
    python3-cryptography
    python3-pil
    python3-pil.imagetk
)

# --- Alfa WiFi USB Adapters & SDR Hardware ---
# AWUS036ACM  → mt76x2u   (in-kernel, needs firmware-mediatek)
# AWUS036AXML → mt7921u   (in-kernel since 5.18, needs firmware-mediatek)
# AWUS1900    → rtl8814au (out-of-tree, needs DKMS build)
PACKAGES_WIFI_EXTRA=(
    # firmware-mediatek, dkms, linux-headers-amd64 already in other arrays
    # rtl8814au driver will be built from source in the build script

    # SDR hardware support
    rtl-sdr
    ubertooth
)

# RTL8814AU driver for AWUS1900
RTL8814AU_REPO="https://github.com/aircrack-ng/rtl8814au.git"

# --- Tor Browser ---
TOR_VERSION="15.0.7"
TOR_ARCH="linux-x86_64"
TOR_DIR="/opt/tor-browser"
TOR_URL="https://dist.torproject.org/torbrowser/${TOR_VERSION}/tor-browser-${TOR_ARCH}-${TOR_VERSION}.tar.xz"

# --- WiFi Security & Penetration Testing ---
# Auditing, rogue AP detection, deauth testing, traffic analysis
PACKAGES_WIFI_SECURITY=(
    # Core WiFi auditing
    aircrack-ng
    kismet-core
    kismet-capture-linux-wifi
    kismet-capture-linux-bluetooth
    kismet-logtools
    wifite
    hostapd
    reaver
    pixiewps

    # Packet capture & analysis
    wireshark
    tshark
    tcpdump
    ettercap-text-only

    # Network monitoring & intrusion detection
    arpwatch
    suricata
    fail2ban

    # Password & hash testing (WPA handshake cracking)
    hashcat
    john
    cowpatty

    # WPA/PMKID capture tools
    hcxdumptool
    hcxtools

    # Network scanning (nmap already in PACKAGES_NETTOOLS)
    masscan
    netdiscover

    # ARP/MITM testing
    dsniff
    hping3
    yersinia

    # Passive analysis & session reconstruction
    p0f
    tcpflow

    # Runtime libraries for tools built from source (mdk4)
    # The -dev packages are build-time only and get removed after build;
    # these are the actual shared libraries mdk4 needs to run
    libnl-3-200
    libnl-genl-3-200
    libpcap0.8
)

# --- Penetration Testing (web, login, reverse engineering) ---
PACKAGES_PENTEST=(
    # Web scanning & exploitation
    nikto
    sqlmap
    gobuster
    dirb
    whatweb
    wfuzz
    mitmproxy
    sslsplit

    # Login & file brute-forcing
    hydra
    medusa
    fcrackzip
    pdfcrack
    ophcrack

    # Wordlist generation
    crunch
    cewl

    # SNMP enumeration
    snmp
    onesixtyone

    # SSL/TLS auditing
    sslscan

    # Exploit database
    exploitdb

    # Reverse engineering & binary analysis
    radare2
    nasm
    gdb
)

# --- OSINT & Reconnaissance ---
PACKAGES_OSINT=(
    theharvester
    recon-ng
    dnsrecon
    dnsenum
    dmitry
    fierce
)

# --- Windows / SMB / Active Directory ---
PACKAGES_WINDOWS=(
    enum4linux
    smbclient
    nbtscan
    ldap-utils
    samdump2
    chntpw
)

# --- WiFi Security — Built from Source (not in Debian repos) ---
# These are cloned from GitHub and built during the OS build phase.
# Format: "name|repo_url|build_command"
WIFI_SECURITY_FROM_SOURCE=(
    "bettercap|https://github.com/bettercap/bettercap.git|go build -o /usr/local/bin/bettercap ."
    "mdk4|https://github.com/aircrack-ng/mdk4.git|make && make install"
)

# Bettercap requires Go, mdk4 requires libpcap-dev and libnl-3-dev — build-time only (not in final OS)
BUILD_ONLY_DEPS=(
    golang-go
    libnl-3-dev
    libnl-genl-3-dev
    libpcap-dev
)

# --- Wordlists (downloaded during build, stored in /opt/wordlists) ---
WORDLIST_URLS=(
    "https://github.com/danielmiessler/SecLists/archive/refs/heads/master.zip|SecLists"
    # rockyou.txt is typically sourced from Kali or extracted from rockyou.txt.gz
)
WORDLISTS_DIR="/opt/wordlists"

# --- Python Tools (installed via pip during build) ---
# Installed with: pip install --break-system-packages ${PYTHON_PACKAGES[*]}
PYTHON_PACKAGES=(
    # Network & WiFi
    scapy
    impacket
    netaddr
    paramiko
    python-nmap
    netifaces
    dpkt

    # Security & Forensics
    volatility3
    yara-python
    pwntools
    pylnk3
    wafw00f
    sublist3r
    hashid
    sslyze
    visidata

    # Data & Analysis
    pandas
    requests
    beautifulsoup4

    # Crypto
    # cryptography
)

# --- Nice to have ---
# Note: fastfetch is installed separately in tonix.sh (Phase 2c) — not in Debian repos
PACKAGES_EXTRA=(
    geany
    qalculate-gtk
    evince
    zathura
    mupdf
    abiword
    gnumeric
    imagemagick
    xclip
    xdotool
    flameshot
    podman
    borgbackup
    rclone
    neomutt
)

# ============================================================================
# All packages combined
# ============================================================================
get_all_packages() {
    echo "${PACKAGES_CORE[@]}" \
         "${PACKAGES_BOOTLOADER[@]}" \
         "${PACKAGES_ENCRYPTION[@]}" \
         "${PACKAGES_DESKTOP[@]}" \
         "${PACKAGES_FIRMWARE[@]}" \
         "${PACKAGES_NETWORKING[@]}" \
         "${PACKAGES_PRIVACY[@]}" \
         "${PACKAGES_BROWSERS[@]}" \
         "${PACKAGES_EDITORS[@]}" \
         "${PACKAGES_FILES[@]}" \
         "${PACKAGES_NETTOOLS[@]}" \
         "${PACKAGES_DEV[@]}" \
         "${PACKAGES_MEDIA[@]}" \
         "${PACKAGES_SYSUTIL[@]}" \
         "${PACKAGES_STEGO[@]}" \
         "${PACKAGES_WIFI_EXTRA[@]}" \
         "${PACKAGES_WIFI_SECURITY[@]}" \
         "${PACKAGES_PENTEST[@]}" \
         "${PACKAGES_OSINT[@]}" \
         "${PACKAGES_WINDOWS[@]}" \
         "${PACKAGES_EXTRA[@]}"
}

# ============================================================================
# Installer-only packages (minimal live environment)
# ============================================================================
PACKAGES_INSTALLER=(
    linux-image-amd64
    live-boot
    live-config
    systemd-sysv
    gdisk
    parted
    cryptsetup
    dosfstools
    e2fsprogs
    grub-common
    grub-pc-bin
    grub-efi-amd64-bin
    grub-efi-ia32-bin
    dialog
    pv
    util-linux
    usbutils
    nano
)