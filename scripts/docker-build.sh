#!/bin/bash
# Runs inside ubuntu:24.04 ARM64 Docker container
# No broken dpkg hooks in a fresh container
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Architecture: $(uname -m)"
echo "==> Installing build tools..."
apt-get update -qq
apt-get install -y \
  xorriso mtools dosfstools e2fsprogs squashfs-tools \
  curl xz-utils rsync openssl binfmt-support \
  grub-common grub-efi-arm64-bin grub-efi-arm64

echo "==> Installing xbps..."
curl -fsSL --retry 3 \
  "https://repo-default.voidlinux.org/static/xbps-static-latest.aarch64-musl.tar.xz" \
  -o /tmp/xbps.tar.xz
mkdir -p /tmp/xbps-static
tar xf /tmp/xbps.tar.xz -C /tmp/xbps-static
for bin in xbps-install xbps-query xbps-reconfigure xbps-remove xbps-rindex; do
  FOUND=$(find /tmp/xbps-static -name "${bin}.static" | head -1)
  [ -n "$FOUND" ] && install -m755 "$FOUND" /usr/local/bin/${bin}
done
echo "xbps: $(xbps-install --version)"

echo "==> Building Void Linux rootfs..."
ROOTFS="/tmp/rootfs"
VOID_REPO="https://repo-default.voidlinux.org/current/aarch64"
mkdir -p "${ROOTFS}"/{dev,proc,sys,run,tmp,var/{log,cache/xbps},etc/xbps.d,boot}
mkdir -p "${ROOTFS}"/etc/runit/{1,2,3,sv,runsvdir/default}
mkdir -p "${ROOTFS}"/home/void
chmod 1777 "${ROOTFS}/tmp"

# Add Hyprland third-party repo (not in official Void repos)
HYPR_REPO="https://raw.githubusercontent.com/Makrennel/hyprland-void/repository-aarch64-glibc"
mkdir -p "${ROOTFS}/etc/xbps.d"
echo "repository=${HYPR_REPO}" > "${ROOTFS}/etc/xbps.d/hyprland-void.conf"

# Trust repo keys by downloading plist files from official sources
mkdir -p /var/db/xbps/keys "${ROOTFS}/var/db/xbps/keys"

# Void Linux key — colon format filename as used by xbps
curl -fsSL   "https://raw.githubusercontent.com/void-linux/xbps/master/data/60:ae:0c:d6:f0:95:17:80:bc:93:46:7a:89:af:a3:2d.plist"   -o "/var/db/xbps/keys/60:ae:0c:d6:f0:95:17:80:bc:93:46:7a:89:af:a3:2d.plist"

# hyprland-void key — accept interactively then copy
# xbps has no --yes flag for key import, so we use expect-style input
# The key is stored after first interactive accept; we pipe yes to handle it
yes | XBPS_ARCH="aarch64" xbps-install   --repository="${VOID_REPO}"   --repository="${HYPR_REPO}"   --rootdir="${ROOTFS}"   --sync 2>&1 || true
# Keys are now stored in /var/db/xbps/keys/ on the host
ls /var/db/xbps/keys/ || true

