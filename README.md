# voidarm64

Ultra-lightweight Void Linux ARM64 fork with Hyprland, built for UTM on Apple Silicon.

## How to get the ISO

1. **Fork or clone this repo** to your GitHub account
2. Go to **Actions** tab → the build starts automatically on every push
3. Wait ~15 minutes for the build to finish
4. Go to **Releases** → download `voidarm64-hyprland.iso`

Or trigger a manual build: **Actions → Build voidarm64 ISO → Run workflow**

## How to boot in UTM

1. UTM → **+** → **Virtualize** → **Linux**
2. Select the downloaded ISO as the boot image
3. Memory: `4096 MB` · CPU Cores: `4`
4. Display card: **`virtio-gpu-gl-pci`** ← required for Hyprland GPU acceleration
5. Boot → log in as `void` / `voidarm64`
6. Hyprland starts automatically

## Default credentials

| User | Password |
|------|----------|
| `void` | `voidarm64` |
| `root` | `voidarm64` |

**Change these immediately after first boot:**
```bash
passwd void
sudo passwd root
```

## Key bindings

| Keys | Action |
|------|--------|
| `Super + Enter` | Terminal (foot) |
| `Super + D` | App launcher (wofi) |
| `Super + Shift + Q` | Close window |
| `Super + Shift + E` | Exit Hyprland |
| `Super + F` | Fullscreen |
| `Super + 1-5` | Switch workspace |
| `Print` | Screenshot (select area) |
| `Shift + Print` | Screenshot (full screen) |

## Customisation

Edit files in `configs/` and push — GitHub Actions will rebuild the ISO automatically.

| File | What it controls |
|------|-----------------|
| `configs/hypr/hyprland.conf` | Keybinds, gaps, animations, autostart |
| `configs/waybar/config` | Status bar modules |
| `configs/waybar/style.css` | Status bar colours |
| `configs/wofi/config` | App launcher behaviour |
| `configs/foot/foot.ini` | Terminal font + colours |
| `scripts/build-rootfs.sh` | Package list |

## Stack

- **Base**: Void Linux aarch64 glibc
- **Init**: runit
- **Compositor**: Hyprland (Wayland)
- **Bar**: Waybar
- **Terminal**: foot
- **Launcher**: wofi
- **Audio**: PipeWire + WirePlumber
- **Network**: NetworkManager
- **GPU**: virtio-gpu-gl-pci → virgl → Metal (via UTM)
