#!/usr/bin/env bash
# =============================================================================
# Universal Arch Linux & CachyOS Bootstrap & Installer
# Target Hardware: MSI Thin GF63 12VE (Alder Lake + RTX 4050/3050)
# Desktop Ecosystem: Niri / Hyprland (Lua) + Pixie SDDM + Bibata + GTK Themes
# =============================================================================
set -euo pipefail

# --- Color Formatting ---
BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_distro()  { echo -e "${CYAN}[DISTRO]${NC} $1"; }

# -----------------------------------------------------------------------------
# 0. Automatic OS & Environment Detection
# -----------------------------------------------------------------------------
if [[ ! -f /etc/os-release ]]; then
    log_error "Cannot detect Linux distribution. /etc/os-release is missing."
    exit 1
fi

source /etc/os-release

IS_CACHYOS=false
IS_ARCH=false

if [[ "${ID:-}" == "cachyos" ]] || grep -qi "cachyos" /etc/os-release; then
    IS_CACHYOS=true
    DISTRO_NAME="CachyOS"
elif [[ "${ID:-}" == "arch" ]] || [[ "${ID_LIKE:-}" == *"arch"* ]]; then
    IS_ARCH=true
    DISTRO_NAME="Arch Linux"
else
    log_error "Unsupported distribution: ${NAME:-Unknown}. This script only supports Arch Linux and CachyOS."
    exit 1
fi

log_distro "Operating System detected: ${BOLD}${DISTRO_NAME}${NC}"

IS_CHROOT=false
if [[ "$(stat -c %d:%i / 2>/dev/null)" != "$(stat -c %d:%i /proc/1/root 2>/dev/null)" ]] || ! systemctl is-system-running &>/dev/null; then
    IS_CHROOT=true
    log_warn "Running in CHROOT / Offline environment. Adjusting systemd & hardware operations."
fi

DETECTED_USER=""
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    DETECTED_USER="$SUDO_USER"
elif [[ "$USER" != "root" ]]; then
    DETECTED_USER="$USER"
fi

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_user() {
    if [[ $EUID -eq 0 ]]; then
        sudo -u "$TARGET_USER" "$@"
    else
        "$@"
    fi
}

purge_conflict() {
    local svc="$1"
    local pkg="$2"
    if ! $IS_CHROOT && systemctl is-active --quiet "$svc" 2>/dev/null; then
        run_root systemctl stop "$svc" || true
    fi
    run_root systemctl disable "$svc" 2>/dev/null || true
    run_root systemctl mask "$svc" 2>/dev/null || true
    if pacman -Qq "$pkg" &>/dev/null; then
        log_warn "Purging conflicting package: $pkg"
        run_root pacman -Rns --noconfirm "$pkg" || true
    fi
}

# -----------------------------------------------------------------------------
# 1. Interactive Menus
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}       1. CHOOSE USER ACCOUNT CONFIGURATION                        ${NC}"
echo -e "${BOLD}===================================================================${NC}"
if [[ -n "$DETECTED_USER" ]]; then
    echo -e " 1) ${GREEN}Current User ('${DETECTED_USER}')${NC} [Configure existing account]"
    echo -e " 2) ${BLUE}Create a New User${NC}            [Create a fresh user account]"
    echo -e "${BOLD}===================================================================${NC}"

    USER_CHOICE=""
    while [[ "$USER_CHOICE" != "1" && "$USER_CHOICE" != "2" ]]; do
        read -rp "Select user option [1 or 2] (Default: 1): " raw_u
        USER_CHOICE="${raw_u:-1}"
    done
else
    echo -e "${YELLOW}Root or chroot session detected. A non-root account must be configured.${NC}"
    USER_CHOICE="2"
fi

if [[ "$USER_CHOICE" == "1" ]]; then
    TARGET_USER="$DETECTED_USER"
    log_info "Configuring for current user: ${TARGET_USER}"
else
    while true; do
        read -rp "Enter new username to create: " raw_name
        TARGET_USER="$(echo "$raw_name" | xargs)"
        if [[ -z "$TARGET_USER" ]]; then
            echo "Username cannot be empty!"
        elif [[ "$TARGET_USER" == "root" ]]; then
            echo "Username cannot be 'root'!"
        elif [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            break
        else
            echo "Invalid syntax. Use lowercase letters, digits, and underscores."
        fi
    done
fi

echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}       2. CHOOSE YOUR WAYLAND COMPOSITOR                           ${NC}"
echo -e "${BOLD}===================================================================${NC}"
echo -e " 1) ${GREEN}Niri${NC}     - Scrollable-tiling Wayland compositor (43PR default)"
echo -e " 2) ${BLUE}Hyprland${NC} - Dynamic tiling Wayland compositor (Lua Enabled)"
echo -e " 3) ${YELLOW}Both${NC}     - Install both (switch anytime at SDDM login)"
echo -e "${BOLD}===================================================================${NC}"

