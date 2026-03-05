#!/bin/bash
# =============================================================================
# scripts/build-rootfs.sh
# Builds the Void Linux ARM64 rootfs with Hyprland
# Called by GitHub Actions — runs on ubuntu-24.04-arm runner
# =============================================================================
set -euo pipefail

ROOTFS="/tmp/voidarm64-rootfs"
VOID_REPO="https://repo-default.voidlinux.org/current"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[·]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
die()  { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
step() { echo -e "\n${BOLD}── $* ──${NC}"; }

step "Building Void Linux ARM64 rootfs"

# ── Directory structure ───────────────────────────────────────────────────────
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"/{dev,proc,sys,run,tmp,var/{log,cache/xbps},etc/xbps.d,boot}
mkdir -p "${ROOTFS}"/etc/runit/{1,2,3,sv,runsvdir/default}
mkdir -p "${ROOTFS}"/usr/{bin,lib,sbin,share}
mkdir -p "${ROOTFS}"/home/void
chmod 1777 "${ROOTFS}/tmp"

# ── Packages ──────────────────────────────────────────────────────────────────
PACKAGES=(
    # Core
    base-system runit-void linux linux-firmware
    e2fsprogs dosfstools util-linux

    # Display stack
    wayland wayland-protocols xorg-server-xwayland
    libdrm mesa mesa-dri

    # Hyprland + Wayland tools
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal xdg-user-dirs
    hyprpaper hypridle
    wl-clipboard wlr-randr grim slurp swappy

    # Desktop apps
    waybar otf-font-awesome
    wofi
    foot foot-terminfo
    noto-fonts-ttf noto-fonts-emoji ttf-ubuntu-font-family
    dunst libnotify

    # Audio
    pipewire pipewire-pulse wireplumber pavucontrol

    # Network
    NetworkManager networkmanager-applet iproute2 openssh

    # Tools
    xbps bash bash-completion vim curl wget git htop
    dbus polkit
)

step "Installing ${#PACKAGES[@]} packages"
XBPS_ARCH="aarch64" xbps-install \
    --repository="${VOID_REPO}" \
    --rootdir="${ROOTFS}" \
    --sync --yes \
    "${PACKAGES[@]}" \
    || die "xbps-install failed"
ok "Packages installed"

# ── System config ─────────────────────────────────────────────────────────────
step "Writing system config"

echo "voidarm64" > "${ROOTFS}/etc/hostname"
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"

cat > "${ROOTFS}/etc/rc.conf" <<'EOF'
TIMEZONE="UTC"
HARDWARECLOCK="UTC"
KEYMAP="us"
TTYS=2
EOF

# ── runit init stages ─────────────────────────────────────────────────────────
cat > "${ROOTFS}/etc/runit/1" <<'EOF'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
mountpoint -q /proc  || mount -t proc     proc     /proc
mountpoint -q /sys   || mount -t sysfs    sysfs    /sys
mountpoint -q /dev   || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/{pts,shm}
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /run   || mount -t tmpfs tmpfs /run
mountpoint -q /tmp   || mount -t tmpfs tmpfs /tmp
chmod 1777 /dev/shm
modprobe virtio_gpu 2>/dev/null || true
modprobe virtio_net 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true
modprobe virtio_rng 2>/dev/null || true
hostname -F /etc/hostname
mount -o remount,rw /
command -v udevd >/dev/null 2>&1 && {
    udevd --daemon
    udevadm trigger
    udevadm settle
}
echo "voidarm64: stage 1 done"
EOF
chmod +x "${ROOTFS}/etc/runit/1"

cat > "${ROOTFS}/etc/runit/2" <<'EOF'
#!/bin/sh
exec env - PATH=/usr/bin:/usr/sbin:/bin:/sbin \
    runsvdir -P /etc/runit/runsvdir/default 'log: ...........'
EOF
chmod +x "${ROOTFS}/etc/runit/2"

cat > "${ROOTFS}/etc/runit/3" <<'EOF'
#!/bin/sh
sv force-stop /etc/runit/runsvdir/default 2>/dev/null || true
umount -a -r 2>/dev/null || true
EOF
chmod +x "${ROOTFS}/etc/runit/3"

# ── Enable services ───────────────────────────────────────────────────────────
for svc in dbus NetworkManager sshd agetty-tty1 agetty-tty2; do
    [ -d "${ROOTFS}/etc/sv/${svc}" ] && \
        ln -sf "/etc/sv/${svc}" "${ROOTFS}/etc/runit/runsvdir/default/${svc}"
done

# ── Hyprland service ──────────────────────────────────────────────────────────
mkdir -p "${ROOTFS}/etc/sv/hyprland/log"

cat > "${ROOTFS}/etc/sv/hyprland/run" <<'EOF'
#!/bin/sh
sv check dbus >/dev/null 2>&1 || sleep 2
export XDG_RUNTIME_DIR="/run/user/1000"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="Hyprland"
export WLR_RENDERER="gles2"
export WLR_NO_HARDWARE_CURSORS="1"
export GBM_BACKEND="virpipe"
export __GLX_VENDOR_LIBRARY_NAME="mesa"
export DISPLAY=":0"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"
chown void:void "${XDG_RUNTIME_DIR}"
exec chpst -u void:void:video:audio:input dbus-run-session -- Hyprland
EOF
chmod +x "${ROOTFS}/etc/sv/hyprland/run"

cat > "${ROOTFS}/etc/sv/hyprland/log/run" <<'EOF'
#!/bin/sh
exec svlogd -tt /var/log/hyprland
EOF
chmod +x "${ROOTFS}/etc/sv/hyprland/log/run"
ln -sf /etc/sv/hyprland "${ROOTFS}/etc/runit/runsvdir/default/hyprland"

# ── User account ──────────────────────────────────────────────────────────────
grep -q "^void:" "${ROOTFS}/etc/passwd" 2>/dev/null || \
    echo "void:x:1000:1000:void,,,:/home/void:/bin/bash" >> "${ROOTFS}/etc/passwd"
grep -q "^void:" "${ROOTFS}/etc/group" 2>/dev/null || \
    echo "void:x:1000:" >> "${ROOTFS}/etc/group"

for grp in wheel video audio input network plugdev; do
    grep -q "^${grp}:" "${ROOTFS}/etc/group" && \
        sed -i "/^${grp}:/ s/$/,void/" "${ROOTFS}/etc/group" || true
done

HASHED=$(openssl passwd -6 "voidarm64")
grep -q "^void:" "${ROOTFS}/etc/shadow" 2>/dev/null || \
    echo "void:${HASHED}:19000:0:99999:7:::" >> "${ROOTFS}/etc/shadow"
sed -i "s|^root:[^:]*:|root:${HASHED}:|" "${ROOTFS}/etc/shadow" 2>/dev/null || true

# ── Copy dot configs from repo ────────────────────────────────────────────────
step "Installing desktop configs"
mkdir -p "${ROOTFS}/home/void/.config"
cp -r configs/hypr   "${ROOTFS}/home/void/.config/"
cp -r configs/waybar "${ROOTFS}/home/void/.config/"
cp -r configs/wofi   "${ROOTFS}/home/void/.config/"
cp -r configs/foot   "${ROOTFS}/home/void/.config/"
cp -r configs/dunst  "${ROOTFS}/home/void/.config/"

cat > "${ROOTFS}/home/void/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_SESSION_TYPE="wayland"
    export XDG_CURRENT_DESKTOP="Hyprland"
    export WLR_RENDERER="gles2"
    export WLR_NO_HARDWARE_CURSORS="1"
    export GBM_BACKEND="virpipe"
    export __GLX_VENDOR_LIBRARY_NAME="mesa"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    exec dbus-run-session -- Hyprland
fi
EOF

cat > "${ROOTFS}/home/void/.bashrc" <<'EOF'
export PS1='\[\033[01;32m\]\u@voidarm64\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
export EDITOR=vim
alias ls='ls --color=auto'
alias ll='ls -lah'
EOF

cat > "${ROOTFS}/etc/motd" <<'EOF'

  ╔══════════════════════════════════════════╗
  ║  voidarm64 + Hyprland  ·  UTM ARM64      ║
  ║  login: void / voidarm64                 ║
  ║  Hyprland starts automatically on tty1   ║
  ╚══════════════════════════════════════════╝

EOF

chown -R 1000:1000 "${ROOTFS}/home/void"
chmod 700 "${ROOTFS}/home/void"

# ── Reconfigure ───────────────────────────────────────────────────────────────
XBPS_ARCH="aarch64" xbps-reconfigure \
    --rootdir="${ROOTFS}" --force --all 2>/dev/null || true

ok "Rootfs complete: $(du -sh ${ROOTFS} | cut -f1)"
