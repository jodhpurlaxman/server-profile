#!/bin/bash
# Skip if not interactive
#[[ $- != *i* ]] && return

IP=$(curl -s ifconfig.me)
TIME1=$(date -I)
TIME2=$(date +%H:%M:%S)

RAM=$(free -m | awk 'NR==2{printf "%s/%sMB (%.2f%%)", $3,$2,$3*100/$2 }')
LOAD=$(uptime | awk -F'[a-z]:' '{ print $2 }')
DISK=$(df -h | awk '$NF=="/"{printf "%d/%dGB (%s)", $3,$2,$5}')
CPU=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage "%"}')
UPTIME=$(uptime | awk -F'( |,|:)+' '{if ($7=="min") m=$6; else {if ($7~/^day/) {d=$6;h=$8;m=$9} else {h=$6;m=$7}}} {print d+0 " days, " h+0 " hours, " m+0 " minutes."}')

# Inode usage
INODE=$(df -i / | sed -n '2s/.* \([0-9]\+%\).*/\1/p')

# Swap
SWAP=$(free -m | awk '/Swap/ {printf "%s/%sMB (%.2f%%)", $3,$2,$3*100/$2}')

# Network connections
NETCON=$(ss -tn state established | awk 'NR>1{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr)

echo ""
echo "==================== Server Stats ===================="
echo "Server IP            : $IP"
echo "Date & Time          : $TIME1 $TIME2"
echo "Load Average         : $LOAD"
echo "CPU Usage            : $CPU"
echo "RAM Usage            : $RAM"
echo "Disk Usage (/ )      : $DISK"
echo "Disk INodes Usage    : $INODE"
echo "Swap Usage           : $SWAP"
echo "System Uptime        : $UPTIME"
echo "Active Connections   : $NETCON"
echo ""

# CPU temperature
if command -v sensors >/dev/null 2>&1; then
    TEMP=$(sensors | grep -E 'Package id 0|Tdie|Tctl' | head -1 | awk '{print $4}')
    echo "CPU Temperature      : $TEMP"
fi

echo ""
# All jails you want to monitor
JAILS=(
    apache-403
    apache-404
    cp-404
    pure-ftpd
    sshd
    postfix-sasl
    postfix
    dovecot
    postfix-rbl
)

echo "===== Fail2Ban Banned IP Report ====="

for jail in "${JAILS[@]}"; do
    if fail2ban-client status "$jail" &>/dev/null; then
        
        BANNED=$(fail2ban-client status "$jail" \
            | awk -F':[ \t]+' '/Banned IP list/{print $2}')

        echo "$jail banned IP(s): $BANNED"
    else
        echo "$jail: jail not found or not enabled"
    fi
done
echo ""
echo "==================== Essential Services ==============="
for svc in lscpd lsws mysql mariadb redis-server postfix dovecot; do
    if systemctl is-active --quiet $svc 2>/dev/null; then
        echo " $svc ✔ running"
    else
        echo " $svc ✘ stopped"
    fi
done

echo "======================================================="
echo ""

echo "Enjoy your accelerated web hosting!"
echo ""

# ln -s /etc/profile.d/serverinfo.sh /usr/bin/sinfo