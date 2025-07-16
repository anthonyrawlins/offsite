#!/bin/bash
set -euo pipefail

# ZFS Cloud Restore Script with Environment Variable Support

# === LOAD CONFIG ===
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "WARNING: Config file not found at $CONFIG_FILE"
    echo "Using default values or environment variables"
fi

# === CONFIG WITH DEFAULTS ===
AGE_PRIVATE_KEY_FILE="${AGE_PRIVATE_KEY_FILE:-$HOME/.config/age/zfs-backup.txt}"
RCLONE_REMOTE="${RCLONE_REMOTE:-cloudremote:zfs-backups}"
TEMP_DIR="${TEMP_DIR:-/tmp}"

# === USAGE ===
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <dataset_path> <backup_file> <target_dataset>"
    echo ""
    echo "Arguments:"
    echo "  dataset_path   - Remote path (e.g., rust_containers)"
    echo "  backup_file    - Backup filename (e.g., full-20250715-000001.zfs.gz.age)"
    echo "  target_dataset - Local ZFS dataset to restore to (e.g., rust/containers-restored)"
    echo ""
    echo "Example:"
    echo "  $0 rust_containers full-20250715-000001.zfs.gz.age rust/containers-restored"
    echo ""
    echo "Configuration:"
    echo "  Remote: $RCLONE_REMOTE"
    echo "  Private key: $AGE_PRIVATE_KEY_FILE"
    echo "  Temp dir: $TEMP_DIR"
    echo ""
    echo "To list available backups:"
    echo "  rclone ls $RCLONE_REMOTE/<dataset_path>/"
    exit 1
fi

# === INPUTS ===
DATASET_PATH="$1"
BACKUP_FILE="$2"
TARGET_DATASET="$3"

# === VALIDATION ===
if [[ ! -f "$AGE_PRIVATE_KEY_FILE" ]]; then
    echo "ERROR: Age private key not found at $AGE_PRIVATE_KEY_FILE"
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

if ! command -v zfs >/dev/null 2>&1; then
    echo "ERROR: zfs not installed"
    exit 1
fi

# Test rclone connection
if ! rclone lsd "${RCLONE_REMOTE%:*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to rclone remote ${RCLONE_REMOTE%:*}"
    exit 1
fi

# === VARIABLES ===
REMOTE_FILE_PATH="${RCLONE_REMOTE}/${DATASET_PATH}/${BACKUP_FILE}"
TMPFILE="${TEMP_DIR}/restore-$(date +%s).zfs.gz.age"

# === VALIDATION ===
echo "=== ZFS Cloud Restore ==="
echo "Remote file: $REMOTE_FILE_PATH"
echo "Target dataset: $TARGET_DATASET"
echo "Temp file: $TMPFILE"
echo ""

# Check if remote file exists
if ! rclone lsf "${RCLONE_REMOTE}/${DATASET_PATH}/" | grep -q "^${BACKUP_FILE}$"; then
    echo "ERROR: Backup file not found: ${BACKUP_FILE}"
    echo ""
    echo "Available backups in ${DATASET_PATH}:"
    rclone lsf "${RCLONE_REMOTE}/${DATASET_PATH}/" | grep -E '^(full|incr)-.*\.zfs\.gz\.age$' | sort
    exit 1
fi

# Check if target dataset already exists
if zfs list "$TARGET_DATASET" >/dev/null 2>&1; then
    echo "WARNING: Target dataset $TARGET_DATASET already exists"
    read -p "Do you want to destroy and recreate it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Restore cancelled"
        exit 1
    fi
    echo "Destroying existing dataset..."
    zfs destroy -r "$TARGET_DATASET"
fi

# === RESTORE ===
echo "[1/4] Downloading backup file..."
rclone copy "$REMOTE_FILE_PATH" "$TMPFILE" --progress

echo "[2/4] Verifying download..."
if [[ ! -f "$TMPFILE" ]]; then
    echo "ERROR: Download failed"
    exit 1
fi

echo "[3/4] Decrypting and restoring to $TARGET_DATASET..."
age -d -i "$AGE_PRIVATE_KEY_FILE" "$TMPFILE" | gunzip | zfs recv -F "$TARGET_DATASET"

echo "[4/4] Cleaning up..."
rm "$TMPFILE"

echo ""
echo "✓ Restore complete!"
echo ""
echo "Restored dataset: $TARGET_DATASET"
echo "You can now:"
echo "  - Mount: zfs mount $TARGET_DATASET"
echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET)"