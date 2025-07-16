#!/bin/bash
set -euo pipefail

# ZFS Restore Script - FIXED VERSION for individually encrypted chunks

# === USAGE ===
if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <provider> <dataset_path> <backup_prefix> <target_dataset>"
    echo ""
    echo "Examples:"
    echo "  $0 backblaze rust_testing test-chunk rust/testing-restored"
    echo "  $0 scaleway rust_containers full-auto-20250716-161605 rust/containers-restored"
    exit 1
fi

PROVIDER="$1"
DATASET_PATH="$2"
BACKUP_PREFIX="$3"
TARGET_DATASET="$4"

# === LOAD CONFIG ===
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# === CONFIG WITH DEFAULTS ===
AGE_PRIVATE_KEY_FILE="${AGE_PRIVATE_KEY_FILE:-$HOME/.config/age/zfs-backup.txt}"
RCLONE_REMOTE="${RCLONE_REMOTE:-cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups}"
SCALEWAY_REMOTE="${SCALEWAY_REMOTE:-scaleway:zfs-buckets-acacia/zfs-backups}"
TEMP_DIR="${TEMP_DIR:-/tmp}"

# === VALIDATION ===
[[ -f "$AGE_PRIVATE_KEY_FILE" ]] || { echo "ERROR: Age private key not found"; exit 1; }
command -v rclone >/dev/null || { echo "ERROR: rclone not installed"; exit 1; }
command -v age >/dev/null || { echo "ERROR: age not installed"; exit 1; }
command -v zfs >/dev/null || { echo "ERROR: zfs not installed"; exit 1; }

# === PROVIDER SELECTION ===
case "$PROVIDER" in
    backblaze|bb)
        SELECTED_REMOTE="$RCLONE_REMOTE"
        PROVIDER_NAME="Backblaze (US)"
        ;;
    scaleway|scw)
        SELECTED_REMOTE="$SCALEWAY_REMOTE"
        PROVIDER_NAME="Scaleway (EU)"
        ;;
    *)
        echo "ERROR: Unknown provider '$PROVIDER'. Use: backblaze, scaleway"
        exit 1
        ;;
esac

echo "=== ZFS Restore (FIXED VERSION) ==="
echo "Provider: $PROVIDER_NAME"
echo "Dataset path: $DATASET_PATH"
echo "Backup prefix: $BACKUP_PREFIX"
echo "Target dataset: $TARGET_DATASET"
echo ""

# === DISCOVER CHUNKS ===
echo "Discovering backup chunks..."
REMOTE_PATH="${SELECTED_REMOTE}/${DATASET_PATH}"

# Look for chunks matching the prefix
CHUNK_FILES=($(rclone lsf "${REMOTE_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-.*\.zfs\.gz\.age$" | sort))

if [[ ${#CHUNK_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No chunks found for backup prefix: ${BACKUP_PREFIX}"
    echo ""
    echo "Available files in ${DATASET_PATH}:"
    rclone lsf "${REMOTE_PATH}/" 2>/dev/null | head -10
    exit 1
fi

echo "Found ${#CHUNK_FILES[@]} chunks: ${CHUNK_FILES[0]} ... ${CHUNK_FILES[-1]}"

# === CONNECTION TEST ===
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${SELECTED_REMOTE%:*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to $PROVIDER_NAME"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

# === TARGET DATASET VALIDATION ===
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

# === RESTORE PROCESS ===
WORK_DIR="${TEMP_DIR}/zfs-restore-$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo ""
echo "Starting restore process..."
echo "Working directory: $WORK_DIR"

# Step 1: Download all chunks
echo "Step 1: Downloading all chunks..."
for chunk_file in "${CHUNK_FILES[@]}"; do
    echo "  Downloading: $chunk_file"
    rclone copy "${REMOTE_PATH}/${chunk_file}" ./
done

# Step 2: Decrypt and decompress chunks
echo "Step 2: Decrypting and decompressing chunks..."
for chunk_file in "${CHUNK_FILES[@]}"; do
    echo "  Processing: $chunk_file"
    base_name=$(basename "$chunk_file" .zfs.gz.age)
    age -d -i "$AGE_PRIVATE_KEY_FILE" "$chunk_file" | gunzip > "${base_name}.restored"
    echo "    ✓ Restored: ${base_name}.restored"
done

# Step 3: Reconstitute stream
echo "Step 3: Reconstituting ZFS stream..."
cat *.restored > complete-stream.zfs
echo "Complete stream size: $(wc -c < complete-stream.zfs) bytes"

# Step 4: ZFS receive
echo "Step 4: Performing ZFS receive..."
zfs recv -F "$TARGET_DATASET" < complete-stream.zfs

# Cleanup
cd /
rm -rf "$WORK_DIR"

echo ""
echo "✅ Restore complete!"
echo ""
echo "Target dataset: $TARGET_DATASET"
echo "Chunks processed: ${#CHUNK_FILES[@]}"
echo "Provider: $PROVIDER_NAME"
echo ""
echo "You can now:"
echo "  - Mount: zfs mount $TARGET_DATASET"
echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET 2>/dev/null || echo 'mount point')"