#!/bin/bash
set -euo pipefail

# Cleanup script to remove all test shards from cloud storage
# Useful for testing the offsite backup system with a clean slate

echo "=== Offsite Test Cleanup Script ==="
echo ""

# Load configuration
CONFIG_FILE="$HOME/.config/offsite/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Run setup.sh first to create the configuration."
    exit 1
fi

echo "Loading configuration from: $CONFIG_FILE"
source "$CONFIG_FILE"

# Check required variables
if [[ -z "${B2_KEY_ID:-}" ]] || [[ -z "${B2_APPLICATION_KEY:-}" ]] || [[ -z "${B2_BUCKET_NAME:-}" ]]; then
    echo "ERROR: Missing Backblaze B2 configuration in $CONFIG_FILE"
    echo "Required: B2_KEY_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME"
    exit 1
fi

# Test dataset and backup prefix
TEST_DATASET="rust/test"
BACKUP_PREFIX="rust_test:now"
DATASET_PATH="rust_test"

echo "Target dataset: $TEST_DATASET"
echo "Backup prefix: $BACKUP_PREFIX"
echo "Dataset path: $DATASET_PATH"
echo ""

# Use existing rclone configs instead of creating temporary ones
# Extract bucket info from existing config
B2_REMOTE_PATH="cloudremote:${B2_BUCKET_NAME}/zfs-backups"

# Configure Scaleway (if available)
if [[ -n "${SCALEWAY_REMOTE:-}" ]]; then
    # SCALEWAY_REMOTE format: "scaleway:bucket/path"
    SCW_BUCKET_NAME=$(echo "$SCALEWAY_REMOTE" | sed 's/scaleway:\([^/]*\).*/\1/')
    SCW_REMOTE_PATH="scaleway:${SCW_BUCKET_NAME}/zfs-backups"
    
    SCALEWAY_AVAILABLE=true
    echo "  ✓ Scaleway: $SCW_BUCKET_NAME"
else
    echo "Note: Scaleway configuration not found, will only clean Backblaze"
    SCALEWAY_AVAILABLE=false
fi

echo "Available providers:"
echo "  ✓ Backblaze B2: $B2_BUCKET_NAME"
# Note: Scaleway status already printed above
echo ""

# Function to list and delete shards from a provider
cleanup_provider() {
    local provider_name="$1"
    local rclone_remote="$2"
    local bucket_path="$3"
    
    echo "[Cleaning $provider_name]"
    
    # List existing files with both old and new naming patterns
    echo "  Listing existing files..."
    echo "  DEBUG: Checking path: ${rclone_remote}:${bucket_path}/${DATASET_PATH}/"
    
    # Old pattern: prefix-s###.zfs.gz.age
    local old_files=$(rclone lsf "${rclone_remote}:${bucket_path}/${DATASET_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-s[0-9][0-9][0-9].zfs.gz.age$" || true)
    
    # New pattern: prefix-s###-b##########.zfs.gz.age  
    local new_files=$(rclone lsf "${rclone_remote}:${bucket_path}/${DATASET_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-s[0-9][0-9][0-9]-b[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].zfs.gz.age$" || true)
    
    local all_files="$old_files"$'\n'"$new_files"
    all_files=$(echo "$all_files" | grep -v "^$" || true)
    
    if [[ -z "$all_files" ]]; then
        echo "  ✓ No files found to clean"
        return 0
    fi
    
    local file_count=$(echo "$all_files" | wc -l)
    echo "  Found $file_count files to delete:"
    
    # List files with sizes
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local size=$(rclone size "${rclone_remote}:${bucket_path}/${DATASET_PATH}/${file}" 2>/dev/null | awk '{print $4}' || echo "unknown")
        echo "    - $file ($size)"
    done <<< "$all_files"
    
    echo ""
    read -p "  Delete these $file_count files from $provider_name? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "  Deleting files..."
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            echo "    Deleting: $file"
            if rclone delete "${rclone_remote}:${bucket_path}/${DATASET_PATH}/${file}" 2>/dev/null; then
                echo "      ✓ Deleted"
            else
                echo "      ✗ Failed to delete"
            fi
        done <<< "$all_files"
        echo "  ✓ Cleanup complete for $provider_name"
    else
        echo "  Skipped cleanup for $provider_name"
    fi
    echo ""
}

# Clean Backblaze B2
cleanup_provider "Backblaze B2" "cloudremote" "${B2_BUCKET_NAME}/zfs-backups"

# Clean Scaleway (if available)
if [[ "$SCALEWAY_AVAILABLE" == "true" ]]; then
    cleanup_provider "Scaleway" "scaleway" "${SCW_BUCKET_NAME}/zfs-backups"
fi

echo "=== Cleanup Complete ==="
echo ""
echo "Next steps:"
echo "1. Run a fresh backup test:"
echo "   ./offsite --backup $TEST_DATASET"
echo ""
echo "2. Verify clean slate:"
echo "   ./offsite --list-backups"
echo ""
echo "Environment is now ready for clean testing!"