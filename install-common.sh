#!/bin/bash
# ============================================================================
# Tonix — Shared Install Logic
# ============================================================================
# Called by both:
#   - tonix.sh install  (direct from dev machine)
#   - install-tonix     (from booted installer ISO)
#
# Required environment:
#   TARBALL_PATH  — path to tonix-*.tar.gz
#   TARGET        — block device (e.g., /dev/sdb)
#
# Optional:
#   NONINTERACTIVE=1  — skip confirmations (for scripted installs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config if available (for partition sizes, etc.)
if [[ -f "$SCRIPT_DIR/config.sh" ]]; then
    source "$SCRIPT_DIR/config.sh"
fi

# Defaults if config not loaded
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-512}"
ROOT_SIZE_MIB="${ROOT_SIZE_MIB:-10240}"

# ============================================================================
# Colors and output helpers
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ============================================================================
# Preflight checks
# ============================================================================
preflight() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root"
    [[ -n "${TARBALL_PATH:-}" ]] || die "TARBALL_PATH not set"
    [[ -f "$TARBALL_PATH" ]] || die "Tarball not found: $TARBALL_PATH"
    [[ -n "${TARGET:-}" ]] || die "TARGET device not set"
    [[ -b "$TARGET" ]] || die "$TARGET is not a block device"

    # Safety: refuse to install to the boot disk
    local boot_disk
    boot_disk=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null || true)
    if [[ "/dev/$boot_disk" == "$TARGET" ]]; then
        die "Refusing to install to the currently booted disk ($TARGET)"
    fi

    # Check required tools
    for cmd in parted mkfs.vfat mkfs.ext4 cryptsetup grub-install tar pv blkid; do
        command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
    done

    info "Tarball:  $TARBALL_PATH ($(du -h "$TARBALL_PATH" | cut -f1))"
    info "Target:   $TARGET ($(lsblk -dno SIZE "$TARGET"))"
}

# ============================================================================
# Detect existing partitions
# ============================================================================
detect_existing() {
    PRESERVE_HOME=false
    HOME_PART="${TARGET}3"

    # Handle nvme-style partition names (e.g., /dev/nvme0n1p3)
    if [[ "$TARGET" =~ [0-9]$ ]]; then
        HOME_PART="${TARGET}p3"
    fi

    if [[ -b "$HOME_PART" ]]; then
        echo ""
        warn "Found existing partition: $HOME_PART"

        if cryptsetup isLuks "$HOME_PART" 2>/dev/null; then
            info "Partition is LUKS encrypted — looks like an existing /home"
            echo ""

            if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
                read -rp "Preserve existing encrypted /home? (yes/no): " ans
                if [[ "$ans" == "yes" ]]; then
                    PRESERVE_HOME=true
                    read -rs -p "Enter decryption password to verify: " HOME_PASSWORD
                    echo ""

                    # Verify password
                    if ! echo -n "$HOME_PASSWORD" | cryptsetup open --test-passphrase "$HOME_PART" --key-file=- 2>/dev/null; then
                        die "Wrong password or partition is not valid LUKS"
                    fi
                    ok "Password verified — /home will be preserved"
                fi
            fi
        fi
    fi
}

# ============================================================================
# Partition the drive
# ============================================================================
partition_drive() {
    local boot_end=$(( BOOT_SIZE_MIB + 1 ))
    local root_end=$(( boot_end + ROOT_SIZE_MIB ))

    if [[ "$PRESERVE_HOME" == true ]]; then
        info "Preserving /home — only reformatting /boot and /"

        # We need to identify partition numbers and only wipe 1 and 2
        # Delete and recreate partitions 1 and 2 only
        parted "$TARGET" --script \
            rm 1 \
            rm 2 \
            mkpart ESP fat32 1MiB "${boot_end}MiB" \
            set 1 boot on \
            set 1 esp on \
            mkpart primary ext4 "${boot_end}MiB" "${root_end}MiB"
    else
        info "Creating fresh partition table..."

        parted "$TARGET" --script \
            mklabel gpt \
            mkpart ESP fat32 1MiB "${boot_end}MiB" \
            set 1 boot on \
            set 1 esp on \
            mkpart primary ext4 "${boot_end}MiB" "${root_end}MiB" \
            mkpart primary "${root_end}MiB" 100%
    fi

    # Wait for kernel to pick up changes
    sleep 2
    partprobe "$TARGET" 2>/dev/null || true
    sleep 2

    # Determine partition device names
    if [[ "$TARGET" =~ [0-9]$ ]]; then
        BOOT_PART="${TARGET}p1"
        ROOT_PART="${TARGET}p2"
        HOME_PART="${TARGET}p3"
    else
        BOOT_PART="${TARGET}1"
        ROOT_PART="${TARGET}2"
        HOME_PART="${TARGET}3"
    fi

    ok "Partitioning complete"
}

