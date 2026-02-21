#!/bin/bash
# ============================================================================
# Tonix — Main Build System
# ============================================================================
# Usage:
#   ./tonix.sh build          Build the OS tarball
#   ./tonix.sh install /dev/sdX   Install directly to USB drive
#   ./tonix.sh iso            Build bootable installer ISO
#   ./tonix.sh vm-test [mode] Test in QEMU VM (iso/iso-with-disk/disk/disk-bios)
#   ./tonix.sh clean          Remove all build artifacts
#
# All modes share the same config (config.sh) and install logic
# (install-common.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
CACHE_DIR="$PROJECT_DIR/cache"
CHROOT_DIR="$BUILD_DIR/chroot"
INSTALLER_DIR="$BUILD_DIR/installer-chroot"
ISO_DIR="$BUILD_DIR/iso-staging"
OVERLAY_DIR="$PROJECT_DIR/overlays"

# Package cache control
REFRESH_CACHE=false

source "$SCRIPT_DIR/config.sh"

# ============================================================================
# Colors
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

# ============================================================================
# Prerequisite check
# ============================================================================
check_build_deps() {
    info "Checking build dependencies..."
    local missing=()

    for cmd in debootstrap mksquashfs xorriso parted cryptsetup grub-install; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing tools: ${missing[*]}"
        info "Installing build dependencies..."
        apt update
        apt install -y \
            debootstrap \
            squashfs-tools \
            xorriso \
            isolinux \
            syslinux-efi \
            grub-pc-bin \
            grub-efi-amd64-bin \
            grub-efi-ia32-bin \
            mtools \
            cryptsetup \
            parted \
            dosfstools \
            e2fsprogs \
            pv \
            git
    fi

    ok "All build dependencies present"
}

# ============================================================================
# BUILD: Create OS tarball
# ============================================================================
do_build() {
    [[ $EUID -eq 0 ]] || die "Build must be run as root (for debootstrap/chroot)"

    check_build_deps

    header "Building ${OS_PRETTY_NAME}"

    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

    # Clean previous build
    if [[ -d "$CHROOT_DIR" ]]; then
        warn "Removing previous build..."
        cleanup_chroot
        rm -rf "$CHROOT_DIR"
    fi

    # --- Phase 1: Bootstrap ---
    header "Phase 1: Bootstrapping Debian ${DEBIAN_RELEASE}"

    debootstrap --arch=amd64 --variant=minbase \
        "$DEBIAN_RELEASE" "$CHROOT_DIR" "$DEBIAN_MIRROR"

    ok "Base system bootstrapped"

    # --- Phase 2: Install packages ---
    header "Phase 2: Installing packages"

    mount_chroot
    mount_cache

    # Add non-free repos for firmware
    cat > "$CHROOT_DIR/etc/apt/sources.list" << EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_RELEASE}-backports main contrib non-free non-free-firmware
EOF

    # Add Kismet repo inside chroot (not in Debian repos)
    info "Adding Kismet repository..."
    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_KISMET_REPO'
set -e
export DEBIAN_FRONTEND=noninteractive
apt update -q
apt install -y wget gnupg
wget -O - https://www.kismetwireless.net/repos/kismet-release.gpg.key --quiet | \
    gpg --dearmor | tee /usr/share/keyrings/kismet-archive-keyring.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/kismet-archive-keyring.gpg] https://www.kismetwireless.net/repos/apt/release/bookworm bookworm main' \
    > /etc/apt/sources.list.d/kismet.list
apt update -q
CHROOT_KISMET_REPO

    # Best-effort packages (firmware + DNS protection)
    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_OPTIONAL'
export DEBIAN_FRONTEND=noninteractive
for pkg in firmware-mediatek; do
    apt install -y "$pkg" 2>/dev/null \
        && echo "OK: $pkg" \
        || echo "WARN: $pkg not available, skipping"
done
# dnscrypt-proxy removed — it takes over port 53 on boot with no config,
# breaking DNS entirely. Tor handles DNS when tormode is active.
CHROOT_OPTIONAL

    local all_packages
    all_packages=$(get_all_packages)

    chroot "$CHROOT_DIR" /bin/bash << CHROOT_PACKAGES
set -e
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y $all_packages

CHROOT_PACKAGES

    ok "All packages installed"

    # --- Phase 2b: Install Python packages via pip ---
    local python_packages="${PYTHON_PACKAGES[*]}"

    if [[ -n "$python_packages" ]]; then
        info "Installing Python packages via pip..."

        chroot "$CHROOT_DIR" /bin/bash << CHROOT_PIP
set -e
# --upgrade-strategy only-if-needed prevents pip from upgrading already-installed
# system packages (e.g. numpy) to versions that break other apt packages (e.g. scipy)
pip install --break-system-packages --upgrade-strategy only-if-needed $python_packages
CHROOT_PIP

        ok "Python packages installed"
    fi

    # --- Phase 2c: Install fastfetch (not in Debian bookworm repos) ---
    header "Phase 2c: Installing fastfetch"

    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_FASTFETCH'
set -e
FASTFETCH_VER="2.23.0"
wget -q -O /tmp/fastfetch.deb \
    "https://github.com/fastfetch-cli/fastfetch/releases/download/${FASTFETCH_VER}/fastfetch-linux-amd64.deb" \
    && dpkg -i /tmp/fastfetch.deb || apt-get install -f -y
rm -f /tmp/fastfetch.deb
echo "fastfetch installed"
CHROOT_FASTFETCH

    ok "fastfetch installed"

    # --- Phase 3: Build RTL8814AU driver for AWUS1900 ---
    header "Phase 3: Building RTL8814AU driver (AWUS1900 support)"

    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_DRIVER'
set -e
export DEBIAN_FRONTEND=noninteractive

if command -v git &>/dev/null && command -v dkms &>/dev/null; then
    cd /usr/src
    if [[ ! -d rtl8814au ]]; then
        git clone https://github.com/aircrack-ng/rtl8814au.git rtl8814au-5.8.5.1
    fi

    # Get kernel version
    KVER=$(ls /lib/modules/ | head -1)

    # Register with DKMS
    cat > /usr/src/rtl8814au-5.8.5.1/dkms.conf << 'DKMS_EOF'
