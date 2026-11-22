# Incident 05: MTU, bond and bridge faults
**Date:** 21 Nov

Environment: Ubuntu on AWS EC2, Linux network namespaces, veth pairs.

## Fault (a): MTU mismatch
Symptom:     small ping works; ping -M do -s 1472 gets 100% loss, no error
Commands:    ip link set veth1 mtu 1400; ping -M do -s 1472 / 1372 / 1373 ...
Evidence:    tcpdump on br0 shows echo requests (length 1480) with no replies;
             small pings show request/reply pairs
Note:        probing showed the cutoff at 1404 bytes of IP packet size
             (equal to ping -s 1376 plus 28 bytes of headers), not exactly 1400.
             Lesson: find the real limit by probing with ping -M do -s, don't
             trust the configured number.
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
Topology:    cli [c0 10.30.1.2/24] --- [r0 10.30.1.1/24] rtr
             [r1 10.30.2.1/24] --- [s0 10.30.2.2/24] srv
             ip_forward=1 on rtr; default routes via the router on cli and srv;
             MTU 1400 on r1 and s0; DROP rule added on cli.
Symptom:     small pings work; ping -M do -s 1472 gets 100% loss, no error message
Commands:    iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j DROP
             (on cli); tcpdump -nn -i c0 icmp; iptables -L INPUT -v -n
Evidence:    tcpdump on cli shows each echo request (length 1480) followed by
             "need to frag (mtu 1400)" from 10.30.1.1; DROP rule counter reached
             6 packets / 3456 bytes (3 + 3 across two runs of the big ping;
             576 bytes per ICMP error)
Root cause:  firewall on the sender drops ICMP type 3 code 4, so Path MTU
             Discovery never learns the 1400 limit
Fix:         removed the DROP rule; flushed route cache; ping shows
             "Frag needed ... mtu = 1400" again
Note:        after the router reported mtu 1400, the client cached it: -s 1372
             (1400 bytes) passed and -s 1373 (1401 bytes) was refused locally
             ("Message too long"). The strict limit comes from the router's
             1400 setting, learned via the ICMP message. To test the router
             itself, flush the route cache first, then ping with -s 1373.

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

Check: why do small requests work while big downloads hang? Small packets fit
under the 1400-byte limit. Big ones don't, are dropped, and no error reaches
the sender, so the download stalls.

## Customer reply

**MTU mismatch / blocked "packet too big" messages**
Thanks for the details. Web pages load but large downloads freeze because one
link on the path can only carry smaller packets than the others, and larger
ones are silently dropped. We matched the packet size on both ends (and
allowed the firewall to pass the "packet too big" messages that tell your
server to send smaller ones). Please retry a large download.

**Bond with a dead member**
Your server is working normally, but one of its two network connections lost
its link, so it is running with no spare. The backup took over automatically,
so you saw no interruption. Please check the cable or switch port for that
connection. Once it is back, redundancy is restored.

**Bridge missing a port**
The network card on one machine looks connected, but it was no longer attached
to the virtual switch that links your machines, so traffic could not pass. We
reattached it and the connection works again.