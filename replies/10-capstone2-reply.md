# Customer reply: Capstone 2

**Ticket:** Our website is down and will not load
**Related incident:** `incidents/10-capstone2.md`

**Subject: Resolved: your website is back online**

Hi,

Thanks for reporting this, and I am sorry for the disruption. Your website was unavailable for about 6 minutes (from about 05:44 to 05:50 UTC today). It was down because the web server software could not start. One of its settings files contained a line it did not recognise, and the server refuses to start when its settings contain an error.

I removed that line, checked that the settings were valid, and started the server again. Your website now loads normally, both from the server itself and from the internet.

I cannot tell how the line got there. If you or your team edited the website's settings shortly before 05:44 UTC today, that is the likely source. Let me know and I can help make sure it does not happen again.

To avoid a repeat, run the web server's built-in settings check before restarting it, and keep a backup copy of the file, stored outside the website's settings folder, before editing it.

Please reply if you notice anything else.

Kind regards,
Sejal Thakur