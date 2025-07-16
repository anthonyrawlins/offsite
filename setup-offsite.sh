#!/bin/bash
set -euo pipefail

# Setup script for offsite backup system with Backblaze B2

echo "=== Offsite Backup System Setup ==="
echo "This script will set up ZFS cloud backups to Backblaze B2"
echo ""

# Check if running as root for some operations
if [[ $EUID -eq 0 ]]; then
    echo "WARNING: Running as root. Some files will be created in root's home directory."
    echo "Consider running as your regular user and using sudo when needed."
    echo ""
fi

# Create directories
echo "[1/7] Creating directories..."
mkdir -p ~/.config/age
mkdir -p ~/.config/rclone
mkdir -p ~/.config/offsite
echo "✓ Directories created"

# Install dependencies
echo "[2/7] Checking dependencies..."
MISSING_DEPS=()

command -v zfs >/dev/null 2>&1 || MISSING_DEPS+=("zfsutils-linux")
command -v rclone >/dev/null 2>&1 || MISSING_DEPS+=("rclone")
command -v age >/dev/null 2>&1 || MISSING_DEPS+=("age")
command -v gzip >/dev/null 2>&1 || MISSING_DEPS+=("gzip")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt install ${MISSING_DEPS[*]}"
    echo "For age: curl -L https://github.com/FiloSottile/age/releases/latest/download/age-v1.1.1-linux-amd64.tar.gz | tar xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen"
    exit 1
fi
echo "✓ Dependencies available"

# Generate age keys if not present
echo "[3/7] Setting up encryption keys..."
if [[ ! -f ~/.config/age/zfs-backup.txt ]]; then
    echo "Generating new age keypair..."
    age-keygen -o ~/.config/age/zfs-backup.txt
    cat ~/.config/age/zfs-backup.txt | grep "# public key:" | cut -d" " -f4 > ~/.config/age/zfs-backup.pub
    chmod 600 ~/.config/age/zfs-backup.txt
    chmod 644 ~/.config/age/zfs-backup.pub
    echo "✓ New age keypair generated"
else
    echo "✓ Age keys already exist"
fi

# Copy example config
echo "[4/7] Setting up configuration..."
if [[ ! -f ~/.config/offsite/config.env ]]; then
    cp example-config.env ~/.config/offsite/config.env
    chmod 600 ~/.config/offsite/config.env
    echo "✓ Configuration template copied to ~/.config/offsite/config.env"
    echo "  Edit this file with your Backblaze B2 credentials"
    echo "  File permissions set to 600 for security"
else
    echo "✓ Configuration already exists"
fi

# Check for rclone config
echo "[5/7] Checking rclone configuration..."
if ! rclone listremotes 2>/dev/null | grep -q "cloudremote:"; then
    echo "⚠ rclone not configured for 'cloudremote'"
    echo "  Run: rclone config"
    echo "  Or configure manually by editing ~/.config/rclone/rclone.conf"
else
    echo "✓ rclone 'cloudremote' configured"
fi

# Install scripts
echo "[6/7] Installing backup scripts..."
sudo cp zfs-backup-all.sh /usr/local/bin/
sudo cp zfs-cloud-restore.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/zfs-backup-all.sh
sudo chmod +x /usr/local/bin/zfs-cloud-restore.sh
echo "✓ Scripts installed to /usr/local/bin/"

# Setup logging
echo "[7/7] Setting up logging..."
sudo touch /var/log/zfs-backup.log
sudo chown $(whoami):$(whoami) /var/log/zfs-backup.log
echo "✓ Log file created"

echo ""
echo "🎉 Setup complete!"
echo ""
echo "Next steps:"
echo "1. Edit ~/.config/offsite/config.env with your Backblaze B2 credentials"
echo "2. Run rclone config if not already done"
echo "3. Test with: ./test-backblaze.sh"
echo "4. Run your first backup: /usr/local/bin/zfs-backup-all.sh"
echo "5. Consider adding to crontab for automation:"
echo "   echo '0 2 * * * /usr/local/bin/zfs-backup-all.sh' | sudo crontab -"
echo ""
echo "Script usage:"
echo "  Backup: /usr/local/bin/zfs-backup-all.sh"
echo "  Restore: /usr/local/bin/zfs-cloud-restore.sh <dataset_path> <backup_file> <target_dataset>"
echo ""
echo "Important: Save your age private key (~/.config/age/zfs-backup.txt) securely!"
echo "          Without it, you cannot restore your backups."