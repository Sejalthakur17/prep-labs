# Server reports 100% disk usage on / while inodes are free

## Environment

- Ubuntu Server (tested on 26.04 LTS), AWS EC2
- Root filesystem on a single disk (6.7G in this example)
- nginx 1.28.3 serving a static page

## Symptom

- `df -h` shows `/` at 100% with very little space available (for example, 48M free).
- Services that only read, such as a web server returning an existing page, may keep working.
- Anything that writes can fail: log files, `apt install`, file uploads, temporary files.

## Cause

One or more large files have used up the free space on the root filesystem. In the example this article is based on, a single 3.1G file in `/var` was responsible.

Not every "disk full" problem is this one. Two other causes look similar and are checked in the steps below:

1. **Inode exhaustion:** the disk has free space, but no free inodes (file entries).
2. **Deleted-but-open files:** a file was deleted, but a running program still holds it open, so the space is not freed.

## Solution

1. **Confirm the problem.**
   ```bash
   df -h /
   ```
   Look for `Use%` at or near 100%.

2. **Rule out inode exhaustion.**
   ```bash
   df -i /
   ```
   If `IUse%` is also near 100%, the problem is too many small files, not large files. This article does not apply.

3. **Find which top-level folder is largest.**
   ```bash
   sudo du -xh / --max-depth=1 2>/dev/null | sort -h | tail
   ```
   `-x` stays on one filesystem. Drill into the largest folder in the same way.

4. **Find the large files.**
   ```bash
   sudo find / -xdev -type f -size +500M -exec ls -lh {} \; 2>/dev/null
   ```
   Note the file's owner and modification time. The time is a useful clue for what created it.

5. **Check for deleted-but-open files.**
   ```bash
   sudo lsof +L1
   ```
   If this lists large entries, restart the program that holds them. Removing files will not free that space until it closes them.

6. **Confirm the file is safe to remove.** Check what it is and who owns it. If it belongs to a customer or an application, ask first. Do not delete files you cannot identify.

7. **Remove the file.**
   ```bash
   sudo rm /path/to/large-file
   ```

## Verification

1. Confirm space was recovered:
   ```bash
   df -h /
   ```
   `Use%` should drop and `Avail` should rise by roughly the size of the removed file.

2. Confirm the disk accepts writes:
   ```bash
   sudo touch /var/testfile && sudo rm /var/testfile && echo "writes OK"
   ```
   Expected output: `writes OK`.

3. Confirm the service still works, for example:
   ```bash
   curl -I http://localhost
   ```

## Notes

- Running `ss -tlnp` without `sudo` can print nothing even when a service is listening, because it needs root to show process names. An empty result may mean no permission, not no listener.

## Prevention

- Alert on disk usage at about 80%.
- Configure log rotation (`logrotate`).
- Keep application data on a separate volume from the root filesystem.
- Monitor growth in `/var`.