PACKAGE_NAME="rtl8814au"
PACKAGE_VERSION="5.8.5.1"
BUILT_MODULE_NAME[0]="8814au"
DEST_MODULE_LOCATION[0]="/kernel/drivers/net/wireless"
AUTOINSTALL="yes"
MAKE[0]="make KSRC=/lib/modules/${kernelver}/build"
CLEAN="make clean"
DKMS_EOF

    dkms add -m rtl8814au -v 5.8.5.1 2>/dev/null || true
    dkms build -m rtl8814au -v 5.8.5.1 -k "$KVER" || echo "WARN: rtl8814au build failed (non-fatal)"
    dkms install -m rtl8814au -v 5.8.5.1 -k "$KVER" || echo "WARN: rtl8814au install failed (non-fatal)"
fi
CHROOT_DRIVER

    ok "WiFi driver build attempted"

    # --- Phase 3a: Build tools from source ---
    if [[ ${#WIFI_SECURITY_FROM_SOURCE[@]} -gt 0 ]]; then
        header "Phase 3a: Building tools from source"

        # Install build-time-only dependencies
        if [[ ${#BUILD_ONLY_DEPS[@]} -gt 0 ]]; then
            local build_deps="${BUILD_ONLY_DEPS[*]}"
            chroot "$CHROOT_DIR" /bin/bash << CHROOT_BUILDDEPS
set -e
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y $build_deps
CHROOT_BUILDDEPS
        fi

        # Build each tool from source
        for entry in "${WIFI_SECURITY_FROM_SOURCE[@]}"; do
            local tool_name tool_repo tool_build
            IFS='|' read -r tool_name tool_repo tool_build <<< "$entry"

            info "Building $tool_name from source..."

            chroot "$CHROOT_DIR" /bin/bash << CHROOT_SRCBUILD
set -e
cd /tmp
if [[ ! -d "$tool_name" ]]; then
    git clone "$tool_repo" "$tool_name"
fi
cd "$tool_name"
$tool_build || echo "WARN: $tool_name build failed (non-fatal)"
cd /tmp && rm -rf "$tool_name"
CHROOT_SRCBUILD

            ok "$tool_name build attempted"
        done

        # Remove build-only dependencies to save space
        if [[ ${#BUILD_ONLY_DEPS[@]} -gt 0 ]]; then
            info "Removing build-only dependencies..."
            local build_deps="${BUILD_ONLY_DEPS[*]}"
            chroot "$CHROOT_DIR" /bin/bash << CHROOT_RMBDEPS
set -e
export DEBIAN_FRONTEND=noninteractive
apt purge -y $build_deps 2>/dev/null || true
apt autoremove -y
CHROOT_RMBDEPS
        fi

        ok "Source builds complete"
    fi

    # --- Phase 3b: Download and install Tor Browser ---
    header "Phase 3b: Installing Tor Browser"

    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_TORBROWSER'
set -e
export DEBIAN_FRONTEND=noninteractive

TOR_VERSION="15.0.6"
TOR_ARCH="linux-x86_64"
TOR_LANG="en-US"
TOR_DIR="/opt/tor-browser"
TOR_URL="https://dist.torproject.org/torbrowser/${TOR_VERSION}/tor-browser-${TOR_ARCH}-${TOR_VERSION}.tar.xz"

echo "Downloading Tor Browser ${TOR_VERSION}..."

mkdir -p "$TOR_DIR"
cd /tmp

# Download Tor Browser
if wget -q --timeout=300 "$TOR_URL" -O tor-browser.tar.xz 2>/dev/null; then
    tar -xJf tor-browser.tar.xz -C "$TOR_DIR" --strip-components=1
    rm -f tor-browser.tar.xz

    # Launcher is provided via overlays/usr/local/bin/tor-browser
    # Create dedicated system user for Tor Browser at build time
    useradd -r -s /usr/sbin/nologin -d /var/lib/tonix-browser -m tonix-browser 2>/dev/null || true
    chown -R tonix-browser:tonix-browser "$TOR_DIR"
    chmod -R 755 "$TOR_DIR"

    echo "Tor Browser ${TOR_VERSION} installed"
else
    echo "WARN: Tor Browser download failed (non-fatal). Install manually later."
    echo "  wget $TOR_URL"
fi

CHROOT_TORBROWSER

    ok "Tor Browser install attempted"

    # --- Phase 4: System configuration ---
    header "Phase 4: System configuration"

    configure_os

    # --- Phase 5: Apply overlays ---
    header "Phase 5: Applying overlay files"

    if [[ -d "$OVERLAY_DIR" ]]; then
        cp -a "$OVERLAY_DIR"/* "$CHROOT_DIR/" 2>/dev/null || true
        ok "Overlays applied"
    fi

    # Make overlay scripts executable
    find "$CHROOT_DIR/usr/local/bin" -type f -exec chmod +x {} \; 2>/dev/null || true

    # Enable overlay systemd services
    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_SERVICES'
set -e

# Enable services from overlays
systemctl enable tonix-wifi-monitor.service 2>/dev/null || true
systemctl enable tonix-hardening.service 2>/dev/null || true
systemctl enable tonix-early-mac.service 2>/dev/null || true

# Enable core services
systemctl enable NetworkManager 2>/dev/null || true
# Boot to CLI — users run startxfce4 manually to start the GUI.
# LightDM is masked entirely to prevent it from auto-starting via
# graphical.target → display-manager.service even when "disabled".
systemctl disable lightdm 2>/dev/null || true
systemctl mask    lightdm 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true
systemctl enable apparmor 2>/dev/null || true
systemctl enable ufw 2>/dev/null || true
# tor is NOT enabled at boot — it starts on demand via tonix-tormode
# Enabling it at boot with no transparent proxy config wastes resources
# and can cause DNS conflicts before NetworkManager is ready.
systemctl disable tor 2>/dev/null || true

# Disable unnecessary services
systemctl mask bluetooth 2>/dev/null || true
systemctl mask cups 2>/dev/null || true
systemctl mask avahi-daemon 2>/dev/null || true
systemctl mask ModemManager 2>/dev/null || true

# Make initramfs hooks executable
chmod +x /etc/initramfs-tools/hooks/tonix-overlay 2>/dev/null || true
chmod +x /etc/initramfs-tools/scripts/init-bottom/tonix-overlay 2>/dev/null || true

# Rebuild initramfs to include overlayfs support and tonix hooks
update-initramfs -u -k all 2>/dev/null || update-initramfs -c -k all

CHROOT_SERVICES

    ok "Services configured"

    # --- Phase 5b: Tonix Wallpapers & XFCE4 Desktop Branding ---
    header "Phase 5b: Wallpapers & XFCE4 branding"

    local wp_src="$SCRIPT_DIR/resources/wallpapers"
    local wp_dest="$CHROOT_DIR/usr/share/backgrounds/tonix"

    # Remove all Debian default wallpapers
    rm -f  "$CHROOT_DIR/usr/share/backgrounds/"*.png \
           "$CHROOT_DIR/usr/share/backgrounds/"*.jpg \
           "$CHROOT_DIR/usr/share/backgrounds/"*.jpeg \
           "$CHROOT_DIR/usr/share/backgrounds/"*.svg \
           "$CHROOT_DIR/usr/share/backgrounds/"*.xml 2>/dev/null || true
    rm -rf "$CHROOT_DIR/usr/share/backgrounds/desktop-background" 2>/dev/null || true
    rm -rf "$CHROOT_DIR/usr/share/xfce4/backdrops" 2>/dev/null || true
    rm -rf "$CHROOT_DIR/usr/share/desktop-base" 2>/dev/null || true
    ok "Debian wallpapers removed"

    # Install Tonix wallpapers
    mkdir -p "$wp_dest"
    local wp_found=0
    for wp in tonix-circuit.png tonix-sunset.png tonix-blue.png tonix-matrix.png; do
        if [[ -f "$wp_src/$wp" ]]; then
            cp "$wp_src/$wp" "$wp_dest/"
            wp_found=$(( wp_found + 1 ))
            info "Installed wallpaper: $wp"
        else
            warn "Wallpaper missing: resources/wallpapers/$wp — add this file before building"
        fi
    done

    if [[ $wp_found -gt 0 ]]; then
        ok "Installed $wp_found / 4 Tonix wallpapers → /usr/share/backgrounds/tonix/"
    else
        warn "No wallpapers installed — add PNG files to resources/wallpapers/ and rebuild"
    fi

    # --- Configure XFCE4 default wallpaper (tonix-sunset.png) ---
    # Three-layer approach ensures the wallpaper applies regardless of monitor name:
    #   1. /etc/xdg/ — system-wide xfconf default (read by xfconfd before user config)
    #   2. ~/.config/ — per-user override copied into /home/tonix and /etc/skel
    #   3. Autostart script — runs at each login and force-sets the wallpaper for the
    #      actual monitor name, covering cases where xfce4-desktop already created
    #      the property with its own default before our XML was consulted.
    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_WALLPAPER'
set -e

WALLPAPER="/usr/share/backgrounds/tonix/tonix-sunset.png"

# Build the xfce4-desktop XML once — used in all three locations below.
# We cover every common monitor name variant. The autostart script handles
# any name not in this list by enumerating live xfconf properties at runtime.
build_xfce4_xml() {
    cat << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorVirtual-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorVirtual1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorHDMI-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorHDMI-2" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorDP-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorDP-2" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitoreDISPLAY" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitorVGA-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
      <property name="monitoreDP-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="image-path" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
          <property name="last-image" type="string" value="/usr/share/backgrounds/tonix/tonix-sunset.png"/>
        </property>
      </property>
    </property>
  </property>
</channel>
XML
}

# --- Layer 1: /etc/xdg/ — system-wide xfconf default ---
# xfconfd reads this BEFORE the user's ~/.config/ on a fresh session.
# This is the highest-priority static fallback.
XDG_XFCONF="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XDG_XFCONF"
build_xfce4_xml > "$XDG_XFCONF/xfce4-desktop.xml"

# --- Layer 2: /etc/skel/ + /home/tonix/ — per-user config ---
# Populated into skel for future users, and directly into /home/tonix
# since useradd already ran before skel was created.
SKEL_XFCONF="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
TONIX_XFCONF="/home/tonix/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$SKEL_XFCONF" "$TONIX_XFCONF"
build_xfce4_xml > "$SKEL_XFCONF/xfce4-desktop.xml"
build_xfce4_xml > "$TONIX_XFCONF/xfce4-desktop.xml"
chown -R tonix:tonix /home/tonix/.config

# --- Layer 3: Autostart script — force-apply at every login ---
# XFCE4's xfce4-desktop daemon creates xfconf properties for the actual
# monitor name when it starts. If that name wasn't in our XML above, it
# uses its own built-in default. This script runs after xfconfd and
# xfce4-desktop are both up, enumerates all live monitor properties, and
# force-sets the wallpaper on each one.
#
# KEY FIX: We must handle two cases for each property:
#   a) Property doesn't exist yet → use -n -t to create it
#   b) Property already exists (xfce4 created it with default) → use -s alone to update
# Using -n alone silently fails case (b). The xfset() helper tries both.

AUTOSTART_DIR="/etc/skel/.config/autostart"
mkdir -p "$AUTOSTART_DIR" "/home/tonix/.config/autostart"

cat > "$AUTOSTART_DIR/tonix-wallpaper.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Tonix Wallpaper
Comment=Apply Tonix default wallpaper on XFCE4 session start
Exec=/usr/local/bin/tonix-set-wallpaper
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP

cp "$AUTOSTART_DIR/tonix-wallpaper.desktop" "/home/tonix/.config/autostart/tonix-wallpaper.desktop"
chown tonix:tonix "/home/tonix/.config/autostart/tonix-wallpaper.desktop"

cat > /usr/local/bin/tonix-set-wallpaper << 'SCRIPT'
#!/bin/bash
# Tonix — force-apply wallpaper at every XFCE4 session start.
# Runs via autostart AFTER xfconfd and xfce4-desktop are up.
WALLPAPER="/usr/share/backgrounds/tonix/tonix-sunset.png"
[[ -f "$WALLPAPER" ]] || exit 0
command -v xfconf-query &>/dev/null || exit 0

# xfset: create-or-update a single xfconf property.
# -n -t creates new properties; plain -s updates existing ones.
# We try create first (fails if exists), then update (works regardless).
xfset_int()    { local p="$1" v="$2"
    xfconf-query -c xfce4-desktop -p "$p" -n -t int    -s "$v" 2>/dev/null \
 || xfconf-query -c xfce4-desktop -p "$p"              -s "$v" 2>/dev/null || true; }
xfset_string() { local p="$1" v="$2"
    xfconf-query -c xfce4-desktop -p "$p" -n -t string -s "$v" 2>/dev/null \
 || xfconf-query -c xfce4-desktop -p "$p"              -s "$v" 2>/dev/null || true; }

# Wait briefly for xfce4-desktop to finish registering all monitor properties
sleep 1

# Enumerate every monitor xfce4-desktop has registered and force our wallpaper
for monitor in $(xfconf-query -c xfce4-desktop -l 2>/dev/null \
        | grep -oP '/backdrop/screen0/monitor[^/]+' | sort -u); do
    for ws in 0 1 2 3; do
        base="$monitor/workspace$ws"
        xfset_int    "$base/color-style"  0
        xfset_int    "$base/image-style"  5
        xfset_string "$base/image-path"   "$WALLPAPER"
        xfset_string "$base/last-image"   "$WALLPAPER"
    done
done
SCRIPT
chmod +x /usr/local/bin/tonix-set-wallpaper

CHROOT_WALLPAPER

    ok "XFCE4 wallpaper configured (tonix-sunset.png)"

    # --- Phase 6: Cleanup and pack ---
    header "Phase 6: Cleanup and packaging"

    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_CLEAN'
set -e
# NOTE: Do NOT run 'apt clean' or remove /var/cache/apt/archives/*.deb here.
# That directory is bind-mounted from the host cache/ folder and removing
# files inside the chroot would destroy the package cache.
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
# Keep locale we need
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
CHROOT_CLEAN

    cleanup_chroot

    # Create tarball
    local tarball="$OUTPUT_DIR/tonix-${OS_VERSION}.tar.gz"

    info "Creating tarball (this takes a few minutes)..."
    tar -czf "$tarball" -C "$CHROOT_DIR" \
        --exclude='./proc/*' \
        --exclude='./sys/*' \
        --exclude='./dev/*' \
        --exclude='./run/*' \
        .

    local size
    size=$(du -h "$tarball" | cut -f1)

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✓ Build complete!                                        ║"
    echo "║                                                           ║"
    echo "║  Image:  $tarball"
    echo "║  Size:   $size"
    echo "║                                                           ║"
    echo "║  Next steps:                                              ║"
    echo "║    ./tonix.sh install /dev/sdX   (direct install)     ║"
    echo "║    ./tonix.sh iso                (build installer)    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

# ============================================================================
# OS configuration (called during build)
# ============================================================================
configure_os() {
    chroot "$CHROOT_DIR" /bin/bash << CHROOT_CONFIG
set -e
export DEBIAN_FRONTEND=noninteractive

# --- Locale ---
echo "${OS_LOCALE} UTF-8" > /etc/locale.gen
locale-gen
update-locale LANG=${OS_LOCALE}

# --- Timezone ---
ln -sf /usr/share/zoneinfo/${OS_TIMEZONE} /etc/localtime
echo "${OS_TIMEZONE}" > /etc/timezone

# --- Hostname ---
echo "${OS_HOSTNAME}" > /etc/hostname
cat > /etc/hosts << 'EOF_HOSTS'
127.0.0.1   localhost
127.0.1.1   ${OS_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF_HOSTS

# --- OS Branding ---
cat > /etc/os-release << 'EOF_OS'
NAME="${OS_NAME}"
VERSION="${OS_VERSION} (${OS_CODENAME})"
ID=tonix
ID_LIKE=debian
PRETTY_NAME="${OS_PRETTY_NAME}"
VERSION_ID="${OS_VERSION}"
LOGO=tonix-logo
EOF_OS

# --- Create regular user 'tonix' with sudo access ---
useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev tonix
echo "tonix:tonix" | chpasswd

# --- Sudoers configuration ---
# tonix can run all sudo commands without password (it's the primary user)
cat > /etc/sudoers.d/tonix << 'EOF_SUDOERS'
# Tonix primary user — full sudo without password
tonix ALL=(ALL) NOPASSWD: ALL

# tonix-browser can only run specific commands needed by the tor-browser launcher
tonix-browser ALL=(root) NOPASSWD: /usr/sbin/aa-complain
tonix-browser ALL=(root) NOPASSWD: /usr/bin/tee /proc/sys/kernel/unprivileged_userns_clone
EOF_SUDOERS
chmod 440 /etc/sudoers.d/tonix

# Add to wireshark group only if it exists (created by wireshark package)
if getent group wireshark &>/dev/null; then
    usermod -aG wireshark tonix
fi

# --- Lock root account (no direct root login) ---
passwd -l root

# --- Disable root login via SSH ---
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-tonix.conf << 'EOF_SSH'
PermitRootLogin no
PasswordAuthentication yes
EOF_SSH

# --- Encryption in initramfs ---
echo "CRYPTSETUP=y" > /etc/cryptsetup-initramfs/conf-hook

# --- Kernel boot parameters ---
cat > /etc/default/grub << 'EOF_GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Tonix"
GRUB_CMDLINE_LINUX_DEFAULT="quiet noresume apparmor=1 security=apparmor"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
EOF_GRUB

# --- Disable default GRUB entry generators ---
# Our custom 10_tonix (installed during install phase) replaces these.
# Disable them now so any build-time update-grub calls don't generate
# configs with wrong /boot/ paths.
chmod -x /etc/grub.d/10_linux 2>/dev/null || true
chmod -x /etc/grub.d/20_linux_xen 2>/dev/null || true
chmod -x /etc/grub.d/30_os-prober 2>/dev/null || true

# --- Firewall (UFW) ---
ufw default deny incoming
ufw default allow outgoing
ufw --force enable 2>/dev/null || true

# --- Sysctl hardening ---
cat > /etc/sysctl.d/99-tonix.conf << 'EOF_SYSCTL'
# Disable swap entirely
vm.swappiness=0

# Network hardening
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# Prevent core dumps (sensitive data leak)
fs.suid_dumpable=0

# Restrict kernel pointer access
kernel.kptr_restrict=2

# Restrict dmesg to root
kernel.dmesg_restrict=1

# ASLR
kernel.randomize_va_space=2
EOF_SYSCTL

# --- Prevent swap creation ---
systemctl mask swap.target 2>/dev/null || true
systemctl mask zram-setup@.service 2>/dev/null || true

# --- MOTD ---
cat > /etc/motd << 'EOF_MOTD'

  Tonix 0.1 — Codename: Mirage

  /home encrypted (LUKS2)      MAC spoofed at boot
  Firewall active (ufw)        AppArmor enabled
  No swap — RAM only           Root is immutable (overlayfs)

  Start GUI:        startxfce4
  Tor-only mode:    sudo tonix-tormode on|off|status
  Tor Browser:      tor-browser
  System status:    tonix-status
  WiFi status:      nmcli device status
  Stego tool:       stego --help
  Change password:  passwd
  Switch to root:   sudo -i

EOF_MOTD

# --- LightDM config (kept minimal — LightDM is masked at boot) ---
# These files are present on disk so the package doesn't complain,
# but LightDM never starts unless the user explicitly runs it.
mkdir -p /etc/lightdm/lightdm.conf.d

cat > /etc/lightdm/lightdm.conf.d/50-tonix.conf << 'EOF_LDM'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=xfce
greeter-hide-users=false
greeter-show-manual-login=true
EOF_LDM

# --- Console login banner (/etc/issue) ---
# /etc/issue is printed by agetty BEFORE the "login:" prompt on every tty.
# We use it to show the Tonix banner and make the prompt context clear.
# No agetty drop-ins needed — the stock agetty + /etc/issue is rock-solid.
cat > /etc/issue << 'EOF_ISSUE'

  ████████╗ ██████╗ ███╗   ██╗██╗██╗  ██╗
     ██╔══╝██╔═══██╗████╗  ██║██║╚██╗██╔╝
     ██║   ██║   ██║██╔██╗ ██║██║ ╚███╔╝
     ██║   ██║   ██║██║╚██╗██║██║ ██╔██╗
     ██║   ╚██████╔╝██║ ╚████║██║██╔╝ ██╗
     ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝

  Codename: Mirage  |  \l

  Enter your username at the prompt below.

EOF_ISSUE

# --- Update initramfs ---
update-initramfs -u -k all 2>/dev/null || update-initramfs -c -k all

CHROOT_CONFIG

    ok "System configured"
}

# ============================================================================
# INSTALL: Direct install to USB drive
# ============================================================================
do_install_direct() {
    [[ $EUID -eq 0 ]] || die "Install must be run as root"

    local target="${1:-}"
    [[ -n "$target" ]] || die "Usage: $0 install /dev/sdX"
    [[ -b "$target" ]] || die "$target is not a block device"

    local tarball="$OUTPUT_DIR/tonix-${OS_VERSION}.tar.gz"
    [[ -f "$tarball" ]] || die "OS image not found: $tarball\nRun '$0 build' first."

    # Export for install-common.sh
    export TARBALL_PATH="$tarball"
    export TARGET="$target"
    export OS_PRETTY_NAME
    export OS_HOSTNAME
    export BOOT_SIZE_MIB
    export ROOT_SIZE_MIB

    source "$SCRIPT_DIR/install-common.sh"
    do_install
}

# ============================================================================
# ISO: Build bootable installer ISO
# ============================================================================
do_build_iso() {
    [[ $EUID -eq 0 ]] || die "ISO build must be run as root"

    check_build_deps

    local tarball="$OUTPUT_DIR/tonix-${OS_VERSION}.tar.gz"
    [[ -f "$tarball" ]] || die "OS image not found: $tarball\nRun '$0 build' first."

    header "Building Installer ISO"

    # Clean previous
    [[ -d "$INSTALLER_DIR" ]] && rm -rf "$INSTALLER_DIR"
    [[ -d "$ISO_DIR" ]] && rm -rf "$ISO_DIR"

    mkdir -p "$INSTALLER_DIR" "$ISO_DIR"

    # --- Minimal live system for installer ---
    info "Bootstrapping installer environment..."
    debootstrap --arch=amd64 --variant=minbase \
        "$DEBIAN_RELEASE" "$INSTALLER_DIR" "$DEBIAN_MIRROR"

    mount --bind /dev  "$INSTALLER_DIR/dev"
    mount --bind /proc "$INSTALLER_DIR/proc"
    mount --bind /sys  "$INSTALLER_DIR/sys"

    # Mount cache for installer packages too
    mkdir -p "$CACHE_DIR/apt-archives"
    mkdir -p "$INSTALLER_DIR/var/cache/apt/archives"
    mount --bind "$CACHE_DIR/apt-archives" "$INSTALLER_DIR/var/cache/apt/archives"

    local installer_packages="${PACKAGES_INSTALLER[*]}"

    chroot "$INSTALLER_DIR" /bin/bash << CHROOT_INSTALLER
set -e
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y $installer_packages

# Explicitly regenerate initrd so live-boot hooks are included.
# live-boot's postinst may not fire correctly inside a chroot, so we
# force it here after all packages are settled.
update-initramfs -u -k all 2>/dev/null || update-initramfs -c -k all

# NOTE: Do NOT run 'apt clean' here — the archives dir is bind-mounted
# from the host cache/ folder. Cleaning would destroy the package cache.
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CHROOT_INSTALLER

    # Set root password for installer environment
    # (root is only used in the live installer to run install-tonix)
    chroot "$INSTALLER_DIR" /bin/bash << 'CHROOT_PASS'
echo "root:tonix" | chpasswd
CHROOT_PASS

    # Embed the OS tarball
    mkdir -p "$INSTALLER_DIR/opt/tonix"
    cp "$tarball" "$INSTALLER_DIR/opt/tonix/"

    # Copy install scripts
    cp "$SCRIPT_DIR/install-common.sh" "$INSTALLER_DIR/opt/tonix/"
    cp "$SCRIPT_DIR/config.sh" "$INSTALLER_DIR/opt/tonix/"

    # Create the installer entry point
    cat > "$INSTALLER_DIR/usr/local/bin/install-tonix" << 'INST_SCRIPT'
#!/bin/bash
# Tonix Installer — runs from booted ISO
set -euo pipefail

SCRIPT_DIR="/opt/tonix"
source "$SCRIPT_DIR/config.sh"

# Find the tarball
TARBALL_PATH=$(ls /opt/tonix/tonix-*.tar.gz | head -1)

clear
echo "╔════════════════════════════════════════════════════════════╗"
echo "║            Tonix Installer                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Available block devices:"
echo ""
lsblk -d -o NAME,SIZE,TYPE,TRAN | grep -E "disk|usb"
echo ""
read -rp "Enter target device (e.g., sda or vda): " dev
TARGET="/dev/${dev}"

export TARBALL_PATH TARGET OS_PRETTY_NAME OS_HOSTNAME BOOT_SIZE_MIB ROOT_SIZE_MIB

source "$SCRIPT_DIR/install-common.sh"
do_install
INST_SCRIPT

    chmod +x "$INSTALLER_DIR/usr/local/bin/install-tonix"

    # Auto-launch installer on boot — shown for root on tty1
    cat > "$INSTALLER_DIR/root/.bash_profile" << 'BASH_PROF'
if [[ "$(tty)" == "/dev/tty1" ]]; then
    echo ""
    echo "Welcome to the Tonix Installer."
    echo ""
    echo "  Run:  install-tonix"
    echo ""
    echo "  Note: In QEMU with virtio, the disk is 'vda' (not 'sda')."
    echo ""
fi
BASH_PROF

    # Unmount
    umount "$INSTALLER_DIR/var/cache/apt/archives" 2>/dev/null || true
    umount "$INSTALLER_DIR/dev"  2>/dev/null || true
    umount "$INSTALLER_DIR/proc" 2>/dev/null || true
    umount "$INSTALLER_DIR/sys"  2>/dev/null || true

    # --- Build the ISO ---
    info "Creating SquashFS..."
    mkdir -p "$ISO_DIR/live"
    mksquashfs "$INSTALLER_DIR" "$ISO_DIR/live/filesystem.squashfs" -comp xz -b 1M

    # Copy kernel and initrd from installer
    local kver
    kver=$(ls "$INSTALLER_DIR/lib/modules/" 2>/dev/null | sort -V | tail -1)
    [[ -n "$kver" ]] || die "Could not detect kernel version in installer environment"
    info "Detected installer kernel: $kver"

    [[ -f "$INSTALLER_DIR/boot/vmlinuz-$kver" ]] || \
        die "Kernel not found: $INSTALLER_DIR/boot/vmlinuz-$kver"
    [[ -f "$INSTALLER_DIR/boot/initrd.img-$kver" ]] || \
        die "Initrd not found: $INSTALLER_DIR/boot/initrd.img-$kver"

    cp "$INSTALLER_DIR/boot/vmlinuz-$kver"    "$ISO_DIR/live/vmlinuz"
    cp "$INSTALLER_DIR/boot/initrd.img-$kver" "$ISO_DIR/live/initrd.img"
    ok "Kernel and initrd copied to ISO (vmlinuz-$kver)"

    # --- Set up ISOLINUX (BIOS boot) ---
    info "Setting up ISOLINUX for BIOS boot..."
    mkdir -p "$ISO_DIR/isolinux"
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/menu.c32 "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/libutil.c32 "$ISO_DIR/isolinux/"

    cat > "$ISO_DIR/isolinux/isolinux.cfg" << 'ISOLINUX_CFG'
DEFAULT tonix
TIMEOUT 50
PROMPT 0

UI menu.c32

LABEL tonix
    MENU LABEL Tonix Installer
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live username=root

LABEL tonix-toram
    MENU LABEL Tonix Installer (toram - copy to RAM)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live toram username=root
ISOLINUX_CFG

    # --- Set up GRUB EFI boot ---
    info "Setting up GRUB for UEFI boot..."
    mkdir -p "$ISO_DIR/boot/grub"

    # Marker file for search --file (reliable on all filesystem types)
    touch "$ISO_DIR/.tonix-iso"

    # The on-disk grub.cfg — used only if someone manually runs configfile
    # from the GRUB shell. The real menu is embedded in the EFI binary below.
    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_ISO'
search --no-floppy --file --set=root /.tonix-iso
set timeout=5
set default=0

menuentry "Tonix Installer" {
    linux ($root)/live/vmlinuz boot=live quiet username=root
    initrd ($root)/live/initrd.img
}

menuentry "Tonix Installer (toram - copy to RAM)" {
    linux ($root)/live/vmlinuz boot=live toram quiet username=root
    initrd ($root)/live/initrd.img
}
GRUB_ISO

    # The embedded GRUB config — baked directly into the EFI binary.
    #
    # CRITICAL DESIGN: We embed the FULL menu here, NOT a two-stage
    # search+configfile handoff. Why:
    #
    #   - xorriso's -isohybrid-gpt-basdat makes the ISO appear as a GPT disk
    #     to UEFI firmware. GRUB then sees GPT partitions, NOT the ISO9660
    #     volume — so 'search --label TONIX_INST' finds nothing.
    #
    #   - 'search --file' works regardless: it scans all accessible
    #     filesystems for a known file, which works through GPT, ISO9660,
    #     and raw block device access alike.
    #
    #   - Embedding the full menu eliminates the configfile failure path
    #     entirely — even if $root is wrong, GRUB still shows the menu.
    #
    local grub_embedded
    grub_embedded=$(mktemp /tmp/grub-embedded.cfg.XXXXXX)
    cat > "$grub_embedded" << 'GRUB_EMBEDDED'
# Tonix Installer — Embedded GRUB Menu
# Finds the ISO filesystem via marker file, then boots directly.

# Strategy 1: search by marker file (most reliable across GPT/ISO9660/hybrid)
search --no-floppy --file --set=root /.tonix-iso

# Strategy 2: search by volume label (works on raw ISO9660 / BIOS boots)
if [ -z "$root" ]; then
    search --no-floppy --label --set=root TONIX_INST
fi

# Strategy 3: search for the kernel directly
if [ -z "$root" ]; then
    search --no-floppy --file --set=root /live/vmlinuz
fi

if [ -z "$root" ]; then
    echo "ERROR: Could not locate Tonix installer filesystem."
    echo ""
    echo "Manual recovery:"
    echo "  ls                                    # list devices"
    echo "  ls (hd0,gpt2)/                        # browse a partition"
    echo "  set root=(hd0,gpt2)                   # set root manually"
    echo "  linux /live/vmlinuz boot=live          # load kernel"
    echo "  initrd /live/initrd.img                # load initrd"
    echo "  boot                                   # boot"
    echo ""
fi

set timeout=5
set default=0

menuentry "Tonix Installer" {
    linux ($root)/live/vmlinuz boot=live quiet username=root
    initrd ($root)/live/initrd.img
}

menuentry "Tonix Installer (toram - copy to RAM)" {
    linux ($root)/live/vmlinuz boot=live toram quiet username=root
    initrd ($root)/live/initrd.img
}
GRUB_EMBEDDED

    # Create EFI boot image
    mkdir -p "$ISO_DIR/EFI/boot"
    local efi_img="$ISO_DIR/boot/grub/efi.img"
    dd if=/dev/zero of="$efi_img" bs=1M count=4
    mkfs.vfat "$efi_img"

    local efi_mount
    efi_mount=$(mktemp -d)
    mount -o loop "$efi_img" "$efi_mount"
    mkdir -p "$efi_mount/EFI/boot"

    # Build GRUB EFI binary — embed the FULL menu + search logic.
    # --modules is critical: since grub-mkstandalone produces a self-contained
    # binary with NO access to a module directory, EVERY needed module must be
    # baked in here. Key requirements:
    #   normal          — menu system + if/else/configfile (without this → rescue shell)
    #   linux           — linux/initrd commands (without this → "can't find command")
    #   gzio            — decompress gzip'd kernels (without this → "file not recognized")
    #   search*         — find ISO filesystem by file/label/UUID
    #   iso9660/fat     — read ISO and EFI filesystems
    #   search_fs_file  — needed for 'search --file' (primary strategy)
    local grub_modules="part_gpt part_msdos fat iso9660 normal linux gzio all_video"
    grub_modules+=" search search_label search_fs_uuid search_fs_file configfile echo test ls cat loopback"

    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$efi_mount/EFI/boot/bootx64.efi" \
        --modules="$grub_modules" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$grub_embedded"

    # Also build 32-bit EFI for older systems
    grub-mkstandalone \
        --format=i386-efi \
        --output="$efi_mount/EFI/boot/bootia32.efi" \
        --modules="$grub_modules" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$grub_embedded" 2>/dev/null || \
        warn "i386-efi standalone not available (non-fatal)"

    rm -f "$grub_embedded"
    umount "$efi_mount"
    rmdir "$efi_mount"

    # Build ISO with xorriso — -V TONIX_INST is the volume label the embedded
    # GRUB config searches for with 'search --label TONIX_INST'
    info "Creating ISO image..."
    local iso_output="$OUTPUT_DIR/tonix-installer-${OS_VERSION}.iso"

    xorriso -as mkisofs \
        -o "$iso_output" \
        -V "TONIX_INST" \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$ISO_DIR" 2>/dev/null || {
            # Fallback: simpler ISO build (BIOS only)
            warn "Full hybrid ISO failed, using simpler method..."
            xorriso -as mkisofs \
                -o "$iso_output" \
                -R -J \
                -V "TONIX_INST" \
                -b isolinux/isolinux.bin \
                -c isolinux/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                "$ISO_DIR"
        }

    local iso_size
    iso_size=$(du -h "$iso_output" | cut -f1)

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✓ Installer ISO built!                                   ║"
    echo "║                                                           ║"
    echo "║  ISO:   $iso_output"
    echo "║  Size:  $iso_size"
    echo "║                                                           ║"
    echo "║  Write to USB:                                            ║"
    echo "║    sudo dd if=$iso_output of=/dev/sdX bs=4M status=progress ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

# ============================================================================
# VM TEST: Boot ISO or installed disk in QEMU for quick testing
# ============================================================================
do_vm_test() {
    local mode="${1:-iso}"  # iso | iso-with-disk | disk | disk-bios
    local disk_file="$PROJECT_DIR/tonix-test.qcow2"
    local iso_file
    iso_file=$(ls "$OUTPUT_DIR"/tonix-installer-*.iso 2>/dev/null | tail -1 || true)

    # Check QEMU is available
    command -v qemu-system-x86_64 &>/dev/null || {
        warn "qemu-system-x86_64 not found. Install with:"
        echo "  sudo apt install qemu-system-x86 qemu-kvm ovmf"
        exit 1
    }

    # KVM acceleration flag
    local kvm_flag=""
    [[ -r /dev/kvm ]] && kvm_flag="-enable-kvm" || warn "KVM not available — VM will be slow without it"

    # OVMF (UEFI firmware) — check common paths across distros
    local ovmf_path=""
    for p in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd /usr/share/ovmf/x64/OVMF.fd; do
        [[ -f "$p" ]] && { ovmf_path="$p"; break; }
    done

    case "$mode" in
        iso|iso-with-disk)
            [[ -f "$iso_file" ]] || die "No installer ISO found in $OUTPUT_DIR — run: $0 iso"
            info "Booting installer ISO in QEMU (UEFI mode)..."
            info "ISO: $iso_file"
            echo ""

            local disk_args=""
            if [[ "$mode" == "iso-with-disk" ]] || [[ ! -f "$disk_file" ]]; then
                [[ -f "$disk_file" ]] || {
                    info "Creating 30GB virtual test disk: $disk_file"
                    qemu-img create -f qcow2 "$disk_file" 30G
                }
                disk_args="-drive file=$disk_file,format=qcow2,if=virtio"
                info "Virtual disk attached: $disk_file"
                info "Inside the VM, run 'install-tonix' and enter 'vda' as the target device."
            fi
            echo ""

            local bios_args=""
            if [[ -n "$ovmf_path" ]]; then
                bios_args="-bios $ovmf_path"
            else
                warn "OVMF not found — using SeaBIOS (legacy BIOS). For UEFI: sudo apt install ovmf"
            fi

            qemu-system-x86_64 \
                $kvm_flag \
                -m 2048 \
                -cdrom "$iso_file" \
                $disk_args \
                $bios_args \
                -boot d \
                -vga virtio
            ;;

        disk|disk-uefi)
            [[ -f "$disk_file" ]] || die "No virtual disk found: $disk_file\nRun '$0 vm-test iso-with-disk' first to create and install Tonix."
            info "Booting installed disk in QEMU (UEFI mode)..."

            local bios_args=""
            if [[ -n "$ovmf_path" ]]; then
                bios_args="-bios $ovmf_path"
            else
                warn "OVMF not found — install with: sudo apt install ovmf"
            fi

            qemu-system-x86_64 \
                $kvm_flag \
                -m 2048 \
                -drive file="$disk_file",format=qcow2,if=virtio \
                $bios_args \
                -boot c \
                -vga virtio
            ;;

        disk-bios)
            [[ -f "$disk_file" ]] || die "No virtual disk found: $disk_file"
            info "Booting installed disk in QEMU (legacy BIOS mode)..."
            info "This specifically tests the BIOS boot partition (partition 1)."

            qemu-system-x86_64 \
                $kvm_flag \
                -m 2048 \
                -drive file="$disk_file",format=qcow2,if=ide \
                -boot c \
                -vga std
            ;;

        *)
            echo ""
            echo "Usage: $0 vm-test [mode]"
            echo ""
            echo "Modes:"
            echo "  iso             Boot installer ISO in UEFI VM (default)"
            echo "  iso-with-disk   Boot ISO + attach virtual disk (for full install test)"
            echo "  disk            Boot installed virtual disk — UEFI"
            echo "  disk-bios       Boot installed virtual disk — legacy BIOS (tests BIOS boot partition)"
            echo ""
            echo "Virtual disk: $disk_file"
            echo "Requires: qemu-system-x86 qemu-kvm  (optionally: ovmf for UEFI)"
            ;;
    esac
}

# ============================================================================
# Helper: mount/unmount chroot binds
# ============================================================================
mount_chroot() {
    mount --bind /dev  "$CHROOT_DIR/dev"
    mount --bind /proc "$CHROOT_DIR/proc"
    mount --bind /sys  "$CHROOT_DIR/sys"
}

cleanup_chroot() {
    umount "$CHROOT_DIR/dev"  2>/dev/null || true
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys"  2>/dev/null || true
    unmount_cache 2>/dev/null || true
}

# ============================================================================
# Helper: package cache management
# ============================================================================
mount_cache() {
    # Create cache directory structure — apt needs the partial/ subdir to exist
    # or it can't stage downloads and silently skips caching
    mkdir -p "$CACHE_DIR/apt-archives/partial"
    mkdir -p "$CHROOT_DIR/var/cache/apt/archives/partial"

    # Clear cache if refresh requested
    if [[ "$REFRESH_CACHE" == true ]]; then
        info "Refreshing package cache..."
        rm -rf "$CACHE_DIR/apt-archives"/*
        mkdir -p "$CACHE_DIR/apt-archives/partial"
        ok "Cache cleared"
    fi

    # Bind mount cache into chroot
    mount --bind "$CACHE_DIR/apt-archives" "$CHROOT_DIR/var/cache/apt/archives"

    # Tell apt to keep downloaded packages after install
    mkdir -p "$CHROOT_DIR/etc/apt/apt.conf.d"
    cat > "$CHROOT_DIR/etc/apt/apt.conf.d/99-tonix-cache" << 'EOF'
APT::Keep-Downloaded-Packages "true";
Binary::apt::APT::Keep-Downloaded-Packages "true";
DPkg::Post-Invoke { "true"; };
EOF

    # Show cache stats
    local cache_size cache_count
    cache_size=$(du -sh "$CACHE_DIR/apt-archives" 2>/dev/null | cut -f1 || echo "0")
    cache_count=$(find "$CACHE_DIR/apt-archives" -name "*.deb" 2>/dev/null | wc -l || echo "0")

    if [[ "$cache_count" -gt 0 ]]; then
        info "Using package cache: $cache_count packages ($cache_size)"
        info "Cached packages will be used as-is; newer versions will be downloaded and cached"
    else
        info "Package cache empty — packages will be downloaded and cached for next build"
    fi
}

unmount_cache() {
    if mountpoint -q "$CHROOT_DIR/var/cache/apt/archives" 2>/dev/null; then
        umount "$CHROOT_DIR/var/cache/apt/archives" 2>/dev/null || true
    fi
}

# ============================================================================
# CLEAN: Remove build artifacts
# ============================================================================
do_clean() {
    warn "This will remove all build artifacts"
    read -rp "Continue? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] || exit 0

    [[ -d "$BUILD_DIR" ]] && {
        cleanup_chroot 2>/dev/null || true
        rm -rf "$BUILD_DIR"
    }

    info "Build directory removed. Output files in $OUTPUT_DIR preserved."
    info "To remove output too: rm -rf $OUTPUT_DIR"
}

# ============================================================================
# Entry point
# ============================================================================

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --refresh)
            REFRESH_CACHE=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

case "${1:-help}" in
    build)
        do_build
        ;;
    install)
        do_install_direct "${2:-}"
        ;;
    iso)
        do_build_iso
        ;;
    vm-test)
        do_vm_test "${2:-iso}"
        ;;
    clean)
        do_clean
        ;;
    cache-info)
        echo ""
        echo "Package Cache Information"
        echo "========================="
        echo "Location: $CACHE_DIR/apt-archives"
        if [[ -d "$CACHE_DIR/apt-archives" ]]; then
            cache_size=$(du -sh "$CACHE_DIR/apt-archives" | cut -f1)
            cache_count=$(find "$CACHE_DIR/apt-archives" -name "*.deb" | wc -l)
            echo "Size: $cache_size"
            echo "Packages: $cache_count"
            echo ""
            echo "To clear cache: rm -rf $CACHE_DIR"
            echo "To rebuild with fresh packages: $0 --refresh build"
        else
            echo "Status: Empty (no cache created yet)"
        fi
        echo ""
        ;;
    *)
        echo ""
        echo "Tonix Build System v${OS_VERSION}"
        echo ""
        echo "Usage:"
        echo "  $0 [--refresh] build        Build the OS image (tarball)"
        echo "  $0 [--refresh] iso          Build bootable installer ISO"
        echo "  $0 install /dev/sdX         Install directly to a USB drive"
        echo "  $0 vm-test [mode]           Test in QEMU VM (iso/iso-with-disk/disk/disk-bios)"
        echo "  $0 clean                    Remove build artifacts"
        echo "  $0 cache-info               Show package cache statistics"
        echo ""
        echo "Options:"
        echo "  --refresh                   Clear package cache before build"
        echo ""
        echo "Package Cache:"
        echo "  Downloaded packages are cached in: $CACHE_DIR"
        echo "  Subsequent builds reuse cached packages for faster builds."
        echo "  Use --refresh to force re-download all packages."
        echo ""
        echo "Typical workflow:"
        echo "  1. $0 build                     # Create OS image (downloads packages)"
        echo "  2. $0 build                     # Rebuild (uses cache, much faster!)"
        echo "  3. $0 install /dev/sdb          # Write to USB"
        echo "  3b. $0 vm-test iso-with-disk    # Or test in QEMU first (recommended)"
        echo ""
        ;;
esac
exit 0