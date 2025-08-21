# Rclone Bisync Bootstrap Script

## What is this?

This script automatically sets up **automatic file synchronization** between two cloud storage locations (like Google Drive, OneDrive, Amazon S3, etc.) using rclone. Think of it as a "set it and forget it" solution that keeps your files in sync across different cloud services.

## What does it do?

1. **Creates a scheduled task** that runs automatically at regular intervals
2. **Synchronizes files** between two cloud storage locations
3. **Keeps backups** of any files that get deleted or changed
4. **Handles conflicts** automatically (newer files win)
5. **Monitors the sync process** and logs everything for troubleshooting

## Prerequisites

Before using this script, you need:

- **Linux system** (Ubuntu, CentOS, etc.)
- **rclone installed** (version 1.68.0 or newer)
- **rclone configured** with your cloud storage accounts
- **Administrator access** (sudo privileges)

## How to use

### Basic usage

```bash
sudo ./bootstrap-bisync.sh \
  --path1 "onedrive@account:/FolderName" \
  --path2 "s3@account:bucket/FolderName"
```

### What the parameters mean

- **`--path1`**: First cloud storage location (source)
- **`--path2`**: Second cloud storage location (destination)
- **`--client`**: Optional name for this sync job (defaults to folder name)
- **`--interval`**: How often to sync (default: 5 minutes)
- **`--user`**: Which user account to run the sync under

### Examples

**Sync OneDrive to S3:**
```bash
sudo ./bootstrap-bisync.sh \
  --path1 "onedrive@work:/Documents" \
  --path2 "s3@backup:mybucket/Documents"
```

**Sync with custom settings:**
```bash
sudo ./bootstrap-bisync.sh \
  --path1 "gdrive@personal:/Photos" \
  --path2 "dropbox@backup:/Photos" \
  --client "PhotoBackup" \
  --interval "1h"
```

## What happens after setup?

1. **Script creates** a scheduled task that runs automatically
2. **First run** does a full sync (this may take a while)
3. **Subsequent runs** only sync changes (much faster)
4. **Logs are created** in `/var/log/rclone/[client-name]/`
5. **Backups are stored** in `_bisync_backups` folders on both locations

## Managing your sync jobs

### Check status
```bash
# Check if the timer is running
systemctl status rclone-bisync@[client-name].timer

# Check the last sync job
systemctl status rclone-bisync@[client-name].service

# View recent logs
journalctl -u rclone-bisync@[client-name].service -n 50
```

### View sync logs
```bash
# Real-time log monitoring
tail -f /var/log/rclone/[client-name]/bisync.log

# Initial sync logs
tail -f /var/log/rclone/[client-name]/bisync-init.log
```

### Stop/start sync jobs
```bash
# Stop automatic syncing
sudo systemctl stop rclone-bisync@[client-name].timer

# Start automatic syncing again
sudo systemctl start rclone-bisync@[client-name].timer

# Run a sync job manually
sudo systemctl start rclone-bisync@[client-name].service
```

## Safety features

- **Automatic backups**: Deleted files are saved before removal
- **Conflict resolution**: Newer files automatically win conflicts
- **Error recovery**: Failed syncs are retried automatically
- **Health checks**: Script verifies both locations are accessible
- **Lock protection**: Prevents multiple sync jobs from running simultaneously

## Troubleshooting

### Common issues

1. **"rclone not found"**: Install rclone first
2. **"Permission denied"**: Make sure you're running with sudo
3. **"Config not found"**: Run `rclone config` to set up your accounts
4. **Sync not starting**: Check if the timer is enabled and running

### Getting help

- Check the logs in `/var/log/rclone/[client-name]/`
- Use `systemctl status` commands to see what's happening
- Ensure both cloud storage locations are accessible
- Verify your rclone configuration is correct

## Advanced options

### Non-interactive mode
```bash
sudo ./bootstrap-bisync.sh --non-interactive \
  --path1 "source:path" \
  --path2 "dest:path" \
  --client "JobName" \
  --interval "30min"
```

### Recreate existing jobs
```bash
sudo ./bootstrap-bisync.sh \
  --path1 "source:path" \
  --path2 "dest:path" \
  --recreate
```

### Custom backup locations
```bash
sudo ./bootstrap-bisync.sh \
  --path1 "source:path" \
  --path2 "dest:path" \
  --bkp1 "source:/custom/backup/path" \
  --bkp2 "dest:/custom/backup/path"
```

## How it works (simplified)

1. **Script analyzes** your cloud storage locations
2. **Creates system service** that runs rclone bisync
3. **Sets up timer** to run the service automatically
4. **First run** does complete file comparison and sync
5. **Ongoing runs** only sync new/changed/deleted files
6. **Everything is logged** for monitoring and troubleshooting

## Support

This script is designed to be self-contained and reliable. If you encounter issues:

1. Check the logs first
2. Verify your rclone configuration
3. Ensure both storage locations are accessible
4. Check system resources (disk space, network connectivity)

The script includes extensive error handling and will provide clear messages about what went wrong and how to fix it.