COMP_CHOICE=""
while [[ "$COMP_CHOICE" != "1" && "$COMP_CHOICE" != "2" && "$COMP_CHOICE" != "3" ]]; do
    read -rp "Select compositor [1, 2, or 3] (Default: 2): " raw_c
    COMP_CHOICE="${raw_c:-2}"
done

echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}       3. CHOOSE LAPTOP POWER & CPU MANAGEMENT ENGINE              ${NC}"
echo -e "${BOLD}===================================================================${NC}"
echo -e " 1) ${GREEN}auto-cpufreq + EnvyControl${NC} (Recommended for GF63 thermals)"
echo -e " 2) ${BLUE}TLP + EnvyControl${NC}          (Maximum idle battery life)"
echo -e "${BOLD}===================================================================${NC}"

POWER_CHOICE=""
while [[ "$POWER_CHOICE" != "1" && "$POWER_CHOICE" != "2" ]]; do
    read -rp "Select power engine [1 or 2] (Default: 1): " raw_p
    POWER_CHOICE="${raw_p:-1}"
done

echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}       4. MSI GF63 12VE BATTERY HEALTH THRESHOLD (msi-ec)          ${NC}"
echo -e "${BOLD}===================================================================${NC}"
echo -e " 1) ${GREEN}80% Limit${NC}  - Balanced (Recommended: preserves battery health)"
echo -e " 2) ${BLUE}60% Limit${NC}  - Desk/Stationary mode (Maximum preservation)"
echo -e " 3) ${YELLOW}100% Limit${NC} - Full charge capacity"
echo -e "${BOLD}===================================================================${NC}"

BAT_CHOICE=""
while [[ "$BAT_CHOICE" != "1" && "$BAT_CHOICE" != "2" && "$BAT_CHOICE" != "3" ]]; do
    read -rp "Select battery threshold [1, 2, or 3] (Default: 1): " raw_b
    BAT_CHOICE="${raw_b:-1}"
done

case "$BAT_CHOICE" in
    1) BATTERY_THRESHOLD=80 ;;
    2) BATTERY_THRESHOLD=60 ;;
    3) BATTERY_THRESHOLD=100 ;;
esac

echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}       5. GAMING SUITE (STEAM, LUTRIS, WINE, GAMEMODE)             ${NC}"
echo -e "${BOLD}===================================================================${NC}"
echo -e " 1) ${GREEN}Install Gaming Stack${NC} (Steam, Lutris, GameMode, Gamescope, MangoHud)"
echo -e " 2) ${BLUE}No Gaming Stack${NC}      (Keep install lightweight)"
echo -e "${BOLD}===================================================================${NC}"

GAME_CHOICE=""
while [[ "$GAME_CHOICE" != "1" && "$GAME_CHOICE" != "2" ]]; do
    read -rp "Select option [1 or 2] (Default: 1): " raw_g
    GAME_CHOICE="${raw_g:-1}"
done

# -----------------------------------------------------------------------------
# 2. Hostname, Timezone & Locales (Chroot & Live Safe)
# -----------------------------------------------------------------------------
log_info "Configuring hostname, timezone, and locales..."

echo "msi-63" | run_root tee /etc/hostname > /dev/null
run_root tee /etc/hosts > /dev/null << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   msi-63.localdomain msi-63
EOF

run_root ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
run_root hwclock --systohc 2>/dev/null || true
run_root sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
run_root locale-gen
echo "LANG=en_US.UTF-8" | run_root tee /etc/locale.conf > /dev/null

# -----------------------------------------------------------------------------
# 3. User Setup & Temporary Sudo for Chroot Build
# -----------------------------------------------------------------------------
if ! id "$TARGET_USER" &>/dev/null; then
    log_info "Creating user '${TARGET_USER}'..."
    run_root useradd -m -g users -G wheel,network,video,audio,input,storage -s /bin/zsh "$TARGET_USER"
    echo "Please set a password for user '${TARGET_USER}':"
    run_root passwd "$TARGET_USER"
else
    log_info "Updating groups for existing user '${TARGET_USER}'..."
    run_root usermod -aG wheel,network,video,audio,input,storage -s /bin/zsh "$TARGET_USER"
fi

run_root pacman -Sy --needed --noconfirm sudo

run_root mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" | run_root tee /etc/sudoers.d/10-installer-temp > /dev/null
run_root chmod 0440 /etc/sudoers.d/10-installer-temp

# -----------------------------------------------------------------------------
# 4. Pacman Configuration & Matching Kernel Headers
# -----------------------------------------------------------------------------
log_info "Configuring Pacman repositories (enabling multilib & parallel downloads)..."

if grep -q "^#\[multilib\]" /etc/pacman.conf; then
    run_root sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
fi
run_root sed -i 's/^#ParallelDownloads = .*/ParallelDownloads = 5/' /etc/pacman.conf
run_root pacman -Sy --needed --noconfirm base-devel git curl wget pacman-contrib

KERNEL_RELEASE=$(uname -r 2>/dev/null || echo "linux")
log_info "Active kernel: ${KERNEL_RELEASE}"

