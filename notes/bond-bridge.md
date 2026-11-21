# Day 11: Linux Bridge and Bond with Network Namespaces

Notes, lab log (what I actually did), and interview Q&A.

---

## Part A: Notes

### Golden rule
Never touch `ens5`. It is the SSH connection. Check that `ip -br addr` shows the same IP before and after the lab (mine: `172.31.10.100/20`).

### Core concepts

| Term | Think of it as | Meaning |
|---|---|---|
| Network namespace | A tiny separate computer | Its own interfaces and IPs, sharing the host kernel |
| veth pair | A cable with 2 ends | What goes in one end comes out the other |
| Bridge | A virtual switch | Everything plugged into it can talk to each other |
| Bond | Two cables acting as one | If one link dies, the other takes over |

### Bridge

```
ns1 [veth1 10.10.0.1] --cable-- [veth1-br] \
                                             br0 (switch)
ns2 [veth2 10.10.0.2] --cable-- [veth2-br] /
```

```bash
sudo ip netns add ns1                                  # create a namespace
sudo ip link add br0 type bridge                       # create the bridge
sudo ip link set br0 up                                # power it on
sudo ip link add veth1 type veth peer name veth1-br    # create a cable
sudo ip link set veth1 netns ns1                       # move one end into ns1
sudo ip link set veth1-br master br0                   # plug other end into bridge
sudo ip link set veth1-br up
sudo ip netns exec ns1 ip addr add 10.10.0.1/24 dev veth1
sudo ip netns exec ns1 ip link set veth1 up
sudo ip netns exec ns1 ip link set lo up
sudo ip netns exec ns1 ping -c 3 10.10.0.2             # test through the switch
```

`ip netns exec ns1 <cmd>` means "run this command inside ns1".

Verify: `bridge link` shows both ports with `master br0` and `state forwarding`; `ip -br link show master br0` lists both; ping gets 3 replies.

### Bond

```
nsb [bond0 10.20.0.2 = vA + vB]  ==two cables==  nsc [brc 10.20.0.1 = vA-p + vB-p]
```

```bash
sudo modprobe bonding
sudo ip netns exec nsc ip link add brc type bridge      # far side: bridge joins both cable ends
sudo ip netns exec nsb ip link add bond0 type bond mode active-backup miimon 100
sudo ip netns exec nsb ip link set vA down              # members must be DOWN before joining
sudo ip netns exec nsb ip link set vB down
sudo ip netns exec nsb ip link set vA master bond0
sudo ip netns exec nsb ip link set vB master bond0
sudo ip netns exec nsb ip addr add 10.20.0.2/24 dev bond0
sudo ip netns exec nsb ip link set bond0 up
sudo ip netns exec nsb cat /proc/net/bonding/bond0      # check state
```

- `mode active-backup`: one cable carries traffic, the other waits as a spare.
- `miimon 100`: check link health every 100 ms.

### Bond modes

| Mode | How it works | Needs switch config? |
|---|---|---|
| active-backup | One works, one waits | No |
| 802.3ad (LACP) | Both work together | Yes |
| balance-alb | Load balancing across both | No |

### Cleanup (always)

```bash
for n in ns1 ns2 nsb nsc; do sudo ip netns del $n; done
sudo ip link del br0
```

Deleting a namespace removes the veth ends inside it. `br0` lives in the main system, so it needs its own delete.

---

## Part B: What I did (lab log)

**Setup**
- Pre-flight: `ens5` was `UP 172.31.10.100/20`, no namespaces, `br0` did not exist. Clean start.
- Created `ns1`, `ns2`, `br0`; `br0` showed `DOWN` with `NO-CARRIER` (nothing plugged in yet, expected).

**Bridge**
- Built both cables. `bridge link` listed `veth1-br` and `veth2-br` with `master br0`, `state forwarding`.
- `ip netns exec ns1 ping -c 3 10.10.0.2`: 3 sent, 3 received, 0% loss.
- **Break-it:** `ip link set veth2-br nomaster`.
  - `veth2` still showed `UP` with `10.10.0.2/24`.
  - Ping: 100% packet loss (no "Unreachable" lines, same meaning).
  - `bridge link` listed only `veth1-br`. That was the only clue.
  - `ip link set veth2-br master br0` restored it; ping back to 0% loss.

**Bond**
- `modprobe bonding` worked without installing extra packages. Driver: `v7.0.0-1017-aws`.
- `/proc/net/bonding/bond0` showed `fault-tolerance (active-backup)`, `Primary Slave: None`, active slave `vA`, both members `MII Status: up`, `Speed: 10000 Mbps`.
- Ping to `10.20.0.1`: 3 sent, 3 received, 0% loss.
- **Failover test 1 (vA down):** my first read happened instantly and still showed `vA` active with all `MII Status: up`, because `miimon` polls every 100 ms. After `vA up`, the file showed active `vB` and `Link Failure Count: 1` on vA, so the failover had happened.
- **Failover test 2 (vB down, with `sleep 1`):** active slave changed from `vB` to `vA`; vB showed `MII Status: down`, `Link Failure Count: 1`. After `vB up`, `vA` stayed active (no switch-back, because no primary is set).
- **Overlapping ping test:** ping running to `10.20.0.1`, then `vA down`, `sleep 1`, read bond file: active slave `vB`. Ping summary: **27 sent, 27 received, 0% loss.**

