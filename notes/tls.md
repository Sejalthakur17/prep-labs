# TLS notes

## Commands
openssl s_client -connect HOST:443 -servername HOST </dev/null    # full handshake
echo | openssl s_client -connect HOST:443 -servername HOST 2>/dev/null \
  | openssl x509 -noout -dates -subject -issuer                   # the facts
... | openssl x509 -noout -checkend 2592000; echo $?              # expires within 30 days? (0 = no)
curl -vI https://HOST 2>&1 | grep -E "subject|expire|issuer|verify|HTTP/"   # curl's view
-servername = SNI, tells the server which certificate to send
</dev/null or echo | = lets s_client exit instead of waiting for input

## example.com on 19 Nov 2026
subject:   CN=example.com (also covers *.example.com)
issuer:    Cloudflare TLS Issuing ECC CA 3 (O=SSL Corporation)
notBefore: Sep 26 2026 22:49:11 GMT
notAfter:  Dec 25 2026 22:56:35 GMT  (about 36 days left)
checkend 30 days: "Certificate will not expire", exit code 0
Verification: OK / Verify return code: 0 (ok)
Protocol TLSv1.3, cipher TLS_AES_256_GCM_SHA384, key group X25519MLKEM768
Key: EC prime256v1 (256 bit)

## Certificate chain (4 levels)
0 example.com                          <- the site's certificate
1 Cloudflare TLS Issuing ECC CA 3      <- intermediate
2 SSL.com TLS Transit ECC CA R2        <- intermediate
3 SSL.com TLS ECC Root CA 2022         <- root, trusted by my machine
Each certificate is signed by the one below it. depth=0 is the site, highest depth is the root.
Trust store on this machine: /etc/ssl/certs/ca-certificates.crt

## What I noticed
- Short-lived certificate: valid only ~90 days, so renewals must be automatic.
- curl tried IPv6 first: "Network is unreachable" (EC2 has no IPv6 here),
  then fell back to IPv4 (104.20.23.154) and worked. Not an error.
- curl: ALPN offered h2,http/1.1. TLS 1.3 handshake steps visible:
  Client hello, Server hello, Encrypted Extensions, Certificate, CERT verify, Finished.
- My first curl command was cut off by head -30 before "SSL certificate verify ok"
  and the HTTP status, so I use grep for the useful lines instead.

## Verify return codes
0   ok
18  self-signed certificate        (seen on self-signed.badssl.com)
10  certificate has expired        (to retest, see below)
62  hostname mismatch              (to retest, see below)
19  self-signed certificate in chain

## Still to retest
expired.badssl.com and wrong.host.badssl.com both returned code 0 for me, not 10 and 62.
Check what they serve now:
echo | openssl s_client -connect expired.badssl.com:443 -servername expired.badssl.com 2>/dev/null | openssl x509 -noout -dates -subject
Reliable alternative on example.com:
echo | openssl s_client -connect example.com:443 -servername example.com -attime $(date -d '2027-01-01' +%s) 2>&1 | grep "Verify return"
echo | openssl s_client -connect example.com:443 -servername example.com -verify_hostname notexample.org 2>&1 | grep "Verify return"

## "My site shows a security warning" checklist
1. Command 2: is notAfter in the past? (expired)
2. Does subject / SAN match the exact hostname the user types? (mismatch)
3. Command 1: read Verify return code and the chain (self-signed, missing intermediate, untrusted root)
4. Check the client's clock and CA store (an old OS may not trust a new root)