if $IS_CACHYOS || pacman -Qq linux-cachyos &>/dev/null || [[ "$KERNEL_RELEASE" =~ "cachyos" ]]; then
    log_distro "Installing CachyOS optimized kernel headers & dkms..."
    run_root pacman -S --needed --noconfirm linux-cachyos-headers dkms
elif pacman -Qq linux-zen &>/dev/null || [[ "$KERNEL_RELEASE" =~ "zen" ]]; then
    run_root pacman -S --needed --noconfirm linux-zen-headers dkms
elif pacman -Qq linux-lts &>/dev/null || [[ "$KERNEL_RELEASE" =~ "lts" ]]; then
    run_root pacman -S --needed --noconfirm linux-lts-headers dkms
else
    run_root pacman -S --needed --noconfirm linux-headers dkms
fi

# -----------------------------------------------------------------------------
# 5. AUR Helper Setup (paru / yay)
# -----------------------------------------------------------------------------
AUR_HELPER=""
if command -v paru &>/dev/null; then
    AUR_HELPER="paru"
elif command -v yay &>/dev/null; then
    AUR_HELPER="yay"
else
    log_info "Bootstrapping yay-bin AUR helper..."
    BUILD_DIR=$(run_user mktemp -d)
    run_user git clone https://aur.archlinux.org/yay-bin.git "$BUILD_DIR/yay-bin"
    (cd "$BUILD_DIR/yay-bin" && run_user makepkg -si --noconfirm)
    rm -rf "$BUILD_DIR"
    AUR_HELPER="yay"
fi
log_success "Using AUR helper: ${AUR_HELPER}"

smart_install() {
    local pkg="$1"
    if pacman -Si "$pkg" &>/dev/null; then
        run_root pacman -S --needed --noconfirm "$pkg"
    else
        run_user "$AUR_HELPER" -S --needed --noconfirm "$pkg"
    fi
}

# -----------------------------------------------------------------------------
# 6. Core Packages, Polkit, VPN, GTK Themes & Utilities
# -----------------------------------------------------------------------------
log_info "Resolving conflicts and preparing package lists..."

if pacman -Qq jack2 &>/dev/null; then
    log_info "Replacing jack2 with pipewire-jack..."
    run_root pacman -Rdd --noconfirm jack2 || true
fi

if $IS_CACHYOS; then
    ROFI_PKG="rofi"
else
    ROFI_PKG="rofi-wayland"
fi

EXTRA_PACKAGES=(
    bibata-cursor-theme-bin
    arc-gtk-theme
    nordic-theme
    catppuccin-gtk-theme-mocha
    dracula-gtk-theme
    msi-ec-dkms-git
    quickshell
    mpvpaper
    zen-browser-bin
    helium-browser-bin
    visual-studio-code-bin
    opencode-bin
)

OFFICIAL_PACKAGES=(
    # --- Microcode & Sound Open Firmware (Alder Lake) ---
    intel-ucode
    sof-firmware
    alsa-ucm-conf
    alsa-firmware
    linux-firmware

    # --- Core Graphics / Mesa (Wayland Core) ---
    mesa
    lib32-mesa
    vulkan-intel
    lib32-vulkan-intel
    vulkan-icd-loader
    lib32-vulkan-icd-loader

    # --- Hardware & Filesystem Tools ---
    ntfs-3g dosfstools exfatprogs pciutils lm_sensors dmidecode openrgb udisks2 udiskie zram-generator

    # --- Polkit Authentication Agents ---
    polkit
    hyprpolkitagent
    polkit-gnome

    # --- Proton VPN Official GUI ---
    proton-vpn-gtk-app

    # --- Screenshot & Clipboard Utilities ---
    grim
    slurp
    hyprshot
    swappy
    cliphist
    wl-clipboard

    # --- Security & Networking ---
    apparmor firewalld networkmanager network-manager-applet systemd-resolvconf

    # --- Audio & Bluetooth ---
    pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber lib32-pipewire rtkit bluez bluez-utils blueman pavucontrol pamixer playerctl

    # --- Display Manager & Session Essentials (Qt6 dependencies for Pixie SDDM) ---
    upower sddm qt6-wayland qt6-svg qt6-multimedia qt6-declarative qt6-5compat xdg-user-dirs xdg-utils

    # --- Official Repository GTK Themes & Icon Suites ---
    adw-gtk-theme
    orchis-theme
    materia-gtk-theme
    adapta-gtk-theme
    breeze-gtk
    gnome-themes-extra
    papirus-icon-theme
    tela-circle-icon-theme-all
    nwg-look
    zenity

    # --- Desktop Integration ---
    thunar thunar-volman tumbler gvfs gvfs-mtp gvfs-smb nautilus file-roller gnome-keyring libsecret seahorse

    # --- CLI & 43PR Dotfiles Stack (includes awww daemon) ---
    zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting starship eza cava matugen awww "${ROFI_PKG}" kitty fastfetch btop ncdu cmatrix jq glib2 gsettings-desktop-schemas imagemagick ffmpeg ffmpegthumbnailer mpv libnotify brightnessctl wf-recorder gammastep 7zip unzip unrar

    # --- Fonts ---
    ttf-roboto ttf-roboto-mono noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-iosevka-nerd

    # --- NVIDIA & Video Acceleration ---
    nvidia-utils lib32-nvidia-utils nvidia-settings nvidia-prime intel-media-driver libva-nvidia-driver libva-utils

    # --- Dev Tools ---
    python python-pip uv nano
)

