# Offsite - Frequently Asked Questions

## 🚀 General Usage

### Q: Can I run offsite backups in the background?
**A: Yes!** Offsite is designed to be background-safe:

```bash
# Safe background operations
offsite --backup rust/hobby@backup-$(date +%Y%m%d) &
offsite --backup tank/data@now --provider scaleway &
offsite --restore rust/old-backup --as rust/recovered &
```

**Background features:**
- Automatic TTY detection prevents interactive prompts
- Progress logged to timestamped files in your home directory
- Clear error messages if background operations fail
- Safe termination if conflicts occur

**Monitor background jobs:**
```bash
# Check progress
tail -f ~/offsite-backup-rust_hobby-*.log

# List running jobs
jobs
ps aux | grep offsite
```

### Q: Can I run multiple offsite instances simultaneously?
**A: Yes!** Multiple instances are fully supported with automatic conflict prevention:

```bash
# ✅ SAFE - Different datasets
offsite --backup rust/hobby@backup-$(date +%Y%m%d) &
offsite --backup rust/projects@now &
offsite --backup tank/data@daily &

# ✅ SAFE - Same dataset, different providers
offsite --backup tank/data@backup-$(date +%Y%m%d) --provider backblaze &
offsite --backup tank/data@backup-$(date +%Y%m%d) --provider scaleway &

# ✅ SAFE - Backup + restore different datasets
offsite --backup rust/hobby@now &
offsite --restore rust/old-backup --as rust/recovered &
```

**Automatic conflict prevention:**
```bash
# ❌ BLOCKED - Same dataset, same operation
offsite --backup rust/hobby@backup1 &
offsite --backup rust/hobby@backup2 &
# Second instance shows: ERROR: Another offsite backup is already running for dataset rust/hobby (PID 12345)
```

### Q: How much disk space do I need for backups?
**A: Minimal!** The streaming approach uses only ~1GB of temporary space:

- **Old approach**: Required disk space = 2x dataset size
- **New streaming**: Only ~1GB temporary space regardless of dataset size
- **Example**: 100TB dataset backup uses only ~1GB temp space

**Temp space usage:**
- Creates 1GB shards temporarily during streaming
- Shards are deleted immediately after upload
- No persistent storage of the full dataset stream

## 🔧 Technical Details

### Q: What happens if my system reboots during a backup?
**A: Automatic recovery!** The system handles post-reboot scenarios intelligently:

```bash
# After reboot, old lock files are automatically cleaned up
offsite --backup rust/hobby
# Output: INFO: Removing old stale lock file (PID 12345, 120 minutes old - likely from reboot)
# ✅ Backup continues normally
```

**Recovery scenarios:**
- **Reboot**: Detects old lock files and removes them
- **Process killed**: Removes stale locks from dead processes
- **PID reused**: Validates the process is actually offsite
- **Corrupted locks**: Handles empty/corrupted lock files

### Q: Are backups resumable after interruptions?
**A: Yes!** Offsite includes intelligent resume capabilities:

```bash
# If backup is interrupted, restart with same command
offsite --backup rust/hobby@backup-20250117
# Output: ✓ Shard already exists: full-backup-20250117-s001.zfs.gz.age
# Output: ✓ Shard already exists: full-backup-20250117-s002.zfs.gz.age
# Output: Processing shard 3 of ~5...
```

**Resume features:**
- Checks existing shards before upload
- Skips shards that already exist in cloud storage
- Continues from where the interruption occurred
- Works across different backup sessions

### Q: How accurate are the progress estimates?
**A: Very accurate!** Progress estimation uses real ZFS metadata:

**Full backups:**
- Uses dataset `used` property for accurate size estimation
- Accounts for compression and deduplication

**Incremental backups:**
- Uses `written` property to estimate changed data
- Fallback to 10% of dataset size if `written` unavailable

**Example output:**
```
Estimated size: 2.3GB (~3 shards)
Processing shard 1 of ~3...
Processing shard 2 of ~3...
✓ Streaming complete: 3 shards processed (as estimated)
```

## 🔒 Security & Safety

### Q: How secure is my data during backup?
**A: Military-grade security** with multiple layers:

1. **End-to-end encryption**: Data encrypted before leaving your system
2. **Individual shard encryption**: Each 1GB shard is independently encrypted
3. **Zero-knowledge architecture**: Cloud providers never see your data
4. **Age cryptography**: Modern, secure encryption standard

**Security model:**
```bash
# Your data flow
ZFS data → Compress → Encrypt → Upload to cloud
          ↓
    Cloud provider sees only encrypted shards
```

### Q: What happens if I lose my encryption key?
**A: Data is unrecoverable!** This is by design for security:

⚠️ **CRITICAL**: Save your age private key securely!
- **Location**: `~/.config/age/zfs-backup.txt`
- **Backup**: Store copies in multiple secure locations
- **Without key**: No recovery possible (zero-knowledge architecture)

**Best practices:**
- Store key in password manager
- Keep offline copies in secure locations
- Never commit keys to version control
- Test restore process with key backup

### Q: Can I trust the resumable backup feature?
**A: Absolutely!** Resumable backups are designed to be safe:

