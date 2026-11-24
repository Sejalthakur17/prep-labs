# NFS mount hangs when the server stops or reboots

**Applies to:** Ubuntu 26.04 client, NFSv4.2, a `hard` mount (the default). Reproduced on AWS EC2 in a lab; see [incidents/07-nfs.md](../incidents/07-nfs.md).

## Symptoms

- `ls`, `cd` or `df` on the mounted folder freezes.
- `mount | grep nfs` still lists the mount as normal.
- `ps -eo pid,stat,cmd | awk '$2 ~ /D/'` shows the stuck command in state `D`.
- After a wait, `sudo dmesg | tail` shows a line like `nfs: server <ip> not responding, timed out` (the wording can differ by kernel).

## Cause

The mount is `hard`, so the client retries forever when the server is unreachable. That protects data from being silently lost, but it blocks anything that touches the mount until the server answers.

## Diagnosis

Run these from a second terminal. Stay out of the mounted folder there, because touching it will hang that terminal too.

```bash
mount | grep nfs                          # confirm "hard" in the options
ps -eo pid,stat,cmd | awk '$2 ~ /D/'      # stuck process in state D
sudo dmesg | tail -5                      # "not responding" (needs a request in flight)
nc -zv -w 5 <server-ip> 2049              # timeout = server down or traffic dropped
```

If `nc` times out, check whether the server is running and whether a security group or `ufw` rule changed. If it says `Connection refused`, the server is up but the NFS service is stopped.

## Resolution (safest first)

1. **Restore the server.** Start it and wait about a minute. The client resumes by itself, with no remount and no data loss. This is the correct fix.
2. **Release what holds the mount.** Press Ctrl+C in the frozen terminal, or `sudo kill -9 <PID>` using the PID from the `ps` output. In my test Ctrl+C freed the command, but the mount stayed and the next access hung again.
3. **Force the unmount** (only if the server cannot come back soon):
   ```bash
   sudo umount -f /mnt/nfs
   ```
   If it says `device is busy`, a process still holds the mount: go back to step 2.
4. **Lazy unmount as a last resort:**
   ```bash
   sudo umount -l /mnt/nfs
   ```
   It detaches the mount immediately and cleans up later.

**Warning:** forcing or lazily unmounting can lose writes the client has not yet flushed to the server. Tell the customer this before recommending steps 3 or 4. (I did not test data loss; this is the documented behaviour.)

## Verification

After the server is back, remount once and check:

```bash
mount | grep nfs                          # prints nothing before you mount
sudo mount -t nfs <server-ip>:/srv/share /mnt/nfs
mount | grep nfs                          # exactly one line
ls /mnt/nfs                               # files listed
```

Always check `mount | grep nfs` before mounting. Mounting over an existing mount stacks a second one on top.

## Prevention

- Monitor the NFS server and port 2049.
- In `/etc/fstab`, use `_netdev` (wait for the network) and `nofail` (do not block boot if the server is down). This is standard guidance; I did not test it here.
- Choose `hard` or `soft` deliberately. `soft` returns errors after timeouts instead of hanging, but can lose or corrupt writes.

## Related

- Mount times out (no hang, `nc` timeout): firewall or security group, see incident 07, Fault B.
- `Stale file handle` while the mount looks healthy: unmount and remount, see incident 07, Fault C.
- Notes: [notes/nfs-faults.md](../notes/nfs-faults.md).