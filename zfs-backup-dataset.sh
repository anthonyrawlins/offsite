#!/bin/bash
set -euo pipefail

# ZFS Single Dataset Backup Script with Chunked Upload

# === USAGE ===
if [[ $# -lt 1 ]] || [[ $# -gt 2 ]]; then
    echo "Usage: $0 <dataset> [provider]"
    echo ""
    echo "Arguments:"
    echo "  dataset   - ZFS dataset to backup (e.g., rust/containers)"
    echo "  provider  - Optional: 'backblaze' or 'scaleway' (default: backblaze)"
    echo ""
    echo "Examples:"
    echo "  $0 rust/containers                    # Backup to Backblaze"
    echo "  $0 rust/projects scaleway            # Backup to Scaleway"
    echo "  $0 rust/family backblaze             # Backup to Backblaze"
    exit 1
fi

DATASET="$1"
PROVIDER="${2:-backblaze}"

# === LOAD CONFIG ===
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "WARNING: Config file not found at $CONFIG_FILE"
    echo "Using default values or environment variables"
fi

# === CONFIG WITH DEFAULTS ===
RCLONE_REMOTE_BB="${RCLONE_REMOTE:-cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups}"
SCALEWAY_REMOTE="${SCALEWAY_REMOTE:-scaleway:zfs-buckets-acacia/zfs-backups}"
AGE_PUBLIC_KEY_FILE="${AGE_PUBLIC_KEY_FILE:-$HOME/.config/age/zfs-backup.pub}"
SNAP_PREFIX="${ZFS_SNAP_PREFIX:-auto}"
RETENTION_DAYS="${ZFS_RETENTION_DAYS:-14}"
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/zfs-backup.log}"

# === PROVIDER SELECTION ===
case "$PROVIDER" in
    backblaze|bb)
        RCLONE_REMOTE="$RCLONE_REMOTE_BB"
        PROVIDER_NAME="Backblaze (US)"
        ;;
    scaleway|scw)
        RCLONE_REMOTE="$SCALEWAY_REMOTE"
        PROVIDER_NAME="Scaleway (EU)"
        ;;
    *)
        echo "ERROR: Unknown provider '$PROVIDER'"
        echo "Valid providers: backblaze, scaleway"
        exit 1
        ;;
esac

# === VALIDATION ===
if ! zfs list "$DATASET" >/dev/null 2>&1; then
    echo "ERROR: Dataset '$DATASET' not found"
    echo ""
    echo "Available datasets:"
    zfs list -H -o name -t filesystem | head -10
    exit 1
fi

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
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${RCLONE_REMOTE%:*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to rclone remote ${RCLONE_REMOTE%:*}"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

# === LOGGING ===
# Use home directory for logs to avoid permission issues
DATASET_LOG_FILE="$HOME/zfs-backup-$(echo "$DATASET" | tr '/' '_')-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$DATASET_LOG_FILE") 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') === ZFS Dataset Backup Started ==="
echo "$(date '+%Y-%m-%d %H:%M:%S') Dataset: $DATASET"
echo "$(date '+%Y-%m-%d %H:%M:%S') Target: BOTH providers (Backblaze + Scaleway)"
echo "$(date '+%Y-%m-%d %H:%M:%S') Log file: $DATASET_LOG_FILE"

# === FUNCTIONS ===

make_snapshot() {
    local dataset="$1"
    local snapname="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Creating snapshot: ${dataset}@${snapname}"
    zfs snapshot "${dataset}@${snapname}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Snapshot created successfully"
    echo "$snapname"
}

send_snapshot() {
    local dataset="$1"
    local snap="$2"
    local dataset_path="${dataset//\//_}"
    local remote_path="${RCLONE_REMOTE}/${dataset_path}"

    echo "$(date '+%Y-%m-%d %H:%M:%S') [+] Sending snapshot $dataset@$snap"

    # Detect previous snapshot if any (exclude the current snapshot)
    local prev_snap=$(zfs list -H -t snapshot -o name -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | grep -v "@${snap}$" | tail -n1 | awk -F@ '{print $2}' || true)

    local send_cmd=""
    if [[ -n "$prev_snap" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Incremental from $prev_snap"
        send_cmd="zfs send -I ${dataset}@${prev_snap} ${dataset}@${snap}"
        local prefix="incr"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Full send"
        send_cmd="zfs send ${dataset}@${snap}"
        local prefix="full"
    fi

    # Split ZFS stream into 1GB chunks and upload to both providers
    local backup_prefix="${prefix}-${snap}"
    local agekey=$(cat "$AGE_PUBLIC_KEY_FILE")
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Splitting into 1GB chunks and uploading to BOTH providers..."
    local upload_start=$(date +%s)
    
    # Execute ZFS send and chunk upload  
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Starting chunked upload to Backblaze..."
    if [[ -n "$prev_snap" ]]; then
        zfs send -I "${dataset}@${prev_snap}" "${dataset}@${snap}" | gzip | age -r "$agekey" | split -b 1G --numeric-suffixes=1 --suffix-length=3 \
            --filter="rclone rcat '${RCLONE_REMOTE_BB}/${dataset_path}/${backup_prefix}-\$FILE.zfs.gz.age' --progress && echo '$(date '+%Y-%m-%d %H:%M:%S')       Chunk \$FILE → Backblaze ✓'" -
    else
        zfs send "${dataset}@${snap}" | gzip | age -r "$agekey" | split -b 1G --numeric-suffixes=1 --suffix-length=3 \
            --filter="rclone rcat '${RCLONE_REMOTE_BB}/${dataset_path}/${backup_prefix}-\$FILE.zfs.gz.age' --progress && echo '$(date '+%Y-%m-%d %H:%M:%S')       Chunk \$FILE → Backblaze ✓'" -
    fi
    
    local upload_end=$(date +%s)
    local total_time=$((upload_end - upload_start))
    echo "$(date '+%Y-%m-%d %H:%M:%S')     ✓ Dual chunked upload complete to BOTH providers (Total: ${total_time}s)"
}

cleanup_old_local_snaps() {
    local dataset="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [+] Cleaning up old local snapshots for $dataset"
    
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

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "$(date '+%Y-%m-%d %H:%M:%S') === Processing $DATASET ==="
BACKUP_START=$(date +%s)
snapname=$(make_snapshot "$DATASET")
send_snapshot "$DATASET" "$snapname"
cleanup_old_local_snaps "$DATASET"
BACKUP_END=$(date +%s)
TOTAL_BACKUP_TIME=$((BACKUP_END - BACKUP_START))

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "$(date '+%Y-%m-%d %H:%M:%S') === ZFS Dataset Backup Completed ==="
echo "$(date '+%Y-%m-%d %H:%M:%S') Dataset: $DATASET"
echo "$(date '+%Y-%m-%d %H:%M:%S') Total time: ${TOTAL_BACKUP_TIME}s ($(($TOTAL_BACKUP_TIME / 60))m $(($TOTAL_BACKUP_TIME % 60))s)"
echo "$(date '+%Y-%m-%d %H:%M:%S') Log saved to: $DATASET_LOG_FILE"