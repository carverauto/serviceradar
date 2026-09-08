---
title: Outbound Mail
---

# Outbound Mail

ServiceRadar has one outbound mailer. Alert email, dashboard reports, and
account email (password reset, confirmation) all go through it.

Configure it in the Web UI. Open **Settings -> Mail** (`/settings/mail`).
You need the `settings.mail.manage` permission (built-in `admin` has it).

Turn **Enable outbound mail** on and save. That row overrides whatever the
pods inherited from the environment. Leave it off and the process falls back
to Helm / `SMTP_RELAY_*` env, which in a default install is the Test adapter
(see below).

:::warning Do not put SMTP passwords in Helm values
A password in `values.yaml` is a password in the Helm release, in
`helm get values`, and in GitOps. Create the mailbox on your mail server,
then paste the username and password into **Settings -> Mail**. The UI
stores the password encrypted (or in a credential secret you select).
:::

## Local vs Test vs SMTP

The **Adapter** field is the whole product decision. These three look similar
in the dropdown and do completely different things:

| Adapter | Leaves the cluster? | What "success" means | When to use it |
| --- | --- | --- | --- |
| **Local** | No | The message is filed in an in-memory mailbox on **that pod** | A single-process `mix phx.server` so you can read `/dev/mailbox` |
| **Test** | No | The adapter always returns success and **discards** the message | Automated tests only. Never a real deployment |
| **SMTP** | Yes, to the relay you configure | The mail server accepted the message (not the same as the recipient reading it) | Production, and any lab that should hit a real inbox |

The other dropdown entries (Mailgun, SendGrid, Postmark, Amazon SES, and
similar) are HTTP API providers. They also leave the cluster. Fill
**Provider options JSON** with that vendor's keys (`api_key`, `domain`,
`region`, ...) instead of SMTP relay fields.

### Why Test and Local are dangerous in production

Both return `ok`. An email notification channel pointed at either one
reports every delivery as `sent` and pages nobody. That looks exactly like a
working channel until an incident.

ServiceRadar therefore refuses to validate an email notification channel
while the resolved adapter is Test or Local
(`OutboundMail.diagnose/0` class `non_delivering_adapter`). Fix it here
before you try to save the channel.

A default install with **Enable outbound mail** off and no Helm relay
resolves to Test. That is intentional: the deployment must not pretend to
mail until someone configures SMTP.

### Local

Local uses Swoosh's in-process mailbox. Nothing is handed to Postfix,
Docker Mailserver, or Google.

- In a **single-process** development server with `SERVICERADAR_DEV_ROUTES`
  enabled, captured messages are at `/dev/mailbox`.
- In a **clustered** deployment each pod has its own memory. Mail saved on
  replica A is invisible on replica B, and a restart wipes it. The runtime
  will not enable the local adapter when clustering is on.

### Test

Test is a stub. Every send returns `ok`. The body is not stored and not
delivered. Do not select it unless you are writing tests.

### SMTP

SMTP opens a TCP connection to **SMTP relay / endpoint** and authenticates
with the username and password you save.

Use this for a real mailbox: in-cluster Docker Mailserver, Microsoft 365,
Google Workspace, or any submission service that speaks SMTP.

"Accepted by the mail server" is as far as ServiceRadar can see. Bounces,
spam folders, and downstream relay failures show up on the mail server, not
in the Save Settings flash.

## Configure SMTP in the UI

