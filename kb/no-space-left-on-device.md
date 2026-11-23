# "No space left on device" but `df -h` shows free space

**Applies to:** Ubuntu 24.04 and later, ext4 filesystems
**Tested on:** AWS EC2, Ubuntu Server, 6.7G root volume

## Symptom

Creating or writing a file fails with:

```
touch: cannot touch '/path/file': No space left on device
```

or an application logs the same error, yet `df -h` shows free space on the filesystem.

## Cause

A filesystem can run out of things other than free blocks. The usual causes are:

1. **Inodes exhausted.** Millions of small files used every inode while blocks are still free. Common sources are mail queues, session files and cache folders.
2. **Deleted-but-open files.** A file was removed, but a running process still has it open, so its space is not released. `df` counts the space, but `du` cannot see the file.
3. **Wrong filesystem.** The path is on a different mount than expected. For example, `/tmp` can be RAM-backed `tmpfs`, which has its own, much smaller limit.
4. **A large file or folder** simply filled the disk.

## Solution

**1. Check the exact path, not just `/`.**

```
df -h /path/in/question
```

Look at the `Filesystem` column. `tmpfs` means the path is in RAM, not on disk.

**2. Check inodes.**

```
df -i /path/in/question
```

If `IUse%` is 100%, find the directory holding the files:

```
sudo find / -xdev -type f | cut -d/ -f2-3 | sort | uniq -c | sort -n | tail
```

The last lines show the folders with the most files. Delete what is safe to remove, and fix whatever keeps creating the files.

**3. Compare `du` with `df`.**

```
sudo du -sh /mount/point
df -h /mount/point
```

If `df` is much larger than `du`, look for deleted files that are still open:

```
sudo lsof +L1
```

Each line ending in `(deleted)` shows the command and PID holding it. Restart or stop that service. The space is released once the process exits. To free space without a restart, truncate through the file descriptor:

```
: > /proc/<PID>/fd/<FD>
```

**4. Otherwise, find the large file or folder.**

```
sudo du -xah / --max-depth=2 2>/dev/null | sort -h | tail -10
sudo find / -xdev -type f -size +500M -exec ls -lh {} +
```

`du` lists only directories unless you add `-a`, so a single large file can hide inside a folder total. If a folder is much bigger than its listed subfolders combined, the difference is a file sitting directly in it.

## Verification

```
df -h /path/in/question
df -i /path/in/question
```

Both show healthy values, and the write that failed now succeeds.

## Notes

- `-x` keeps `du` and `find` on one filesystem, so `/proc` and other mounts do not distort the results.
- `kill` only sends a signal. After stopping a process, give it a moment and run `df` again.
- ext4 reserves about 5% of blocks for root, so non-root users can hit the limit before `df` shows 100%.

## Related

- Set alerts at about 80% for both disk usage and inode usage.
- Rotate or cap logs in `/var/log`.
