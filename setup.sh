#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/jodhpurlaxman/server-profile.git"
CLONE_DIR="/tmp/server-profile-$$"
BACKUP_DIR="/root/firewall-backups"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo bash "$0" "$@"
    fi
}
require_root

echo "==> apt update && install required packages"
apt update -y
apt install -y git curl iproute2 lm-sensors fail2ban || { echo "apt install failed"; exit 1; }

# Optional helpers for actions/backups (do not remove existing firewalls)
apt install -y iptables-persistent nftables ufw firewalld --no-install-recommends || true

detect_firewall() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command -v ufw >/dev/null 2>&1 && ufw status | grep -qi "Status: active"; then
        echo "ufw"
    elif systemctl is-active --quiet nftables 2>/dev/null || (command -v nft >/dev/null 2>&1 && nft list ruleset &>/dev/null); then
        echo "nftables"
    elif command -v iptables-save >/dev/null 2>&1 && iptables-save | grep -q -- '-A'; then
        echo "iptables"
    else
        echo "none"
    fi
}

backup_firewall() {
    local fw="$1"
    mkdir -p "$BACKUP_DIR"
    case "$fw" in
        firewalld)
            firewall-cmd --state &>/dev/null || true
            firewall-cmd --list-all --zone=public > "$BACKUP_DIR/firewalld-zone-public.backup" 2>/dev/null || true
            ;;
        ufw)
            command -v ufw >/dev/null 2>&1 && ufw status verbose > "$BACKUP_DIR/ufw-status.backup" 2>/dev/null || true
            ;;
        nftables)
            command -v nft >/dev/null 2>&1 && nft list ruleset > "$BACKUP_DIR/nftables.ruleset.backup" 2>/dev/null || true
            ;;
        iptables)
            command -v iptables-save >/dev/null 2>&1 && iptables-save > "$BACKUP_DIR/iptables.backup" 2>/dev/null || true
            ;;
    esac
}

choose_banaction() {
    case "$1" in
        firewalld) echo "firewallcmd-ipset" ;;
        ufw)       echo "ufw" ;;
        nftables)  echo "nftables" ;;
        iptables)  echo "iptables-multiport" ;;
        *)         echo "iptables-multiport" ;;
    esac
}

echo "==> Detecting and backing up firewall (no disabling)"
FW=$(detect_firewall)
echo "Detected firewall: $FW"
backup_firewall "$FW"
BANACTION=$(choose_banaction "$FW")
echo "Using Fail2Ban banaction: $BANACTION"

echo "==> Writing Fail2Ban drop-in for banaction"
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/00-serverprofile-banaction.conf <<EOF
[DEFAULT]
banaction = $BANACTION
EOF
chmod 644 /etc/fail2ban/jail.d/00-serverprofile-banaction.conf

# clone repo
echo "==> Cloning repo to $CLONE_DIR"
rm -rf "$CLONE_DIR"
git clone --depth=1 "$REPO_URL" "$CLONE_DIR"

if [[ ! -d "$CLONE_DIR" ]]; then
    echo "ERROR: clone failed"
    exit 1
fi

trap 'rm -rf "$CLONE_DIR"' EXIT

# locate serverinfo.sh
CANDIDATES=(
    "$CLONE_DIR/serverinfo.sh"
    "$CLONE_DIR/serverinfo-setup/src/serverinfo.sh"
    "$CLONE_DIR/serverinfo-setup/serverinfo.sh"
    "$CLONE_DIR/src/serverinfo.sh"
)
REPO_SERVERINFO=""
for p in "${CANDIDATES[@]}"; do
    [[ -f "$p" ]] && { REPO_SERVERINFO="$p"; break; }
done
if [[ -z "$REPO_SERVERINFO" ]]; then
    echo "ERROR: serverinfo.sh not found in repo"
    exit 1
fi

# deploy fail2ban configs if present
REPO_FAIL2BAN_DIR=""
for d in "$CLONE_DIR/serverinfo-setup/src/fail2ban-configs" "$CLONE_DIR/fail2ban-configs" "$CLONE_DIR/src/fail2ban-configs"; do
    [[ -d "$d" ]] && { REPO_FAIL2BAN_DIR="$d"; break; }
done

if [[ -n "$REPO_FAIL2BAN_DIR" ]]; then
    echo "==> Copying fail2ban configs from $REPO_FAIL2BAN_DIR"
    mkdir -p /etc/fail2ban
    [[ -f "$REPO_FAIL2BAN_DIR/jail.local" ]] && cp -a "$REPO_FAIL2BAN_DIR/jail.local" /etc/fail2ban/jail.local && chmod 644 /etc/fail2ban/jail.local
    for sub in filter.d action.d jail.d; do
        if [[ -d "$REPO_FAIL2BAN_DIR/$sub" ]]; then
            mkdir -p "/etc/fail2ban/$sub"
            cp -a "$REPO_FAIL2BAN_DIR/$sub/"* "/etc/fail2ban/$sub/" 2>/dev/null || true
            chown -R root:root "/etc/fail2ban/$sub"
            if [[ "$sub" == "action.d" ]]; then
                find "/etc/fail2ban/$sub" -type f -name "*.py" -exec chmod 755 {} \; || true
            else
                find "/etc/fail2ban/$sub" -type f -exec chmod 644 {} \; || true
            fi
        fi
    done
else
    echo "==> No fail2ban-configs in repo, skipping"
fi

echo "==> Enable and restart fail2ban"
systemctl enable --now fail2ban || true
systemctl restart fail2ban || true

command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status || true

echo "==> Install serverinfo script and symlink"
mkdir -p /etc/profile.d
cp -a "$REPO_SERVERINFO" /etc/profile.d/serverinfo.sh
chown root:root /etc/profile.d/serverinfo.sh
chmod 755 /etc/profile.d/serverinfo.sh
ln -sf /etc/profile.d/serverinfo.sh /usr/bin/sinfo
chmod +x /usr/bin/sinfo

echo "==> Test run (non-fatal)"
bash /etc/profile.d/serverinfo.sh || true

echo "Done. Backups (if any): $BACKUP_DIR"