if ! pacman -Qq | grep -qE "^(nvidia|nvidia-dkms|nvidia-open|linux-cachyos-nvidia.*)$"; then
    if $IS_CACHYOS && pacman -Qq linux-cachyos &>/dev/null && pacman -Si linux-cachyos-nvidia &>/dev/null; then
        log_distro "Selecting precompiled CachyOS NVIDIA module (linux-cachyos-nvidia)..."
        OFFICIAL_PACKAGES+=(linux-cachyos-nvidia)
    else
        log_distro "Selecting universal NVIDIA DKMS module (nvidia-dkms)..."
        OFFICIAL_PACKAGES+=(nvidia-dkms)
    fi
fi

if [[ "$COMP_CHOICE" == "1" || "$COMP_CHOICE" == "3" ]]; then
    OFFICIAL_PACKAGES+=(niri xwayland-satellite xdg-desktop-portal-gtk)
fi

if [[ "$COMP_CHOICE" == "2" || "$COMP_CHOICE" == "3" ]]; then
    OFFICIAL_PACKAGES+=(hyprland hyprlock hypridle xdg-desktop-portal-hyprland)
fi

if ! printf '%s\n' "${OFFICIAL_PACKAGES[@]}" | grep -q "^hyprlock$"; then
    OFFICIAL_PACKAGES+=(hyprlock)
fi

if [[ "$GAME_CHOICE" == "1" ]]; then
    log_info "Adding Steam, Lutris, and gaming libraries..."
    OFFICIAL_PACKAGES+=(
        steam lutris gamemode lib32-gamemode gamescope mangohud lib32-mangohud
        wine-staging giflib lib32-giflib gnutls lib32-gnutls
    )
fi

# AUTO-VALIDATION FILTER (Prevents missing-package aborts)
log_info "Validating packages against active repositories..."
VALID_OFFICIAL_PACKAGES=()
for pkg in "${OFFICIAL_PACKAGES[@]}"; do
    if pacman -Si "$pkg" &>/dev/null; then
        VALID_OFFICIAL_PACKAGES+=("$pkg")
    else
        log_warn "Package '$pkg' is not in official repositories. Queuing for AUR installation..."
        EXTRA_PACKAGES+=("$pkg")
    fi
done

log_info "Installing official repository packages..."
run_root pacman -S --needed --noconfirm "${VALID_OFFICIAL_PACKAGES[@]}"

# -----------------------------------------------------------------------------
# 7. Autostart Daemons (awww-daemon, hyprpolkitagent) & Shortcuts
# -----------------------------------------------------------------------------
log_info "Configuring autostart daemons (awww-daemon, hyprpolkitagent) and keybindings..."

run_root tee /usr/local/bin/screenshot > /dev/null << 'EOF'
#!/usr/bin/env bash
mkdir -p "$HOME/Pictures/Screenshots"
FILE="$HOME/Pictures/Screenshots/Screenshot_$(date +'%Y-%m-%d_%H-%M-%S').png"
MODE="${1:-full}"

if [ "$MODE" = "full" ]; then
    grim "$FILE"
    wl-copy < "$FILE"
    notify-send -i "$FILE" "Screenshot Captured" "Full screen saved and copied to clipboard."
elif [ "$MODE" = "area" ]; then
    GEOM=$(slurp)
    if [ -n "$GEOM" ]; then
        grim -g "$GEOM" "$FILE"
        wl-copy < "$FILE"
        notify-send -i "$FILE" "Area Screenshot Captured" "Selected area saved and copied to clipboard."
    fi
fi
EOF
run_root chmod +x /usr/local/bin/screenshot

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# --- 1. Hyprland Configuration (Lua Standard + Conf Fallback) ---
HYPR_CONFIG_DIR="${USER_HOME}/.config/hypr"
HYPR_LUA_FILE="${HYPR_CONFIG_DIR}/hyprland.lua"
HYPR_CONF_FILE="${HYPR_CONFIG_DIR}/hyprland.conf"
run_root mkdir -p "$HYPR_CONFIG_DIR"

if [[ -f "$HYPR_LUA_FILE" ]] || [[ ! -f "$HYPR_CONF_FILE" ]]; then
    [[ ! -f "$HYPR_LUA_FILE" ]] && run_root touch "$HYPR_LUA_FILE"
    if ! grep -q "awww-daemon" "$HYPR_LUA_FILE"; then
        cat << 'EOF' | run_root tee -a "$HYPR_LUA_FILE" > /dev/null

