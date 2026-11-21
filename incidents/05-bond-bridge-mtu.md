# Incident 05: MTU, bond and bridge faults

Environment: Ubuntu on AWS EC2, Linux network namespaces, veth pairs.

## Fault (a): MTU mismatch
Symptom:     small ping works; ping -M do -s 1472 gets 100% loss, no error
Commands:    ip link set veth1 mtu 1400; ping -M do -s 1472 / 1372 / 1373 ...
Evidence:    tcpdump on br0 shows echo requests (length 1480) with no replies;
             small pings show request/reply pairs
Note:        probing showed the cutoff was 1404 bytes, not exactly 1400. The Linux
             bridge likely allows a few bytes of slack above the port MTU. Lesson:
             find the real limit by probing with ping -M do -s, don't trust the
             configured number.
Root cause:  MTU on veth1 reduced to 1400, larger packets silently dropped
Fix:         ip link set veth1 mtu 1500; big ping works again

## Fault (b): bond with a dead member
Symptom:     none for users; 189 packets sent, 189 received (0% loss) across the
             failover; redundancy gone
Commands:    ip link set vB down (active slave); cat /proc/net/bonding/bond0
Evidence:    Currently Active Slave switched vB -> vA; vB MII Status: down
Root cause:  one bond member lost link; active-backup failed over to the standby
Fix:         ip link set vB up; vB rejoins as standby (no primary configured)
Note:        the bonding file updates within one miimon interval (100 ms), so
             sleep 1 before reading it, or you may see stale state.

## Fault (c): bridge missing a port
Symptom:     ping ns1 to ns2 gets 100% loss, even small pings; ns2's veth2 still
             shows UP with its IP
Commands:    ip link set veth2-br nomaster; ping; bridge link; ip -br addr (in ns2)
Evidence:    bridge link lists only veth1-br; veth2-br is absent
Root cause:  veth2-br was no longer a member of br0
Fix:         ip link set veth2-br master br0; ping works again (0% loss)

## Fault (d): firewall blocks ICMP "fragmentation needed"
Symptom:     small pings work; ping -M do -s 1472 gets 100% loss, no error message
Commands:    iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j DROP
             (on cli); tcpdump -nn -i c0 icmp; iptables -L INPUT -v -n
Evidence:    tcpdump on cli shows each echo request (length 1480) followed by
             "need to frag (mtu 1400)" from 10.30.1.1; DROP rule counter reached
             6 packets / 3456 bytes across two runs of the big ping
Root cause:  firewall on the sender drops ICMP type 3 code 4, so Path MTU
             Discovery never learns the 1400 limit
Fix:         removed the DROP rule; flushed route cache; ping shows
             "Frag needed ... mtu = 1400" again
Note:        a router enforces MTU strictly (1400 passed, 1401 failed), unlike the
             bridge in Fault (a), which let 1404 bytes through

## Comparison

| Fault | What users see | Tell-tale sign |
|---|---|---|
| MTU mismatch | Small works, big hangs | Works until you add -M do -s 1472 |
| Dead bond member | Nothing, just lost redundancy | MII Status: down in bonding file |
| Bridge missing a port | Everything to that host fails | Port absent from bridge link |
| Firewall drops ICMP type 3 code 4 | Small works, big hangs, no error | tcpdump shows ICMP arriving, firewall counter rising |

## Key lesson
(a) and (d) both look like "small works, big hangs". In (a) nothing sends an
error. In (d) the router does send "Frag needed", tcpdump shows it arriving, and
the firewall counter shows it being dropped. Never block all ICMP; allow type 3.
