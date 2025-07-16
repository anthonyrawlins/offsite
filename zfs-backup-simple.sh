#!/bin/bash
set -euo pipefail

# Simple ZFS Dataset Backup - No fancy logging, just working backup

DATASET="$1"
PROVIDER="${2:-backblaze}"

# Load config
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Config
RCLONE_REMOTE_BB="${RCLONE_REMOTE:-cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups}"
SCALEWAY_REMOTE="${SCALEWAY_REMOTE:-scaleway:zfs-buckets-acacia/zfs-backups}"
AGE_PUBLIC_KEY_FILE="${AGE_PUBLIC_KEY_FILE:-$HOME/.config/age/zfs-backup.pub}"
SNAP_PREFIX="${ZFS_SNAP_PREFIX:-auto}"

# Validation
if ! zfs list "$DATASET" >/dev/null 2>&1; then
    echo "ERROR: Dataset '$DATASET' not found"
    exit 1
fi

if [[ ! -f "$AGE_PUBLIC_KEY_FILE" ]]; then
    echo "ERROR: Age public key not found"
    exit 1
fi

echo "Starting backup of $DATASET to $PROVIDER..."

# Create snapshot
snapname="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
echo "Creating snapshot: ${DATASET}@${snapname}"
zfs snapshot "${DATASET}@${snapname}"

# Determine backup type
dataset_path="${DATASET//\//_}"
prev_snap=$(zfs list -H -t snapshot -o name -s creation | grep "^${DATASET}@${SNAP_PREFIX}-" | grep -v "@${snapname}$" | tail -n1 | awk -F@ '{print $2}' || true)

if [[ -n "$prev_snap" ]]; then
    echo "Incremental backup from $prev_snap"
    backup_prefix="incr-${snapname}"
    zfs send -I "${DATASET}@${prev_snap}" "${DATASET}@${snapname}" | \
        gzip | age -r "$(cat "$AGE_PUBLIC_KEY_FILE")" | \
        split -b 1G --numeric-suffixes=1 --suffix-length=3 \
        --filter='rclone rcat "'"${RCLONE_REMOTE_BB}/${dataset_path}/${backup_prefix}"'-$FILE.zfs.gz.age" && echo "Chunk $FILE uploaded"' -
else
    echo "Full backup (no previous snapshots)"
    backup_prefix="full-${snapname}"
    zfs send "${DATASET}@${snapname}" | \
        gzip | age -r "$(cat "$AGE_PUBLIC_KEY_FILE")" | \
        split -b 1G --numeric-suffixes=1 --suffix-length=3 \
        --filter='rclone rcat "'"${RCLONE_REMOTE_BB}/${dataset_path}/${backup_prefix}"'-$FILE.zfs.gz.age" && echo "Chunk $FILE uploaded"' -
fi

echo "Backup complete!"
echo "Uploaded to: ${RCLONE_REMOTE_BB}/${dataset_path}/"