# ============================================================================
# Format partitions
# ============================================================================
format_partitions() {
    info "Formatting /boot (FAT32)..."
    mkfs.vfat -F32 -n TONIX "$BOOT_PART"

    info "Formatting / (ext4)..."
    mkfs.ext4 -F -L root "$ROOT_PART"

    if [[ "$PRESERVE_HOME" == false ]]; then
        echo ""
        info "Setting up encrypted /home partition..."
        echo ""

        # Get password
        local pass1 pass2
        while true; do
            read -rs -p "Set encryption password for /home: " pass1
            echo ""
            read -rs -p "Confirm password: " pass2
            echo ""

            if [[ "$pass1" == "$pass2" ]]; then
                HOME_PASSWORD="$pass1"
                break
            else
                warn "Passwords don't match, try again"
            fi
        done

        info "Encrypting /home with LUKS2 (this may take a moment)..."
        echo -n "$HOME_PASSWORD" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --iter-time 5000 \
            --key-file=- \
            "$HOME_PART"

        ok "Encryption setup complete"
    fi

    ok "All partitions formatted"
}

# ============================================================================
# Mount everything
# ============================================================================
mount_target() {
    MOUNT_ROOT="/mnt/tonix-install"

    info "Mounting partitions..."

    mkdir -p "$MOUNT_ROOT"
    mount "$ROOT_PART" "$MOUNT_ROOT"

    mkdir -p "$MOUNT_ROOT/boot"
    mount "$BOOT_PART" "$MOUNT_ROOT/boot"

    # Open and mount encrypted /home
    echo -n "$HOME_PASSWORD" | cryptsetup open "$HOME_PART" secure_home --key-file=-
    mkdir -p "$MOUNT_ROOT/home"
    mount /dev/mapper/secure_home "$MOUNT_ROOT/home"

    ok "All partitions mounted at $MOUNT_ROOT"
}

# ============================================================================
# Extract the OS
# ============================================================================
extract_os() {
    info "Extracting OS image (this will take a few minutes)..."

    local tarball_size
    tarball_size=$(stat -c%s "$TARBALL_PATH")

    pv -s "$tarball_size" "$TARBALL_PATH" | tar -xzf - -C "$MOUNT_ROOT"

    ok "OS extracted"
}

# ============================================================================
# Configure the installed system
# ============================================================================
configure_system() {
    info "Configuring installed system..."

    # --- fstab ---
    local boot_uuid root_uuid home_uuid
    boot_uuid=$(blkid -s UUID -o value "$BOOT_PART")
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    home_uuid=$(blkid -s UUID -o value "$HOME_PART")

    cat > "$MOUNT_ROOT/etc/fstab" << EOF
# /etc/fstab — Generated by Tonix installer
UUID=$root_uuid    /        ext4   defaults,noatime,errors=remount-ro  0 1
UUID=$boot_uuid    /boot    vfat   defaults,noatime,umask=0077         0 2
/dev/mapper/secure_home  /home  ext4  defaults,noatime,nosuid,nodev   0 2

# Tmpfs mounts (keep sensitive data out of disk)
tmpfs   /tmp        tmpfs   defaults,noatime,mode=1777,nodev,nosuid,noexec  0 0
tmpfs   /var/tmp    tmpfs   defaults,noatime,mode=1777,nodev,nosuid,noexec  0 0
tmpfs   /var/log    tmpfs   defaults,noatime,mode=0755,nodev,nosuid         0 0
tmpfs   /run/shm    tmpfs   defaults,noatime,nodev,nosuid,noexec            0 0
EOF

    # --- crypttab ---
    cat > "$MOUNT_ROOT/etc/crypttab" << EOF
# /etc/crypttab — Encrypted /home
secure_home  UUID=$home_uuid  none  luks,discard
EOF

    # --- Hostname ---
    echo "${OS_HOSTNAME:-tonix}" > "$MOUNT_ROOT/etc/hostname"

    # --- Regenerate initramfs to include cryptsetup ---
    info "Regenerating initramfs with encryption support..."
    mount --bind /dev  "$MOUNT_ROOT/dev"
    mount --bind /proc "$MOUNT_ROOT/proc"
    mount --bind /sys  "$MOUNT_ROOT/sys"

    chroot "$MOUNT_ROOT" /bin/bash << 'CHROOT_INIT'
set -e

# Ensure cryptsetup is in initramfs
echo "CRYPTSETUP=y" > /etc/cryptsetup-initramfs/conf-hook
update-initramfs -u -k all 2>/dev/null || update-initramfs -c -k all

CHROOT_INIT

    ok "Initramfs updated"
}

