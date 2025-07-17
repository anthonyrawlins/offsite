# Offsite - Secure ZFS Cloud Backup

**Never lose your data again.** Offsite provides military-grade encrypted, resumable ZFS backups to multiple cloud providers with a single command.

## Why Offsite?

### 🔒 **Security First**
- **End-to-end encryption** using age cryptography
- **Individual chunk encryption** - no single point of failure
- **Zero-knowledge architecture** - your data is encrypted before it leaves your system

### 🚀 **Bulletproof Reliability**
- **Resumable backups** - interrupted transfers continue where they left off
- **Multi-provider support** - backup to multiple clouds simultaneously
- **Incremental backups** - only transfer what changed
- **Automatic retry** - handles network failures gracefully
- **Background execution** - safe to run in background with full logging
- **Multi-terminal support** - run multiple backups concurrently with conflict prevention

### 💾 **ZFS Native**
- **Snapshot-based** - consistent, point-in-time backups
- **Compression optimized** - efficient storage and transfer
- **Restoration to any point** - restore specific snapshots or latest state
- **Pool-level support** - backup entire ZFS pools or individual datasets

### ⚡ **Revolutionary Streaming Technology**
- **99.9% less temp space** - backup 100TB using only ~1GB temp storage
- **Real-time progress tracking** - see "Processing chunk 3 of ~15..."
- **Direct streaming pipeline** - `zfs send | chunk | compress | encrypt | upload`
- **No disk bottlenecks** - never runs out of space during backup

### 🎯 **Dead Simple**
```bash
# Recommended: Snapshot first, then backup
zfs snapshot tank/important/data@backup-$(date +%Y%m%d)
offsite --backup tank/important/data@backup-$(date +%Y%m%d)

# Or let offsite create the snapshot for you
offsite --backup tank/important/data --as @backup-$(date +%Y%m%d)

# Background backup with progress tracking
offsite --backup tank/photos@daily-backup &
tail -f ~/offsite-backup-tank_photos-*.log

# Restore when needed  
offsite --restore tank/important/data@backup-20250117
```

## Quick Start

### 1. Install
```bash
git clone https://github.com/anthonyrawlins/offsite.git
cd offsite
./setup.sh
```

### 2. Configure
Edit `~/.config/offsite/config.env` with your cloud storage credentials:
```bash
# Supports Backblaze B2, Scaleway, Amazon S3, Google Cloud, and more
RCLONE_REMOTE="your-cloud-provider:bucket-name/backups"
```

### 3. Backup
```bash
# BEST PRACTICE: Create snapshot first, then backup
zfs snapshot tank/photos@daily-$(date +%Y%m%d)
offsite --backup tank/photos@daily-$(date +%Y%m%d)

# Backup to specific provider
zfs snapshot tank/documents@backup-$(date +%Y%m%d)
offsite --backup tank/documents@backup-$(date +%Y%m%d) --provider backblaze

# Let offsite create the snapshot for you
offsite --backup tank/projects --as @before-upgrade
```

### 4. Restore
```bash
# Restore latest backup
offsite --restore tank/photos

# Restore to different location
offsite --restore tank/photos --as tank/photos-recovered

# Restore specific backup
offsite --restore tank/projects@before-upgrade
```

## Key Features

### 🎯 **Core Functionality**
- **One-command operation** - backup and restore with a single command
- **Streaming architecture** - no large temp files required
- **Real-time progress** - see chunk progress and size estimates
- **Smart resumption** - skips already uploaded chunks on restart
- **Multi-cloud redundancy** - backup to multiple providers simultaneously

### 🔄 **Concurrent Operations**
- **Background execution** - safe to run with `&` operator
- **Multi-terminal support** - run multiple backups simultaneously
- **Automatic conflict prevention** - dataset-level locking
- **Post-reboot recovery** - handles stale locks intelligently

### 📊 **Monitoring & Logging**
- **Progress estimation** - shows "Processing chunk 3 of ~15..."
- **Size estimation** - displays GB/MB estimates before starting
- **Comprehensive logging** - detailed logs for monitoring and troubleshooting
- **Background-safe logging** - automatic log file creation for `&` jobs

