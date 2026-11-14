#!/usr/bin/env bash
# =============================================================================
# Settings-Only Configuration Script for MSI Thin GF63 12VE (Arch / CachyOS)
# Applies system configs, sysctl, power rules, and conditional desktop keybinds
# =============================================================================
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# -----------------------------------------------------------------------------
# 0. User & Compositor Selection
# -----------------------------------------------------------------------------
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
elif [[ "$USER" != "root" ]]; then
    TARGET_USER="$USER"
else
    TARGET_USER="lki"
fi

USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
USER_GID=$(id -g "$TARGET_USER")

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo ""
echo -e "${BOLD}===================================================================${NC}"
echo -e "${BOLD}   WHICH COMPOSITOR WOULD YOU LIKE TO CONFIGURE SHORTCUTS FOR?     ${NC}"
echo -e "${BOLD}===================================================================${NC}"
echo -e " 1) ${GREEN}Hyprland${NC}             - Configure hyprland.lua (Print, Mod+V, Mod+Z, Mod+N)"
echo -e " 2) ${CYAN}Niri${NC}                 - Configure config.kdl (Print, Mod+V, Mod+Z, Mod+N)"
echo -e " 3) ${BLUE}Both (Hyprland + Niri)${NC} - Configure both compositors"
echo -e " 4) ${YELLOW}None / Other (COSMIC)${NC}  - Skip all compositor shortcuts & autostart"
echo -e "${BOLD}===================================================================${NC}"

COMP_CHOICE=""
while [[ ! "$COMP_CHOICE" =~ ^[1-4]$ ]]; do
    read -rp "Select option [1-4] (Default: 4): " raw_c
    COMP_CHOICE="${raw_c:-4}"
done

log_info "Applying settings for user: ${BOLD}${TARGET_USER}${NC}"

# -----------------------------------------------------------------------------
# 1. System Identity, Hostname & Locales
# -----------------------------------------------------------------------------
log_info "1/9 Setting hostname, timezone, and locales..."
echo "msi-63" | run_root tee /etc/hostname > /dev/null
run_root tee /etc/hosts > /dev/null << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   msi-63.localdomain msi-63
EOF

run_root ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
run_root hwclock --systohc 2>/dev/null || true
run_root sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
run_root locale-gen > /dev/null
echo "LANG=en_US.UTF-8" | run_root tee /etc/locale.conf > /dev/null

run_root mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" | run_root tee /etc/sudoers.d/10-wheel > /dev/null
run_root chmod 0440 /etc/sudoers.d/10-wheel

# -----------------------------------------------------------------------------
# 2. Kernel Sysctl Hardening & Module Loading
# -----------------------------------------------------------------------------
log_info "2/9 Writing kernel hardening sysctl..."
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
run_root sysctl --system > /dev/null 2>&1 || true

echo "msi-ec" | run_root tee /etc/modules-load.d/msi-ec.conf > /dev/null

# -----------------------------------------------------------------------------
# 3. DNS-over-TLS (systemd-resolved) & NetworkManager
# -----------------------------------------------------------------------------
log_info "3/9 Configuring DNS-over-TLS (AdGuard + Quad9)..."
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

# -----------------------------------------------------------------------------
# 4. Laptop Power (TLP) & MSI GF63 80% Battery Threshold
# -----------------------------------------------------------------------------
log_info "4/9 Configuring TLP profiles & MSI 80% battery cap..."
run_root systemctl mask power-profiles-daemon.service tuned.service tuned-ppd.service 2>/dev/null || true

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

run_root tee /etc/systemd/system/msi-battery-threshold.service > /dev/null << 'EOF'
[Unit]
Description=MSI GF63 Battery Charge Limit (80%)
After=sys-devices-platform-msi\x2dec.device
Wants=sys-devices-platform-msi\x2dec.device

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 80 > /sys/devices/platform/msi-ec/battery_charge_threshold || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
run_root systemctl daemon-reload
run_root systemctl enable msi-battery-threshold.service 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. NVIDIA Power Management & Video Acceleration
# -----------------------------------------------------------------------------
log_info "5/9 Writi
