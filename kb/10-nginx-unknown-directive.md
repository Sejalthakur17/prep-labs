# KB article: nginx fails to start with "unknown directive"

## Title

nginx fails to start: `unknown directive` in a configuration file

## Environment

- Ubuntu Server (tested on 26.04 LTS), AWS EC2
- nginx 1.28.x mand will not load
**Related incident:** `incidents/10-capstone2.md`

**Subject: Resolved: your website is back online**

Hi,

Thanks for reporting this. Your website was down because the web server software could not start. One of its settings files contained a line it did not recognise, and the server refuses to start when its settings contain an error.

I removed that line, checked that the settings were valid, and started the server again. Your website now loads normally, both from the server itself and from the internet.

I cannot tell how the line got there. If you or your team edited the website's settings shortly before about 05:44 UTC today, that is the likely source. Let me know and I can help make sure it does not happen again.

To avoid a repeat, run the web server's built-in settings check before restarting it, and keep a backup copy of the file before editing it.

Please reply if you notice anything else.

Kind regards,
Sejal