# Incident 03: TLS certificate warnings

## Symptom
Clients refuse to connect over HTTPS: curl error 60, or a browser security warning.

## Environment
- Ubuntu 26.04.1 LTS on AWS EC2 (`lab1`, ap-south-1), nginx 1.28.3
- Test site `lab.local` on port 443, tested locally with `curl --resolve`
- Certificates built with openssl: Root CA -> Intermediate CA -> leaf (`lab.local`)

## Diagnosis
Command:

```bash
echo | openssl s_client -connect HOST:443 -servername NAME -CAfile root.pem 2>&1 | grep -E "verify error|Verify return"
```

| Code | Meaning | What I saw in the lab |
|---|---|---|
| 0 | OK | healthy chain (fullchain.pem) |
| 10 | certificate expired | `faketime -f '+400d'`; error printed 3 times (leaf, intermediate, root all past expiry) |
| 62 | hostname mismatch | asked for `other.local`, certificate says `lab.local` |
| 20 / 21 | issuer unknown / chain incomplete | nginx served the leaf only; curl showed 20, s_client ended on 21 |
| 18 | self-signed certificate | default `cert.pem`, not trusted by curl |

## Root cause and fix
- **Expired:** renew the certificate, reload nginx.
- **Wrong name:** reissue with the correct `subjectAltName`, or use the right hostname.
- **Incomplete chain:** build `fullchain.pem` (leaf first, then intermediate), point `ssl_certificate` at it, reload nginx.

```bash
sudo sh -c 'cat leaf.pem int.pem > fullchain.pem'
# nginx: ssl_certificate     /etc/ssl/lab/fullchain.pem;
#        ssl_certificate_key /etc/ssl/lab/leaf.key;
sudo nginx -t && sudo systemctl reload nginx
```

Verify the chain is really sent:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername lab.local -showcerts 2>/dev/null | grep -E "^ *[0-9] s:|^ *i:"
```

Expected: leaf issued by the intermediate, then the intermediate issued by the root.

## Mistakes I made (and what they taught me)
- Pointed `ssl_certificate_key` at the certificate (`leaf.pem`) instead of the private key (`leaf.key`). `nginx -t` failed, nginx went down on restart, and every other site on the server went down with it. Always run `nginx -t` before restarting, and confirm the sites come back afterwards.
- A failed `nginx -t && reload` means the old config keeps running, so test results can come from the old setup. Check which certificate is actually being served.
- `faketime '+400d'` fails; the correct form is `faketime -f '+400d' <command>`.
- After a reload, wait a moment and retest before concluding a fix did not work.

## Prevention
- Calendar reminder 30 days before certificate expiry.
- Test with a real client and a real CA file, never only with `curl -k` (it hides every problem above).
- Check the chain with `s_client -showcerts` after every certificate change.
- Run `nginx -t` before every reload or restart.

## Customer reply
Your visitors see a warning because the site's security certificate, like an ID card, expired on <expiry date>. Browsers refuse expired IDs to protect people. Renewing the certificate and reloading the web server fixes it. After renewing, open the site and check the padlock. Set a reminder 30 days before the next expiry.