**Cleanup**
- Deleted all four namespaces and `br0`. `netns list` empty, `br0` does not exist, `ens5` still `172.31.10.100/20`. SSH never touched.

**Lessons I saw with my own eyes**
1. "Interface UP + correct IP + traffic fails" on a bridge means check `bridge link` for a missing port.
2. Bond state lags a link change by up to the `miimon` interval. Wait about 1 second before reading it.
3. Without a `primary`, the bond does not switch back after a failed link recovers.
4. Always compare `ens5` before and after.

---

## Part C: Troubleshooting table

| You see | Meaning | Fix |
|---|---|---|
| `Operation not permitted` | Missing sudo | Add `sudo` |
| `RTNETLINK answers: File exists` | You re-ran without cleanup | Run cleanup, then redo |
| `Cannot find device "veth1"` | Typo, or it already moved into a namespace | Check the name; look inside with `sudo ip netns exec ns1 ip link` |
| `Device or resource busy` when joining the bond | Interface is still up | `ip link set <iface> down` first |
| `/proc/net/bonding/bond0: No such file` | Module not loaded, or wrong namespace | `sudo modprobe bonding`; use `ip netns exec nsb` |
| Bridge lab works, bond ping fails | nsc side isn't up | Recheck that `brc`, `vA-p`, `vB-p` are all UP |
| Interface UP, IP correct, ping fails (bridge) | Port missing from the bridge | `bridge link`, then `ip link set <port> master br0` |
| Bond still shows old active slave right after a link down | `miimon` polling delay | Wait about 1 second, then re-read |
| Ping fails and Docker is installed | Docker's firewall rules interfere | `sudo iptables -L FORWARD -n` |

---

## Part D: Interview questions with answers

### Basics

**1. What is a network namespace, and why use one for labs?**
A separate network environment inside one machine, with its own interfaces, IPs, routes and firewall rules, sharing the host kernel. It lets you build multi-"machine" networks without VMs and without risking your real network.

**2. What is a veth pair?**
A virtual Ethernet cable with two ends. Traffic entering one end comes out the other. Usually one end goes into a namespace and the other into a bridge or another namespace.

**3. What does `ip netns exec ns1 ping 10.10.0.2` mean?**
Run the `ping` command inside the `ns1` namespace, using ns1's interfaces and routing.

**4. What is a Linux bridge?**
A virtual layer-2 switch. Interfaces attached with `master br0` become ports, and the bridge forwards Ethernet frames between them by learning MAC addresses.

**5. What is a bond?**
Several interfaces combined into one logical interface for redundancy (failover) and/or more throughput, depending on the mode.

### Troubleshooting

**6. A customer says "the interface is UP and has the right IP, but it can't reach its neighbour through a bridge." What do you check?**
Whether the port is actually attached to the bridge: `bridge link` or `ip -br link show master br0`. A missing port looks healthy on the interface itself but traffic fails. Fix: `ip link set <port> master br0`. Then check the bridge itself is up, and firewall rules.

**7. Bridge traffic is blocked and Docker is installed. Where do you look?**
Docker's iptables rules, for example `sudo iptables -L FORWARD -n`. Bridged traffic can be dropped by FORWARD policy or Docker chains.

**8. You get `Device or resource busy` when adding an interface to a bond. Why?**
The interface is still up. Set it down first (`ip link set <iface> down`), then enslave it, then bring the bond up.

**9. `/proc/net/bonding/bond0` doesn't exist. What now?**
Either the bonding module isn't loaded (`sudo modprobe bonding`; on some kernels `linux-modules-extra-$(uname -r)` is needed), or you're looking in the wrong namespace (use `ip netns exec nsb ...`).

**10. You took the active bond member down and the file still shows it as active. Is failover broken?**
Probably not. Link state is detected by polling (`miimon 100` = every 100 ms), so the file can lag. Wait about a second and read again. I saw exactly this in my lab.

**11. After a failed link comes back, the bond doesn't switch back to it. Is that a bug?**
No. With `Primary Slave: None` no member is preferred, so the bond stays on the current active one. To prefer a member, set the `primary` option (with `primary_reselect` controlling when to switch back).

**12. What does `Link Failure Count` tell you?**
How many times that member's link has gone down. A rising count on one member points to a flaky cable, port or NIC.

### Bond modes and design

**13. Which bond mode needs switch cooperation?**
802.3ad (LACP). The switch ports must be configured as a LACP group. `active-backup` and `balance-alb` need no special switch configuration.

**14. Explain active-backup.**
One member carries traffic, the others wait. If the active one fails, a backup takes over automatically. Simple and works with any switch, but only one link's bandwidth is used at a time.

