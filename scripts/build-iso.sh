#!/bin/bash
# =============================================================================
# scripts/build-iso.sh
# Wraps the Void Linux rootfs into a bootable ISO image
# Uses SquashFS for the live root + GRUB EFI bootloader
# =============================================================================
set -euo pipefail

ROOTFS="/tmp/voidarm64-rootfs"
ISO_WORK="/tmp/voidarm64-iso"
OUTPUT_DIR="$(pwd)/output"
ISO_NAME="voidarm64-hyprland.iso"
ISO_LABEL="VOIDARM64"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[·]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
die()  { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
step() { echo -e "\n${BOLD}── $* ──${NC}"; }

[[ -d "${ROOTFS}" ]] || die "Rootfs not found at ${ROOTFS} — run build-rootfs.sh first"

for cmd in xorriso mksquashfs grub-mkstandalone; do
    command -v "$cmd" &>/dev/null || die "Missing: $cmd"
done

step "Building bootable ISO"
mkdir -p "${ISO_WORK}"/{boot/grub,efi/boot,live}
mkdir -p "${OUTPUT_DIR}"

# ── Step 1: Compress rootfs into SquashFS ─────────────────────────────────────
step "Compressing rootfs → squashfs (this takes a few minutes)"
mksquashfs "${ROOTFS}" "${ISO_WORK}/live/filesystem.squashfs" \
    -comp zstd \
    -Xcompression-level 6 \
    -b 1M \
    -noappend \
    -e "${ROOTFS}/proc" \
    -e "${ROOTFS}/sys" \
    -e "${ROOTFS}/dev" \
    -e "${ROOTFS}/run" \
    -e "${ROOTFS}/tmp"
ok "SquashFS: $(du -sh ${ISO_WORK}/live/filesystem.squashfs | cut -f1)"

# ── Step 2: Copy kernel and initramfs ─────────────────────────────────────────
step "Copying kernel and initramfs"
KERNEL=$(ls "${ROOTFS}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "${ROOTFS}/boot/initramfs-"* 2>/dev/null | sort -V | tail -1)

[[ -n "${KERNEL}" ]] || die "No kernel found in rootfs. Was 'linux' package installed?"
[[ -n "${INITRD}" ]] || die "No initramfs found in rootfs."

cp "${KERNEL}" "${ISO_WORK}/boot/vmlinuz"
cp "${INITRD}" "${ISO_WORK}/boot/initramfs"
ok "Kernel:    $(basename ${KERNEL})"
ok "Initramfs: $(basename ${INITRD})"

# ── Step 3: Write GRUB config ─────────────────────────────────────────────────
step "Writing GRUB config"
cat > "${ISO_WORK}/boot/grub/grub.cfg" <<EOF
# voidarm64 + Hyprland — GRUB config
set default=0
set timeout=5

insmod all_video
insmod gfxterm
terminal_output gfxterm

menuentry "voidarm64 + Hyprland (UTM / Apple Silicon)" {
    linux  /boot/vmlinuz \\
        root=live:CDLABEL=${ISO_LABEL} \\
        rd.live.image \\
        rd.live.overlay.overlayfs=1 \\
        console=ttyAMA0 \\
        console=tty0 \\
        loglevel=4 \\
        quiet
    initrd /boot/initramfs
}

menuentry "voidarm64 + Hyprland (verbose boot)" {
    linux  /boot/vmlinuz \\
        root=live:CDLABEL=${ISO_LABEL} \\
        rd.live.image \\
        rd.live.overlay.overlayfs=1 \\
        console=ttyAMA0 \\
        console=tty0 \\
        loglevel=7
    initrd /boot/initramfs
}
EOF

# ── Step 4: Build GRUB EFI binary ─────────────────────────────────────────────
step "Building GRUB ARM64 EFI binary"

# Modules needed for ARM64 EFI boot from ISO
GRUB_MODULES="
    part_gpt part_msdos fat iso9660
    normal boot linux echo configfile
    search search_label search_fs_uuid
    ls cat reboot halt
    gfxterm all_video video_fb
    squash4 zstd
"

grub-mkstandalone \
    --format=arm64-efi \
    --output="${ISO_WORK}/efi/boot/bootaa64.efi" \
    --modules="${GRUB_MODULES}" \
    "boot/grub/grub.cfg=${ISO_WORK}/boot/grub/grub.cfg"

ok "GRUB EFI binary: $(du -sh ${ISO_WORK}/efi/boot/bootaa64.efi | cut -f1)"

# ── Step 5: Create EFI FAT image ─────────────────────────────────────────────
step "Creating EFI system partition image"
EFI_IMG="${ISO_WORK}/boot/efi.img"
EFI_SIZE_KB=$(( ($(du -sk "${ISO_WORK}/efi" | cut -f1) + 1024) ))
dd if=/dev/zero of="${EFI_IMG}" bs=1K count="${EFI_SIZE_KB}" 2>/dev/null
mkfs.fat -F12 "${EFI_IMG}"
# Copy EFI binary into the FAT image
mmd    -i "${EFI_IMG}" ::/EFI ::/EFI/BOOT
mcopy  -i "${EFI_IMG}" "${ISO_WORK}/efi/boot/bootaa64.efi" ::/EFI/BOOT/
ok "EFI image: $(du -sh ${EFI_IMG} | cut -f1)"

# ── Step 6: Build final ISO with xorriso ──────────────────────────────────────
step "Building ISO with xorriso"
xorriso \
    -as mkisofs \
    -iso-level 3 \
    -volid "${ISO_LABEL}" \
    -full-iso9660-filenames \
    -rational-rock \
    -joliet \
    \
    -e boot/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    \
    -eltorito-alt-boot \
    -e boot/efi.img \
    -no-emul-boot \
    -isohybrid-apm-hfsplus \
    \
    -append_partition 2 0xef "${ISO_WORK}/boot/efi.img" \
    \
    -output "${OUTPUT_DIR}/${ISO_NAME}" \
    "${ISO_WORK}" \
    2>&1 | tail -5     # only show last 5 lines (xorriso is very verbose)

ok "ISO built: ${OUTPUT_DIR}/${ISO_NAME}"
echo ""
echo "  Size: $(du -sh ${OUTPUT_DIR}/${ISO_NAME} | cut -f1)"
echo ""
