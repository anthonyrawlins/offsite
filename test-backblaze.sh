#!/bin/bash
set -euo pipefail

# Test script for Backblaze B2 configuration with offsite backup system

echo "=== Testing Backblaze B2 Configuration ==="

# Check prerequisites
echo "[1/6] Checking prerequisites..."
command -v rclone >/dev/null 2>&1 || { echo "ERROR: rclone not installed"; exit 1; }
command -v age >/dev/null 2>&1 || { echo "ERROR: age not installed"; exit 1; }
command -v zfs >/dev/null 2>&1 || { echo "ERROR: zfs not installed"; exit 1; }

# Test rclone configuration
echo "[2/6] Testing rclone configuration..."
if ! rclone lsd cloudremote: >/dev/null 2>&1; then
    echo "ERROR: rclone not configured for 'cloudremote'. Run rclone config first."
    exit 1
fi
echo "✓ rclone configured"

# Test bucket access
echo "[3/6] Testing bucket access..."
if ! rclone mkdir cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups 2>/dev/null; then
    echo "Note: Bucket may already exist"
fi
echo "✓ Bucket accessible"

# Test age keys
echo "[4/6] Testing age encryption setup..."
if [[ ! -f "$HOME/.config/age/zfs-backup.txt" ]]; then
    echo "Creating age keypair..."
    mkdir -p ~/.config/age
    age-keygen -o ~/.config/age/zfs-backup.txt
    cat ~/.config/age/zfs-backup.txt | grep "# public key:" | cut -d" " -f4 > ~/.config/age/zfs-backup.pub
fi
echo "✓ Age keys available"

# Test encryption/decryption
echo "[5/6] Testing encryption pipeline..."
test_data="test-$(date +%s)"
echo "$test_data" | age -r "$(cat ~/.config/age/zfs-backup.pub)" > /tmp/test.age
decrypted=$(age -d -i ~/.config/age/zfs-backup.txt /tmp/test.age)
if [[ "$test_data" != "$decrypted" ]]; then
    echo "ERROR: Encryption test failed"
    exit 1
fi
rm /tmp/test.age
echo "✓ Encryption working"

# Test upload/download
echo "[6/6] Testing upload/download..."
echo "test upload" > /tmp/test-upload.txt
rclone copy /tmp/test-upload.txt cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups/test/
rclone copy cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups/test/test-upload.txt /tmp/test-download.txt
if ! diff /tmp/test-upload.txt /tmp/test-download.txt >/dev/null; then
    echo "ERROR: Upload/download test failed"
    exit 1
fi
rclone delete cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups/test/test-upload.txt
rm /tmp/test-upload.txt /tmp/test-download.txt
echo "✓ Upload/download working"

echo ""
echo "🎉 All tests passed! Backblaze B2 is ready for offsite backups."
echo ""
echo "Next steps:"
echo "1. Review the backup script configuration"
echo "2. Test with a small ZFS dataset first"
echo "3. Set up automated scheduling"