**15. What does `miimon 100` do, and what's the trade-off?**
It checks each member's link state every 100 ms. A lower value detects failures faster but polls more often; a higher value is lighter but slower to notice. It detects link-level failure only, not a broken path further away (ARP monitoring can cover that).

**16. Why did the far side of my bond lab use a bridge (`brc`)?**
Both cables ended in the same namespace, and they needed to appear as one IP/network to the bond. The bridge joined both cable ends under `10.20.0.1`. It was scaffolding for the test, not the topic being studied.

### Scenario (Canonical-style support)

**17. A customer reports "our server lost network for a few seconds, then recovered by itself, and now only one NIC is carrying traffic." How would you investigate?**
- Check bond mode and state: `cat /proc/net/bonding/<bond>`.
- Look at which member is active and each member's `MII Status`.
- Check `Link Failure Count` for a flapping member.
- Check kernel logs for link up/down events (`dmesg`, `journalctl -k`).
- Explain that active-backup failing over and not switching back is expected behaviour, and offer a `primary` setting if they want a preferred NIC.
- If a member keeps flapping, look at the cable, switch port, or NIC/driver.

**18. How do you make sure a lab doesn't damage your real connection?**
Work only on newly created interfaces and namespaces, never modify `ens5`, record `ip -br addr` before and after, and always run cleanup.

---

## Part E: Self-check

### Correct answers (clean version)

| # | Question | Correct answer |
|---|---|---|
| 1 | Which command shows which ports are attached to a bridge? | `bridge link` (or `ip -br link show master br0`). To change membership: `ip link set <port> master br0`. |
| 2 | Why must bond members be down before joining? | The kernel can refuse to enslave an interface that is still up (`Device or resource busy`), and joining a bond changes how the interface is configured. Order: member down, join the bond, bring the bond up. |
| 3 | Which bond mode needs the switch configured? | **802.3ad (LACP)**. The switch ports must be set up as a matching LACP group. `active-backup` and `balance-alb` need no switch configuration. |
| 4 | Why can the bond file show the old active slave right after a link goes down? | Link state is polled every `miimon` interval (100 ms), so the file can lag. Wait about 1 second and read again. |
| 5 | Why doesn't the bond switch back after the original link recovers? | No `primary` is configured (`Primary Slave: None`), so no member is preferred. Set `primary` (and `primary_reselect`) if you want it to switch back. |

---

### My answers, graded

### 1. Which command shows which ports are attached to a bridge?
- **My answer:** `bridge link` or `ip link set`.
- **Grade:** half right.
- `bridge link` is correct.
- `ip link set` is wrong. It **changes** things (like `master br0` or `nomaster`); it doesn't show anything.
- **Correct answer:** `bridge link`, or `ip -br link show master br0`. To change membership you use `ip link set <port> master br0`.

### 2. Why must bond members be down before joining?
- **My answer:** so there is no locking out of the instance or VM.
- **Grade:** not right.
- **Correct answer:** the kernel can refuse to add an interface that is still up (`Device or resource busy`), and joining a bond changes how the interface is configured (the bond takes control of it). So the rule is: set the member down, join it to the bond, then bring the bond up.
- **Where the lockout idea does belong:** the golden rule. Never use your SSH interface (`ens5`) for these experiments, because changing it can cut your connection. That's a separate safety rule, not the reason for "down first".

### 3. Which bond mode needs the switch configured?
- **My answer:** switch configured to connect both instances with one another.
- **Grade:** the idea is close, but I didn't name the mode and the reason is off.
- **Correct answer:** **802.3ad (LACP)**. The switch ports must be set up as a matching LACP group so the switch treats both links as one logical link. It has nothing to do with connecting instances to each other. `active-backup` and `balance-alb` need no switch configuration.

### 4. Why can the bond file show the old active slave right after a link goes down?
- **My answer:** polling delay, gone after a second. (My extra sentence, "so that we can connect to them and the connection is not lost", is wrong.)
- **Grade:** the first part is correct.
- **Correct answer:** link state is checked by polling every `miimon` interval (100 ms), so the file can lag behind for a moment. Wait about a second and read again.
- **Fix to the extra sentence:** the stale display is just a lag, not a feature. The connection stays alive because the bond **fails over** to the other member, not because the file shows the old state.

### 5. Why doesn't the bond switch back after the original link recovers?
- **My answer:** I didn't answer this one separately (my last sentence repeated question 4).
- **Correct answer:** no `primary` is configured (`Primary Slave: None`), so no member is preferred. The bond stays on the member that's currently active. To prefer one NIC, set the `primary` option (and `primary_reselect` to control when it switches back).


Memory lines to fix the gaps:
1. **Show** = `bridge link`. **Change** = `ip link set`.
2. **Down first** because the kernel refuses an up interface (`busy`), not because of lockout. Lockout is why we never touch `ens5`.
3. **LACP needs the switch.** Active-backup and balance-alb don't.
4. **Stale read** = `miimon` polling lag. Wait about 1 second.
5. **No switch-back** = no `primary` set.