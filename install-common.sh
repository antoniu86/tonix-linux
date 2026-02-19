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
    HOME_PART="${TARGET}4"

    # Handle nvme-style partition names (e.g., /dev/nvme0n1p4)
    if [[ "$TARGET" =~ [0-9]$ ]]; then
        HOME_PART="${TARGET}p4"
    fi

    # Also detect old 3-partition layout (no BIOS boot partition) and warn
    local old_home="${TARGET}3"
    [[ "$TARGET" =~ [0-9]$ ]] && old_home="${TARGET}p3"
    if [[ ! -b "$HOME_PART" ]] && [[ -b "$old_home" ]]; then
        warn "Detected old 3-partition layout (no BIOS boot partition)."
        warn "Upgrading to 4-partition layout — /home (partition 3) cannot be preserved."
        warn "Your /home data will be erased. Back it up first if needed."
        HOME_PART="$old_home"
        # Force fresh install; can't preserve since partition numbers shift
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
# Prepare device — unmount, close LUKS, disable automount & USB autosuspend
# ============================================================================
prepare_device() {
    info "Preparing $TARGET for installation..."

    # 1. Close any open LUKS/dm-crypt mappings that reference this device
    while IFS= read -r dmname; do
        local dmdev
        dmdev=$(dmsetup info -c --noheadings -o open_count "$dmname" 2>/dev/null || true)
        info "Closing dm-crypt mapping: $dmname"
        cryptsetup close "$dmname" 2>/dev/null || true
    done < <(dmsetup ls 2>/dev/null | awk '{print $1}' | while read -r name; do
        dmsetup deps -o devname "$name" 2>/dev/null | grep -q "$(basename "$TARGET")" && echo "$name"
    done)

    # 2. Unmount all partitions of the target device (reverse order for safety)
    local mounted
    mounted=$(mount | awk -v dev="$TARGET" '$1 ~ dev {print $1}' | sort -r)
    if [[ -n "$mounted" ]]; then
        while IFS= read -r part; do
            info "Unmounting $part..."
            umount -l "$part" 2>/dev/null || true
        done <<< "$mounted"
    fi

    # 3. Disable GNOME automount so the OS doesn't re-mount partitions mid-install
    if command -v gsettings &>/dev/null && [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" gsettings set org.gnome.desktop.media-handling automount false      2>/dev/null || true
        sudo -u "$SUDO_USER" gsettings set org.gnome.desktop.media-handling automount-open false 2>/dev/null || true
    fi

    # 4. Disable USB autosuspend for the target drive to prevent bus dropouts
    #    during heavy writes (mkfs, tar extract). Find the sysfs path by matching
    #    the block device back to its USB port.
    local sysblock
    sysblock=$(readlink -f /sys/block/"$(basename "$TARGET")" 2>/dev/null || true)
    if [[ -n "$sysblock" ]]; then
        # Walk up the sysfs tree to find the USB device directory
        local syspath="$sysblock"
        while [[ "$syspath" != "/" ]]; do
            if [[ -f "$syspath/idVendor" ]]; then
                local portpath="$syspath"
                if [[ -f "$portpath/power/autosuspend" ]]; then
                    echo -1 > "$portpath/power/autosuspend"   2>/dev/null || true
                    echo on > "$portpath/power/control"        2>/dev/null || true
                    info "USB autosuspend disabled for $(basename "$portpath")"
                fi
                break
            fi
            syspath=$(dirname "$syspath")
        done
    fi

    # 5. Give udev a moment to settle after any unmounts
    udevadm settle --timeout=5 2>/dev/null || sleep 2

    ok "Device $TARGET is ready"
}

# ============================================================================
# Partition the drive
# ============================================================================
partition_drive() {
    local bios_end=2
    local boot_end=$(( bios_end + BOOT_SIZE_MIB ))
    local root_end=$(( boot_end + ROOT_SIZE_MIB ))

    if [[ "$PRESERVE_HOME" == true ]]; then
        info "Preserving /home — only reformatting ESP (part 2) and root (part 3)..."
        # Keep part 1 (BIOS boot) and part 4 (encrypted /home) intact.
        parted "$TARGET" --script \
            rm 2 \
            rm 3 \
            mkpart ESP fat32 "${bios_end}MiB" "${boot_end}MiB" \
            set 2 boot on \
            set 2 esp on \
            mkpart primary ext4 "${boot_end}MiB" "${root_end}MiB"
    else
        info "Creating fresh partition table..."

        parted "$TARGET" --script \
            mklabel gpt \
            mkpart BIOS fat32 1MiB "${bios_end}MiB" \
            set 1 bios_grub on \
            mkpart ESP fat32 "${bios_end}MiB" "${boot_end}MiB" \
            set 2 boot on \
            set 2 esp on \
            mkpart primary ext4 "${boot_end}MiB" "${root_end}MiB" \
            mkpart primary "${root_end}MiB" 100%
    fi

    # Wait for kernel to pick up changes
    sleep 2
    partprobe "$TARGET" 2>/dev/null || true
    sleep 2

    # Determine partition device names
    if [[ "$TARGET" =~ [0-9]$ ]]; then
        BIOS_PART="${TARGET}p1"
        BOOT_PART="${TARGET}p2"
        ROOT_PART="${TARGET}p3"
        HOME_PART="${TARGET}p4"
    else
        BIOS_PART="${TARGET}1"
        BOOT_PART="${TARGET}2"
        ROOT_PART="${TARGET}3"
        HOME_PART="${TARGET}4"
    fi

    ok "Partitioning complete (BIOS:${BIOS_PART} ESP:${BOOT_PART} root:${ROOT_PART} home:${HOME_PART})"
}

# ============================================================================
# Format partitions
# ============================================================================
format_partitions() {
    info "Formatting /boot (FAT32)..."
    mkfs.vfat -F32 -n TONIX "$BOOT_PART"
    sync

    # Write a marker file to the boot partition root.
    # The embedded GRUB EFI binary searches for /.tonix-boot to reliably
    # identify the boot partition without confusing it with the root ext4.
    local boot_tmp
    boot_tmp=$(mktemp -d)
    mount "$BOOT_PART" "$boot_tmp"
    touch "$boot_tmp/.tonix-boot"
    umount "$boot_tmp"
    rmdir "$boot_tmp"

    info "Formatting / (ext4)..."
    mkfs.ext4 -F -L root -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard "$ROOT_PART"
    sync

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

        # Open, format with ext4, then close (mount_target will reopen)
        echo -n "$HOME_PASSWORD" | cryptsetup open "$HOME_PART" secure_home --key-file=-
        info "Formatting /home (ext4 inside LUKS)..."
        mkfs.ext4 -F -L home -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard /dev/mapper/secure_home
        sync
        cryptsetup close secure_home

        ok "Encryption setup complete"
    fi

    ok "All partitions formatted"
}

# ============================================================================
# Mount everything
# ============================================================================
mount_target() {
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
secure_home  UUID=$home_uuid  none  luks
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

    # Clean up our own bind mounts (install_bootloader will create its own)
    umount "$MOUNT_ROOT/dev"  2>/dev/null || true
    umount "$MOUNT_ROOT/proc" 2>/dev/null || true
    umount "$MOUNT_ROOT/sys"  2>/dev/null || true

    ok "Initramfs updated"
}

# ============================================================================
# Install GRUB (dual BIOS + UEFI)
# ============================================================================
install_bootloader() {
    info "Installing GRUB bootloader (BIOS + UEFI)..."

    # Bind mounts should already be up from configure_system(), but ensure
    # they're present (defensive — makes this function self-contained)
    mountpoint -q "$MOUNT_ROOT/dev"  2>/dev/null || mount --bind /dev  "$MOUNT_ROOT/dev"
    mountpoint -q "$MOUNT_ROOT/proc" 2>/dev/null || mount --bind /proc "$MOUNT_ROOT/proc"
    mountpoint -q "$MOUNT_ROOT/sys"  2>/dev/null || mount --bind /sys  "$MOUNT_ROOT/sys"

    # Mount efivarfs if available (some grub-install versions probe for it)
    if [[ -d /sys/firmware/efi/efivars ]]; then
        mkdir -p "$MOUNT_ROOT/sys/firmware/efi/efivars"
        mount --bind /sys/firmware/efi/efivars "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null || true
    fi

    # --- BIOS (legacy) ---
    #
    # We do NOT use grub-install for the BIOS core image.
    #
    # grub-install calls grub-probe to find which device backs the
    # --boot-directory path and embeds that as the prefix. But during install:
    #
    #   - From a live ISO: grub-probe sees the ISO's own filesystem backing
    #     $MOUNT_ROOT/boot, not TARGET. It embeds the ISO device as prefix.
    #   - From a chroot: grub-probe cannot resolve block devices at all.
    #
    # Either way the embedded prefix is wrong, and GRUB drops to rescue shell.
    #
    # Instead we use grub-mkimage with an EXPLICIT prefix: (,gpt2)/grub
    # The (,gpt2) syntax means "current disk, partition 2" — GRUB resolves
    # "current disk" at runtime as whichever disk the MBR was read from.
    # This is always correct regardless of whether the target is hd0, hd1,
    # vda, sda, or any other disk name.
    #
    info "Installing GRUB (BIOS/i386-pc) via grub-mkimage with explicit prefix..."

    local grub_mod_dir="/usr/lib/grub/i386-pc"
    [[ -d "$grub_mod_dir" ]] || die "GRUB i386-pc modules not found at $grub_mod_dir — install grub-pc-bin"

    # Install modules to the boot partition
    mkdir -p "$MOUNT_ROOT/boot/grub/i386-pc"
    cp "$grub_mod_dir"/*.mod "$MOUNT_ROOT/boot/grub/i386-pc/" 2>/dev/null || true

    # Build core.img with (,gpt2)/grub as the prefix.
    # Modules baked in: enough to read FAT32 and load grub.cfg.
    local core_img
    core_img=$(mktemp /tmp/grub-core.img.XXXXXX)

    grub-mkimage \
        --directory="$grub_mod_dir" \
        --prefix="(,gpt2)/grub" \
        --output="$core_img" \
        --format=i386-pc \
        --compression=auto \
        part_gpt part_msdos fat ext2 normal linux \
        search search_label search_fs_uuid search_fs_file \
        configfile echo gzio all_video

    # Write MBR boot code + embed core.img after it.
    # boot.img goes in the MBR (first 446 bytes), core.img goes in the
    # BIOS boot partition (partition 1, set bios_grub on, 1MiB gap).
    dd if="$grub_mod_dir/boot.img" of="$TARGET" bs=446 count=1 conv=notrunc 2>/dev/null
    dd if="$core_img" of="$TARGET" bs=512 seek=4 conv=notrunc 2>/dev/null

    # Also write core.img into the BIOS boot GPT partition (partition 1)
    # Some firmwares read from there instead of the post-MBR gap.
    dd if="$core_img" of="$BIOS_PART" bs=512 conv=notrunc 2>/dev/null || true

    rm -f "$core_img"
    ok "BIOS GRUB installed (grub-mkimage, prefix=(,gpt2)/grub)"

    # --- UEFI — build our own EFI binaries with grub-mkstandalone ---
    #
    # We do NOT use 'grub-install --target=x86_64-efi'.
    # Why: grub-install embeds Debian's default search config which looks for
    # /.disk/info (a Debian live convention). When that file doesn't exist,
    # $root stays empty, GRUB can't find grub.cfg, and drops to rescue shell.
    #
    # We use grub-mkstandalone from the HOST (not the chroot) with a fully
    # embedded menu config. This eliminates all runtime config-file searching:
    # the menu is baked directly into the EFI binary, same as the installer ISO.
    #
    info "Building custom GRUB EFI binaries (host grub-mkstandalone)..."

    local root_uuid_for_embed
    root_uuid_for_embed=$(blkid -s UUID -o value "$ROOT_PART")

    local kver_for_embed
    kver_for_embed=$(ls "$MOUNT_ROOT/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1 | sed "s|$MOUNT_ROOT/boot/vmlinuz-||")
    [[ -n "$kver_for_embed" ]] || die "Could not detect kernel version in installed OS"
    info "Detected kernel for EFI embed: $kver_for_embed"

    # The embedded config IS the full boot menu — no second-stage configfile.
    # search --label is reliable here: the ESP label (TONIX) is set by mkfs.vfat
    # and FAT labels are read natively by GRUB's fat module without needing
    # a filesystem scan. We also keep the marker file search as primary.
    local grub_embedded
    grub_embedded=$(mktemp /tmp/grub-embedded.cfg.XXXXXX)
    cat > "$grub_embedded" << GRUB_EMBED
# Tonix — Embedded GRUB Menu (baked into EFI binary)
# No external grub.cfg needed — this IS the menu.

# Find the boot partition (FAT32 ESP, label TONIX)
search --no-floppy --file --set=root /.tonix-boot
if [ -z "\$root" ]; then
    search --no-floppy --label --set=root TONIX
fi

set timeout=5
set default=0
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "${OS_PRETTY_NAME:-Tonix} — Immutable (default)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=yes apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Persistent Root (writable)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=no apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — RAM Only (entire OS in RAM)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=yes toram apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Recovery" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro single noresume tonix.overlay=no
    initrd /initrd.img-${kver_for_embed}
}
GRUB_EMBED

    local grub_modules="part_gpt part_msdos fat ext2 normal linux gzio all_video"
    grub_modules+=" search search_label search_fs_uuid search_fs_file"
    grub_modules+=" configfile echo test ls cat loopback"

    mkdir -p "$MOUNT_ROOT/boot/EFI/BOOT"

    # 64-bit EFI — run on HOST so we use host's grub module path
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$MOUNT_ROOT/boot/EFI/BOOT/BOOTX64.EFI" \
        --modules="$grub_modules" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$grub_embedded" \
        2>/dev/null || warn "x86_64-efi standalone build had warnings"

    # 32-bit EFI (older systems)
    grub-mkstandalone \
        --format=i386-efi \
        --output="$MOUNT_ROOT/boot/EFI/BOOT/BOOTIA32.EFI" \
        --modules="$grub_modules" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$grub_embedded" \
        2>/dev/null || warn "i386-efi standalone not available (non-fatal)"

    rm -f "$grub_embedded"

    ok "GRUB EFI binaries built (host grub-mkstandalone, full embedded menu)"

    # --- Write grub.cfg to boot partition ---
    #
    # This grub.cfg is used by BIOS boot (grub-install writes modules to
    # /boot/grub/i386-pc/ and loads /boot/grub/grub.cfg at runtime).
    # UEFI boot uses the fully embedded menu in the EFI binary above, but
    # also falls back to this file if configfile is called manually.
    #
    # CRITICAL PATH RULE: /boot is a SEPARATE FAT32 partition (partition 2).
    # GRUB's $root is set to the boot partition, so kernel paths have NO
    # /boot/ prefix — files are at /vmlinuz-X, not /boot/vmlinuz-X.
    #
    info "Writing GRUB configuration..."
    cat > "$MOUNT_ROOT/boot/grub/grub.cfg" << EOF
# Tonix GRUB Configuration — Codename: Mirage
# Paths are relative to the boot partition (no /boot/ prefix).

set timeout=5
set default=0
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "${OS_PRETTY_NAME:-Tonix} — Immutable (default)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=yes apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Persistent Root (writable)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=no apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — RAM Only (entire OS in RAM)" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro quiet noresume tonix.overlay=yes toram apparmor=1 security=apparmor
    initrd /initrd.img-${kver_for_embed}
}

menuentry "${OS_PRETTY_NAME:-Tonix} — Recovery" {
    linux /vmlinuz-${kver_for_embed} root=UUID=${root_uuid_for_embed} ro single noresume tonix.overlay=no
    initrd /initrd.img-${kver_for_embed}
}
EOF
    ok "grub.cfg written to boot partition"

    # Force flush to FAT32 — without this, umount can lose buffered writes
    sync

    # --- Install 10_tonix grub.d script ---
    # This handles future kernel updates on the RUNNING system (where
    # update-grub works properly, unlike in the installer chroot).
    cat > "$MOUNT_ROOT/etc/grub.d/10_tonix" << 'GRUB_SCRIPT'
#!/bin/bash
# Tonix custom GRUB menu entry generator.
# Runs via grub-mkconfig / update-grub on the live system.
#
# Uses make_system_path_relative_to_its_root() to correctly handle
# /boot as a separate partition:
#   separate /boot → /vmlinuz-X       (strips /boot prefix)
#   /boot on root  → /boot/vmlinuz-X  (keeps /boot prefix)
set -e

if [ -f /usr/lib/grub/grub-mkconfig_lib ]; then
    . /usr/lib/grub/grub-mkconfig_lib
else
    make_system_path_relative_to_its_root() { echo "$1"; }
fi

KVER=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's/.*vmlinuz-//')
[ -z "$KVER" ] && exit 0

LINUX=$(make_system_path_relative_to_its_root "/boot/vmlinuz-$KVER")
INITRD=$(make_system_path_relative_to_its_root "/boot/initrd.img-$KVER")
ROOT_UUID=$(grub-probe --target=fs_uuid / 2>/dev/null) || ROOT_UUID="DETECT_FAILED"

[ -f /etc/default/grub ] && . /etc/default/grub
QUIET="${GRUB_CMDLINE_LINUX_DEFAULT:-quiet noresume apparmor=1 security=apparmor}"
DISTRO="${GRUB_DISTRIBUTOR:-Tonix}"

cat << EOF
set timeout=${GRUB_TIMEOUT:-5}
set default=0
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "${DISTRO} — Immutable (default)" {
    linux ${LINUX} root=UUID=${ROOT_UUID} ro ${QUIET} tonix.overlay=yes
    initrd ${INITRD}
}

menuentry "${DISTRO} — Persistent Root (writable)" {
    linux ${LINUX} root=UUID=${ROOT_UUID} ro ${QUIET} tonix.overlay=no
    initrd ${INITRD}
}

menuentry "${DISTRO} — RAM Only (entire OS in RAM)" {
    linux ${LINUX} root=UUID=${ROOT_UUID} ro ${QUIET} tonix.overlay=yes toram
    initrd ${INITRD}
}

menuentry "${DISTRO} — Recovery" {
    linux ${LINUX} root=UUID=${ROOT_UUID} ro single noresume tonix.overlay=no
    initrd ${INITRD}
}
EOF
GRUB_SCRIPT
    chmod +x "$MOUNT_ROOT/etc/grub.d/10_tonix"

    # Disable default Debian generators (our 10_tonix replaces them)
    chmod -x "$MOUNT_ROOT/etc/grub.d/10_linux"  2>/dev/null || true
    chmod -x "$MOUNT_ROOT/etc/grub.d/20_linux_xen" 2>/dev/null || true
    chmod -x "$MOUNT_ROOT/etc/grub.d/30_os-prober" 2>/dev/null || true

    # Unmount bind mounts
    umount "$MOUNT_ROOT/sys/firmware/efi/efivars" 2>/dev/null || true
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

    # Only unmount if MOUNT_ROOT exists
    if [[ -d "${MOUNT_ROOT:-}" ]]; then
        umount "$MOUNT_ROOT/home"                       2>/dev/null || true
        cryptsetup close secure_home                     2>/dev/null || true
        umount "$MOUNT_ROOT/boot"                        2>/dev/null || true
        umount "$MOUNT_ROOT/sys/firmware/efi/efivars"    2>/dev/null || true
        umount "$MOUNT_ROOT/dev"                         2>/dev/null || true
        umount "$MOUNT_ROOT/proc"                        2>/dev/null || true
        umount "$MOUNT_ROOT/sys"                         2>/dev/null || true
        umount "$MOUNT_ROOT"                             2>/dev/null || true
        rmdir "$MOUNT_ROOT" 2>/dev/null || true
    fi

    sync

    ok "Cleanup complete"
}

# ============================================================================
# Main install flow
# ============================================================================
do_install() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║            Tonix Installer                                 ║"
    echo "╠════════════════════════════════════════════════════════════╣"
    echo "║  Target:  $TARGET                                          ║"
    echo "║  Image:   $(basename "$TARBALL_PATH")                      ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Confirmation
    if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
        warn "This will ERASE /boot and / on $TARGET"
        read -rp "Continue? (yes/no): " confirm
        [[ "$confirm" == "yes" ]] || { info "Cancelled."; exit 0; }
    fi

    MOUNT_ROOT="/mnt/tonix-install"

    trap cleanup EXIT

    preflight
    prepare_device
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
    echo "║  ✓ Installation complete!                                  ║"
    echo "║                                                            ║"
    echo "║  Remove installer media, then boot from $TARGET"
    echo "║  You will be prompted for your /home encryption password.  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}