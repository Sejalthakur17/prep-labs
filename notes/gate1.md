# Gate 1 checkpoint (19 Nov 2026)

A cold test of three tasks. On this first attempt I used guidance, so none of these counts as a cold pass yet. I'm repeating all three without hints or notes.

| Task | Result | Time | What tripped me up |
|---|---|---|---|
| 1. Broken `fstab`, recover via a rescue instance | Pass (guided) | about 11 min (rescue and repair, per EC2 console) | needed the walkthrough; mounted the right partition (`xvdf1`) once shown the layout |
| 2. Service that fails to start | Pass with hints | 7 min | read the symptom before the cause |
| 3. Planted DNS fault | Pass with hints | 9 min | ran lookups before checking the resolver service |

Times for tasks 2 and 3 come from the `Time since planted` line of the fault script's `reveal` command.

---

## Task 1: broken `fstab` recovery

**Symptom**
After adding a bad line to `/etc/fstab` and rebooting, <!-- FILL IN: what SSH did, and what the console system log showed --> .

**Why it happened**
The bad line pointed at a device that doesn't exist (`/dev/xvdz1`). Without the `nofail` option, a missing disk can stop the boot from reaching normal mode, so the instance never comes up for SSH.

**Safer way to write it**
Use `UUID=` or `LABEL=` instead of a device name, because device names can change between boots (this Ubuntu image already uses `LABEL=` entries). Add `nofail` for any disk that isn't essential to booting.

**Recovery**
1. Stopped the broken instance and detached its root volume.
2. Attached the volume to a rescue instance in the **same Availability Zone** (an EBS volume can only attach within its own zone).
3. `lsblk` on the rescue instance showed `xvda` (its own disk, mounted at `/` and `/boot`) and `xvdf` (the broken disk, no mountpoints, same layout). The 6.9G partition `xvdf1` held the root filesystem.
4. Mounted `xvdf1` at `/mnt/rescue`, commented out the bad line (it was in the file twice), and unmounted.
5. Detached the volume, reattached it to the original instance as exactly `/dev/sda1` (the root device name the instance expects), started it, and read the new public IP from the console.
6. Terminated the rescue instance.

**Verification**
- `systemctl --failed` listed 0 units.
- `sudo findmnt --verify` reported "Success, no errors or warnings detected". Without `sudo` it showed three "Permission denied" warnings. Those came from not being root, not from a real problem.

---

## Task 2: service that fails to start

**Fault (from `reveal`):** script exits immediately. Time since planted: 7 min.

**Symptom**
`hello.service` kept failing. The status showed a message about start requests being repeated too quickly.

**Cause**
The script exited immediately with status 1 (a stray `exit 1` on its second line). `Restart=on-failure` kept restarting it until systemd hit its start limit and gave up. The "repeated too quickly" message was a symptom. The cause was in the earlier journal lines and in the script itself.

**Fix**
Removed the `exit 1` line, then:
```
sudo systemctl daemon-reload
sudo systemctl reset-failed hello
sudo systemctl restart hello
```
`reset-failed` was needed because systemd refuses to start a unit that has hit its start limit.

**Verification**
`systemctl status hello` showed `active (running)`.

**What I'd tell a customer**
When a service won't stay up, read the first failure in the journal, not the last. Run the script by hand to see whether it works on its own.

---

## Task 3: DNS fault

**Fault (from `reveal`):** `systemd-resolved` masked and stopped. Time since planted: 9 min.

**Evidence I gathered**
- `dig` returned "connection refused" from `127.0.0.53#53`.
- `ss -tulpn` showed nothing listening on port 53.
- A `ping` to the gateway worked and `ip r` looked normal, so the network layer was fine.
- `resolvectl status` failed with an error naming the resolver's own unit (`dbus-org.freedesktop.resolve1.service`).

**Cause**
`systemd-resolved` was masked and stopped. `systemctl status` showed `Loaded: masked` and `Active: inactive (dead)`.

**Masked versus stopped**
A stopped service can simply be started. A masked one is blocked from starting at all, so it has to be unmasked first.

**Fix**
```
sudo systemctl unmask systemd-resolved
sudo systemctl start systemd-resolved
```

**Verification**
- `systemctl is-active systemd-resolved` printed `active`
- `ss -tulpn | grep ':53'` showed listeners on `127.0.0.53` again
- `dig example.com +short` and `getent hosts example.com` both returned addresses
- After `undo`, `systemctl --failed` listed 0 units

**Why compare `dig` with `getent hosts`**
`dig` asks a DNS server directly. `getent hosts` uses the system's normal lookup order, including `/etc/hosts` and `nsswitch`. If the two disagree, the fault is in one of those layers, not in the resolver. This time they agreed once the resolver was back.

---

## Hints I needed

- **Task 2:** I was pointed to the script's contents after the unit file looked fine.
- **Task 3:** I was pointed to the `systemd-resolved` service after my evidence showed nothing was listening on port 53.

## Attempts

| Date | Task | Fault | Notes or AI used? | Time | Result |
|---|---|---|---|---|---|
| 19 Nov | 1. fstab recovery | bad `/etc/fstab` line I added myself | yes, walkthrough | about 11 min (rescue and repair) | pass (guided) |
| 19 Nov | 2. service | script exits immediately | yes, hints | 7 min | pass with hints |
| 19 Nov | 3. DNS | `systemd-resolved` masked and stopped | yes, hints | 9 min | pass with hints |

## What I'm practising next

- Checking that a service is running before testing anything that depends on it.
- Reading the first failure in the logs, then what the service actually executes.
- Writing the fstab recovery steps from memory.