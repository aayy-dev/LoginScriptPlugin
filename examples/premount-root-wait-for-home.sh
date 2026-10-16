#!/bin/bash
#
# Example LoginScriptPlugin script: hold the login until the home folder is
# mounted, for Macs where a home folder lives on an external drive that
# /etc/fstab mounts.
#
# LoginScriptPlugin runs this as root on every login, automatic login
# included, right before macOS sets up the home folder. Arguments:
#   $1 = UID, $2 = GID, $3 = home folder, e.g. /Users/alice
#
# * If no /etc/fstab entry mounts the home folder (or a folder above it),
#   the home is on the internal disk and the login goes ahead right away.
# * Otherwise, wait up to TIMEOUT seconds for that drive to be mounted.
# * If it never shows up, refuse the login (exit 77). Letting it go ahead
#   would make macOS create a new, empty home folder on the internal disk.
#
# Write mount points in /etc/fstab without symbolic links (for example
# /private/tmp, not /tmp), because mount(8) reports the resolved path.
#
# Install as root:wheel, mode 755, in
# /Library/Application Support/LoginScriptPlugin/. Each run is logged to LOG.


declare -r FSTAB="/etc/fstab"
declare -r LOG="/var/log/wait-for-home.log"
declare -ri TIMEOUT=90
declare -ri EX_NOPERM=77

home="$3"


function log() {
    echo "$(/bin/date '+%F %T') $*" >> "$LOG"
}

# Find the longest fstab mount point that is the home folder or a folder
# above it. fstab writes spaces in paths as \040.
mount_point=$(/usr/bin/awk -v home="$home" '
    /^[[:space:]]*#/ || NF < 2 { next }
    {
        mp = $2
        gsub(/\\040/, " ", mp)
        if ((home == mp || index(home, mp "/") == 1) && length(mp) > length(best)) {
            best = mp
        }
    }
    END { print best }' "$FSTAB" 2>/dev/null)

if [[ -z "$mount_point" ]]; then
    exit 0
fi

for (( i = 1; i <= TIMEOUT; i++ )); do
    if /sbin/mount | /usr/bin/grep -qF " on $mount_point ("; then
        log "$mount_point mounted (check $i)"
        exit 0
    fi
    /bin/sleep 1
done

log "$mount_point not mounted after ${TIMEOUT}s, refused login for $home"
exit $EX_NOPERM
