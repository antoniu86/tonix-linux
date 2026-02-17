#!/bin/bash
# ============================================================================
# Tonix — Main Build System
# ============================================================================
# Usage:
#   ./tonix.sh build          Build the OS tarball
#   ./tonix.sh install /dev/sdX   Install directly to USB drive
#   ./tonix.sh iso            Build bootable installer ISO
#   ./tonix.sh clean          Remove all build artifacts
#
# All modes share the same config (config.sh) and install logic
# (install-common.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_DIR="$PROJECT_DIR/output"
CHROOT_DIR="$BUILD_DIR/chroot"
INSTALLER_DIR="$BUILD_DIR/installer-chroot"
ISO_DIR="$BUILD_DIR/iso-staging"
OVERLAY_DIR="$PROJECT_DIR/overlays"

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

    # Add non-free repos for firmware
    cat > "$CHROOT_DIR/etc/apt/sources.list" << EOF
deb $DEBIAN_MIRROR $DEBIAN_RELEASE main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
EOF

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
pip install --break-system-packages $python_packages
CHROOT_PIP

        ok "Python packages installed"
    fi

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

TOR_VERSION="14.0.4"
TOR_ARCH="linux-x86_64"
TOR_LANG="en-US"
TOR_DIR="/opt/tor-browser"
TOR_URL="https://www.torproject.org/dist/torbrowser/${TOR_VERSION}/tor-browser-${TOR_ARCH}-${TOR_VERSION}_ALL.tar.xz"

echo "Downloading Tor Browser ${TOR_VERSION}..."

mkdir -p "$TOR_DIR"
cd /tmp

# Download Tor Browser
if wget -q --timeout=60 "$TOR_URL" -O tor-browser.tar.xz 2>/dev/null; then
    tar -xJf tor-browser.tar.xz -C "$TOR_DIR" --strip-components=1
    rm -f tor-browser.tar.xz

    # Create launcher script
    cat > /usr/local/bin/tor-browser << 'TB_LAUNCHER'
#!/bin/bash
# Tonix Tor Browser Launcher
# Runs Tor Browser from /opt/tor-browser
cd /opt/tor-browser
./start-tor-browser.desktop --detach "$@" 2>/dev/null || \
./Browser/start-tor-browser --detach "$@" 2>/dev/null || \
echo "Error: Could not start Tor Browser"
TB_LAUNCHER
    chmod +x /usr/local/bin/tor-browser

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
systemctl disable lightdm 2>/dev/null || true
systemctl enable apparmor 2>/dev/null || true
systemctl enable ufw 2>/dev/null || true
systemctl enable tor 2>/dev/null || true

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

    # --- Phase 6: Cleanup and pack ---
    header "Phase 6: Cleanup and packaging"

    chroot "$CHROOT_DIR" /bin/bash << 'CHROOT_CLEAN'