-- Autostart Daemons (Polkit, Wallpaper & Clipboard)
hl.exec_cmd("/usr/lib/hyprpolkitagent/hyprpolkitagent")
hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
hl.exec_cmd("awww-daemon")
hl.exec_cmd("wl-paste --type text --watch cliphist store")
hl.exec_cmd("wl-paste --type image --watch cliphist store")
hl.exec_cmd("hyprctl setcursor Bibata-Modern-Classic 24")

-- Shortcuts: Screenshots, Clipboard, Apps
hl.bind("PRINT", hl.dsp.exec_cmd("/usr/local/bin/screenshot full"))
hl.bind("CTRL + PRINT", hl.dsp.exec_cmd("/usr/local/bin/screenshot area"))
hl.bind("SUPER + V", hl.dsp.exec_cmd("sh -c 'cliphist list | rofi -dmenu -p \"Clipboard\" | cliphist decode | wl-copy'"))
hl.bind("SUPER + Z", hl.dsp.exec_cmd("zen-browser"))
hl.bind("SUPER + N", hl.dsp.exec_cmd("sh -c 'protonvpn-app || protonvpn'"))
EOF
    fi
fi

if [[ -f "$HYPR_CONF_FILE" ]]; then
    if ! grep -q "awww-daemon" "$HYPR_CONF_FILE"; then
        cat << 'EOF' | run_root tee -a "$HYPR_CONF_FILE" > /dev/null

# Autostart Daemons
exec-once = /usr/lib/hyprpolkitagent/hyprpolkitagent
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = awww-daemon
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = hyprctl setcursor Bibata-Modern-Classic 24

# Keybindings: Screenshots, Clipboard, Apps
bind = , Print, exec, /usr/local/bin/screenshot full
bind = CTRL, Print, exec, /usr/local/bin/screenshot area
bind = SUPER, V, exec, cliphist list | rofi -dmenu -p "Clipboard" | cliphist decode | wl-copy
bind = SUPER, Z, exec, zen-browser
bind = SUPER, N, exec, sh -c "protonvpn-app || protonvpn"
EOF
    fi
fi

# --- 2. Niri Configuration (KDL Format) ---
NIRI_CONFIG_DIR="${USER_HOME}/.config/niri"
NIRI_CONFIG_FILE="${NIRI_CONFIG_DIR}/config.kdl"
run_root mkdir -p "$NIRI_CONFIG_DIR"

if [[ ! -f "$NIRI_CONFIG_FILE" ]]; then
    run_root touch "$NIRI_CONFIG_FILE"
fi

if ! grep -q "awww-daemon" "$NIRI_CONFIG_FILE"; then
    cat << 'EOF' | run_root tee -a "$NIRI_CONFIG_FILE" > /dev/null

// Autostart Daemons (Polkit, Wallpaper & Clipboard)
spawn-at-startup "/usr/lib/hyprpolkitagent/hyprpolkitagent"
spawn-at-startup "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"
spawn-at-startup "awww-daemon"
spawn-at-startup "wl-paste" "--type" "text" "--watch" "cliphist" "store"
spawn-at-startup "wl-paste" "--type" "image" "--watch" "cliphist" "store"

// Cursor Configuration
cursor {
    xcursor-theme "Bibata-Modern-Classic"
    xcursor-size 24
}

// Keybindings: Screenshots, Clipboard, Apps
binds {
    Print { spawn "/usr/local/bin/screenshot" "full"; }
    Ctrl+Print { spawn "/usr/local/bin/screenshot" "area"; }
    Mod+V { spawn "sh" "-c" "cliphist list | rofi -dmenu -p 'Clipboard' | cliphist decode | wl-copy"; }
    Mod+Z { spawn "zen-browser"; }
    Mod+N { spawn "sh" "-c" "protonvpn-app || protonvpn"; }
}
EOF
fi

USER_GID=$(id -g "$TARGET_USER")
run_root chown -R "${TARGET_USER}:${USER_GID}" "${USER_HOME}/.config"

# --- 3. Systemd User Units & Global Wants ---
run_root mkdir -p /etc/systemd/user /etc/systemd/user/graphical-session.target.wants

run_root tee /etc/systemd/user/hyprpolkitagent.service > /dev/null << 'EOF'
[Unit]
Description=Hyprland Polkit Authentication Agent
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/lib/hyprpolkitagent/hyprpolkitagent
Restart=on-failure
RestartSec=1
TimeoutStopSec=5sec

[Install]
WantedBy=graphical-session.target
EOF

# Enable hyprpolkitagent at system-wide user level
run_root ln -sf /etc/systemd/user/hyprpolkitagent.service /etc/systemd/user/graphical-session.target.wants/hyprpolkitagent.service

run_root tee /etc/systemd/user/polkit-gnome-authentication-agent-1.service > /dev/null << 'EOF'
[Unit]
Description=GNOME Polkit Authentication Agent
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
Restart=on-failure
RestartSec=1
TimeoutStopSec=5sec

[Install]
WantedBy=graphical-session.target
EOF

# --- 4. XDG Autostart Desktop Entries ---
run_root mkdir -p /etc/xdg/autostart

