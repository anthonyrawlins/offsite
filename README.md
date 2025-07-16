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

### 💾 **ZFS Native**
- **Snapshot-based** - consistent, point-in-time backups
- **Compression optimized** - efficient storage and transfer
- **Restoration to any point** - restore specific snapshots or latest state
- **Pool-level support** - backup entire ZFS pools or individual datasets

### ⚡ **Dead Simple**
```bash
# Backup your data
offsite --backup tank/important/data

# Restore when needed  
offsite --restore tank/important/data
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
# Backup to all configured providers
offsite --backup tank/photos

# Backup to specific provider
offsite --backup tank/documents --provider backblaze

# Create named snapshot
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

- **One-command operation** - backup and restore with a single command
- **Automatic chunking** - splits large datasets into manageable 1GB chunks
- **Smart resumption** - skips already uploaded chunks on restart
- **Multi-cloud redundancy** - backup to multiple providers simultaneously
- **Flexible scheduling** - perfect for cron jobs and automation
- **Comprehensive logging** - detailed logs for monitoring and troubleshooting

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

### Automated Backups
```bash
# Daily backup at 2 AM
echo "0 2 * * * offsite --backup tank/critical --as @daily-$(date +%Y%m%d)" | crontab -
```

### Multi-Provider Redundancy
```bash
# Backup to all providers simultaneously
offsite --backup tank/important --provider all

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