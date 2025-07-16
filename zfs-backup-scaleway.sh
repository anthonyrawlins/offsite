#!/bin/bash
set -euo pipefail

# ZFS Cloud Backup Script - Scaleway Only
# Modified version for alternating backup schedule

# === LOAD CONFIG ===
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "WARNING: Config file not found at $CONFIG_FILE"
    echo "Using default values or environment variables"
fi

# === CONFIG WITH DEFAULTS ===
POOL="${ZFS_POOL:-rust}"
RCLONE_REMOTE="${SCALEWAY_REMOTE:-scaleway:zfs-buckets-acacia/zfs-backups}"
AGE_PUBLIC_KEY_FILE="${AGE_PUBLIC_KEY_FILE:-$HOME/.config/age/zfs-backup.pub}"
SNAP_PREFIX="${ZFS_SNAP_PREFIX:-auto}"
RETENTION_DAYS="${ZFS_RETENTION_DAYS:-14}"
TEMP_DIR="${TEMP_DIR:-/tmp}"
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/zfs-backup.log}"

# === VALIDATION ===
if [[ ! -f "$AGE_PUBLIC_KEY_FILE" ]]; then
    echo "ERROR: Age public key not found at $AGE_PUBLIC_KEY_FILE"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone not installed"
    exit 1
fi

if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age not installed"
    exit 1
fi

# Test rclone connection
if ! rclone lsd "${RCLONE_REMOTE%:*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to rclone remote ${RCLONE_REMOTE%:*}"
    exit 1
fi

# === LOGGING ===
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== ZFS Backup Started (Scaleway): $(date) ==="

# === FUNCTIONS ===

make_snapshot() {
    local dataset="$1"
    local snapname="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    zfs snapshot "${dataset}@${snapname}"
    echo "$snapname"
}

send_snapshot() {
    local dataset="$1"
    local snap="$2"
    local dataset_path="${dataset//\//_}"
    local remote_path="${RCLONE_REMOTE}/${dataset_path}"

    echo "[+] Sending snapshot $dataset@$snap"

    # Detect previous snapshot if any
    local prev_snap=$(zfs list -H -t snapshot -o name -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | grep -B1 "$snap" | head -n1 | awk -F@ '{print $2}' || true)

    local send_cmd=""
    if [[ -n "$prev_snap" && "$prev_snap" != "$snap" ]]; then
        echo "    Incremental from $prev_snap"
        send_cmd="zfs send -I @${prev_snap} ${dataset}@${snap}"
        local prefix="incr"
    else
        echo "    Full send"
        send_cmd="zfs send ${dataset}@${snap}"
        local prefix="full"
    fi

    # Split ZFS stream into 1GB chunks and upload
    local backup_prefix="${prefix}-${snap}"
    local agekey=$(cat "$AGE_PUBLIC_KEY_FILE")
    
    echo "    Splitting into 1GB chunks and uploading to ${remote_path}/"
    eval "$send_cmd" | split -b 1G --numeric-suffixes=1 --suffix-length=3 \
        --filter="gzip | age -r '$agekey' | rclone rcat '${remote_path}/${backup_prefix}-\$FILE.zfs.gz.age' --progress && echo '      Chunk \$FILE uploaded'" -
    
    echo "    Chunked upload complete"
}

cleanup_old_local_snaps() {
    local dataset="$1"
    echo "[+] Cleaning up old local snapshots for $dataset"
    
    zfs list -H -t snapshot -o name,creation -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | while read snap creation; do
        local snap_time=$(echo "$snap" | awk -F@ '{print $2}' | sed 's/.*-//')
        local snap_date=$(date -d "${snap_time:0:8} ${snap_time:8:2}:${snap_time:10:2}:${snap_time:12:2}" +%s 2>/dev/null || continue)
        local now=$(date +%s)
        local age_days=$(( (now - snap_date) / 86400 ))
        
        if (( age_days > RETENTION_DAYS )); then
            echo "    Destroying old snapshot $snap (${age_days} days old)"
            zfs destroy "$snap"
        fi
    done
}

# === MAIN ===

echo "Configuration:"
echo "  Pool: $POOL"
echo "  Remote: $RCLONE_REMOTE (Scaleway)"
echo "  Retention: $RETENTION_DAYS days"
echo "  Age key: $AGE_PUBLIC_KEY_FILE"
echo ""

zfs list -H -o name -t filesystem -r "$POOL" | while read dataset; do
    echo "=== Processing $dataset ==="
    snapname=$(make_snapshot "$dataset")
    send_snapshot "$dataset" "$snapname"
    cleanup_old_local_snaps "$dataset"
    echo ""
done

echo "=== ZFS Backup Completed (Scaleway): $(date) ==="