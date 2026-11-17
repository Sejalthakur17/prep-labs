# Processes, packages and systemd

## Processes

A process is a program while it is running. Every process has a PID (its ID) and a PPID (the PID of the parent that started it).

- PID 1 is `systemd`, the ancestor of all normal processes. PID 2 is `kthreadd`, the parent of kernel threads, which show in `[brackets]`. That is why `ps -ef | head` starts with PID 2: kernel threads fill the top of the list.
- Both PID 1 and PID 2 have PPID 0, meaning they were started by the kernel itself.

Three ways to find a process:
- By name: `pgrep -a sleep` (add `-f` to match the full command line)
- By PID: `ps -p <PID>`
- By usage: `top` or `htop` (in top, `M` sorts by memory, `P` by CPU)

Useful commands: `ps aux`, `ps -ef --forest`, `pgrep -af name`, `echo $$` (PID of my shell).

## Signals and exit codes

`kill` sends a signal. The process decides what to do with it. The default is 15.

- `kill -15 <PID>` (SIGTERM) asks the process to stop. It can clean up first, or ignore the request.
- `kill -9 <PID>` (SIGKILL) is forced by the kernel and cannot be caught. No cleanup, so it can leave lock files behind.
- Pausing is a different signal: SIGSTOP (19), resumed with SIGCONT (18).
- Order of use: try 15, wait a few seconds, use 9 only if it is still running.
- A normal user can only signal their own processes. `kill -15 1` returns `Operation not permitted`, which is correct.
- `<PID>` is a placeholder. Use the real PID from `pgrep` or `$!` (PID of the last background job).

A process killed by a signal gives exit code `128 + signal number`:
- `143` = 128 + 15, killed by SIGTERM
- `137` = 128 + 9, killed by SIGKILL (in containers this is often the out-of-memory killer)
- Check with `wait $!; echo $?` after killing a background job.

I proved the difference with a script that traps SIGTERM: `kill -15` printed its message and the script kept running, `kill -9` destroyed it.

## Packages

- `apt` is the high-level tool. It downloads packages from repositories and resolves dependencies, then calls dpkg.
- `dpkg` is the low-level tool. It installs a local `.deb` file and keeps the database of what is installed. It does not download anything or resolve dependencies.
- `snap` is a separate system. Snaps carry their own dependencies and update through channels. `snap list`, `snap info <name>`.
- `apt policy <pkg>` shows installed version, candidate version and which repository it comes from.
- `dpkg -L <pkg>` lists the files a package installed.

Which package owns a file:
- `which ls` prints the path, `readlink -f` follows links to the real file, `dpkg -S <path>` names the package.
- Example: `dpkg -S /usr/sbin/nginx`
- If no package owns the file, `dpkg -S` prints `no path found matching pattern`. It does not print nothing.

`sudo apt-mark hold <pkg>` stops that package being upgraded. It is for when an upgrade breaks something or a version must stay fixed. Other packages still upgrade. Undo it with `apt-mark unhold`, check it with `apt-mark showhold`.

## systemd

systemd is PID 1. It starts services, restarts them and collects their logs. My own unit files go in `/etc/systemd/system/`.

`hello.service` runs `/opt/hello.sh`, a loop that writes a log line every 5 seconds:
- `ExecStart=/opt/hello.sh` is the command to run. It must be a full path.
- `Restart=on-failure` restarts it after a crash or a kill by signal, not after a clean `systemctl stop`.
- `WantedBy=multi-user.target` is used by `systemctl enable` to start it at boot.
- After any edit to a unit file, run `sudo systemctl daemon-reload`.
- Killing the main PID with `kill -9` made systemd start it again with a new PID.

## What I broke and how I fixed it

1. **Wrong path in ExecStart** (`/opt/helo.sh` instead of `/opt/hello.sh`)
   - Symptom: service failed with `status=203/EXEC`. After repeated failures systemd showed `start-limit-hit`.
   - Diagnosis: `journalctl -xeu hello` showed `No such file or directory`. Code 203 means systemd could not execute the command.
   - Fix: correct the path with `sed -i`, then `sudo systemctl daemon-reload` (so systemd reads the corrected file), `sudo systemctl reset-failed hello` (clears the failed state and start-limit counter), `sudo systemctl restart hello`.

2. **Removed execute permission** (`chmod -x /opt/hello.sh`)
   - Symptom: `203/EXEC` again.
   - Diagnosis: the journal this time said `Permission denied`, and `ls -l` showed no `x`. Same code, different cause.
   - Fix: `sudo chmod +x /opt/hello.sh`, `reset-failed`, `restart`. No `daemon-reload` was needed because the unit file did not change.

