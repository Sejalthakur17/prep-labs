# Incident 07: NFS failures (permissions, firewall, stale handle, hung mount)

Lab 7, 24 Nov 2026. AWS EC2, Ubuntu 26.04, ap-south-1. Throwaway lab machines, no customer data.
Commands and full output: [../notes/nfs-faults.md](../notes/nfs-faults.md). Baseline build: [../notes/storage-lvm-nfs.md](../notes/storage-lvm-nfs.md). KB article: [../kb/nfs-mount-hangs-server-down.md](../kb/nfs-mount-hangs-server-down.md).

## Summary

I broke a working NFSv4.2 share four ways and diagnosed each from symptoms: permission denied (three forms), a firewall dropping port 2049 (security group and `ufw`), a stale file handle, and a hard mount hanging after the server stopped. Each fault looked different, but the first useful command was different in each case, which is the main takeaway.

## Environment

| Item | Value |
|---|---|
| Server | `nfs-server`, 172.31.2.131, exports `/srv/share` |
| Client | `nfs-client`, 172.31.9.106, mounts at `/mnt/nfs` |
| Export | `/srv/share 172.31.9.106(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,root_squash,no_all_squash)` |
| Mount | `nfs4`, `vers=4.2`, `hard`, `timeo=600`, `retrans=2`, `sec=sys` |
| Security group | `nfs-sg`: 2049 and 111 from its own members, SSH from my IP |

## Fault A: Permission denied

**Symptom:** writes to `/mnt/nfs` fail on the client.
**Diagnosis:** `id` showed UID 1000. `ls -lnd /mnt/nfs` showed owner `0 0`, mode 755. `sudo touch` also failed. `exportfs -v` on the server listed `root_squash`.
**Root cause:** the exported folder was `root:root 755`. Normal users have no write access, and root is squashed to `nobody`, so root has none either. A second form: a file owned by UID 2001 appeared on the client as a bare number and could not be modified by UID 1000 (mode 644).
**Fix:** `chown 1000:1000 /srv/share` (precise) or `chmod 777` (lab only). No remount needed.
**Verification:** `touch` as `ubuntu` worked; `sudo touch` still failed, which is correct.
**Customer should monitor:** UIDs and ownership staying consistent between machines; do not use `no_root_squash` just to make an error go away.

## Fault B: Mount hangs or times out (firewall)

**Symptom:** `mount` hung, and `nc -zv -w 5 172.31.2.131 2049` printed `timed out: Operation now in progress`. Nothing was mounted.
**Diagnosis:** a timeout means packets are dropped. I checked the security group first (the 2049 rule had been removed), then, after restoring it, the OS firewall (`ufw` enabled with only `OpenSSH` allowed). Both layers produced the identical symptom.
**Root cause:** two separate layers dropping traffic to 2049.
**Fix:** re-add TCP 2049 (source `nfs-sg`); `sudo ufw allow from 172.31.9.106 to any port 2049`.
**Verification:** `nc` printed `succeeded!`; the mount worked and listed the files.
**Customer should monitor:** firewall changes on both the cloud and the OS layer; allow only the client addresses.

*Not captured: `ufw status` after the fix.*

## Fault C: Stale file handle

**Symptom:** `ls` in the mounted folder failed with `Stale file handle` (errno 116, shown as `StaleNetworkFileHandle`) while `mount | grep nfs` still looked healthy.
**Diagnosis:** the server's `/srv/share` had been deleted and recreated while the client had it open. `dmesg` showed nothing about it.
**Root cause:** the client held a handle to the old directory. The new one has the same name but is a different object.
**Fix:** leave the mount, `umount` (found `tail` holding it with `fuser -vm`), mount again. The share was empty afterwards, so I restored the files from a backup copy.
**Verification:** `ls /mnt/nfs` listed the restored files; `findmnt` showed one mount.
**Customer should monitor:** anything that recreates an export (restores, failover); remount clients afterwards.

## Fault D: Hung hard mount