run_root tee /etc/xdg/autostart/hyprpolkitagent.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Hyprpolkitagent
Comment=Hyprland Polkit Authentication Agent
Exec=/usr/lib/hyprpolkitagent/hyprpolkitagent
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
EOF

run_root tee /etc/xdg/autostart/polkit-gnome-authentication-agent-1.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Polkit GNOME Authentication Agent
Comment=PolicyKit Authentication Agent
Exec=/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
EOF

# -----------------------------------------------------------------------------
# 8. Power Management Setup (Purges Distro PPD & Tuned)
# -----------------------------------------------------------------------------
log_info "Configuring chosen power management engine..."

purge_conflict "power-profiles-daemon.service" "power-profiles-daemon"
purge_conflict "tuned-ppd.service" "tuned-ppd"
purge_conflict "tuned.service" "tuned"

if [[ "$POWER_CHOICE" == "1" ]]; then
    purge_conflict "tlp.service" "tlp"
    purge_conflict "tlp.service" "tlp-rdw"
    run_root rm -f /etc/tlp.d/01-custom.conf
    smart_install "auto-cpufreq"
    smart_install "envycontrol"
    run_root systemctl unmask auto-cpufreq.service 2>/dev/null || true
    run_root systemctl enable auto-cpufreq.service
else
    purge_conflict "auto-cpufreq.service" "auto-cpufreq"
    smart_install "tlp"
    smart_install "envycontrol"
    run_root mkdir -p /etc/tlp.d
    run_root tee /etc/tlp.d/01-custom.conf > /dev/null << 'EOF'
CPU_SCALING_GOVERNOR_ON_AC="performance"
CPU_ENERGY_PERF_POLICY_ON_AC="performance"
PLATFORM_PROFILE_ON_AC="performance"
CPU_MIN_PERF_ON_AC=0
CPU_MAX_PERF_ON_AC=100
CPU_SCALING_GOVERNOR_ON_BAT="powersave"
CPU_ENERGY_PERF_POLICY_ON_BAT="balance_performance"
PLATFORM_PROFILE_ON_BAT="balanced"
CPU_MIN_PERF_ON_BAT=0
CPU_MAX_PERF_ON_BAT=80
EOF
    run_root systemctl unmask tlp.service 2>/dev/null || true
    run_root systemctl enable tlp.service
fi

# -----------------------------------------------------------------------------
# 9. AUR Packages (Bibata Cursors, Extra GTK Themes, Browsers)
# -----------------------------------------------------------------------------
log_info "Installing Bibata cursors, GTK themes & browser ecosystem from AUR..."

for pkg in "${EXTRA_PACKAGES[@]}"; do
    log_info "Processing: $pkg"
    smart_install "$pkg" || log_warn "Failed to install $pkg via AUR (continuing...)"
done

# -----------------------------------------------------------------------------
# 10. MSI GF63 Hardware Features & Battery Threshold
# -----------------------------------------------------------------------------
log_info "Configuring MSI EC module & battery charge threshold (${BATTERY_THRESHOLD}%)..."

echo "msi-ec" | run_root tee /etc/modules-load.d/msi-ec.conf > /dev/null

run_root tee /etc/systemd/system/msi-battery-threshold.service > /dev/null << EOF
[Unit]
Description=MSI GF63 Battery Charge Limit (${BATTERY_THRESHOLD}%)
After=sys-devices-platform-msi\\x2dec.device
Wants=sys-devices-platform-msi\\x2dec.device

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ${BATTERY_THRESHOLD} > /sys/devices/platform/msi-ec/battery_charge_threshold || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

run_root systemctl enable msi-battery-threshold.service

# -----------------------------------------------------------------------------
# 11. Early KMS & Initramfs Auto-Configuration
# -----------------------------------------------------------------------------
INITRAMFS_ENGINE="unknown"
if command -v mkinitcpio &>/dev/null && [[ -f /etc/mkinitcpio.conf ]]; then
    INITRAMFS_ENGINE="mkinitcpio"
elif command -v dracut &>/dev/null; then
    INITRAMFS_ENGINE="dracut"
fi
log_distro "Detected initramfs generator: ${INITRAMFS_ENGINE}"

if [[ "$INITRAMFS_ENGINE" == "mkinitcpio" ]]; then
    for mod in intel_agp i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
        if ! grep -q "$mod" /etc/mkinitcpio.conf; then
            run_root sed -i "s/^MODULES=(\(.*\))/MODULES=(\1 $mod)/" /etc/mkinitcpio.conf
        fi
    done

    run_root mkdir -p /etc/pacman.d/hooks
    run_root tee /etc/pacman.d/hooks/nvidia.hook > /dev/null << 'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia*
Target=linux*

[Action]
Description=Update NVIDIA modules in mkinitcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux*) exit 0; esac; done; /usr/bin/mkinitcpio -P'
EOF
    run_root mkinitcpio -P || true

elif [[ "$INITRAMFS_ENGINE" == "dracut" ]]; then
    run_root mkdir -p /etc/dracut.conf.d
    run_root tee /etc/dracut.conf.d/nvidia.conf > /dev/null << 'EOF'