set -e
apt clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -rf /var/cache/apt/archives/*.deb
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
# Keep locale we need
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
CHROOT_CLEAN

    cleanup_chroot

    # Create tarball
    local tarball="$OUTPUT_DIR/tonix-${OS_VERSION}.tar.gz"

    info "Creating tarball (this takes a few minutes)..."
    tar -czf "$tarball" -C "$CHROOT_DIR" .

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

# --- Root password (user should change on first boot) ---
echo "root:tonix" | chpasswd

# --- Encryption in initramfs ---
echo "CRYPTSETUP=y" > /etc/cryptsetup-initramfs/conf-hook

# --- Kernel boot parameters ---
cat > /etc/default/grub << 'EOF_GRUB'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet noresume apparmor=1 security=apparmor"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
EOF_GRUB

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
  Tor-only mode:    sudo tonix-tormode on
  Tor Browser:      tor-browser
  System status:    tonix-status
  WiFi status:      nmcli device status
  Stego tool:       stego --help
  Change password:  passwd

EOF_MOTD

# --- LightDM autologin (optional, remove for login prompt) ---
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-tonix.conf << 'EOF_LDM'
[Seat:*]
# Uncomment below for auto-login (less secure):
# autologin-user=root
# autologin-user-timeout=0
greeter-hide-users=false
greeter-show-manual-login=true
EOF_LDM

# --- Create first regular user (optional) ---
# useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev user
# echo "user:changeme" | chpasswd

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

    local installer_packages="${PACKAGES_INSTALLER[*]}"

    chroot "$INSTALLER_DIR" /bin/bash << CHROOT_INSTALLER
set -e
export DEBIAN_FRONTEND=noninteractive

apt update
apt install -y $installer_packages

apt clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

CHROOT_INSTALLER

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
read -rp "Enter target device (e.g., sdb): " dev
TARGET="/dev/${dev}"

export TARBALL_PATH TARGET OS_PRETTY_NAME OS_HOSTNAME BOOT_SIZE_MIB ROOT_SIZE_MIB

source "$SCRIPT_DIR/install-common.sh"
do_install
INST_SCRIPT

    chmod +x "$INSTALLER_DIR/usr/local/bin/install-tonix"

    # Auto-launch installer on boot
    cat > "$INSTALLER_DIR/root/.bash_profile" << 'BASH_PROF'
if [[ "$(tty)" == "/dev/tty1" ]]; then
    echo ""
    echo "Welcome to the Tonix Installer."
    echo "Type 'install-tonix' to begin, or use this shell."
    echo ""
fi
BASH_PROF

    # Unmount
    umount "$INSTALLER_DIR/dev"  2>/dev/null || true
    umount "$INSTALLER_DIR/proc" 2>/dev/null || true
    umount "$INSTALLER_DIR/sys"  2>/dev/null || true

    # --- Build the ISO ---
    info "Creating SquashFS..."
    mkdir -p "$ISO_DIR/live"
    mksquashfs "$INSTALLER_DIR" "$ISO_DIR/live/filesystem.squashfs" -comp xz -b 1M

    # Copy kernel and initrd from installer
    local kver
    kver=$(ls "$INSTALLER_DIR/lib/modules/" | head -1)
    cp "$INSTALLER_DIR/boot/vmlinuz-$kver"  "$ISO_DIR/live/vmlinuz"
    cp "$INSTALLER_DIR/boot/initrd.img-$kver" "$ISO_DIR/live/initrd.img"

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
    APPEND initrd=/live/initrd.img boot=live toram
ISOLINUX_CFG

    # --- Set up GRUB EFI boot ---
    info "Setting up GRUB for UEFI boot..."
    mkdir -p "$ISO_DIR/boot/grub"
    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_ISO'
set timeout=5
set default=0

menuentry "Tonix Installer" {
    linux /live/vmlinuz boot=live toram
    initrd /live/initrd.img
}
GRUB_ISO

    # Create EFI boot image
    mkdir -p "$ISO_DIR/EFI/boot"
    local efi_img="$ISO_DIR/boot/grub/efi.img"
    dd if=/dev/zero of="$efi_img" bs=1M count=4
    mkfs.vfat "$efi_img"

    local efi_mount
    efi_mount=$(mktemp -d)
    mount -o loop "$efi_img" "$efi_mount"
    mkdir -p "$efi_mount/EFI/boot"

    # Build GRUB EFI binary
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$efi_mount/EFI/boot/bootx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

    # Also build 32-bit EFI for older systems
    grub-mkstandalone \
        --format=i386-efi \
        --output="$efi_mount/EFI/boot/bootia32.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg" 2>/dev/null || \
        warn "i386-efi standalone not available (non-fatal)"

    umount "$efi_mount"
    rmdir "$efi_mount"

    # Build ISO with xorriso
    info "Creating ISO image..."
    local iso_output="$OUTPUT_DIR/tonix-installer-${OS_VERSION}.iso"

    xorriso -as mkisofs \
        -o "$iso_output" \
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
    clean)
        do_clean
        ;;
    *)
        echo ""
        echo "Tonix Build System v${OS_VERSION}"
        echo ""
        echo "Usage:"
        echo "  $0 build              Build the OS image (tarball)"
        echo "  $0 install /dev/sdX   Install directly to a USB drive"
        echo "  $0 iso                Build a bootable installer ISO"
        echo "  $0 clean              Remove build artifacts"
        echo ""
        echo "Typical workflow:"
        echo "  1. $0 build           # Create OS image"
        echo "  2. $0 install /dev/sdb   # Write to USB (or: $0 iso)"
        echo ""
        ;;
esac
