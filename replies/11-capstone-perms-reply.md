# Customer reply: Extra capstone run (403 Forbidden)

**Ticket:** Our website shows 403 Forbidden
**Related incident:** `incidents/11-capstone-perms.md`

**Subject: Resolved: your website was showing "403 Forbidden"**

Hi,

Thanks for reporting this. Your website was showing a "403 Forbidden" message because of a permission setting on the folder that holds your web pages. The web server was running, but the setting only allowed the main administrator account to open that folder, so the web server was turned away.

I changed the folder's permission so the web server can read it again. Your page now loads normally, both from the server itself and from the internet.

I cannot tell how the setting changed. If anyone ran a clean-up, a deployment or a permission change on the server around 05:54 UTC today, that is the likely source. Let me know and I can help make sure it does not happen again.

To avoid a repeat, check that the web server can read your website's folder after any update, and consider an automatic check that alerts you if the site stops loading normally.

Please reply if you notice anything else.

Kind regards,
Sejal Thakur