cp /var/db/xbps/keys/* "${ROOTFS}/var/db/xbps/keys/" 2>/dev/null || true

XBPS_ARCH="aarch64" xbps-install \
  --repository="${VOID_REPO}" \
  --repository="${HYPR_REPO}" \
  --rootdir="${ROOTFS}" \
  --sync --yes \
  base-system runit-void linux linux-firmware \
  e2fsprogs dosfstools util-linux \
  wayland wayland-protocols xorg-server-xwayland \
  libdrm mesa mesa-dri \
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal xdg-user-dirs \
  hyprpaper hypridle wl-clipboard wlr-randr grim slurp swappy \
  Waybar wofi \
  foot foot-terminfo \
  noto-fonts-ttf noto-fonts-emoji font-ttf-ubuntu \
  dunst libnotify \
  pipewire wireplumber pavucontrol \
  NetworkManager network-manager-applet iproute2 openssh \
  xbps bash bash-completion vim curl wget git htop dbus polkit

echo "==> Configuring system..."
echo "voidarm64" > "${ROOTFS}/etc/hostname"
echo "LANG=en_US.UTF-8" > "${ROOTFS}/etc/locale.conf"
cat > "${ROOTFS}/etc/rc.conf" << 'EOF'
TIMEZONE="UTC"
HARDWARECLOCK="UTC"
KEYMAP="us"
TTYS=2
EOF

cat > "${ROOTFS}/etc/runit/1" << 'EOF'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
mountpoint -q /proc  || mount -t proc proc /proc
mountpoint -q /sys   || mount -t sysfs sysfs /sys
mountpoint -q /dev   || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/{pts,shm}
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /run   || mount -t tmpfs tmpfs /run
mountpoint -q /tmp   || mount -t tmpfs tmpfs /tmp
chmod 1777 /dev/shm
modprobe virtio_gpu 2>/dev/null || true
modprobe virtio_net 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true
hostname -F /etc/hostname
mount -o remount,rw /
command -v udevd >/dev/null 2>&1 && { udevd --daemon; udevadm trigger; udevadm settle; }
echo "stage 1 done"
EOF
chmod +x "${ROOTFS}/etc/runit/1"

cat > "${ROOTFS}/etc/runit/2" << 'EOF'
#!/bin/sh
exec env - PATH=/usr/bin:/usr/sbin:/bin:/sbin \
  runsvdir -P /etc/runit/runsvdir/default 'log: ...........'
EOF
chmod +x "${ROOTFS}/etc/runit/2"

cat > "${ROOTFS}/etc/runit/3" << 'EOF'
#!/bin/sh
sv force-stop /etc/runit/runsvdir/default 2>/dev/null || true
umount -a -r 2>/dev/null || true
EOF
chmod +x "${ROOTFS}/etc/runit/3"

for svc in dbus NetworkManager sshd agetty-tty1 agetty-tty2; do
  [ -d "${ROOTFS}/etc/sv/${svc}" ] && \
    ln -sf "/etc/sv/${svc}" "${ROOTFS}/etc/runit/runsvdir/default/${svc}" || true
done

mkdir -p "${ROOTFS}/etc/sv/hyprland/log"
cat > "${ROOTFS}/etc/sv/hyprland/run" << 'EOF'
#!/bin/sh
sv check dbus >/dev/null 2>&1 || sleep 2
export XDG_RUNTIME_DIR="/run/user/1000"
export XDG_SESSION_TYPE="wayland"
export XDG_CURRENT_DESKTOP="Hyprland"
export WLR_RENDERER="gles2"
export WLR_NO_HARDWARE_CURSORS="1"
export GBM_BACKEND="virpipe"
export __GLX_VENDOR_LIBRARY_NAME="mesa"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"
chown void:void "${XDG_RUNTIME_DIR}"
exec chpst -u void:void:video:audio:input dbus-run-session -- Hyprland
EOF
chmod +x "${ROOTFS}/etc/sv/hyprland/run"
printf '#!/bin/sh\nexec svlogd -tt /var/log/hyprland\n' > "${ROOTFS}/etc/sv/hyprland/log/run"
chmod +x "${ROOTFS}/etc/sv/hyprland/log/run"
ln -sf /etc/sv/hyprland "${ROOTFS}/etc/runit/runsvdir/default/hyprland"

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

echo "==> Writing desktop configs..."
mkdir -p "${ROOTFS}/home/void/.config"/{hypr,Waybar,wofi,foot,dunst}

cat > "${ROOTFS}/home/void/.config/hypr/hyprland.conf" << 'HYPR'
monitor = , preferred, auto, 1
exec-once = pipewire
exec-once = wireplumber
exec-once = pipewire-pulse
exec-once = dunst
exec-once = Waybar
exec-once = nm-applet --indicator
input {
  kb_layout = us
  follow_mouse = 1
  sensitivity = 0
}
general {
  gaps_in = 4
  gaps_out = 8
  border_size = 2
  col.active_border = rgba(88c0d0ff) rgba(81a1c1ff) 45deg
  col.inactive_border = rgba(2e3440ff)
  layout = dwindle
}
decoration {
  rounding = 6
  blur { enabled = false }
  drop_shadow = false
}
animations {
  enabled = true
  bezier = easeOut, 0.05, 0.9, 0.1, 1.0
  animation = windows, 1, 4, easeOut
  animation = fade, 1, 4, default
  animation = workspaces, 1, 4, default
}
dwindle { pseudotile = true; preserve_split = true }
misc { force_default_wallpaper = 0; disable_hyprland_logo = true }
$mod = SUPER
bind = $mod, Return, exec, foot
bind = $mod, D, exec, wofi --show drun
bind = $mod SHIFT, Q, killactive
bind = $mod SHIFT, E, exit
bind = $mod, F, fullscreen
bind = $mod SHIFT, space, togglefloating
bind = $mod, h, movefocus, l
bind = $mod, l, movefocus, r
bind = $mod, k, movefocus, u
bind = $mod, j, movefocus, d
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bind = $mod SHIFT, 4, movetoworkspace, 4
bind = $mod SHIFT, 5, movetoworkspace, 5
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
HYPR

cat > "${ROOTFS}/home/void/.config/Waybar/config" << 'WAYBAR'
{
  "layer": "top", "position": "top", "height": 28, "spacing": 4,
  "modules-left": ["hyprland/workspaces", "hyprland/window"],
  "modules-center": ["clock"],
  "modules-right": ["pulseaudio", "network", "cpu", "memory", "tray"],
  "hyprland/workspaces": { "format": "{id}", "on-click": "activate" },
  "clock": { "format": "{:%a %d %b  %H:%M}" },
  "cpu": { "format": " {usage}%", "interval": 3 },
  "memory": { "format": " {used:0.1f}G", "interval": 5 },
  "pulseaudio": { "format": "{icon} {volume}%", "on-click": "pavucontrol" },
  "network": { "format-wifi": " {essid}", "format-ethernet": " {ipaddr}", "format-disconnected": "offline" },
  "tray": { "spacing": 8 }
}
WAYBAR

cat > "${ROOTFS}/home/void/.config/Waybar/style.css" << 'CSS'
* { font-family: monospace; font-size: 12px; border: none; min-height: 0; }
window#Waybar { background: rgba(46,52,64,0.95); color: #eceff4; }
#workspaces button { padding: 0 6px; color: #81a1c1; background: transparent; }
#workspaces button.active { color: #88c0d0; border-bottom: 2px solid #88c0d0; }
#clock { color: #88c0d0; padding: 0 10px; }
#cpu { color: #a3be8c; padding: 0 10px; }
#memory { color: #ebcb8b; padding: 0 10px; }
#network { color: #81a1c1; padding: 0 10px; }
CSS

cat > "${ROOTFS}/home/void/.config/wofi/config" << 'WOFI'
width=400
height=300
location=center
show=drun
prompt=Search...
gtk_dark=true
allow_images=true
WOFI

cat > "${ROOTFS}/home/void/.config/wofi/style.css" << 'WOFICSS'
window { background-color: #2e3440; border: 1px solid #4c566a; border-radius: 8px; }
#input { background-color: #3b4252; color: #eceff4; border: none; border-radius: 4px; margin: 8px; padding: 6px 10px; }
#entry:selected { background-color: #4c566a; color: #88c0d0; }
#text { color: #d8dee9; }
WOFICSS

cat > "${ROOTFS}/home/void/.config/foot/foot.ini" << 'FOOT'
[main]
font=monospace:size=11
dpi-aware=yes
[colors]
background=2e3440
foreground=d8dee9
regular0=3b4252
regular1=bf616a
regular2=a3be8c
regular3=ebcb8b
regular4=81a1c1
regular5=b48ead
regular6=88c0d0
regular7=e5e9f0
FOOT

cat > "${ROOTFS}/home/void/.config/dunst/dunstrc" << 'DUNST'
[global]
origin = top-right
offset = 12x12
width = 320
font = Sans 11
corner_radius = 6
background = "#2e3440"
foreground = "#d8dee9"
timeout = 5
DUNST

cat > "${ROOTFS}/home/void/.bash_profile" << 'EOF'
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

chown -R 1000:1000 "${ROOTFS}/home/void"
chmod 700 "${ROOTFS}/home/void"
XBPS_ARCH="aarch64" xbps-reconfigure --rootdir="${ROOTFS}" --force --all 2>/dev/null || true
echo "Rootfs: $(du -sh ${ROOTFS} | cut -f1)"

echo "==> Building ISO..."
ISO_WORK="/tmp/iso"
ISO_LABEL="VOIDARM64"
mkdir -p "${ISO_WORK}"/{boot/grub,efi/boot,live}

mksquashfs "${ROOTFS}" "${ISO_WORK}/live/filesystem.squashfs" \
  -comp zstd -Xcompression-level 6 -b 1M -noappend \
  -e "${ROOTFS}/proc" -e "${ROOTFS}/sys" \
  -e "${ROOTFS}/dev" -e "${ROOTFS}/run" -e "${ROOTFS}/tmp"
echo "SquashFS: $(du -sh ${ISO_WORK}/live/filesystem.squashfs | cut -f1)"

KERNEL=$(ls "${ROOTFS}/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "${ROOTFS}/boot/initramfs-"* 2>/dev/null | sort -V | tail -1)
[ -n "$KERNEL" ] || { echo "ERROR: no kernel"; exit 1; }
[ -n "$INITRD" ] || { echo "ERROR: no initramfs"; exit 1; }
cp "${KERNEL}" "${ISO_WORK}/boot/vmlinuz"
cp "${INITRD}" "${ISO_WORK}/boot/initramfs"
echo "Kernel: $(basename $KERNEL)"

cat > "${ISO_WORK}/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=5
menuentry "voidarm64 + Hyprland" {
  linux /boot/vmlinuz root=live:CDLABEL=VOIDARM64 rd.live.image rd.live.overlay.overlayfs=1 console=ttyAMA0 console=tty0 loglevel=4 quiet
  initrd /boot/initramfs
}
EOF

grub-mkstandalone \
  --format=arm64-efi \
  --output="${ISO_WORK}/efi/boot/bootaa64.efi" \
  "boot/grub/grub.cfg=${ISO_WORK}/boot/grub/grub.cfg"

EFI_IMG="${ISO_WORK}/boot/efi.img"
dd if=/dev/zero of="${EFI_IMG}" bs=1K count=4096 2>/dev/null
mkfs.fat -F12 "${EFI_IMG}"
mmd   -i "${EFI_IMG}" ::/EFI ::/EFI/BOOT
mcopy -i "${EFI_IMG}" "${ISO_WORK}/efi/boot/bootaa64.efi" ::/EFI/BOOT/

xorriso -as mkisofs \
  -iso-level 3 -volid "${ISO_LABEL}" \
  -full-iso9660-filenames -rational-rock -joliet \
  -e boot/efi.img -no-emul-boot \
  -append_partition 2 0xef "${ISO_WORK}/boot/efi.img" \
  -output "/output/voidarm64-hyprland.iso" \
  "${ISO_WORK}" 2>&1 | tail -5

echo "==> Done! ISO: $(du -sh /output/voidarm64-hyprland.iso | cut -f1)"