**Symptom:** `ls /mnt/nfs` froze after the server was stopped.
**Diagnosis:** `ps` showed the process in state `D` (`1653 D+ ls --color=auto /mnt/nfs`). `mount | grep nfs` still showed a normal mount. After a second `ls` and a wait, `dmesg` printed `nfs: server 172.31.2.131 not responding, timed out`.
**Root cause:** `hard` mount with the server unreachable. The client retries forever to protect data.
**Fix:** start the server; the client resumed with no remount. If the server cannot come back: release holders, `umount -f`, then `umount -l`. `umount -f` first failed with `device is busy` (the frozen `ls` held the mount) and succeeded after I released it.
**Verification:** one mount line and the files listed after the final remount.
**Customer should monitor:** server availability, and consider `_netdev,nofail` for fstab entries (standard guidance, not tested here).
**Risk:** forcing the mount away can lose writes not yet flushed. I did not test this.

## Symptom to first command

| Symptom | First command | What it tells you |
|---|---|---|
| Mount hangs or times out | `nc -zv -w 5 <server> 2049` | Timeout = dropped; refused = nothing listening |
| Write denied, root too | `ls -lnd <dir>` and `exportfs -v` | Owner, mode and `root_squash` |
| Owners shown as numbers | `ls -ln` on both machines | UID mismatch |
| `Stale file handle` | `mount \| grep nfs` | Looks healthy; the object changed |
| Commands freeze | `ps -eo pid,stat,cmd \| awk '$2 ~ /D/'` | State D on the mount path |

## Where my results differed from what I expected

- A process in state `D` looked unkillable, but Ctrl+C freed my `ls`. Only the single command was cancelled; the mount and the problem stayed.
- The kernel line was `not responding, timed out`, not `still trying`, and no recovery line appeared in `dmesg` after the server returned. The working `ls` was the proof of recovery.
- The kernel message did not appear until a request was in flight (my reasoning; not verified).
- `umount -f` did not work on a busy mount, even with the server down.
- `ls` on Ubuntu 26.04 printed the stale error in a different format from classic `ls`, but the same errno.

## My mistakes

1. Typed a placeholder literally (`<server-private-ip>`), so the mount never ran.
2. Ran client commands on the server.
3. Pasted prompt text into the shell.
4. Ran `dmesg` without sudo.
5. Mounted over a busy stale mount, which stacked mounts.

## Not verified

The source of the `+` (ACL) on files, the `Connection refused` case, what the first terminal's frozen `ls` did when the server returned, data loss under `umount -f`, and the contents under the stacked mount.

## Customer reply 1: shared folder frozen

> Subject: Your shared folder is frozen — what happened and what to do
>
> Hi <name>,
>
> Thanks for the details. Here is what I confirmed: the file server that hosts your shared folder stopped responding, and commands that touch the folder are waiting instead of failing. Your system is set up to wait on purpose, so it does not lose data that hasn't been saved yet.
>
> What I don't know yet: why the server stopped.
>
> What I did: I confirmed the folder is configured to wait for the server and that the waiting processes are blocked on it. When I started the server again, the folder worked again without any restart on your side.
>
> What to do: if the server is down, please start it and give it a minute. Your folder should resume by itself. If the server cannot be restored soon, tell me before disconnecting the folder by force. Forcing a disconnect can lose changes that haven't been saved to the server yet.
>
> I will check back in an hour to confirm the folder is responding normally. If you see it freeze again, please send me the time it happened.
>
> Thanks,
> <your name>

## Customer reply 2: mount times out

> Subject: Mounting the shared folder times out — what I checked
>
> Hi <name>,
>
> Thanks for reporting this. What I confirmed: the connection to the file server's NFS port (2049) times out, so the request never reaches the server. A timeout, rather than a refusal, means something between your machine and the server is dropping the traffic, usually a firewall rule.
>
> What I don't know yet: which of your firewall layers is responsible. There can be two (the cloud security group and the firewall on the server itself).
>
> What I did: I tested the port from your machine, checked the cloud security group, and then the server's own firewall. When port 2049 was allowed for your machine's address in both places, the folder mounted and your files were listed.
>
> What to do: please confirm that the NFS port is allowed from your machine in both layers, and keep access limited to the machines that need it.
>
> I will update you today after you confirm the mount works.
>
> Thanks,
> <your name>

## Interview questions

- Root is denied on an NFS share. Why? (`root_squash`)
- A mount hangs. What do you run first, and how do you read the result? (`nc`, timeout vs refused)
- What is a stale file handle, and how do you fix it?
- Why does a command freeze when the server dies, and how do you recover safely?
- `umount -f` says the device is busy. What next?
- What is the risk of a forced or lazy unmount?