# ============================================================================
# Install GRUB (dual BIOS + UEFI)
# ============================================================================
install_bootloader() {
    info "Installing GRUB bootloader (BIOS + UEFI)..."

    # --- UEFI (64-bit) ---
    mkdir -p "$MOUNT_ROOT/boot/EFI/BOOT"
    chroot "$MOUNT_ROOT" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot \
        --boot-directory=/boot \
        --removable \
        --no-nvram \
        2>/dev/null || warn "x86_64-efi GRUB install had warnings (may be OK)"

    # --- UEFI (32-bit, for older UEFI systems) ---
    chroot "$MOUNT_ROOT" grub-install \
        --target=i386-efi \
        --efi-directory=/boot \
        --boot-directory=/boot \
        --removable \
        --no-nvram \
        2>/dev/null || warn "i386-efi GRUB install had warnings (may be OK)"

    # --- BIOS (legacy) ---
    chroot "$MOUNT_ROOT" grub-install \
        --target=i386-pc \
        --boot-directory=/boot \
        "$TARGET" \
        2>/dev/null || warn "i386-pc GRUB install had warnings (may be OK)"

    # --- GRUB config ---
    local root_uuid
    root_uuid=$(blkid -s UUID -o value "$ROOT_PART")

    cat > "$MOUNT_ROOT/boot/grub/grub.cfg" << EOF
# Tonix GRUB Configuration — Codename: Mirage
set timeout=5
set default=0

# Theme
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "${OS_PRETTY_NAME:-Tonix} — Immutable (default)" {
    linux /boot/vmlinuz-* root=UUID=$root_uuid ro quiet noresume tonix.overlay=yes apparmor=1 security=apparmor
    initrd /boot/initrd.img-*
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Persistent Root (writable)" {
    linux /boot/vmlinuz-* root=UUID=$root_uuid ro quiet noresume tonix.overlay=no apparmor=1 security=apparmor
    initrd /boot/initrd.img-*
}

menuentry "${OS_PRETTY_NAME:-Tonix} — RAM Only (entire OS in RAM)" {
    linux /boot/vmlinuz-* root=UUID=$root_uuid ro quiet noresume tonix.overlay=yes toram apparmor=1 security=apparmor
    initrd /boot/initrd.img-*
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Recovery" {
    linux /boot/vmlinuz-* root=UUID=$root_uuid ro single noresume tonix.overlay=no
    initrd /boot/initrd.img-*
}
EOF

    # Unmount bind mounts
    umount "$MOUNT_ROOT/dev"  2>/dev/null || true
    umount "$MOUNT_ROOT/proc" 2>/dev/null || true
    umount "$MOUNT_ROOT/sys"  2>/dev/null || true

    ok "Bootloader installed (BIOS + UEFI 32/64)"
}

# ============================================================================
# Cleanup and unmount
# ============================================================================
cleanup() {
    info "Cleaning up..."

    # Clear sensitive variables
    HOME_PASSWORD=""

    # Unmount in reverse order
    umount "$MOUNT_ROOT/home"  2>/dev/null || true
    cryptsetup close secure_home 2>/dev/null || true
    umount "$MOUNT_ROOT/boot"  2>/dev/null || true
    umount "$MOUNT_ROOT"       2>/dev/null || true

    # Unmount bind mounts if still active
    umount "$MOUNT_ROOT/dev"   2>/dev/null || true
    umount "$MOUNT_ROOT/proc"  2>/dev/null || true
    umount "$MOUNT_ROOT/sys"   2>/dev/null || true

    rmdir "$MOUNT_ROOT" 2>/dev/null || true

    sync

    ok "Cleanup complete"
}

# ============================================================================
# Main install flow
# ============================================================================
do_install() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            Tonix Installer                             ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  Target:  $TARGET"
    echo "║  Image:   $(basename "$TARBALL_PATH")"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Confirmation
    if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
        warn "This will ERASE /boot and / on $TARGET"
        read -rp "Continue? (yes/no): " confirm
        [[ "$confirm" == "yes" ]] || { info "Cancelled."; exit 0; }
    fi

    trap cleanup EXIT

    preflight
    detect_existing
    partition_drive
    format_partitions
    mount_target
    extract_os
    configure_system
    install_bootloader
    cleanup

    trap - EXIT

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✓ Installation complete!                                 ║"
    echo "║                                                           ║"
    echo "║  Remove installer media, then boot from $TARGET"
    echo "║  You will be prompted for your /home encryption password. ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}