force_drivers+=" intel_agp i915 nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF
    if command -v dracut-rebuild &>/dev/null; then
        run_root dracut-rebuild || true
    else
        run_root dracut --force --regenerate-all || true
    fi
fi

# -----------------------------------------------------------------------------
# 12. ZRAM, Video Acceleration, Cursors & Environment Variables
# -----------------------------------------------------------------------------
log_info "Configuring ZRAM swap, Bibata cursor defaults, and video acceleration..."

run_root tee /etc/systemd/zram-generator.conf > /dev/null << 'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

run_root systemctl enable systemd-oomd

# Set system-wide default cursor to Bibata Modern Classic
run_root mkdir -p /usr/share/icons/default
run_root tee /usr/share/icons/default/index.theme > /dev/null << 'EOF'
[Icon Theme]
Name=Default
Comment=Default Cursor Theme
Inherits=Bibata-Modern-Classic
EOF

# System-wide Environment variables
run_root tee /etc/environment > /dev/null << 'EOF'
NIXOS_OZONE_WL=1
ELECTRON_OZONE_PLATFORM_HINT=auto
QT_QPA_PLATFORM="wayland;xcb"
GDK_BACKEND="wayland,x11,*"
GSETTINGS_SCHEMA_DIR="/usr/share/glib-2.0/schemas/"
LIBVA_DRIVER_NAME=iHD
VDPAU_DRIVER=va_gl
XCURSOR_THEME=Bibata-Modern-Classic
XCURSOR_SIZE=24
EOF

# Configure user GSettings for cursor
run_user gsettings set org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Classic' 2>/dev/null || true
run_user gsettings set org.gnome.desktop.interface cursor-size 24 2>/dev/null || true

# -----------------------------------------------------------------------------
# 13. Security Sysctl, DNS-over-TLS & First-Boot Firewall
# -----------------------------------------------------------------------------
log_info "Configuring sysctl hardening, DoT, and firewall..."

run_root tee /etc/sysctl.d/99-hardening.conf > /dev/null << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF

# DNS-over-TLS (AdGuard + Quad9)
run_root mkdir -p /etc/systemd/resolved.conf.d /etc/NetworkManager/conf.d
run_root tee /etc/systemd/resolved.conf.d/dns.conf > /dev/null << 'EOF'
[Resolve]
DNS=94.140.14.14#dns.adguard-dns.com 94.140.15.15#dns.adguard-dns.com
FallbackDNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSSEC=allow-downgrade
DNSOverTLS=yes
EOF

run_root tee /etc/NetworkManager/conf.d/dns.conf > /dev/null << 'EOF'
[main]
dns=systemd-resolved
EOF
run_root ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# First-boot firewalld configuration service
run_root tee /etc/systemd/system/firewall-firstboot.service > /dev/null << 'EOF'
[Unit]
Description=Initial Firewall Configuration
After=firewalld.service
Wants=firewalld.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'firewall-cmd --set-default-zone=public --permanent && firewall-cmd --zone=trusted --add-interface=virbr0 --permanent && firewall-cmd --zone=trusted --add-interface=docker0 --permanent && firewall-cmd --zone=public --add-icmp-block=echo-request --permanent && firewall-cmd --reload'
ExecStartPost=/bin/sh -c 'systemctl disable firewall-firstboot.service && rm -f /etc/systemd/system/firewall-firstboot.service'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
run_root systemctl enable firewall-firstboot.service

# -----------------------------------------------------------------------------
# 14. SDDM Theme (Pixie SDDM), Wayland & NVIDIA Power Management
# -----------------------------------------------------------------------------
log_info "Installing and configuring Pixie SDDM theme (xCaptaiN09/pixie-sddm)..."

THEME_DIR="/usr/share/sddm/themes/pixie"
run_root mkdir -p "/usr/share/sddm/themes"

run_root rm -rf "$THEME_DIR" "/usr/share/sddm/pixie"
if git clone --depth=1 https://github.com/xCaptaiN09/pixie-sddm.git "$THEME_DIR"; then
    run_root ln -sf "$THEME_DIR" "/usr/share/sddm/pixie"
    run_root chmod -R 755 "$THEME_DIR"
    run_root chmod 755 /usr/share/sddm /usr/share/sddm/themes
    log_success "Pixie SDDM theme installed with permissions (755)."
else
    log_warn "Failed to clone Pixie SDDM directly. Falling back to AUR..."
    smart_install "pixie-sddm-git" || log_warn "Could not install pixie-sddm-git"
    run_root chmod -R 755 "$THEME_DIR" 2>/dev/null || true
fi

run_root mkdir -p /etc/sddm.conf.d
run_root tee /etc/sddm.conf.d/wayland.conf > /dev/null << 'EOF'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Theme]
Current=pixie
ThemeDir=/usr/share/sddm/themes
EOF

