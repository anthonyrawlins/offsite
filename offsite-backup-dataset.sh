#!/bin/bash
set -euo pipefail

# Offsite Backup - Single Dataset
# Creates ZFS snapshots and uploads encrypted chunks to cloud storage

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
TEMP_DIR="${TEMP_DIR:-/tmp}"

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

# Test rclone connection
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${RCLONE_REMOTE%:*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to rclone remote ${RCLONE_REMOTE%:*}"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

# === LOGGING ===
DATASET_LOG_FILE="$HOME/offsite-backup-$(echo "$DATASET" | tr '/' '_')-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$DATASET_LOG_FILE") 2>&1

echo "$(date '+%Y-%m-%d %H:%M:%S') === Offsite Backup Started ==="
echo "$(date '+%Y-%m-%d %H:%M:%S') Dataset: $DATASET"
echo "$(date '+%Y-%m-%d %H:%M:%S') Provider: $PROVIDER_NAME"
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

backup_dataset() {
    local dataset="$1"
    local snap="$2"
    local dataset_path="${dataset//\//_}"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') [+] Backing up ${dataset}@${snap}"

    # Detect previous snapshot for incremental backup
    local prev_snap=$(zfs list -H -t snapshot -o name -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | grep -v "@${snap}$" | tail -n1 | awk -F@ '{print $2}' || true)

    # Create working directory
    local work_dir="${TEMP_DIR}/offsite-backup-$(date +%s)"
    mkdir -p "$work_dir"
    cd "$work_dir"

    # Get trimmed age public key (remove newlines)
    local agekey=$(cat "$AGE_PUBLIC_KEY_FILE" | tr -d '\n')

    if [[ -n "$prev_snap" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Incremental backup from $prev_snap"
        local prefix="incr"
        local backup_prefix="${prefix}-${snap}"
        
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Creating incremental stream..."
        zfs send -I "${dataset}@${prev_snap}" "${dataset}@${snap}" > stream.zfs
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Full backup"
        local prefix="full"
        local backup_prefix="${prefix}-${snap}"
        
        echo "$(date '+%Y-%m-%d %H:%M:%S')     Creating full stream..."
        zfs send "${dataset}@${snap}" > stream.zfs
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Stream created: $(ls -la stream.zfs | awk '{print $5}') bytes"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Splitting into 1GB chunks..."
    split -b 1G stream.zfs chunk- --numeric-suffixes=1 --suffix-length=3
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Chunks created: $(ls -la chunk-* | wc -l)"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Compressing, encrypting and uploading chunks..."
    for chunk in chunk-*; do
        echo "$(date '+%Y-%m-%d %H:%M:%S')       Processing $chunk..."
        gzip < "$chunk" | age -r "$agekey" > "${backup_prefix}-x${chunk#chunk-}.zfs.gz.age"
        rclone copy "${backup_prefix}-x${chunk#chunk-}.zfs.gz.age" "${RCLONE_REMOTE}/${dataset_path}/"
        echo "$(date '+%Y-%m-%d %H:%M:%S')         ✓ Uploaded ${backup_prefix}-x${chunk#chunk-}.zfs.gz.age ($(ls -la ${backup_prefix}-x${chunk#chunk-}.zfs.gz.age | awk '{print $5}') bytes)"
    done
    
    # Cleanup
    cd /
    rm -rf "$work_dir"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     ✓ Backup complete to $PROVIDER_NAME"
}

cleanup_old_snapshots() {
    local dataset="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [+] Cleaning up old snapshots for $dataset"
    
    zfs list -H -t snapshot -o name,creation -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | while read snap creation; do
        local snap_time=$(echo "$snap" | awk -F@ '{print $2}' | sed 's/.*-//')
        local snap_date=$(date -d "${snap_time:0:8} ${snap_time:8:2}:${snap_time:10:2}:${snap_time:12:2}" +%s 2>/dev/null || continue)
        local now=$(date +%s)
        local age_days=$(( (now - snap_date) / 86400 ))
        
        if (( age_days > RETENTION_DAYS )); then
            echo "$(date '+%Y-%m-%d %H:%M:%S')     Destroying old snapshot $snap (${age_days} days old)"
            zfs destroy "$snap"
        fi
    done
}

# === MAIN ===
BACKUP_START=$(date +%s)

snapname=$(make_snapshot "$DATASET")
backup_dataset "$DATASET" "$snapname"
cleanup_old_snapshots "$DATASET"

BACKUP_END=$(date +%s)
TOTAL_TIME=$((BACKUP_END - BACKUP_START))

echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "$(date '+%Y-%m-%d %H:%M:%S') === Offsite Backup Completed ==="
echo "$(date '+%Y-%m-%d %H:%M:%S') Dataset: $DATASET"
echo "$(date '+%Y-%m-%d %H:%M:%S') Provider: $PROVIDER_NAME"
echo "$(date '+%Y-%m-%d %H:%M:%S') Total time: ${TOTAL_TIME}s ($(($TOTAL_TIME / 60))m $(($TOTAL_TIME % 60))s)"
echo "$(date '+%Y-%m-%d %H:%M:%S') Log saved to: $DATASET_LOG_FILE"