## Supported Cloud Providers

Via rclone integration:
- **Backblaze B2** - Cost-effective, reliable
- **Amazon S3** - Industry standard
- **Google Cloud Storage** - Fast and scalable
- **Scaleway** - European data sovereignty
- **Microsoft Azure** - Enterprise integration
- **And 70+ others** - Any rclone-supported provider

## Use Cases

### Personal
- **Home NAS backup** - Protect family photos, documents, media
- **Development projects** - Version control for code and assets
- **Digital archives** - Long-term storage of important data

### Professional
- **Server backup** - Automated daily backups of critical systems
- **Compliance** - Meet data retention and recovery requirements
- **Disaster recovery** - Geographic redundancy for business continuity

## Advanced Usage

### 🔄 **Concurrent Operations**
```bash
# Multiple datasets simultaneously
offsite --backup tank/photos --provider backblaze &
offsite --backup tank/projects --provider scaleway &
offsite --backup rust/hobby &

# Monitor all background jobs
jobs
tail -f ~/offsite-backup-*.log
```

### 🕐 **Automated Backups**
```bash
# Daily backup at 2 AM (background-safe)
echo "0 2 * * * offsite --backup tank/critical --as @daily-\$(date +%Y%m%d)" | crontab -

# Multiple daily backups to different providers
echo "0 2 * * * offsite --backup tank/data --as @backup-\$(date +%Y%m%d) --provider backblaze" | crontab -
echo "0 3 * * * offsite --backup tank/data --as @backup-\$(date +%Y%m%d) --provider scaleway" | crontab -
```

### 🌐 **Multi-Provider Redundancy**
```bash
# Backup to all providers simultaneously
offsite --backup tank/important --provider all

# Concurrent multi-provider backup
offsite --backup tank/critical --provider backblaze &
offsite --backup tank/critical --provider scaleway &
offsite --backup tank/critical --provider amazonS3 &

# Restore from any provider automatically
offsite --restore tank/important --provider auto
```

### Disaster Recovery
```bash
# Full system restore
offsite --restore tank                           # Restore entire pool
offsite --restore tank/system --as tank/system-recovery
```

## Requirements

- **ZFS filesystem** - OpenZFS on Linux, FreeBSD, or macOS
- **rclone** - For cloud storage integration
- **age** - For encryption (installed automatically)
- **Bash 4.0+** - For script execution

## Security Model

1. **Local encryption** - Data encrypted before upload using age
2. **Chunked security** - Each chunk independently encrypted
3. **Zero-knowledge** - Cloud providers never see your data
4. **Key management** - Your keys stay on your systems
5. **Deterministic streams** - Consistent backups enable safe resumption

## ❓ Frequently Asked Questions

**Q: Can I run backups in the background?**
A: Yes! Fully background-safe with automatic logging:
```bash
offsite --backup tank/data &
tail -f ~/offsite-backup-tank_data-*.log
```

**Q: Can I run multiple backups simultaneously?**
A: Yes! Multi-terminal support with automatic conflict prevention:
```bash
offsite --backup tank/photos &    # ✅ Safe
offsite --backup tank/projects &  # ✅ Safe  
offsite --backup tank/photos &    # ❌ Blocked automatically
```

**Q: How much disk space do I need?**
A: Only ~1GB! Streaming approach eliminates large temp files:
- **Before**: 100TB backup required 200TB+ temp space
- **Now**: 100TB backup requires ~1GB temp space

**Q: What happens if my system reboots during backup?**
A: Automatic recovery! Stale locks are detected and cleaned up:
```bash
# After reboot
offsite --backup tank/data
# Output: INFO: Removing old stale lock file (120 minutes old - likely from reboot)
```

**For more questions, see [FAQ.md](FAQ.md)**

## Contributing

Found a bug? Have a feature request? Contributions welcome!

1. Fork the repository
2. Create your feature branch
3. Submit a pull request

## License

GPL-3.0 - See LICENSE file for details.

Built with ❤️ by [Anthony Rawlins](https://github.com/anthonyrawlins)

---

**Start protecting your data today. Your future self will thank you.**