## Troubleshooting method

1. Find the failed service: `systemctl list-units --failed`.
2. Read its state and exit code: `systemctl status <name>`.
3. Read the real error: `journalctl -xeu <name>`.
4. Check the path and permissions with `ls -l`.
5. Change one thing, `daemon-reload` if the unit changed, `reset-failed`, restart and verify with `systemctl is-active <name>`.

## Cheat sheet

Processes
- `ps aux` lists everything, `ps -ef --forest` shows the parent/child tree
- `pgrep -a <name>` finds by name, `ps -p <PID>` by PID
- `top` / `htop` show live usage (`q` to quit)
- `kill -15 <PID>` asks to stop, `kill -9 <PID>` forces it, `pkill <name>` signals by name
- `kill -STOP <PID>` pauses, `kill -CONT <PID>` resumes, `kill -l` lists signals
- `$$` is my shell's PID, `$!` is the last background job's PID, `$?` is the last exit code
- `ps` STAT letters: `S` sleeping, `R` running, `D` waiting on I/O (even `kill -9` cannot stop it), `T` stopped, `Z` zombie

Packages
- `apt policy <pkg>` installed vs candidate version
- `apt show <pkg>` package details, `apt list --upgradable` what could be upgraded
- `dpkg -l | grep <pkg>` is it installed (`ii` = installed, `rc` = removed but config left)
- `dpkg -L <pkg>` files in a package, `dpkg -S <path>` which package owns a file
- `sudo apt-mark hold|unhold <pkg>`, `apt-mark showhold`
- `snap list`, `snap info <name>`
- `apt update` refreshes the list of versions, `apt upgrade` installs newer ones

systemd
- `sudo systemctl daemon-reload` after editing a unit file
- `sudo systemctl start|stop|restart|enable|disable <name>`
- `systemctl status <name> --no-pager`, `systemctl is-active <name>`, `systemctl is-enabled <name>`
- `sudo systemctl reset-failed <name>` clears the failed state and start-limit counter
- `journalctl -u <name>` logs, `-f` follows, `-xeu` adds explanations and jumps to the end
- `journalctl -t <tag>` logs by tag
- `systemctl list-units --failed` all failed units
- `systemctl show -p MainPID --value <name>` main PID of a service

## Common errors

Connecting to lab1
- `Operation timed out`: the security group doesn't allow my current IP, the instance isn't running, or the public IP changed after a stop and start. Fix: check the instance is Running, copy the current public IPv4, run `curl -4 ifconfig.me`, set the SSH rule source to that IPv4 `/32`, test with `nc -vz -w 5 <ip> 22`.
- `Connection reset` or `refused` right after start: SSH isn't ready yet. Wait a minute and retry.
- `Permission denied (publickey)`: wrong user or key. Use `ubuntu@<ip>` and `lab-key.pem`.
- `UNPROTECTED PRIVATE KEY FILE`: key permissions too open. Fix: `chmod 400 lab-key.pem`.

Processes
- `kill: (1) - Operation not permitted`: the process belongs to root or is a kernel thread. Only signal my own processes, and never use `sudo kill` on system processes.
- `kill: 1510: invalid signal specification`: typed `-1510` with no space. Write `kill -15 <PID>`.
- Process survives `kill -15`: it handles or ignores SIGTERM. Wait a few seconds, then `kill -9`.
- Can't see PID 1 in `ps -ef | head`: kernel threads fill the top. Use `ps -ef --forest | grep -v '\]$'` or `pstree -p`.

Packages
- `Could not get lock /var/lib/dpkg/lock-frontend`: another apt or dpkg process is running. Wait, check `pgrep -a apt`, retry.
- `E: Unable to locate package`: the package list is old or the name is wrong. Run `sudo apt update` and check the spelling.
- `Permission denied` or `are you root?`: add `sudo`.
- `dpkg -S` says `no path found matching pattern`: no package owns that file (or the path is a symlink, so resolve it with `readlink -f`).

systemd
- `Unit hello.service not found`: wrong file name or location. It must be `/etc/systemd/system/hello.service`.
- Edited the unit and nothing changed: systemd still has the old copy. Run `daemon-reload`.
- `start-limit-hit` or `Start request repeated too quickly`: too many failures too fast. Fix the cause, then `reset-failed` and start again.
- `203/EXEC`: systemd cannot execute the command. Check the path and the execute bit with `ls -l`, and read `journalctl -xeu <name>` for the exact reason.
- `journalctl` shows nothing: not enough rights or the service never started. Add `sudo` and check `systemctl status`.