- **Shard verification**: Each shard is verified before skipping
- **Atomic operations**: Chunks are uploaded completely or not at all
- **No partial shards**: Failed uploads don't leave partial data
- **Consistency checks**: Backup integrity is maintained

## 🌐 Cloud Storage

### Q: Which cloud providers are supported?
**A: 70+ providers** via rclone integration:

**Popular providers:**
- **Backblaze B2**: Cost-effective, reliable
- **Amazon S3**: Industry standard
- **Google Cloud Storage**: Fast and scalable
- **Scaleway**: European data sovereignty
- **Microsoft Azure**: Enterprise integration

**Setup any provider:**
```bash
# Configure with rclone
rclone config

# Use in offsite
offsite --backup tank/data --provider your-provider
```

### Q: Can I backup to multiple cloud providers simultaneously?
**A: Yes!** Multi-provider redundancy is built-in:

```bash
# Backup to all configured providers
offsite --backup tank/data --provider all

# Backup to specific providers simultaneously
offsite --backup tank/data --provider backblaze &
offsite --backup tank/data --provider scaleway &
```

**Benefits:**
- **Geographic redundancy**: Data in multiple regions
- **Provider redundancy**: Protection against provider issues
- **Cost optimization**: Use cheapest provider for regular access
- **Performance**: Fastest provider for time-sensitive restores

## 🛠️ Troubleshooting

### Q: I'm getting "gzip stdin: file size changed while zipping" errors
**A: Fixed in latest version!** This was a race condition that's now resolved:

**Root cause:** Processing shards while they were still being written
**Solution:** Implemented file size stability checking

```bash
# Update to latest version
git pull
./offsite --backup your-dataset  # Should work without errors
```

### Q: Backup seems slow - any optimization tips?
**A: Several optimization strategies:**

1. **Network bandwidth**: Use provider closest to you
2. **Parallel uploads**: Different datasets to different providers
3. **Incremental backups**: After initial full backup
4. **Compression**: ZFS compression reduces upload size

```bash
# Optimize for speed
offsite --backup tank/data --provider closest-provider

# Parallel processing
offsite --backup tank/data --provider backblaze &
offsite --backup tank/photos --provider scaleway &
```

### Q: How do I monitor backup progress?
**A: Multiple monitoring options:**

**Console output:**
```bash
# Real-time progress
offsite --backup tank/data@backup-$(date +%Y%m%d)
# Shows: Processing shard 3 of ~15...
```

**Log files:**
```bash
# Background monitoring
tail -f ~/offsite-backup-tank_data-*.log

# Review completed backups
ls -la ~/offsite-backup-*.log
```

**System monitoring:**
```bash
# Check running processes
ps aux | grep offsite

# Monitor network usage
iftop
nethogs
```

## 📋 Best Practices

### Q: What's the recommended backup schedule?
**A: Depends on your needs:**

**Personal use:**
```bash
# Daily backups
0 2 * * * offsite --backup tank/important@daily-$(date +%Y%m%d)

# Alternative: Auto-timestamped backups
0 2 * * * offsite --backup tank/important
```

**Professional use:**
```bash
# Multiple daily backups
0 2,14 * * * offsite --backup tank/critical@backup-$(date +%Y%m%d-%H%M)

# Multiple providers
0 2 * * * offsite --backup tank/data@backup-$(date +%Y%m%d) --provider backblaze
0 3 * * * offsite --backup tank/data@backup-$(date +%Y%m%d) --provider scaleway
```

### Q: Are backups always full backups?
**A: Yes!** Version 2.0 simplified the backup process:

- **Always full backups**: No incremental complexity
- **Predictable behavior**: Every backup is complete and independent
- **Easier restore**: No dependency chains to worry about
- **Reliable**: No risk of broken incremental chains

```bash
# All backups are full backups
offsite --backup tank/data@backup-$(date +%Y%m%d)
offsite --backup tank/data@daily-backup
offsite --backup tank/data  # Auto-timestamped
```

## 🔄 Migration & Compatibility

### Q: I'm upgrading from an older version - what changed?
**A: Major improvements** in the streaming version:

**Breaking changes:**
- None! All existing backups remain compatible

**New features:**
- Streaming backup (99.9% less temp space)
- Progress estimation with shard counting
- Background execution support
- Multi-terminal safety with locking
- Enhanced error handling
- Simplified backup logic (always full backups)
- Configurable shard sizes
- Removed --as flag from backup operations

**Migration:**
```bash
# Simply update and continue using
git pull
offsite --backup your-dataset@backup-$(date +%Y%m%d)  # Uses new simplified approach
```

### Q: Can I restore backups made with older versions?
**A: Yes!** Full backward compatibility:

- All shard formats remain compatible
- Restore process unchanged
- Encryption/decryption identical
- File naming conventions preserved

```bash
# Restore old backups normally
offsite --restore old-dataset@backup-20250101
```

---

## 📞 Need More Help?

- **Documentation**: See [README.md](README.md) for detailed usage
- **Issues**: Report bugs at [GitHub Issues](https://github.com/anthonyrawlins/offsite/issues)
- **Examples**: Check the setup script output for command examples
- **Community**: Share experiences and get help from other users

**Remember**: Your encryption key is your responsibility - back it up securely!