1. Sign in as an administrator.
2. Go to **Settings -> Mail**.
3. Check **Enable outbound mail**.
4. Set **Adapter** to `SMTP`.
5. Set **From name** and **From email**. The From address must be an identity
   your mail server will accept (see [Spoof protection](#spoof-protection)).
6. Fill the SMTP fields. Two common layouts:

   **Implicit TLS (port 465)** — typical for Docker Mailserver and many
   hosted submission endpoints:

   | Field | Value |
   | --- | --- |
   | SMTP relay / endpoint | hostname of the mail server, for example `mail.example.com` |
   | Port | `465` |
   | SMTP hostname | same hostname (EHLO and TLS server name) |
   | Username | the mailbox, for example `alerts@example.com` |
   | Auth | `Always` |
   | TLS | `Never` |
   | Use SSL socket | checked |

   **STARTTLS (port 587)**:

   | Field | Value |
   | --- | --- |
   | SMTP relay / endpoint | hostname of the mail server |
   | Port | `587` |
   | SMTP hostname | same hostname |
   | Username | the mailbox |
   | Auth | `Always` |
   | TLS | `Always` |
   | Use SSL socket | unchecked |

7. Leave **Password secret** on **Local encrypted value** unless you already
   store the SMTP password as a network credential. Paste the mailbox
   password into **Password**.
8. Leave **API key** empty for SMTP.
9. Click **Save Settings**.
10. Click **Validate Runtime Config**. That only checks the saved settings
    can be turned into a mailer config. It does **not** send a message.
11. Prove delivery with a real send: an email notification channel's
    **Test** button, or a dashboard report. Confirm the message arrives.

Then create an `email` notification channel under
**Settings -> Notifications**. The channel will not validate until this
page resolves to a delivering adapter. See [Notifications](./notifications.md).

### Field reference

| Field | What it is |
| --- | --- |
| Enable outbound mail | Master switch. Off means this page is ignored and senders use the process mailer (Helm / env, usually Test). |
| Adapter | Local, Test, SMTP, or an HTTP provider. |
| From name / From email | Envelope display name and address. |
| SMTP relay / endpoint | Host ServiceRadar connects to. |
| Port | Submission port. `465` or `587` in almost every setup. Port `25` is server-to-server, not authenticated submission. |
| SMTP hostname | Name announced in EHLO and used for TLS. Set it to the relay hostname. |
| Username | SMTP AUTH user. Usually the full mailbox address. |
| Auth | `Always` for any mailbox that requires a password. `If available` / `Never` are for open lab relays only. |
| TLS | STARTTLS policy. `Always` on 587. `Never` when **Use SSL socket** is on (465). |
| Use SSL socket | Implicit TLS from the first byte. Check this for 465. |
| Retries | How many times Swoosh retries a failed SMTP handshake. Default `1`. |
| Password secret / API key secret | Optional pointer at a credential from **Settings -> Networks -> Credential Rules** (`/settings/networks/credentials`). Empty means "use the Password / API key box on this form". |
| Password / API key | Stored encrypted. The form will not show the saved value again; a `(saved)` label means one is present. |
| Provider options JSON | Extra keys for HTTP adapters. Leave `{}` for SMTP. |

## Credentials

Two ways to hold the SMTP password:

1. **Local encrypted value** (default). Paste the password into **Password**
   and save. ServiceRadar encrypts it in the `outbound_mail_settings` row.
   Fine for a dedicated outbound mailbox.
2. **Password secret**. Create the secret under **Settings -> Networks ->
   Credentials**, then select it here. Use this when several features should
   share one vault-backed secret.

## Spoof protection

Many mail servers (including Docker Mailserver with `SPOOF_PROTECTION=1`)
reject a From address that does not match the authenticated user.

If you authenticate as `alerts@example.com`, set **From email** to
`alerts@example.com`. Using `noreply@example.com` on that mailbox will be
accepted by ServiceRadar and refused by the mail server.

## What uses these settings

When **Enable outbound mail** is on:

| Feature | Uses this page? |
| --- | --- |
| Email notification channels | Yes |
| Dashboard report email | Yes |
| Password-reset and confirmation email from the identity senders | Yes |

When the toggle is off, those same features fall back to the process mailer
(Helm `core.mailer` / `SMTP_RELAY_*`). A missing settings row is not an
error; it means "no operator override".

The Helm fallback is documented under
[Kubernetes (Helm)](./helm-configuration.md#outbound-mail) for automation.
Prefer this page for day-to-day operation.

## Troubleshooting

- **Email channel will not validate.** `OutboundMail.diagnose` is not `:ok`.
  Usually Test/Local (`non_delivering_adapter`) or SMTP with no relay
  (`smtp_relay_missing`). Enable SMTP here and save.
- **Validate Runtime Config succeeds, inbox is empty.** Validation does not
  send mail. Use a notification channel Test send or a dashboard report.
  Then check the mail server logs for the authenticated user.
- **Channel or report looks successful, nobody was paged.** Adapter is Test
  or Local. The email transport now refuses to validate that state; older
  saved channels can still be pointed at it.
- **Auth failed / 535.** Wrong username or password, or Auth is not
  `Always`.
- **TLS / handshake errors.** Port and TLS mode disagree. 465 + SSL socket
  + TLS Never, or 587 + TLS Always + SSL socket off.
- **Sender rejected / 553 / spoof.** From email does not match the mailbox.
- **Timeout from the web-ng or core pod.** The pod cannot reach the relay
  host on that port. Check DNS, NetworkPolicy egress, and that you used a
  hostname the cluster can resolve.
- **Settings page missing.** Your role lacks `settings.mail.manage`. See
  [Roles & Permissions](./rbac-and-roles.md).

## Related

- [Notifications](./notifications.md) — email channels, test send, delivery
  log
- [Self-Authored Dashboards](./self-authored-dashboards.md) — scheduled
  reports
- [Authentication](./auth-configuration.md) — password-reset links
- [Kubernetes (Helm)](./helm-configuration.md#outbound-mail) — env fallback
  only