for pam_file in /etc/pam.d/login /etc/pam.d/sddm; do
    if [[ -f "$pam_file" ]] && ! grep -q "pam_gnome_keyring.so" "$pam_file"; then
        echo "auth     optional  pam_gnome_keyring.so" | run_root tee -a "$pam_file" > /dev/null
        echo "session  optional  pam_gnome_keyring.so auto_start" | run_root tee -a "$pam_file" > /dev/null
    fi
done

run_root tee /etc/modprobe.d/nvidia.conf > /dev/null << 'EOF'
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
EOF

run_root tee /etc/bluetooth/main.conf > /dev/null << 'EOF'
[General]
Experimental = true
AutoEnable = true
EOF

run_root chsh -s /bin/zsh "$TARGET_USER"
run_user xdg-user-dirs-update 2>/dev/null || true

# -----------------------------------------------------------------------------
# 15. Enable System Daemons (Chroot & Live Safe)
# -----------------------------------------------------------------------------
log_info "Enabling core system services..."

SERVICES=(
    NetworkManager.service
    systemd-resolved.service
    firewalld.service
    apparmor.service
    bluetooth.service
    upower.service
    sddm.service
    rtkit-daemon.service
    udisks2.service
    nvidia-suspend.service
    nvidia-hibernate.service
    nvidia-resume.service
    fstrim.timer
    paccache.timer
)

for service in "${SERVICES[@]}"; do
    run_root systemctl enable "$service" 2>/dev/null || log_warn "Could not enable $service"
done

# -----------------------------------------------------------------------------
# 16. Bootloader Kernel Parameters
# -----------------------------------------------------------------------------
KERNEL_PARAMS="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 randomize_kstack_offset=on nvidia_drm.modeset=1 nvidia_drm.fbdev=1 apparmor=1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

if [[ -f /etc/default/grub ]]; then
    log_info "Updating GRUB command-line parameters..."
    run_root sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${KERNEL_PARAMS}\"|" /etc/default/grub
    run_root grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
elif [[ -f /boot/limine.conf || -f /boot/limine/limine.conf || -f /boot/EFI/limine/limine.conf ]]; then
    log_info "Limine bootloader detected. Make sure cmdline contains:"
    echo -e "${YELLOW}cmdline: ... ${KERNEL_PARAMS}${NC}"
elif [[ -d /boot/loader/entries ]]; then
    log_info "systemd-boot detected. Ensure options in /boot/loader/entries/*.conf contain:"
    echo -e "${YELLOW}options ... ${KERNEL_PARAMS}${NC}"
fi

# -----------------------------------------------------------------------------
# 17. Security Cleanup: Restore Secure Sudoers
# -----------------------------------------------------------------------------
log_info "Finalizing sudoers security..."
run_root rm -f /etc/sudoers.d/10-installer-temp
echo "%wheel ALL=(ALL:ALL) ALL" | run_root tee /etc/sudoers.d/10-wheel > /dev/null
run_root chmod 0440 /etc/sudoers.d/10-wheel

# -----------------------------------------------------------------------------
log_success "================================================================="
log_success " Bootstrap Complete on ${DISTRO_NAME}!"
log_success " Configured Account: ${TARGET_USER}"
log_success " SDDM Theme: Pixie (xCaptaiN09/pixie-sddm) Activated with 755 permissions"
log_success " Polkit Agents: hyprpolkitagent + polkit-gnome (Enabled & Autostarting)"
log_success " Wallpaper Daemon: awww-daemon configured in hyprland.lua & config.kdl"
log_success " Cursors: Bibata Modern Classic (System-wide default)"
log_success " Themes: Orchis, Materia, Adapta, Nordic, Catppuccin, Dracula, Arc"
log_success " Compositor Configs:"
log_success "   • Hyprland: Modern Lua API (hyprland.lua) & hyprland.conf"
log_success "   • Niri: KDL Configuration (config.kdl)"
log_success " Shortcuts & Clipboard Integration:"
log_success "   • [PrintScreen]: Full-screen capture (Saved to ~/Pictures & Copied)"
log_success "   • [Ctrl + PrintScreen]: Area selection (Saved to ~/Pictures & Copied)"
log_success "   • [Mod + V]: Open Clipboard History (Cliphist + Rofi)"
log_success "   • [Mod + Z]: Launch Zen Browser"
log_success "   • [Mod + N]: Launch Proton VPN"
log_success " Power Engine: $([ "$POWER_CHOICE" == "1" ] && echo "auto-cpufreq + EnvyControl" || echo "TLP + EnvyControl")"
log_success " Battery Threshold: ${BATTERY_THRESHOLD}% (via msi-ec)"
log_success " Gaming Suite: $([ "$GAME_CHOICE" == "1" ] && echo "Installed" || echo "Skipped")"
log_success " Initramfs Engine: ${INITRAMFS_ENGINE}"
log_success "================================================================="
if $IS_CHROOT; then
    log_info "You are inside chroot: type 'exit', then 'umount -R /mnt' and 'reboot'."
else
    log_info "Installation finished! Please reboot your laptop: sudo reboot"
fi
