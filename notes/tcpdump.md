# tcpdump notes

tcpdump shows the raw packets on a network interface. Needs sudo.

## Commands I used
sudo tcpdump -nn -i any port 53 -w dns.pcap   # capture DNS to a file
sudo tcpdump -nn -r dns.pcap                  # read a saved capture
sudo tcpdump -nn -i lo port 80                # watch HTTP on loopback
sudo ss -tlnp | grep ':80 '                   # who is listening on port 80?

## Flags
-nn      no name lookups (show IPs and port numbers)
-i any   all interfaces      -i lo = loopback only
port N   filter by port      (DNS = 53, HTTP = 80)
-w file  write packets to a file     -r file  read them back
Ctrl+C   stops the capture and prints "N packets captured"

## DNS capture (dig example.com, dig github.com) = 8 packets, 4 per name
1 lo   127.0.0.1 -> 127.0.0.53:53   dig asks the local resolver (systemd-resolved)
2 ens5 172.31.10.100 -> 172.31.0.2:53   resolver forwards to AWS DNS
3 ens5 172.31.0.2 -> 172.31.10.100      answer: A 172.66.147.243, A 104.20.23.154
4 lo   127.0.0.53 -> 127.0.0.1          resolver hands the answer back to dig
- 172.31.0.2 = the AWS VPC DNS server (VPC network address + 2)
- lo = traffic inside my own machine; ens5 = the real network card
- query ID in tcpdump (47921) matches "id: 47921" in the dig output
- "+" after the ID = recursion desired; 2/0/1 = 2 answers, 0 authority, 1 extra
- "promiscuous mode" and "interface names" warnings are harmless with -i any

## Healthy TCP connection to nginx on port 80 (curl http://127.0.0.1)
[S] [S.] [.] then [P.] GET / HTTP/1.1, [.], [P.] HTTP/1.1 200 OK, [.], [F.] [F.] [.]

## Nginx stopped (connection refused)
[S] followed instantly by [R.]  (RST = "nothing is listening here")
curl: (7) Failed to connect ... Connection refused    exit code 7

## Reading ss output
0.0.0.0:80 = listening on all IPv4 addresses
[::]:80    = listening on all IPv6 addresses
Several nginx PIDs = worker processes sharing the same socket

## Not tested yet
- A second dig within the TTL: expect only the lo lines (answered from cache)
- tcpdump -nn -i any host <IP> (all traffic to or from one IP)
