# Customer reply: Capstone 1

**Ticket:** Server seems wrong, but the website loads
**Related incident:** `incidents/09-capstone1.md`

---

**Subject:** Resolved: your server's storage was full

Hi,

Thank you for reporting this. I understand it is worrying when a server behaves strangely, even if the website still loads.

**What I found**
Your server's main storage had filled up completely. Only about 48 MB of 6.7 GB was free. A single large file, about 3.1 GB, was taking up almost half of the disk.

This is why the website still loaded: showing an existing page only reads from storage. But a full disk stops the server from saving anything new, such as log files, uploads, software updates or temporary files. That is likely what you noticed

**What I did**
I identified the large file and checked that no running program was using it. Before removing it, I noted its details so we can trace where it came from: the file is /var/fill, 3.1 GB, created at 07:13 UTC today. I then removed it. The server now has about 3.1 GB free (54% of the disk in use).

**How I checked it works**
- The website loads normally from outside our network.
- I created and deleted a test file on the server, which confirms it can save data again.

**What I do not know**
I cannot tell how the large file was created. If you or your team ran a backup, an export or a large download around 07:13 UTC today, that may be the source. If you can tell me what ran then, I can help stop it from happening again.

**What I recommend**
- Set up an alert when disk usage reaches about 80%, so you have warning before it fills up.
- Make sure log files are rotated, so they cannot grow without limit.
- If you store large amounts of data, keep it on a separate disk from the main system.

If you notice any problem, reply to this message and I will look at it right away.

Kind regards,
Sejal Thakur
