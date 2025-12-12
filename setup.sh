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

echo "==> Install required packages"
apt update -y
apt install -y git curl iproute2 lm-sensors fail2ban || { echo "apt install failed"; exit 1; }

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
        none) ;;
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

echo "==> Detect firewall (no disabling) and backup"
FW=$(detect_firewall)
echo "Detected: $FW"
backup_firewall "$FW"
BANACTION=$(choose_banaction "$FW")
echo "Selected Fail2Ban banaction: $BANACTION"

echo "==> Write Fail2Ban banaction drop-in"
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/00-serverprofile-banaction.conf <<EOF
[DEFAULT]
banaction = $BANACTION
EOF
chmod 644 /etc/fail2ban/jail.d/00-serverprofile-banaction.conf

echo "==> Clone repo to $CLONE_DIR"
rm -rf "$CLONE_DIR"
git clone --depth=1 "$REPO_URL" "$CLONE_DIR"
if [[ ! -d "$CLONE_DIR" ]]; then
    echo "ERROR: clone failed"; exit 1
fi
trap 'rm -rf "$CLONE_DIR"' EXIT

# locate serverinfo and fail2ban configs in repo
REPO_FAIL2BAN_DIR=""
for d in "$CLONE_DIR/serverinfo-setup/src/fail2ban-configs" "$CLONE_DIR/fail2ban-configs" "$CLONE_DIR/src/fail2ban-configs"; do
    [[ -d "$d" ]] && { REPO_FAIL2BAN_DIR="$d"; break; }
done

REPO_SERVERINFO=""
for p in "$CLONE_DIR/serverinfo.sh" "$CLONE_DIR/serverinfo-setup/src/serverinfo.sh" "$CLONE_DIR/src/serverinfo.sh"; do
    [[ -f "$p" ]] && { REPO_SERVERINFO="$p"; break; }
done
if [[ -z "$REPO_SERVERINFO" ]]; then
    echo "ERROR: serverinfo.sh not found in repo"; exit 1
fi

# === Interactive AbuseIPDB prompt (before deploying configs) ===
ABUSE_ENABLE="no"
ABUSE_APIKEY=""
ABUSE_APPROVED="no"

if [[ -n "$REPO_FAIL2BAN_DIR" && -f "$REPO_FAIL2BAN_DIR/action.d/abuseipdb.py" ]]; then
    read -r -p "Would you like to use AbuseIPDB which require account at https://abuseipdb.com? [y/N]: " resp
    resp=${resp:-N}
    if [[ "$resp" =~ ^[Yy]$ ]]; then
        ABUSE_ENABLE="yes"
        read -r -s -p "Enter AbuseIPDB API key (input hidden): " APIKEY
        echo
        APIKEY=${APIKEY:-}
        if [[ -z "$APIKEY" ]]; then
            echo "No API key provided; AbuseIPDB will remain disabled."
            ABUSE_ENABLE="no"
        else
            ABUSE_APIKEY="$APIKEY"
            read -r -p "Is your AbuseIPDB account approved for reporting AbuseIP? [y/N]: " apr
            apr=${apr:-N}
            if [[ "$apr" =~ ^[Yy]$ ]]; then
                ABUSE_APPROVED="yes"
            else
                ABUSE_APPROVED="no"
            fi
        fi
    fi
else
    echo "No AbuseIPDB action script found in repo; skipping AbuseIPDB prompt."
fi
# === end AbuseIPDB prompt ===

# deploy fail2ban configs if present (copy first, then adjust for AbuseIPDB)
if [[ -n "$REPO_FAIL2BAN_DIR" ]]; then
    echo "==> Deploying fail2ban configs from $REPO_FAIL2BAN_DIR"
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

    # If user enabled AbuseIPDB and provided API key, inject it into deployed action script
    if [[ "$ABUSE_ENABLE" == "yes" && -n "$ABUSE_APIKEY" && -f "/etc/fail2ban/action.d/abuseipdb.py" ]]; then
        dst="/etc/fail2ban/action.d/abuseipdb.py"
        # escape for sed
        esc=$(printf '%s' "$ABUSE_APIKEY" | sed -e 's/[\/&]/\\&/g')
        # replace placeholder $APIKEYS (works whether quoted or not)
        sed -i.bak -E "s/\\\$APIKEYS/${esc}/g" "$dst" || true
        dst="/etc/fail2ban/action.d/abuseipdb.conf"
        sed -i.bak -E "s/\\\$APIKEYS/${esc}/g" "$dst" || true
        chown root:root "$dst"
        chmod 755 "$dst"
        echo "Injected AbuseIPDB API key into $dst (backup: ${dst}.bak)"
    fi

    # If user approved automated reporting, uncomment abuseipdb lines in deployed configs (make backups)
    if [[ "$ABUSE_APPROVED" == "yes" ]]; then
        echo "Enabling AbuseIPDB lines in deployed jail/action configs (backups created with .bak)"
        # uncomment lines mentioning abuseipdb in jail.local and jail.d files
        if [[ -f /etc/fail2ban/jail.local ]]; then
            sed -i.bak -E 's/^[[:space:]]*#[[:space:]]*(.*abuseipdb.*)/\1/' /etc/fail2ban/jail.local || true
        fi
        for jf in /etc/fail2ban/jail.d/*; do
            [[ -f "$jf" ]] && sed -i.bak -E 's/^[[:space:]]*#[[:space:]]*(.*abuseipdb.*)/\1/' "$jf" || true
        done
        # action.d files (mail.conf or others referencing abuseipdb)
        for af in /etc/fail2ban/action.d/*; do
            [[ -f "$af" ]] && grep -qi "abuseipdb" "$af" 2>/dev/null && sed -i.bak -E 's/^[[:space:]]*#[[:space:]]*(.*abuseipdb.*)/\1/' "$af" || true
        done
    fi
else
    echo "==> No fail2ban-configs in repo; skipping deploy"
fi

echo "==> Enable and restart fail2ban (will fail if configs reference missing filters/logs)"
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
exit 0
